//! Sink contract
//! --------------
//! A sink is any type exposing:
//!
//!     pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize
//!
//! `write` takes OWNERSHIP of `buf`. On return the buffer has been handed
//! off: synchronous sinks call `pool.put(@constCast(buf))` before
//! returning; asynchronous sinks (a future io_uring sink) stash
//! `(pool, buf)` keyed by `user_data` and release it on CQE, success or
//! failure. On `error.WriteFailed` the sink must still release the buffer.
//!
//! The pool is a concrete `*BufferPool` so callers and sinks are stitched
//! together without agreement on a generic parameter. The downstream writer,
//! on the other hand, is a comptime factory parameter so there are no
//! vtables and no indirect calls on the hot path.
//!
//! `FileSink`, `PrettySink` and `SyncWriter` themselves are comptime
//! factories over a downstream `Writer` type. They verify at comptime that the
//! supplied type exposes
//!
//!     pub fn write(self: *Writer, bytes: []const u8) E!usize
//!
//! and generate a log sink that forwards its bytes there. `SyncWriter` wraps
//! any such `Writer` and serializes concurrent calls with a mutex. Nothing in
//! this file names `std.Io`: the concrete file, stdout or in-memory writer is
//! supplied by the caller, so the logger stays free of any concrete IO.

const std = @import("std");
const builtin = @import("builtin");
const buffer_pool = @import("buffer_pool.zig");
const mutex = @import("mutex.zig");
const crc32c = @import("crc32c.zig");
const render = @import("render.zig");
const viewer = @import("viewer.zig");
const jsonsink = @import("jsonsink.zig");

/// The pool type every writer's `write` consumes.
pub const BufferPool = buffer_pool.BufferPool(false);

/// Error surfaced by every log sink whenever the downstream write fails.
pub const WriteError = error{WriteFailed};

/// Comptime contract check for a downstream writer type: it must look like
///
///     pub fn write(self: *Writer, bytes: []const u8) E!usize
///
/// Any error set is accepted; a failing write is reported as
/// `error.WriteFailed` by the wrapping log sink.
fn assertWriter(comptime Writer: type) void {
    switch (@typeInfo(Writer)) {
        .@"struct" => {},
        else => @compileError(@typeName(Writer) ++ " must be a struct exposing `fn write(self: *" ++
            @typeName(Writer) ++ ", bytes: []const u8) E!usize`"),
    }
    if (!@hasDecl(Writer, "write")) {
        @compileError(@typeName(Writer) ++ " is missing `fn write(self: *" ++
            @typeName(Writer) ++ ", bytes: []const u8) E!usize`");
    }

    const WriteFn = @TypeOf(Writer.write);
    if (@typeInfo(WriteFn) != .@"fn") {
        @compileError(@typeName(Writer) ++ ".write must be a function `fn (*" ++
            @typeName(Writer) ++ ", []const u8) E!usize`");
    }
    const info = @typeInfo(WriteFn).@"fn";
    if (info.params.len != 2 or
        info.params[0].type != *Writer or
        info.params[1].type != []const u8)
    {
        @compileError(@typeName(Writer) ++ ".write must have the signature `fn (*" ++
            @typeName(Writer) ++ ", []const u8) E!usize`");
    }

    const ret = info.return_type orelse
        @compileError(@typeName(Writer) ++ ".write must return `E!usize`");
    switch (@typeInfo(ret)) {
        .error_union => |eu| {
            if (eu.payload != usize) {
                @compileError(@typeName(Writer) ++ ".write must return an error union with a usize payload");
            }
        },
        else => @compileError(@typeName(Writer) ++ ".write must return `E!usize`"),
    }
}

/// Captures every record it receives; used by tests and in-memory tooling.
pub const MemorySink = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Records the logger had to drop before they reached this sink.
    dropped: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize {
        self.bytes.appendSlice(self.allocator, buf) catch {
            _ = pool.put(@constCast(buf));
            return error.WriteFailed;
        };
        _ = pool.put(@constCast(buf));
        return buf.len;
    }
};

