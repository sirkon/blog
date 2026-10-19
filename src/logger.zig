const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts.zig");
const encoding = @import("encoding.zig");
const crc32c = @import("crc32c.zig");
const diag_mod = @import("diag.zig");

/// A thin cursor over the record payload, shared with the diagnostics encoder.
const LogFrame = encoding.Frame;

/// Width in bytes of a log header for a payload of `payload_len` bytes:
/// `0xFF + CRC32C(4) + 0xFE + uvarint(payload_len)`.
/// Matches the Go encoder in `internal/core/logger.go`.
pub fn headerWidth(payload_len: usize) usize {
    const bits_len: usize = if (payload_len == 0) 0 else 64 - @clz(payload_len);
    return 6 + (bits_len + 6) / 7;
}

/// Clock read used for every record timestamp. CLOCK_REALTIME is always 0
/// in the Linux ABI.
///
/// With libc linked the call goes through the C library, which serves it
/// from the vDSO (a few nanoseconds). Calling `std.os.linux.clock_gettime`
/// instead would fall back to a real syscall on every record: its vDSO
/// lookup goes through `getauxval`, which resolves to glibc's version, and
/// Zig's own `_start` never runs `__libc_start_main`, so glibc's auxv copy
/// stays empty and the lookup fails permanently. Without libc, Zig's start
/// code populates `elf_aux_maybe` and the std path does reach the vDSO, so
/// it stays as the fallback.
fn loglClockNs() u64 {
    var ts: std.os.linux.timespec = undefined;

    if (builtin.link_libc) {
        if (std.c.clock_gettime(.REALTIME, &ts) == 0) {
            @branchHint(.likely);
            return toUnixNs(ts);
        }
        return 0;
    }

    const res = std.os.linux.clock_gettime(.REALTIME, &ts);

    if (res == 0) {
        @branchHint(.likely);
        return toUnixNs(ts);
    }

    return 0;
}

