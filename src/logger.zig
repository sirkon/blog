const std = @import("std");
const consts = @import("consts.zig");
const encoding = @import("encoding.zig");
const crc32c = @import("crc32c.zig");

/// A thin cursor over the record payload. It knows nothing about pools, IO,
/// or log framing, and only appends serialized fields.
const LogFrame = struct {
    cur: [*]u8,

    pub inline fn init(payload_ptr: [*]u8) LogFrame {
        return .{ .cur = payload_ptr };
    }

    pub inline fn appendField(self: *LogFrame, comptime name: []const u8, value: anytype) void {
        const T = @TypeOf(value);

        const kind: consts.ValueKind = comptime block: {
            break :block switch (@typeInfo(T)) {
                .bool => .bool,
                .int => |info| if (info.signedness == .signed) {
                    break :block if (info.bits <= 8) .int8 else if (info.bits <= 16) .int16 else if (info.bits <= 32) .int32 else .int64;
                } else {
                    break :block if (info.bits <= 8) .uint8 else if (info.bits <= 16) .uint16 else if (info.bits <= 32) .uint32 else .uint64;
                },
                .comptime_int => consts.intKind(value),
                .float => |info| if (info.bits == 32) .float32 else .float64,
                .@"struct" => .nodeGroup,
                .pointer => |ptrInfo| if (ptrInfo.size == .slice) {
                    const Child = ptrInfo.child;
                    break :block switch (@typeInfo(Child)) {
                        .bool => .sliceBool,
                        .int => |info| if (info.signedness == .signed) {
                            break :block if (info.bits <= 8) .sliceInt8 else if (info.bits <= 16) .sliceInt16 else if (info.bits <= 32) .sliceInt32 else .sliceInt64;
                        } else {
                            break :block if (info.bits <= 8) .sliceUint8 else if (info.bits <= 16) .sliceUint16 else if (info.bits <= 32) .sliceUint32 else .sliceUint64;
                        },
                        .float => |info| if (info.bits == 32) .sliceFloat32 else .sliceFloat64,
                        else => @compileError("Unsupported slice item: " ++ @typeName(Child)),
                    };
                } else if (ptrInfo.size == .one and (ptrInfo.child == u8 or switch (@typeInfo(ptrInfo.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                })) {
                    break :block .string;
                } else {
                    @compileError("Unsupported pointer type: " ++ @typeName(T));
                },
                .array => |arrInfo| {
                    const Child = arrInfo.child;
                    break :block switch (@typeInfo(Child)) {
                        .bool => .sliceBool,
                        .int => |info| if (info.signedness == .signed) {
                            break :block if (info.bits <= 8) .sliceInt8 else if (info.bits <= 16) .sliceInt16 else if (info.bits <= 32) .sliceInt32 else .sliceInt64;
                        } else {
                            break :block if (info.bits <= 8) .sliceUint8 else if (info.bits <= 16) .sliceUint16 else if (info.bits <= 32) .sliceUint32 else .sliceUint64;
                        },
                        .float => |info| if (info.bits == 32) .sliceFloat32 else .sliceFloat64,
                        else => @compileError("Unsupported array item: " ++ @typeName(Child)),
                    };
                },
                else => @compileError("Unsupported record field type: " ++ @typeName(T)),
            };
        };

        self.cur[0] = @intFromEnum(kind);
        self.cur += 1;

        self.cur = encoding.appendVarint(self.cur, name.len);
        @memcpy(self.cur[0..name.len], name);
        self.cur += name.len;

        switch (@typeInfo(T)) {
            .@"struct" => {
                const sub_info = @typeInfo(T);
                inline for (sub_info.@"struct".fields) |f| {
                    self.appendField(f.name, @field(value, f.name));
                }
                self.cur[0] = @intFromEnum(consts.ValueKind.nodeGroupEnd);
                self.cur += 1;
            },
            else => {
                self.cur = encoding.append(self.cur, value);
            },
        }
    }
};

/// Width in bytes of a log header for a payload of `payload_len` bytes:
/// `0xFF + CRC32C(4) + 0xFE + uvarint(payload_len)`.
/// Matches the Go encoder in `internal/core/logger.go`.
pub fn headerWidth(payload_len: usize) usize {
    const bits_len: usize = if (payload_len == 0) 0 else 64 - @clz(payload_len);
    return 6 + (bits_len + 6) / 7;
}

/// Monotonic-free logl clock read via a raw `clock_gettime` syscall.
/// CLOCK_REALTIME is always 0 in the Linux ABI.
fn loglClockNs() u64 {
    var ts: std.os.linux.timespec = undefined;

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
///     var logger = Logger(Pool, Sink).init(&pool, &sink);
///     logger.warn("something happened", .{ .key = value });
pub fn Logger(comptime Pool: type, comptime Sink: type) type {
    return struct {
        const Self = @This();

        pool: *Pool,
        sink: *Sink,
        /// Full allocation backing the `With` prefix, so `put` recovers it.
        prefix_alloc: ?[]u8 = null,
        /// Payload bytes contributed by `With` (a subview of `prefix_alloc`).
        prefix: []const u8 = &.{},

        pub fn init(pool: *Pool, sink: *Sink) Self {
            return .{ .pool = pool, .sink = sink };
        }

        pub fn deinit(self: *Self) void {
            if (self.prefix_alloc) |buf| {
                self.prefix_alloc = null;
                self.prefix = &.{};
                _ = self.pool.put(buf);
            }
        }

        /// Returns a child logger whose records carry `attrs` as a prefix.
        /// One frame is pinned for the child's lifetime and returned by
        /// `deinit`.
        pub fn With(self: *Self, attrs: anytype) Self {
            const attrs_size = encoding.getStructEncodedSize(attrs);
            const buf = self.pool.get(attrs_size) catch {
                self.drop();
                return .{ .pool = self.pool, .sink = self.sink };
            };

            var frame = LogFrame.init(buf.ptr);
            const attrs_info = @typeInfo(@TypeOf(attrs));
            inline for (attrs_info.@"struct".fields) |field| {
                frame.appendField(field.name, @field(attrs, field.name));
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
        /// sink. Failures drop the record and bump the sink's `dropped`
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
            buf[pos] = @intFromEnum(level);
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
            const attrs_info = @typeInfo(@TypeOf(attrs));
            inline for (attrs_info.@"struct".fields) |field| {
                frame.appendField(field.name, @field(attrs, field.name));
            }
            std.debug.assert(@intFromPtr(frame.cur) - @intFromPtr(buf.ptr) == total);

            writeHeader(buf[0..total], payload_len);

            _ = self.sink.write(self.pool, buf[0..total]) catch {
                self.drop();
                return;
            };
        }

        inline fn drop(self: *Self) void {
            _ = self.sink.dropped.fetchAdd(1, .monotonic);
        }
    };
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
    var pool = try buffer_pool.BufferPool(false).init(allocator, 8, 2048);
    defer pool.deinit();

    var sink = writer.MemorySink.init(allocator);
    defer sink.deinit();

    var logger = Logger(@TypeOf(pool), @TypeOf(sink)).init(&pool, &sink);
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
    var pool = try buffer_pool.BufferPool(false).init(allocator, 4, 512);
    defer pool.deinit();

    var sink = writer.MemorySink.init(allocator);
    defer sink.deinit();

    var root = Logger(@TypeOf(pool), @TypeOf(sink)).init(&pool, &sink);
    var child = root.With(.{ .job = "sync" });
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

    try expectEqual(@intFromEnum(consts.ValueKind.string), p[0]);
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
    var pool = try buffer_pool.BufferPool(false).init(allocator, 4, 512);
    defer pool.deinit();

    var sink = FailingSink{};
    var logger = Logger(@TypeOf(pool), FailingSink).init(&pool, &sink);

    logger.warn("one", .{});
    logger.err("two", .{});
    logger.info("three", .{});

    try expectEqual(@as(usize, 3), sink.calls);
    try expectEqual(@as(u64, 3), sink.dropped.load(.monotonic));
}

test "drop accounting when the pool is out of memory" {
    const buffer_pool = @import("buffer_pool.zig");
    const writer = @import("writer.zig");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const allocator = failing.allocator();

    // Pool init performs 3 allocations; every later heap fallback fails.
    var pool = try buffer_pool.BufferPool(false).init(allocator, 1, 512);
    defer pool.deinit();

    var sink = writer.MemorySink.init(std.testing.allocator);
    defer sink.deinit();

    var logger = Logger(@TypeOf(pool), @TypeOf(sink)).init(&pool, &sink);

    // Longer than the frame, so `get` falls back to the heap, which fails.
    const big = "x" ** 4096;
    logger.warn(big, .{});

    try expectEqual(@as(u64, 1), sink.dropped.load(.monotonic));
    try expectEqual(@as(usize, 0), sink.bytes.items.len);
}