/// Synchronous writer over a raw POSIX file descriptor.
///
/// Exposes the downstream `Writer` contract
///
///     pub fn write(self: *FdWriter, bytes: []const u8) WriteError!usize
///
/// so an `FdWriter` can be handed straight to `FileSink`, wrapped in a
/// `SyncWriter`, or used on its own. Each call writes the whole slice,
/// retrying short writes and `EINTR` until every byte is out. The descriptor
/// is borrowed: `FdWriter` never opens, duplicates or closes it.
pub const FdWriter = struct {
    const Self = @This();

    fd: std.posix.fd_t,

    pub fn init(fd: std.posix.fd_t) Self {
        return .{ .fd = fd };
    }

    pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
        // Linux caps a single transfer at 0x7ffff000 bytes because the return
        // value is a signed int; mirror `std.posix.read` to avoid EINVAL.
        const max_count = switch (builtin.os.tag) {
            .linux => 0x7ffff000,
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.math.maxInt(i32),
            else => std.math.maxInt(isize),
        };

        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.posix.system.write(self.fd, bytes.ptr + off, @min(bytes.len - off, max_count));
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return error.WriteFailed;
                    off += n;
                },
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        return bytes.len;
    }
};

/// Synchronous file sink over a comptime `Writer`.
///
/// `Writer` must expose `pub fn write(self: *Writer, bytes: []const u8) E!usize`;
/// every record is forwarded there. Wrap the downstream `Writer` in
/// `SyncWriter` first when concurrent calls must be serialized so they cannot
/// interleave partial frames. The last detailed error is kept on the struct
/// and surfaced to callers as `error.WriteFailed`.
pub fn FileSink(comptime Writer: type) type {
    comptime assertWriter(Writer);

    return struct {
        const Self = @This();

        /// Downstream writer; supplied by the caller. Not owned.
        writer: *Writer,
        last_error: ?anyerror = null,
        written: u64 = 0,
        /// Records the logger had to drop before they reached this sink.
        dropped: std.atomic.Value(u64) = .init(0),

        pub fn init(writer: *Writer) Self {
            return .{ .writer = writer };
        }

        pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize {
            defer _ = pool.put(@constCast(buf));

            var off: usize = 0;
            while (off < buf.len) {
                const n = self.writer.write(buf[off..]) catch |err| {
                    self.last_error = err;
                    return error.WriteFailed;
                };
                if (n == 0) return error.WriteFailed;
                off += n;
            }
            self.written += buf.len;
            return buf.len;
        }
    };
}