inline fn toUnixNs(ts: std.os.linux.timespec) u64 {
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// High-level logger engine over a `BufferPool` and a Sink.
///
/// `Pool.get` owns the record memory, the sink's `write` both writes the
/// record and recycles its buffer, so the logger never touches memory
/// lifecycle directly. Both are comptime parameters: no vtables, no
/// indirect calls on the hot path.
///
///     var logger: Logger(Pool, Sink) = undefined;
///     logger.init(&pool, &sink);
///     logger.warn("something happened", .{ .key = value });
pub fn Logger(comptime Pool: type, comptime Sink: type) type {
    return struct {
        const Self = @This();

        pool: *Pool,
        sink: *Sink,
        /// Records this logger could not hand to the sink: pool exhaustion or
        /// a sink that returned `error.WriteFailed`. A sink that rejects a
        /// record internally counts it in its own `dropped`, if it has one.
        dropped: std.atomic.Value(u64) = .init(0),
        /// Full allocation backing the `with` prefix, so `put` recovers it.
        prefix_alloc: ?[]u8 = null,
        /// Payload bytes contributed by `with` (a subview of `prefix_alloc`).
        prefix: []const u8 = &.{},

        /// The diagnostic type this logger hands out. A diagnostic is a plain
        /// value the caller owns; the logger only lends the pool.
        pub const Diag = diag_mod.Diag(Pool);

        pub fn init(self: *Self, pool: *Pool, sink: *Sink) void {
            self.* = .{
                .pool = pool,
                .sink = sink,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.prefix_alloc) |buf| {
                self.prefix_alloc = null;
                self.prefix = &.{};
                _ = self.pool.put(buf);
            }
        }

        // ------------------------------------------------------- diagnostics

        /// Starts a rich diagnostic from a Zig error value. Log it exactly once
        /// as `.{ .key = &diag }`; any other use is a terminal bug.
        pub fn diag_err(self: *Self, err_value: anyerror, ctx: anytype) std.mem.Allocator.Error!Diag {
            return Diag.start(self.pool, err_value, @errorName(err_value), null, ctx);
        }

        /// Starts a spec-less diagnostic: a pure invariant violation without a
        /// certain code.
        pub fn diag_txt(self: *Self, msg: []const u8, ctx: anytype) std.mem.Allocator.Error!Diag {
            return Diag.start(self.pool, null, msg, null, ctx);
        }

        /// Like `diag_err`, with the call site attached.
        pub fn diag_err_loc(
            self: *Self,
            err_value: anyerror,
            loc: std.builtin.SourceLocation,
            ctx: anytype,
        ) std.mem.Allocator.Error!Diag {
            return Diag.start(self.pool, err_value, @errorName(err_value), loc, ctx);
        }

        /// Like `diag_txt`, with the call site attached.
        pub fn diag_txt_loc(
            self: *Self,
            loc: std.builtin.SourceLocation,
            msg: []const u8,
            ctx: anytype,
        ) std.mem.Allocator.Error!Diag {
            return Diag.start(self.pool, null, msg, loc, ctx);
        }

        /// Returns a child logger whose records carry `attrs` as a prefix.
        /// One frame is pinned for the child's lifetime and returned by
        /// `deinit`.
        pub fn with(self: *Self, attrs: anytype) Self {
            // A diagnostic captured in the prefix would be copied once per
            // child record, so it cannot be owned by the child (nor logged).
            comptime std.debug.assert(!hasDiagnostics(@TypeOf(attrs)));

            const attrs_size = encoding.getStructEncodedSize(attrs);
            const buf = self.pool.get(attrs_size) catch {
                self.drop();
                return .{
                    .pool = self.pool,
                    .sink = self.sink,
                };
            };

            var frame: LogFrame = undefined;
            frame.init(buf.ptr);
            const attrs_info = @typeInfo(@TypeOf(attrs)).@"struct";
            inline for (attrs_info.field_names, attrs_info.field_types) |name, _| {
                frame.appendField(name, @field(attrs, name));
            }

            return .{
                .pool = self.pool,
                .sink = self.sink,
                .prefix_alloc = buf,
                .prefix = buf,
            };
        }

        pub fn trace(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.trace, msg, attrs, loglClockNs());
        }
        pub fn debug(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.debug, msg, attrs, loglClockNs());
        }
        pub fn info(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.info, msg, attrs, loglClockNs());
        }
        pub fn warn(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.warning, msg, attrs, loglClockNs());
        }
        pub fn err(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.err, msg, attrs, loglClockNs());
        }
        pub fn panic(self: *Self, comptime msg: []const u8, attrs: anytype) void {
            self.writeRecord(.panic, msg, attrs, loglClockNs());
        }

        /// Renders a full log record into a pooled buffer and hands it to the
        /// sink. Failures drop the record and bump this logger's `dropped`
        /// counter.
        inline fn writeRecord(
            self: *Self,
            comptime level: consts.logLevel,
            comptime msg: []const u8,
            attrs: anytype,
            timestamp: u64,
        ) void {
            const msg_len = msg.len;
            const attrs_size = encoding.getStructEncodedSize(attrs);
            const payload_len = 2 + 8 + 1 + 1 + encoding.varintSize(msg_len) + msg_len + self.prefix.len + attrs_size;
            const width = headerWidth(payload_len);
            const total = width + payload_len;

            const buf = self.pool.get(total) catch {
                self.drop();
                return;
            };

            // Payload starts right after the header, so the record slice
            // equals the allocation and `put` recovers it exactly.
            var pos: usize = width;
            std.mem.writeInt(u16, buf[pos..][0..2], consts.version, .little);
            pos += 2;
            std.mem.writeInt(u64, buf[pos..][0..8], timestamp, .little);
            pos += 8;
            buf[pos] = @backingInt(level);
            pos += 1;
            buf[pos] = 0; // location placeholder
            pos += 1;

            var cur: [*]u8 = buf.ptr + pos;
            cur = encoding.appendVarint(cur, msg_len);
            @memcpy(cur[0..msg_len], msg);
            cur += msg_len;

            if (self.prefix.len > 0) {
                @memcpy(cur[0..self.prefix.len], self.prefix);
                cur += self.prefix.len;
            }

            var frame = LogFrame{ .cur = cur };
            const attrs_info = @typeInfo(@TypeOf(attrs)).@"struct";
            inline for (attrs_info.field_names, attrs_info.field_types) |name, _| {
                frame.appendField(name, @field(attrs, name));
            }
            std.debug.assert(@intFromPtr(frame.cur) - @intFromPtr(buf.ptr) == total);

            writeHeader(buf[0..total], payload_len);

            // The bytes are copied into the record, so the diagnostics that
            // contributed them are consumed (and their frames released) before
            // the sink is entered, whether it succeeds or not.
            consumeDiagnostics(self, attrs);

            _ = self.sink.write(self.pool, buf[0..total]) catch {
                self.drop();
                return;
            };
        }

        /// Consumes every `*Diag` attribute of a record exactly once, walking
        /// nested context groups too. Not `inline`: the recursion must be
        /// monomorphized per attribute type.
        fn consumeDiagnostics(self: *Self, attrs: anytype) void {
            const attrs_info = @typeInfo(@TypeOf(attrs)).@"struct";
            inline for (attrs_info.field_names, attrs_info.field_types) |name, T| {
                if (comptime encoding.isDiagPtr(T)) {
                    @field(attrs, name).consume();
                } else if (comptime @typeInfo(T) == .@"struct") {
                    self.consumeDiagnostics(@field(attrs, name));
                }
            }
        }

        inline fn drop(self: *Self) void {
            _ = self.dropped.fetchAdd(1, .monotonic);
        }
    };
}