/// Serializes writes to a comptime `Writer` behind a `mutex.Mutex`.
///
/// `Writer` must expose `pub fn write(self: *Writer, bytes: []const u8) E!usize`;
/// `SyncWriter(Writer)` exposes the same contract and forwards every call to
/// the wrapped writer while holding the lock, so concurrent calls never
/// interleave partial frames. The wrapped writer is not owned; call `deinit`
/// to release the mutex.
pub fn SyncWriter(comptime Writer: type) type {
    comptime assertWriter(Writer);

    const WriteReturn = @typeInfo(@TypeOf(Writer.write)).@"fn".return_type.?;

    return struct {
        const Self = @This();

        mutex: mutex.Mutex,
        /// Downstream writer; supplied by the caller. Not owned.
        writer: *Writer,

        pub fn init(writer: *Writer) Self {
            return .{
                .mutex = mutex.Mutex.init(),
                .writer = writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
        }

        pub inline fn write(self: *Self, bytes: []const u8) WriteReturn {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.writer.write(bytes);
        }
    };
}

/// Tree viewer sink over a comptime `Writer`: verifies each log frame, then
/// writes a human-readable rendering of the record (header + context tree or
/// compact JSON) to the downstream writer.
///
/// `Writer` must expose `pub fn write(self: *Writer, bytes: []const u8) E!usize`;
/// any regular file, stdout or in-memory destination can be adapted to that
/// contract by the caller. On any framing, CRC or parse failure the record is
/// dropped and nothing is written downstream.
///
/// Takes ownership of `buf` and always returns it to `pool`, success or not.
pub fn PrettySink(comptime Writer: type) type {
    comptime assertWriter(Writer);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Destination for rendered records; supplied by the caller. Not owned.
        out: *Writer,
        /// Scratch space for a single record; flushed to `out` then reused.
        scratch: std.ArrayList(u8) = .empty,
        /// Records the logger had to drop before they reached this sink.
        dropped: std.atomic.Value(u64) = .init(0),
        profile: render.ColorProfile = .plain,
        options: render.RenderOptions = .{},
        record: viewer.ParsedRecord = .{},
        renderer: render.Renderer,

        pub fn init(
            allocator: std.mem.Allocator,
            profile: render.ColorProfile,
            out: *Writer,
        ) Self {
            return .{
                .allocator = allocator,
                .out = out,
                .profile = profile,
                .renderer = render.Renderer.init(allocator, profile),
            };
        }

        pub fn deinit(self: *Self) void {
            self.scratch.deinit(self.allocator);
            self.record.deinit(self.allocator);
            self.renderer.deinit();
        }

        pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize {
            defer _ = pool.put(@constCast(buf));
            defer self.scratch.clearRetainingCapacity();

            self.renderFrame(buf) catch {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return error.WriteFailed;
            };

            var off: usize = 0;
            while (off < self.scratch.items.len) {
                const n = self.out.write(self.scratch.items[off..]) catch return error.WriteFailed;
                if (n == 0) return error.WriteFailed;
                off += n;
            }
            return buf.len;
        }

        fn renderFrame(self: *Self, frame: []const u8) !void {
            const payload = try verifyFrame(frame);

            try viewer.parseRecord(self.allocator, payload, &self.record);
            self.renderer.profile = self.profile;
            self.renderer.options = self.options;
            try self.renderer.render(&self.scratch, payload, &self.record);
        }
    };
}

/// Compact-JSONL sink: one line of JSON per record.
///
/// Wraps a single-pass transformer (`jsonsink.renderRecord`) that walks each
/// framed record's payload once and writes compact JSON as it reads. `Writer`
/// must expose `pub fn write(self: *Writer, bytes: []const u8) E!usize`; on any
/// framing, CRC or parse failure the record is dropped, nothing is written
/// downstream, and `dropped` is incremented.
///
/// Takes ownership of `buf` and always returns it to `pool`, success or not.
pub fn JsonSink(comptime Writer: type) type {
    comptime assertWriter(Writer);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// Destination for rendered lines; supplied by the caller. Not owned.
        out: *Writer,
        /// Records the logger had to drop before they reached this sink.
        dropped: std.atomic.Value(u64) = .init(0),
        /// Reusable per-record render state (error fragment refs, scratch).
        ctx: jsonsink.Ctx,

        pub fn init(allocator: std.mem.Allocator, out: *Writer) Self {
            return .{
                .allocator = allocator,
                .out = out,
                .ctx = jsonsink.Ctx.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.ctx.deinit();
        }

        pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize {
            defer _ = pool.put(@constCast(buf));

            const payload = verifyFrame(buf) catch {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return error.WriteFailed;
            };

            const out_buf = pool.get(jsonsink.initialCapacity(payload.len)) catch {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return error.WriteFailed;
            };
            var out = jsonsink.Out{ .pool = pool, .buf = out_buf };
            jsonsink.renderRecord(&out, &self.ctx, payload) catch {
                out.release();
                _ = self.dropped.fetchAdd(1, .monotonic);
                return error.WriteFailed;
            };
            out.byte('\n') catch {
                out.release();
                _ = self.dropped.fetchAdd(1, .monotonic);
                return error.WriteFailed;
            };

            const line = out.written();
            var off: usize = 0;
            while (off < line.len) {
                const n = self.out.write(line[off..]) catch {
                    out.release();
                    return error.WriteFailed;
                };
                if (n == 0) {
                    out.release();
                    return error.WriteFailed;
                }
                off += n;
            }
            out.release();
            return buf.len;
        }
    };
}

/// Verifies a log frame and returns its payload.
///
/// A valid frame is `0xFF [CRC32C×4 LE] 0xFE [uvarint len] payload`, with no
/// trailing bytes and a CRC32C over the payload that matches its header. Any
/// deviation returns an error so the caller can drop the record cleanly.
pub fn verifyFrame(frame: []const u8) ![]const u8 {
    if (frame.len < 7 or frame[0] != 0xFF or frame[5] != 0xFE) return error.BadFrame;

    const len = try viewer.readUvarint(frame, 6);
    const start = 6 + len.size;
    const end = start + @as(usize, @intCast(len.val));
    if (end != frame.len) return error.BadFrame;

    const payload = frame[start..end];
    const crc = std.mem.readInt(u32, frame[1..5], .little);
    if (crc32c.hardwareCrc32C(payload) != crc) return error.CrcMismatch;
    return payload;
}

/// Test-only downstream writer: appends every byte to an owned buffer.
const CaptureWriter = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn write(self: *@This(), bytes: []const u8) error{WriteFailed}!usize {
        self.list.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
        return bytes.len;
    }

    fn deinit(self: *@This()) void {
        self.list.deinit(std.testing.allocator);
    }

    fn written(self: *@This()) []const u8 {
        return self.list.items;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "memory sink captures and releases the buffer" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    var sink = MemorySink.init(allocator);
    defer sink.deinit();

    const a = try pool.get(16);
    @memcpy(a[0..5], "hello");
    _ = try sink.write(&pool, a[0..5]);

    const b = try pool.get(16);
    try expectEqual(a.ptr, b.ptr);
    _ = try sink.write(&pool, b[0..0]);

    try expectEqualSlices(u8, "hello", sink.bytes.items);
}

test "file sink reports a failing writer and still releases the buffer" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);

    // Any type with `fn write(self, bytes) E!usize` is a valid downstream writer.
    const FailingWriter = struct {
        calls: usize = 0,

        pub fn write(self: *@This(), bytes: []const u8) error{WriteFailed}!usize {
            _ = bytes;
            self.calls += 1;
            return error.WriteFailed;
        }
    };

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    var failing = FailingWriter{};
    var sink = FileSink(FailingWriter).init(&failing);

    const buf = try pool.get(8);
    @memcpy(buf, "12345678");
    const res = sink.write(&pool, buf);
    try std.testing.expectError(error.WriteFailed, res);
    try expect(sink.last_error != null);

    // Even on failure the buffer must be back on the free list.
    const again = try pool.get(8);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "file sink writes frames to disk" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);
    const Io = std.Io;

    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    const path = "test_writer_frames.tmp";
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var file_buffer: [64]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &file_buffer);

    var synced = SyncWriter(Io.Writer).init(&file_writer.interface);
    defer synced.deinit();
    var sink = FileSink(SyncWriter(Io.Writer)).init(&synced);

    const buf = try pool.get(4);
    @memcpy(buf, "abcd");
    _ = try sink.write(&pool, buf);
    try file_writer.interface.flush();

    var read_buf: [4]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try expectEqual(@as(usize, 4), n);
    try expectEqualSlices(u8, "abcd", &read_buf);
}