/// True when `T` holds a `*Diag` directly or inside a nested context group.
/// Type-driven on purpose: the check runs before any value exists.
fn hasDiagnostics(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_types) |FieldType| {
        if (comptime encoding.isDiagPtr(FieldType)) return true;
        if (comptime hasDiagnostics(FieldType)) return true;
    }
    return false;
}

/// Writes the log header in front of an already-rendered payload.
fn writeHeader(record: []u8, payload_len: usize) void {
    const width = headerWidth(payload_len);
    record[0] = 0xFF;
    const checksum = crc32c.hardwareCrc32C(record[width..][0..payload_len]);
    std.mem.writeInt(u32, record[1..][0..4], checksum, .little);
    record[5] = 0xFE;
    _ = encoding.appendVarint(record.ptr + 6, payload_len);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const decoding = @import("decoding.zig");

test "golden log frame bytes (timestamp pinned) and decode round-trip" {
    const buffer_pool = @import("buffer_pool.zig");
    const writer = @import("writer.zig");

    const allocator = std.testing.allocator;
    var pool: buffer_pool.BufferPool(false) = undefined;
    try pool.init(allocator, 8, 2048);
    defer pool.deinit();

    var sink: writer.MemorySink = undefined;
    sink.init(allocator);
    defer sink.deinit();

    var logger: Logger(@TypeOf(pool), @TypeOf(sink)) = undefined;
    logger.init(&pool, &sink);
    logger.writeRecord(.warning, "hi", .{ .n = @as(u32, 7) }, 0x0102030405060708);

    const golden = [_]u8{
        0xff, 0xc1, 0x5b, 0xbb, 0x4e, 0xfe, 0x16, // header (CRC32C from the Go encoder)
        0x01, 0x00, // version
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // timestamp
        0x28, // warning
        0x00, // location
        0x02, 'h', 'i', // msg
        0x32, 0x01, 'n', 0x07, 0x00, 0x00, 0x00, // n = u32(7)
    };
    try expectEqualSlices(u8, &golden, sink.bytes.items);

    // Structural checks against the frozen wire format.
    const rec = sink.bytes.items;
    try expectEqual(@as(u8, 0xFF), rec[0]);
    try expectEqual(@as(u8, 0xFE), rec[5]);

    var payload_len: u64 = 0;
    const after_len = try decoding.decodeVarint(&payload_len, rec.ptr + 6);
    const header_len = @intFromPtr(after_len) - @intFromPtr(rec.ptr);
    try expectEqual(@as(usize, 7), header_len);
    try expectEqual(@as(usize, @intCast(payload_len)), rec.len - header_len);

    const stored_crc = std.mem.readInt(u32, rec[1..5], .little);
    try expectEqual(crc32c.hardwareCrc32C(rec[header_len..]), stored_crc);
}

test "with prefix is encoded, then returned to the pool on deinit" {
    const buffer_pool = @import("buffer_pool.zig");
    const writer = @import("writer.zig");

    const allocator = std.testing.allocator;
    var pool: buffer_pool.BufferPool(false) = undefined;
    try pool.init(allocator, 4, 512);
    defer pool.deinit();

    var sink: writer.MemorySink = undefined;
    sink.init(allocator);
    defer sink.deinit();

    var root: Logger(@TypeOf(pool), @TypeOf(sink)) = undefined;
    root.init(&pool, &sink);
    var child = root.with(.{ .job = "sync" });
    defer child.deinit();

    try expect(child.prefix_alloc != null);
    const prefix_buf = child.prefix_alloc.?;

    child.info("started", .{ .n = @as(u8, 1) });

    // Prefix attr ("job" = "sync") must precede the call-site attr.
    const rec = sink.bytes.items;
    var payload_len: u64 = 0;
    const after_len = try decoding.decodeVarint(&payload_len, rec.ptr + 6);
    var p = after_len;

    const version = std.mem.readInt(u16, p[0..2], .little);
    try expectEqual(consts.version, version);
    p += 2 + 8; // version + timestamp
    p += 1 + 1; // level + location

    var msg_len: u64 = 0;
    p = try decoding.decodeVarint(&msg_len, p);
    try expectEqualSlices(u8, "started", p[0..@intCast(msg_len)]);
    p += msg_len;

    try expectEqual(@backingInt(consts.ValueKind.string), p[0]);
    var name_len: u64 = 0;
    p = try decoding.decodeVarint(&name_len, p + 1);
    try expectEqualSlices(u8, "job", p[0..@intCast(name_len)]);
    p += name_len;
    var val_len: u64 = 0;
    p = try decoding.decodeVarint(&val_len, p);
    try expectEqualSlices(u8, "sync", p[0..@intCast(val_len)]);

    child.deinit();
    const again = try pool.get(prefix_buf.len);
    try expectEqual(prefix_buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "drop accounting when the sink fails" {
    const buffer_pool = @import("buffer_pool.zig");

    const FailingSink = struct {
        dropped: std.atomic.Value(u64) = .init(0),
        calls: usize = 0,

        pub fn write(self: *@This(), pool: *buffer_pool.BufferPool(false), buf: []const u8) error{WriteFailed}!usize {
            self.calls += 1;
            _ = pool.put(@constCast(buf));
            return error.WriteFailed;
        }
    };

    const allocator = std.testing.allocator;
    var pool: buffer_pool.BufferPool(false) = undefined;
    try pool.init(allocator, 4, 512);
    defer pool.deinit();

    var sink = FailingSink{};
    var logger: Logger(@TypeOf(pool), FailingSink) = undefined;
    logger.init(&pool, &sink);

    logger.warn("one", .{});
    logger.err("two", .{});
    logger.info("three", .{});

    try expectEqual(@as(usize, 3), sink.calls);
    try expectEqual(@as(u64, 3), logger.dropped.load(.monotonic));
}

test "drop accounting when the pool is out of memory" {
    const buffer_pool = @import("buffer_pool.zig");
    const writer = @import("writer.zig");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const allocator = failing.allocator();

    // Pool init performs 3 allocations; every later heap fallback fails.
    var pool: buffer_pool.BufferPool(false) = undefined;
    try pool.init(allocator, 1, 512);
    defer pool.deinit();

    var sink: writer.MemorySink = undefined;
    sink.init(std.testing.allocator);
    defer sink.deinit();

    var logger: Logger(@TypeOf(pool), @TypeOf(sink)) = undefined;
    logger.init(&pool, &sink);

    // Longer than the frame, so `get` falls back to the heap, which fails.
    const big: []const u8 = &@as([4096]u8, @splat('x'));
    logger.warn(big, .{});

    try expectEqual(@as(u64, 1), logger.dropped.load(.monotonic));
    try expectEqual(@as(usize, 0), sink.bytes.items.len);
}