test "sync writer forwards and serializes writes" {
    const CountingWriter = struct {
        bytes: usize = 0,

        pub fn write(self: *@This(), bytes: []const u8) error{WriteFailed}!usize {
            self.bytes += bytes.len;
            return bytes.len;
        }
    };

    var inner = CountingWriter{};
    var synced = SyncWriter(CountingWriter).init(&inner);
    defer synced.deinit();

    try expectEqual(@as(usize, 3), try synced.write("abc"));
    try expectEqual(@as(usize, 2), try synced.write("de"));
    try expectEqual(@as(usize, 5), inner.bytes);

    // A `SyncWriter` is itself a valid downstream writer for a log sink.
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    var sink = FileSink(SyncWriter(CountingWriter)).init(&synced);
    const buf = try pool.get(4);
    @memcpy(buf, "wxyz");
    _ = try sink.write(&pool, buf);
    try expectEqual(@as(usize, 9), inner.bytes);

    const again = try pool.get(4);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "fd writer writes to a file descriptor" {
    const Io = std.Io;

    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "test_fd_writer.tmp";
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var fd_writer = FdWriter.init(file.handle);
    try expectEqual(@as(usize, 5), try fd_writer.write("hello"));
    // A zero-length write is a no-op that still succeeds.
    try expectEqual(@as(usize, 0), try fd_writer.write(""));

    var read_buf: [5]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try expectEqual(@as(usize, 5), n);
    try expectEqualSlices(u8, "hello", &read_buf);
}

test "fd writer composes as a downstream sink writer" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);
    const Io = std.Io;

    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    const path = "test_fd_writer_sink.tmp";
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var fd_writer = FdWriter.init(file.handle);
    var sink = FileSink(FdWriter).init(&fd_writer);

    const buf = try pool.get(4);
    @memcpy(buf, "abcd");
    _ = try sink.write(&pool, buf);

    var read_buf: [4]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try expectEqual(@as(usize, 4), n);
    try expectEqualSlices(u8, "abcd", &read_buf);

    const again = try pool.get(4);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

/// Wraps a payload into a full log frame: `0xFF [CRC32C×4] 0xFE [uvarint len]`.
fn frameInto(dst: []u8, payload: []const u8) void {
    dst[0] = 0xFF;
    std.mem.writeInt(u32, dst[1..5], crc32c.hardwareCrc32C(payload), .little);
    dst[5] = 0xFE;
    var p: usize = 6;
    var x = payload.len;
    while (x >= 0x80) {
        dst[p] = @as(u8, @truncate(x)) | 0x80;
        p += 1;
        x >>= 7;
    }
    dst[p] = @intCast(x);
    p += 1;
    @memcpy(dst[p..][0..payload.len], payload);
}

fn frameSize(payload_len: usize) usize {
    const logger = @import("logger.zig");
    return logger.headerWidth(payload_len) + payload_len;
}

test "pretty sink renders a frame and releases the buffer" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = PrettySink(CaptureWriter).init(allocator, .plain, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "just a message");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);

    try expectEqualSlices(
        u8,
        "1970-01-01 00:00:00.000  INFO just a message {}\n",
        out.written(),
    );

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "pretty sink drops a corrupt frame and releases the buffer" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = PrettySink(CaptureWriter).init(allocator, .plain, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "just a message");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    buf[1] ^= 0xFF; // corrupt the CRC

    try std.testing.expectError(error.WriteFailed, sink.write(&pool, buf[0..size]));
    try expectEqual(@as(u64, 1), sink.dropped.load(.monotonic));
    try expectEqual(@as(usize, 0), out.written().len);

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "pretty sink reuses parser and renderer across records" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = PrettySink(CaptureWriter).init(allocator, .plain, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "one");
    try pb.key(allocator, .int64, "a");
    try pb.le(allocator, u64, 1);
    try pb.key(allocator, .int64, "b");
    try pb.le(allocator, u64, 2);
    try pb.key(allocator, .int64, "c");
    try pb.le(allocator, u64, 3);
    try pb.key(allocator, .int64, "d");
    try pb.le(allocator, u64, 4);

    const size = frameSize(pb.list.items.len);
    const buf1 = try pool.get(size);
    frameInto(buf1[0..size], pb.list.items);
    _ = try sink.write(&pool, buf1[0..size]);

    var pb2 = viewer.PB{};
    defer pb2.deinit(allocator);
    try pb2.header(allocator, 1_000_000, @intFromEnum(consts.logLevel.warning));
    try pb2.msg(allocator, "two");

    const size2 = frameSize(pb2.list.items.len);
    const buf2 = try pool.get(size2);
    frameInto(buf2[0..size2], pb2.list.items);
    _ = try sink.write(&pool, buf2[0..size2]);

    try expectEqualSlices(
        u8,
        "1970-01-01 00:00:00.000  INFO one \n" ++
            "\u{251C}\u{2500} a: 1\n" ++
            "\u{251C}\u{2500} b: 2\n" ++
            "\u{251C}\u{2500} c: 3\n" ++
            "\u{2514}\u{2500} d: 4\n" ++
            "1970-01-01 00:00:00.001  WARN two {}\n",
        out.written(),
    );
}

test "pretty sink renders an error/location record end to end" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 4096);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = PrettySink(CaptureWriter).init(allocator, .plain, &out);
    defer sink.deinit();
    sink.options = .{ .tz_offset_seconds = render.ERRORS_TZ };

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try render.buildErrorsFixture(allocator, &pb);

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);

    try expectEqualSlices(
        u8,
        "2026-04-22 20:48:19.371 ERROR errors \n" ++
            "\u{251C}\u{2500} err-foreign: EOF\n" ++
            "\u{251C}\u{2500} err-beer: \n" ++
            "\u{2502}  \u{251C}\u{2500} @context\n" ++
            "\u{2502}  \u{2502}  \u{251C}\u{2500} NEW: error\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:331\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{2514}\u{2500} new-string: Hello World!\n" ++
            "\u{2502}  \u{2502}  \u{251C}\u{2500} WRAP: wrap\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:332\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{2514}\u{2500} wrap-int: 1\n" ++
            "\u{2502}  \u{2502}  \u{2514}\u{2500} CTX\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:333\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{2514}\u{2500} just-pi: 3.141592653589793\n" ++
            "\u{2502}  \u{2514}\u{2500} @text: wrap: error\n" ++
            "\u{251C}\u{2500} err-foreign-root: \n" ++
            "\u{2502}  \u{251C}\u{2500} @context\n" ++
            "\u{2502}  \u{2502}  \u{2514}\u{2500} WRAP: wrap foreign\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:335\n" ++
            "\u{2502}  \u{2502}  \u{2502}  \u{2514}\u{2500} wrap-bool: true\n" ++
            "\u{2502}  \u{2514}\u{2500} @text: wrap foreign: EOF: wrap: error\n" ++
            "\u{2514}\u{2500} err-intermixed: \n" ++
            "   \u{251C}\u{2500} @context\n" ++
            "   \u{2502}  \u{2514}\u{2500} NEW: error\n" ++
            "   \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:337\n" ++
            "   \u{2502}  \u{2502}  \u{2514}\u{2500} new-time: 2026-04-22 20:48:19.371\n" ++
            "   \u{2514}\u{2500} @text: foreign wrap: error\n",
        out.written(),
    );

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "pretty sink renders a panic frame with the gzipped stacktrace" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 4096);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = PrettySink(CaptureWriter).init(allocator, .plain, &out);
    defer sink.deinit();
    sink.options = .{ .tz_offset_seconds = render.ERRORS_TZ };

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try render.buildPanicFixture(allocator, &pb);

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);

    const want_head =
        "2026-04-22 20:48:19.375 PANIC {\"recovered\": \"this is a panic\"}\n" ++
        ".... goroutine 56 [running]:\n" ++
        ".... runtime/debug.Stack()\n";
    try expect(std.mem.startsWith(u8, out.written(), want_head));
    try expect(std.mem.indexOf(
        u8,
        out.written(),
        ".... created by testing.(*T).Run in goroutine 34\n",
    ) != null);

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "pretty sink writes a rendered record to a file" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);
    const Io = std.Io;

    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    const path = "test_tree_writer_file.tmp";
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var file_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &file_buffer);

    var sink = PrettySink(Io.Writer).init(allocator, .plain, &file_writer.interface);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "to a file");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);
    try file_writer.interface.flush();

    var read_buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try expectEqualSlices(
        u8,
        "1970-01-01 00:00:00.000  INFO to a file {}\n",
        read_buf[0..n],
    );

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "json sink renders a frame and releases both buffers" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = JsonSink(CaptureWriter).init(allocator, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "just a message");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);

    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"just a message\"}\n",
        out.written(),
    );
    try expectEqual(@as(u64, 0), sink.dropped.load(.monotonic));

    // Both the input frame and the output buffer are back on the free list.
    const a = try pool.get(size);
    const b = try pool.get(size);
    try expectEqual(buf.ptr, a.ptr);
    try expect(pool.put(a));
    try expect(pool.put(b));
}

test "json sink drops a corrupt frame and releases the buffer" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = JsonSink(CaptureWriter).init(allocator, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "just a message");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    buf[1] ^= 0xFF; // corrupt the CRC

    try std.testing.expectError(error.WriteFailed, sink.write(&pool, buf[0..size]));
    try expectEqual(@as(u64, 1), sink.dropped.load(.monotonic));
    try expectEqual(@as(usize, 0), out.written().len);

    const again = try pool.get(size);
    try expectEqual(buf.ptr, again.ptr);
    try expect(pool.put(again));
}

test "json sink drops malformed payloads without writing" {
    const pool_mod = @import("buffer_pool.zig");
    const Pool = pool_mod.BufferPool(false);
    const consts = @import("consts.zig");

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 4, 2048);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = JsonSink(CaptureWriter).init(allocator, &out);
    defer sink.deinit();

    // Bad version.
    {
        var pb = viewer.PB{};
        defer pb.deinit(allocator);
        try pb.le(allocator, u16, 99);
        try pb.le(allocator, u64, 0);
        try pb.byte(allocator, 30);
        try pb.byte(allocator, 0);
        try pb.uvarint(allocator, 0);
        try writeFramed(&pool, &sink, &pb);
    }
    // Truncated message: the length says more than the payload holds.
    {
        var pb = viewer.PB{};
        defer pb.deinit(allocator);
        try pb.le(allocator, u16, consts.version);
        try pb.le(allocator, u64, 0);
        try pb.byte(allocator, @intFromEnum(consts.logLevel.info));
        try pb.byte(allocator, 0);
        try pb.uvarint(allocator, 5);
        try pb.raw(allocator, "ab");
        try writeFramed(&pool, &sink, &pb);
    }
    // Unknown context kind byte.
    {
        var pb = viewer.PB{};
        defer pb.deinit(allocator);
        try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
        try pb.msg(allocator, "m");
        try pb.byte(allocator, 200);
        try writeFramed(&pool, &sink, &pb);
    }
    // Unknown predefined key code.
    {
        var pb = viewer.PB{};
        defer pb.deinit(allocator);
        try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
        try pb.msg(allocator, "m");
        try pb.byte(allocator, 0);
        try pb.uvarint(allocator, 9);
        try writeFramed(&pool, &sink, &pb);
    }

    try expectEqual(@as(u64, 4), sink.dropped.load(.monotonic));
    try expectEqual(@as(usize, 0), out.written().len);
}

test "json sink reuses state across records" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 4096);
    defer pool.deinit();

    var out = CaptureWriter{};
    defer out.deinit();

    var sink = JsonSink(CaptureWriter).init(allocator, &out);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 1, @intFromEnum(consts.logLevel.debug));
    try pb.msg(allocator, "one");
    try pb.key(allocator, .int64, "a");
    try pb.le(allocator, u64, 1);
    try writeFramed(&pool, &sink, &pb);

    var pb2 = viewer.PB{};
    defer pb2.deinit(allocator);
    try pb2.header(allocator, 1_000_000, @intFromEnum(consts.logLevel.warning));
    try pb2.msg(allocator, "two");
    try writeFramed(&pool, &sink, &pb2);

    try expectEqualSlices(
        u8,
        "{\"time\":1,\"level\":\"D\",\"message\":\"one\",\"a\":1}\n" ++
            "{\"time\":1000000,\"level\":\"W\",\"message\":\"two\"}\n",
        out.written(),
    );
}

test "json sink writes a JSONL line to a file" {
    const pool_mod = @import("buffer_pool.zig");
    const consts = @import("consts.zig");
    const Pool = pool_mod.BufferPool(false);
    const Io = std.Io;

    const allocator = std.testing.allocator;
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    const path = "test_json_writer_file.tmp";
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true });
    defer {
        file.close(io);
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    var file_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &file_buffer);

    var sink = JsonSink(Io.Writer).init(allocator, &file_writer.interface);
    defer sink.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(allocator);
    try pb.header(allocator, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(allocator, "to a file");

    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = try sink.write(&pool, buf[0..size]);
    try file_writer.interface.flush();

    var read_buf: [128]u8 = undefined;
    const n = try file.readPositionalAll(io, &read_buf, 0);
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"to a file\"}\n",
        read_buf[0..n],
    );
}

/// Frames `pb`'s payload and writes it through a JSON sink. A drop is not an
/// error here: callers assert on `sink.dropped` and the captured output.
fn writeFramed(pool: anytype, sink: anytype, pb: *const viewer.PB) !void {
    const size = frameSize(pb.list.items.len);
    const buf = try pool.get(size);
    frameInto(buf[0..size], pb.list.items);
    _ = sink.write(pool, buf[0..size]) catch {};
}

// For manual testing only. Writing to stdout corrupts the build runner's
// `--listen=-` protocol stream, which hangs `zig build test`, so this only
// runs when stdout is an interactive terminal.
test "pretty sink manual try" {
    const pool_mod = @import("buffer_pool.zig");
    const logger = @import("logger.zig");
    const writer_mod = @import("writer.zig");

    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;

    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    const Writer = FdWriter;

    const Sink = writer_mod.PrettySink(Writer);
    var writer = Writer.init(2);

    var sink = Sink.init(
        std.testing.allocator,
        .light,
        &writer,
    );
    defer sink.deinit();

    var log = logger.Logger(Pool, Sink).init(&pool, &sink);
    defer log.deinit();

    log.debug("message", .{
        .name = "Name",
        .value = 12,
        .group = .{
            .id = 0xFE,
            .weight = 100,
            .array = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 7 },
            .children = [_]u16{ 8, 7, 6, 5, 4, 3, 2, 1, 0 },
        },
    });

    log.info("info", .{
        .name = "Name",
        .weight = 80,
        .age = 44,
    });
}

// For manual testing only. Writing to stdout corrupts the build runner's
// `--listen=-` protocol stream, which hangs `zig build test`, so this only
// runs when stdout is an interactive terminal.
test "json sink manual try" {
    const pool_mod = @import("buffer_pool.zig");
    const logger = @import("logger.zig");
    const writer_mod = @import("writer.zig");

    const Pool = pool_mod.BufferPool(false);

    const allocator = std.testing.allocator;

    var pool = try Pool.init(allocator, 2, 2048);
    defer pool.deinit();

    const Writer = FdWriter;

    const Sink = writer_mod.JsonSink(Writer);
    var writer = Writer.init(2);

    var sink = Sink.init(
        std.testing.allocator,
        &writer,
    );
    defer sink.deinit();

    var log = logger.Logger(Pool, Sink).init(&pool, &sink);
    defer log.deinit();

    log.debug("message", .{
        .name = "Name",
        .value = 12,
        .group = .{
            .id = 0xFE,
            .weight = 100,
            .array = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 7 },
            .children = [_]u16{ 8, 7, 6, 5, 4, 3, 2, 1, 0 },
        },
    });

    log.info("info", .{
        .name = "Name",
        .weight = 80,
        .age = 44,
    });
}
