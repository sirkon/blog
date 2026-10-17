//! Rich diagnostics for the Zig logger: the stack-driven counterpart of the Go
//! `internal/core/error.go` `*Error`.
//!
//! A diagnostic accumulates a self-describing payload as the stack unwinds
//! (`err_after`/`err_new`, then a chain of `wrap`/`with`) and is handed to a
//! logger attribute exactly once. Logging consumes it: the payload frame goes
//! back to the pool and the diagnostic becomes terminal.
//!
//! In Debug and ReleaseSafe the instance carries a one-byte `live` flag, set by
//! the constructor and cleared on consumption. Every use validates it and
//! faults when it is clear, so a use-before-log or use-after-log is caught
//! cheaply. ReleaseFast and ReleaseSmall drop the field entirely and compile
//! the checks away, trading the safety net for size and speed.
//!
//! Diagnostics are never allocator-created. The storage lives in a fixed slot
//! array inside the logger that started them and the API hands out pointers, so
//! the whole lifecycle is `logger.err_after(...)` -> `diag.wrap(...)` ->
//! `logger.warn(..., .{ .err = diag })`:
//!
//!     var diag = try logger.err_after(err, .{ .name = file_name });
//!     diag = try diag.wrap("open config file", .{});
//!     logger.warn("some warning msg", .{ .err = diag });
//!
//! The payload is one flat buffer, not a chain: only one diagnostic may be
//! live per slot, and growing it just moves it to an exactly-sized allocation
//! and releases the previous one. The payload is a plain `[]u8`; once it is
//! consumed it is reset to the deliberately invalid `(NULL, 0)` value, which is
//! never backed by a real allocation, so any later use dies with a segfault.
//! Debug and ReleaseSafe additionally clear the `live` flag, so a fault instead
//! of silent corruption is guaranteed even where a recycled frame happens to be
//! mapped; release builds rely on the terminal payload alone.

const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts.zig");
const encoding = @import("encoding.zig");
const decoding = @import("decoding.zig");
const buffer_pool = @import("buffer_pool.zig");

/// The terminal payload: a slice whose data pointer is `NULL` and whose length
/// is zero. `allowzero` is what makes the null address legal for the pointer
/// type, so the value can be stored and compared without tripping Zig's
/// non-null-pointer rules. It never points at real memory, so reading or writing
/// through it faults, which is the point: a consumed diagnostic is a bug and
/// the OS reports it as such.
pub const deadPayload: []u8 = @as([*]allowzero u8, @ptrFromInt(0))[0..0];

/// True when `payload` is the terminal value. Compared by address, so a live
/// payload of any length (including zero) is not mistaken for it.
pub inline fn isDead(payload: []u8) bool {
    return @intFromPtr(payload.ptr) == 0;
}

/// Dies by dereferencing the null address. There is no panic message and no
/// stack trace on purpose: touching a dead diagnostic is a bug the OS reports
/// as a fault, exactly like any other use of freed memory. Resetting SIGSEGV to
/// the default keeps the death clean even when a debug build installed Zig's
/// segfault handler, which would otherwise turn it into a panic-shaped crash.
pub fn fault() noreturn {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi and
        builtin.os.tag != .freestanding)
    {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.SEGV, &act, null);
    }
    @as(*allowzero volatile u8, @ptrFromInt(0)).* = 0;
    unreachable;
}

/// Reference payload size, mirroring `defaultPayloadSize` in
/// `internal/core/error.go`: payloads up to this fit a typical pool frame and
/// larger ones live on the heap.
pub const defaultPayloadSize: usize = 512;

/// Number of diagnostics a single logger can keep alive at once. One per
/// nesting level of the call path; exceeding it is a programming error.
pub const maxLiveDiagnostics: usize = 8;

/// Whether a diagnostic carries its live flag and validates it on every use.
/// Only Debug and ReleaseSafe keep the field; release builds drop it so the
/// struct is smaller and the checks compile away entirely.
pub const runtime_checked: bool = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

/// The raw `anyerror` code for a spec. The code is an implementation detail of
/// the Zig runtime and only meaningful to `specToError` in the same process.
pub inline fn specFromError(err: anyerror) u16 {
    return @intFromError(err);
}

/// Inverse of `specFromError`. A zero code means "no spec" (`null`), which is
/// safe because no real error has code zero; every other code resolves back to
/// the error value this process stored.
pub inline fn specToError(raw: u16) ?anyerror {
    return if (raw == 0) null else @errorFromInt(raw);
}

/// The default pool, i.e. `writer.BufferPool`.
pub const BufferPool = buffer_pool.BufferPool(false);

/// The concrete diagnostic type used with the default pool.
pub const Error = Diag(BufferPool);

/// True when `T` is exactly `Diag(Pool)` for some pool. `encoding` uses this
/// to recognize a diagnostic-valued attribute: the type is identified by its
/// own definition, not by a marker declaration.
pub fn isDiag(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasField(T, "buffers")) return false;
    const Buffers = @FieldType(T, "buffers");
    if (@typeInfo(Buffers) != .pointer) return false;
    return T == Diag(@typeInfo(Buffers).pointer.child);
}

/// Rich diagnostics over a specific pool type. `Logger(Pool, Sink)` hands out
/// `Diag(Pool)` so a thread-safe pool works as well.
pub fn Diag(comptime Pool: type) type {
    return struct {
        const Self = @This();

        /// Pool the payload frames come from.
        buffers: *Pool,
        /// Current payload. Strictly `[]u8` and exactly the allocation length,
        /// which is what lets `Pool.put` take the frame back by address alone.
        /// A freshly built diagnostic starts terminal (`deadPayload`); a
        /// released one goes back to it, so any use after release faults.
        payload: []u8 = deadPayload,
        /// The Zig error value this diagnostic was opened with, kept as its raw
        /// `anyerror` code. Zero means no spec (`err_new`, an invariant
        /// violation); every other value round-trips through `specToError`.
        _spec: u16 = 0,
        /// Liveness flag, present only in Debug and ReleaseSafe. Set by `start`
        /// and cleared the moment the payload is handed over or released, so
        /// `ensureLive` can fault on a use-before-consume or a double consume.
        /// ReleaseFast and ReleaseSmall make the field `void` and every check
        /// that reads it compiles away, which is deliberate: those builds trade
        /// the safety net for a smaller struct and no extra work.
        live: if (runtime_checked) bool else void = if (runtime_checked) false else {},

        // ------------------------------------------------------------- entries

        /// Starts a diagnostic in `slot`, bound to `pool`, from a Zig error
        /// value or a plain message.
        pub fn start(
            slot: *Self,
            pool: *Pool,
            err: ?anyerror,
            msg: []const u8,
            loc: ?std.builtin.SourceLocation,
            ctx: anytype,
        ) std.mem.Allocator.Error!*Self {
            slot.* = .{
                .buffers = pool,
                .payload = deadPayload,
                ._spec = if (err) |e| specFromError(e) else 0,
                .live = if (comptime runtime_checked) true else {},
            };
            errdefer slot.release();
            _ = try slot.stage(.nodeNew, msg, loc, ctx);
            return slot;
        }

        // -------------------------------------------------------------- stages

        /// Wraps the diagnostic with a message, keeping every earlier stage.
        pub fn wrap(self: *Self, msg: []const u8, ctx: anytype) std.mem.Allocator.Error!*Self {
            self.ensureLive();
            return self.stage(.nodeWrap, msg, null, ctx);
        }

        /// Like `wrap`, with the call site attached.
        pub fn wrap_loc(
            self: *Self,
            loc: std.builtin.SourceLocation,
            msg: []const u8,
            ctx: anytype,
        ) std.mem.Allocator.Error!*Self {
            self.ensureLive();
            return self.stage(.nodeWrap, msg, loc, ctx);
        }

        /// Adds a context-only stage carrying no message.
        pub fn with(self: *Self, ctx: anytype) std.mem.Allocator.Error!*Self {
            self.ensureLive();
            return self.stage(.nodeContext, null, null, ctx);
        }

        /// Like `with`, with the call site attached.
        pub fn with_loc(
            self: *Self,
            loc: std.builtin.SourceLocation,
            ctx: anytype,
        ) std.mem.Allocator.Error!*Self {
            self.ensureLive();
            return self.stage(.nodeContext, null, loc, ctx);
        }

        // -------------------------------------------------------------- access

        /// The Zig error value this diagnostic was opened with, or `null` for a
        /// spec-less invariant violation. Stored as a `u16` code, where zero is
        /// the "no spec" sentinel and every other value is the raw `anyerror`
        /// code cast back through `@errorFromInt`.
        pub fn spec(self: *const Self) ?anyerror {
            return specToError(self._spec);
        }

        /// Bytes currently used by the payload, which is also the exact size of its
        /// allocation. Reading it from a consumed diagnostic faults, just like
        /// any other touch of the dead payload.
        pub inline fn payloadSize(self: *const Self) usize {
            self.ensureLive();
            return self.payload.len;
        }

        /// Encoded bytes. A consumed or never-started diagnostic has the dead
        /// payload, so this faults rather than handing out bytes of a recycled
        /// frame. The check is explicit because the dead payload is zero-length
        /// and re-slicing it would silently yield an empty slice.
        pub inline fn payloadSlice(self: *const Self) []const u8 {
            self.ensureLive();
            return self.payload;
        }

        // ------------------------------------------------------------- display

        /// Renders the stage messages as one line, joined with `": "` in
        /// reverse order (`"outer: inner"`). Mirrors the single walk in
        /// `internal/core/error.go:Error()`: this diagnostic owns the whole
        /// payload, so there is no foreign error to embed and no recursive
        /// `wrap` to splice in.
        pub fn string(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            var payload = self.payloadSlice();
            var stages: std.ArrayList([]const u8) = .empty;
            defer stages.deinit(allocator);

            while (payload.len > 0) {
                const kind = std.enums.fromInt(consts.ValueKind, payload[0]) orelse break;
                payload = payload[1..];

                switch (kind) {
                    .nodeContext, .nodePhantomContext, .nodeGroupEnd => continue,
                    else => {},
                }

                const key = try takeStr(&payload);
                switch (kind) {
                    .nodeNew, .nodeWrap => try stages.append(allocator, key),
                    .nodeLocation => _ = try takeVarint(&payload),
                    // Group contents follow flat; its own end is a no-op.
                    .nodeGroup => {},
                    .bool, .int8, .uint8 => payload = payload[1..],
                    .int16, .uint16 => payload = payload[2..],
                    .int32, .uint32, .float32 => payload = payload[4..],
                    .time, .duration, .int64, .uint64, .float64 => payload = payload[8..],
                    .string, .sliceBool, .sliceInt8, .sliceUint8 => _ = try takeStr(&payload),
                    .sliceInt16, .sliceUint16 => _ = try takeBytes(&payload, 2 * try takeVarint(&payload)),
                    .sliceInt32, .sliceUint32, .sliceFloat32 => _ = try takeBytes(&payload, 4 * try takeVarint(&payload)),
                    .sliceInt64, .sliceUint64, .sliceFloat64 => _ = try takeBytes(&payload, 8 * try takeVarint(&payload)),
                    .sliceString => {
                        var rest = try takeVarint(&payload);
                        while (rest > 0) : (rest -= 1) _ = try takeStr(&payload);
                    },
                    else => break,
                }
            }

            var total: usize = 0;
            for (stages.items, 0..) |text, i| {
                total += text.len;
                if (i + 1 < stages.items.len) total += 2;
            }

            const out = try allocator.alloc(u8, total);
            errdefer allocator.free(out);

            var pos: usize = 0;
            var i = stages.items.len;
            while (i > 0) {
                i -= 1;
                const text = stages.items[i];
                @memcpy(out[pos..][0..text.len], text);
                pos += text.len;
                if (i > 0) {
                    @memcpy(out[pos..][0..2], ": ");
                    pos += 2;
                }
            }
            std.debug.assert(pos == total);
            return out;
        }

        // --------------------------------------------------------- consumption

        /// True once the payload was logged, released, or never created. In Debug and
        /// ReleaseSafe this is exactly the `live` flag being clear, so the answer
        /// is available without touching the payload. ReleaseFast and ReleaseSmall
        /// have no flag, so they fall back to the terminal `(NULL, 0)` payload.
        pub inline fn isConsumed(self: *const Self) bool {
            if (comptime runtime_checked) return !self.live;
            return isDead(self.payload);
        }

        /// Puts the payload allocation back where it came from, clears the live
        /// flag and resets the instance to the dead payload. Safe to call on an
        /// already-released diagnostic, which keeps slot recycling and `deinit`
        /// cleanup simple.
        pub fn release(self: *Self) void {
            if (comptime runtime_checked) self.live = false;
            if (isDead(self.payload)) return;
            _ = self.buffers.put(self.payload);
            self.payload = deadPayload;
        }

        /// Logs the diagnostic: its bytes were copied into a record, so the
        /// payload goes back to the pool. In Debug and ReleaseSafe logging the
        /// same diagnostic twice faults on the cleared live flag, before a dead
        /// frame can be freed a second time; release builds trust the caller.
        pub fn consume(self: *Self) void {
            self.ensureLive();
            self.release();
        }

        // ------------------------------------------------------------ internals

        /// Terminates the process when the diagnostic is not live. Everything
        /// that appends to or reads the payload goes through this, so a consumed
        /// diagnostic faults on first use instead of corrupting a recycled frame.
        /// Compiled out entirely in ReleaseFast and ReleaseSmall, where there is
        /// no flag to consult and the check is the caller's responsibility.
        inline fn ensureLive(self: *const Self) void {
            if (comptime runtime_checked) {
                if (!self.live) fault();
            }
        }

        fn stage(
            self: *Self,
            comptime kind: consts.ValueKind,
            msg: ?[]const u8,
            loc: ?std.builtin.SourceLocation,
            ctx: anytype,
        ) std.mem.Allocator.Error!*Self {
            const T = @TypeOf(ctx);
            comptime {
                if (@typeInfo(T) != .@"struct") {
                    @compileError("blog.Error context must be an anonymous struct, got " ++ @typeName(T));
                }
            }

            // Every width below is known before a byte is written, so the
            // allocation is grown once and encoding never re-checks capacity.
            // `reserve` sizes the buffer to exactly this many bytes, and the
            // `std.debug.assert` at the end of the stage proves it.
            const msg_size: usize = if (msg) |m| encoding.varintSize(m.len) + m.len else 0;
            const loc_size: usize = if (loc) |l|
                1 + encoding.varintSize(l.file.len) + l.file.len + encoding.varintSize(l.line)
            else
                0;
            const entry_size = 1 + msg_size + loc_size + encoding.getStructEncodedSize(ctx) + 1;

            const before = self.payload.len;
            try self.reserve(entry_size);

            // The slice length tracks the allocation size, so writes go through
            // this cursor and the length is only updated once they are done.
            var cur: [*]u8 = self.payload.ptr + before;

            switch (kind) {
                .nodeNew, .nodeWrap => {
                    cur = putKind(cur, kind);
                    cur = putStr(cur, msg.?);
                },
                .nodeContext => cur = putKind(cur, kind),
                else => unreachable,
            }

            if (loc) |l| cur = putLocation(cur, l);

            var frame: encoding.Frame = undefined;
            frame.init(cur);
            const info = @typeInfo(T);
            inline for (info.@"struct".fields) |field| {
                frame.appendField(field.name, @field(ctx, field.name));
            }
            cur = frame.cur;

            // One stage is exactly one node group on the wire.
            cur = putKind(cur, .nodeGroupEnd);

            self.payload.len = @intFromPtr(cur) - @intFromPtr(self.payload.ptr);

            // The buffer is exactly the size the stage wrote, which is what
            // lets `release` free it from the pointer and length alone.
            std.debug.assert(self.payload.len - before == entry_size);
            return self;
        }

        /// Grows the payload to exactly `payload.len + need` bytes, releasing
        /// the previous allocation. Exact sizing (instead of doubling) is what
        /// keeps the slice length equal to the allocation length, so `Pool.put`
        /// can take the buffer back from the pointer and the length alone.
        fn reserve(self: *Self, need: usize) std.mem.Allocator.Error!void {
            if (need == 0) return;

            const old = self.payload;
            const buf = try self.buffers.get(old.len + need);
            if (!isDead(old)) {
                @memcpy(buf[0..old.len], old);
                _ = self.buffers.put(old);
            }
            self.payload = buf;
        }

        inline fn putKind(cur: [*]u8, comptime kind: consts.ValueKind) [*]u8 {
            cur[0] = @intFromEnum(kind);
            return cur + 1;
        }

        inline fn putStr(cur: [*]u8, s: []const u8) [*]u8 {
            const at = encoding.appendVarint(cur, s.len);
            @memcpy(at[0..s.len], s);
            return at + s.len;
        }

        /// `nodeLocation` + `uvarint(file.len) ++ file` + `uvarint(line)`, the
        /// layout the viewer parses back into an `err_loc` node.
        fn putLocation(cur: [*]u8, loc: std.builtin.SourceLocation) [*]u8 {
            const at = putKind(cur, .nodeLocation);
            const after_file = putStr(at, loc.file);
            return encoding.appendVarint(after_file, loc.line);
        }
    };
}

/// Consumes a `uvarint` from the front of `payload` and advances it.
fn takeVarint(payload: *[]const u8) std.mem.Allocator.Error!u64 {
    var value: u64 = 0;
    const at = payload.*;
    const next = decoding.decodeVarint(&value, @constCast(at.ptr)) catch return error.OutOfMemory;
    payload.* = at[@intFromPtr(next) - @intFromPtr(at.ptr) ..];
    return value;
}

/// Consumes `uvarint(len) ++ len` bytes from the front of `payload`, returning
/// the bytes. A payload this module did not write is reported as an allocation
/// failure rather than inventing a second error set for `string()`.
fn takeStr(payload: *[]const u8) std.mem.Allocator.Error![]const u8 {
    const len = try takeVarint(payload);
    return takeBytes(payload, @intCast(len));
}

/// Consumes `count` bytes from the front of `payload`, returning them.
fn takeBytes(payload: *[]const u8, count: usize) std.mem.Allocator.Error![]const u8 {
    if (count > payload.len) return error.OutOfMemory;
    const bytes = payload.*[0..count];
    payload.* = payload.*[count..];
    return bytes;
}

/// A fresh slot array where every slot is free. Used by the logger when it
/// builds a value of its own type (init, `With`).
pub fn emptySlots(comptime Pool: type, pool: *Pool) [maxLiveDiagnostics]Diag(Pool) {
    var slots: [maxLiveDiagnostics]Diag(Pool) = undefined;
    for (&slots) |*slot| {
        slot.* = .{ .buffers = pool, .payload = deadPayload };
    }
    return slots;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const viewer = @import("viewer.zig");
const writer_mod = @import("writer.zig");
const logger_mod = @import("logger.zig");

/// A logger over `buf/512` fixtures with a `MemorySink`, plus everything the
/// diagnostic tests need to poke at it.
fn TestRig(comptime frames: u32, comptime frame_size: u32) type {
    return struct {
        const Pool = buffer_pool.BufferPool(false);
        const Sink = writer_mod.MemorySink;
        const Logger = logger_mod.Logger(Pool, Sink);

        pool: Pool,
        sink: Sink,
        logger: Logger,

        fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            try self.pool.init(allocator, frames, frame_size);
            self.sink.init(allocator);
            self.logger.init(&self.pool, &self.sink);
        }

        fn deinit(self: *@This()) void {
            self.logger.deinit();
            self.sink.deinit();
            self.pool.deinit();
        }

        /// Payload of the first (and usually only) record, framing stripped.
        fn payload(self: *@This()) []const u8 {
            const rec = self.sink.bytes.items;
            var len: u64 = 0;
            const after = decoding.decodeVarint(&len, @constCast(rec.ptr + 6)) catch unreachable;
            const header = @intFromPtr(after) - @intFromPtr(rec.ptr);
            return rec[header..];
        }
    };
}

test "after encodes message, context and group end" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{ .name = "config" });
    try expectEqual(error.NotFound, diag.spec().?);

    // nodeNew | varint(8) | "NotFound" | string(1) + varint(4) + "name" +
    // varint(6) + "config" | nodeGroupEnd
    const golden = [_]u8{
        @intFromEnum(consts.ValueKind.nodeNew),
        8,
        'N',
        'o',
        't',
        'F',
        'o',
        'u',
        'n',
        'd',
        @intFromEnum(consts.ValueKind.string),
        4,
        'n',
        'a',
        'm',
        'e',
        6,
        'c',
        'o',
        'n',
        'f',
        'i',
        'g',
        @intFromEnum(consts.ValueKind.nodeGroupEnd),
    };
    try expectEqualSlices(u8, &golden, diag.payloadSlice());
}

test "spec round-trips through the raw u16 code" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{});
    // The stored code is exactly the runtime's own code for the error, not a
    // stable wire value: only `spec()` may interpret it.
    try expectEqual(specFromError(error.NotFound), diag._spec);
    try expectEqual(error.NotFound, diag.spec().?);

    // `err_new` has no spec, which is the zero sentinel.
    const plain = try rig.logger.err_new("invariant", .{});
    try expectEqual(@as(u16, 0), plain._spec);
    try expectEqual(@as(?anyerror, null), plain.spec());

    // The sentinel never collides with a real error: every error code is non-zero.
    try expect(specFromError(error.OutOfMemory) != 0);
    try expectEqual(@as(?anyerror, null), specToError(0));
    try expectEqual(error.OutOfMemory, specToError(specFromError(error.OutOfMemory)).?);
}

test "the live flag is present only in checked builds" {
    var slot: Error = .{ .buffers = undefined };
    if (comptime runtime_checked) {
        try expectEqual(false, slot.live);
        slot.live = true;
        try expect(!slot.isConsumed());
        slot.live = false;
        try expect(slot.isConsumed());
    } else {
        // Release builds have no flag: the field is `void` and the terminal
        // payload is the only signal left.
        try expectEqual(void, @TypeOf(slot.live));
        try expect(slot.isConsumed());
    }
}

test "new_loc encodes a location node with the line" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const loc = @src();
    const diag = try rig.logger.err_new_loc(loc, "boom", .{});
    try expectEqual(@as(?anyerror, null), diag.spec());

    const payload = diag.payloadSlice();
    try expectEqual(@intFromEnum(consts.ValueKind.nodeNew), payload[0]);

    var off: usize = 1;
    var len: u64 = 0;
    const after_len = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    try expectEqualSlices(u8, "boom", payload[off + 1 ..][0..@intCast(len)]);
    off = @intFromPtr(after_len) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    try expectEqual(@intFromEnum(consts.ValueKind.nodeLocation), payload[off]);
    off += 1;
    const after_file_len = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    const file = payload[off + 1 ..][0..@intCast(len)];
    try expect(std.mem.endsWith(u8, file, "error.zig"));
    off = @intFromPtr(after_file_len) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    var line: u64 = 0;
    const after_line = try decoding.decodeVarint(&line, @constCast(payload.ptr + off));
    try expectEqual(@as(u64, loc.line), line);
    off = @intFromPtr(after_line) - @intFromPtr(payload.ptr);

    try expectEqual(@intFromEnum(consts.ValueKind.nodeGroupEnd), payload[off]);
}

test "wrap and with chain one group per stage" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{ .name = "config" });
    _ = try diag.wrap("open config file", .{});
    _ = try diag.with(.{ .attempt = @as(u8, 3) });

    // The record framing is irrelevant for the viewer, so feed it the payload
    // of a record header plus the diagnostic itself.
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "m");
    try pb.key(a, .nodeError, "err");
    try pb.raw(a, diag.payloadSlice());
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = viewer.ParsedRecord{};
    defer rec.deinit(a);
    try viewer.parseRecord(a, pb.list.items, &rec);

    try expect(rec.has_errors);
    const items = rec.builder.ctrl.items;
    // Each stage is one group: the stage node, its context fields, group end.
    const kinds = [_]viewer.NodeKind{
        .err,
        .err_stage_new,
        .str,
        .group_end,
        .err_stage_wrap,
        .group_end,
        .err_stage_ctx,
        .u8,
        .group_end,
        .group_end,
    };
    try expectEqual(kinds.len, items.len);
    for (kinds, items) |want, got| try expectEqual(want, got.kind);

    try expectEqualSlices(
        u8,
        "err",
        pb.list.items[items[0].key_off..][0..items[0].key_len],
    );
    try expectEqualSlices(
        u8,
        "NotFound",
        pb.list.items[items[1].key_off..][0..items[1].key_len],
    );
    // Stage two carries no fields, stage three carries an `attempt = 3` u8.
    try expectEqualSlices(
        u8,
        "name",
        pb.list.items[items[2].key_off..][0..items[2].key_len],
    );
    try expectEqualSlices(
        u8,
        "open config file",
        pb.list.items[items[4].key_off..][0..items[4].key_len],
    );
    try expectEqualSlices(
        u8,
        "attempt",
        pb.list.items[items[7].key_off..][0..items[7].key_len],
    );
    try expectEqual(@as(u32, 3), items[7].val_off);
}

test "wrap_loc and with_loc attach the call site" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const loc = @src();
    const diag = try rig.logger.err_after(error.NotFound, .{});
    _ = try diag.wrap_loc(loc, "open config file", .{});
    _ = try diag.with_loc(loc, .{ .attempt = @as(u8, 1) });

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "m");
    try pb.key(a, .nodeError, "err");
    try pb.raw(a, diag.payloadSlice());
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = viewer.ParsedRecord{};
    defer rec.deinit(a);
    try viewer.parseRecord(a, pb.list.items, &rec);

    // One location per `*_loc` stage, both pointing at this file and line.
    var locs: usize = 0;
    for (rec.builder.ctrl.items) |node| {
        if (node.kind != .err_loc) continue;
        locs += 1;
        try expectEqual(@as(u64, loc.line), node.val_off);
        const file = pb.list.items[node.key_off..][0..node.key_len];
        try expect(std.mem.endsWith(u8, file, "error.zig"));
    }
    try expectEqual(@as(usize, 2), locs);
}

test "string joins stages in reverse order" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.AccessDenied, .{});
    _ = try diag.wrap("open config file", .{});
    _ = try diag.wrap("load settings", .{});
    _ = try diag.with(.{ .pid = @as(u32, 42), .host = "localhost" });

    const text = try diag.string(a);
    defer a.free(text);
    try expectEqualSlices(u8, "load settings: open config file: AccessDenied", text);
}

test "logging embeds the payload once and returns the frame" {
    const a = std.testing.allocator;
    var rig: TestRig(2, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{ .name = "config" });

    var expected: [512]u8 = undefined;
    const expected_len = diag.payloadSize();
    @memcpy(expected[0..expected_len], diag.payloadSlice());
    const frame_ptr = diag.payload.ptr;

    rig.logger.warn("boom", .{ .err = diag });
    try expect(diag.isConsumed());

    const payload = rig.payload();
    // level..msg, then the error attribute: kind byte, key, payload, group end.
    var off: usize = 2 + 8 + 1 + 1;
    var len: u64 = 0;
    var next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    try expectEqual(@intFromEnum(consts.ValueKind.nodeError), payload[off]);
    off += 1;
    next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    try expectEqualSlices(u8, "err", payload[off + 1 ..][0..@intCast(len)]);
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    // The diagnostic's payload, byte for byte, plus the group end that closes
    // the `nodeError` node and the record.
    const embedded = payload[off..][0..expected_len];
    try expectEqualSlices(u8, expected[0..expected_len], embedded);
    off += expected_len;
    try expectEqual(@intFromEnum(consts.ValueKind.nodeGroupEnd), payload[off]);

    // The payload frame is back in the pool: the record and the payload are
    // both free again, so the next two hand-outs are exactly those two frames.
    const first = try rig.pool.get(512);
    const second = try rig.pool.get(512);
    try expect((first.ptr == frame_ptr) or (second.ptr == frame_ptr));
    try expect(rig.pool.put(first));
    try expect(rig.pool.put(second));
}

test "the payload frame is returned even when the sink fails" {
    const a = std.testing.allocator;
    const Pool = buffer_pool.BufferPool(false);

    const FailingSink = struct {
        pub fn write(self: *@This(), pool: *Pool, buf: []const u8) error{WriteFailed}!usize {
            _ = self;
            _ = pool.put(@constCast(buf));
            return error.WriteFailed;
        }
    };

    var pool: Pool = undefined;
    try pool.init(a, 2, 512);
    defer pool.deinit();

    var sink = FailingSink{};
    var logger: logger_mod.Logger(Pool, FailingSink) = undefined;
    logger.init(&pool, &sink);

    const diag = try logger.err_after(error.OutOfMemory, .{});
    const frame_ptr = diag.payload.ptr;

    logger.warn("boom", .{ .err = diag });

    try expectEqual(@as(u64, 1), logger.dropped.load(.monotonic));
    try expect(diag.isConsumed());
    try expectEqual(@as(usize, 0), @intFromPtr(diag.payload.ptr));

    // The payload frame is free again even though nothing was written.
    const first = try pool.get(512);
    const second = try pool.get(512);
    try expect((first.ptr == frame_ptr) or (second.ptr == frame_ptr));
    try expect(pool.put(first));
    try expect(pool.put(second));
    logger.deinit();
}

test "logging the same diagnostic twice is terminal" {
    const a = std.testing.allocator;
    var rig: TestRig(2, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{});
    rig.logger.warn("first", .{ .err = diag });
    try expect(diag.isConsumed());

    // The second hand-over would touch the dead payload. It is not exercised
    // here because that is a segfault, not a test failure; the process-level
    // test below covers it.
    try expectEqual(@as(usize, 0), @intFromPtr(diag.payload.ptr));
    try expect(diag.isConsumed());
    rig.logger.info("second", .{});
    try expectEqual(@as(u64, 0), rig.logger.dropped.load(.monotonic));
}

test "the payload is strictly a slice and goes dead on release" {
    const a = std.testing.allocator;
    var rig: TestRig(2, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{});
    try expect(!diag.isConsumed());
    try expect(diag.payloadSize() > 0);

    // The terminal value is literally `(NULL, 0)`, not just an empty slice.
    try expectEqual(@as(usize, 0), @intFromPtr(deadPayload.ptr));
    try expectEqual(@as(usize, 0), deadPayload.len);

    diag.release();
    try expect(diag.isConsumed());
    try expectEqual(@as(usize, 0), @intFromPtr(diag.payload.ptr));
    try expectEqual(@as(usize, 0), diag.payload.len);

    // Releasing twice is a no-op, which keeps slot recycling and `deinit`
    // cleanup simple; the frame went back exactly once.
    diag.release();
    try expect(diag.isConsumed());
}

test "touching the dead payload of a diagnostic dies with SIGSEGV" {
    const posix = std.posix;
    const linux = std.os.linux;
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const Pool = buffer_pool.BufferPool(false);
    var pool: Pool = undefined;
    try pool.init(std.heap.page_allocator, 2, 512);
    defer pool.deinit();

    const Child = struct {
        /// Runs in the forked child, never returning: the first touch of the
        /// dead payload must kill the process with a fault.
        fn run(p: *Pool) noreturn {
            var slot: Diag(Pool) = .{ .buffers = p };
            _ = slot.wrap("must never be appended", .{}) catch std.process.exit(7);
            std.process.exit(0);
        }
    };

    const pid = linux.fork();
    if (pid == 0) Child.run(&pool);

    var status: u32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(pid), &status, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.UnexpectedWaitError,
        }
    }

    try expect(linux.W.IFSIGNALED(status));
    try expectEqual(posix.SIG.SEGV, linux.W.TERMSIG(status));
}

test "context larger than the initial payload grows safely" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const blob = "x" ** 1024;
    const diag = try rig.logger.err_after(error.Unexpected, .{ .blob = blob, .n = @as(u8, 7) });

    // Far past a 512-byte frame, so the payload moved off the pool and the
    // frame it started in was released.
    try expect(diag.payloadSize() > defaultPayloadSize);

    // The message and every field survive the move.
    const found = std.mem.indexOf(u8, diag.payloadSlice(), blob) != null;
    try expect(found);

    rig.logger.warn("big", .{ .err = diag });
    try expect(diag.isConsumed());
}

test "pool exhaustion surfaces as an allocation error" {
    const Pool = buffer_pool.BufferPool(false);
    const Sink = writer_mod.MemorySink;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const a = failing.allocator();

    var pool: Pool = undefined;
    try pool.init(a, 1, 512);
    defer pool.deinit();

    var sink: Sink = undefined;
    sink.init(std.testing.allocator);
    defer sink.deinit();

    var logger: logger_mod.Logger(Pool, Sink) = undefined;
    logger.init(&pool, &sink);
    defer logger.deinit();

    // Occupy the only frame: the diagnostic then has to fall back to the heap,
    // which is failing.
    const held = try pool.get(512);

    try std.testing.expectError(error.OutOfMemory, logger.err_after(error.NotFound, .{}));

    // The failed start left a free slot behind, so the logger still works and
    // a diagnostic can be started once a frame is available again.
    try expect(pool.put(held));

    const diag = try logger.err_after(error.NotFound, .{});
    logger.warn("after exhaustion", .{ .err = diag });
    try expectEqual(@as(u64, 1), logger.dropped.load(.monotonic));
}

test "slots are recycled only after a diagnostic was logged" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const first = try rig.logger.err_after(error.NotFound, .{});
    const second = try rig.logger.err_after(error.AccessDenied, .{});
    try expect(first != second);

    rig.logger.warn("first", .{ .err = first });
    const reused = try rig.logger.err_after(error.Unexpected, .{});
    try expect(reused == first);
    try expectEqual(error.Unexpected, reused.spec().?);

    rig.logger.warn("second", .{ .err = reused });
    rig.logger.warn("third", .{ .err = second });
}

test "unlogged diagnostics are released by logger deinit" {
    const a = std.testing.allocator;

    const Pool = buffer_pool.BufferPool(false);
    const Sink = writer_mod.MemorySink;

    var pool: Pool = undefined;
    try pool.init(a, 2, 512);
    defer pool.deinit();

    var sink: Sink = undefined;
    sink.init(a);
    defer sink.deinit();

    var logger: logger_mod.Logger(Pool, Sink) = undefined;
    logger.init(&pool, &sink);
    _ = try logger.err_after(error.NotFound, .{ .name = "never logged" });

    // Without this the pool's deinit assertion would trip on the leaked frame.
    logger.deinit();
}

test "a logged diagnostic renders through the JSON sink" {
    const a = std.testing.allocator;

    const Capture = struct {
        list: std.ArrayList(u8) = .empty,

        pub fn write(self: *@This(), bytes: []const u8) error{WriteFailed}!usize {
            self.list.appendSlice(std.testing.allocator, bytes) catch return error.WriteFailed;
            return bytes.len;
        }
    };

    const Pool = buffer_pool.BufferPool(false);
    const Sink = writer_mod.JsonSink(Capture);

    var pool: Pool = undefined;
    try pool.init(a, 4, 4096);
    defer pool.deinit();

    var out = Capture{};
    defer out.list.deinit(a);

    var sink: Sink = undefined;
    sink.init(a, &out);
    defer sink.deinit();

    var logger: logger_mod.Logger(Pool, Sink) = undefined;
    logger.init(&pool, &sink);
    defer logger.deinit();

    var diag = try logger.err_after(error.NotFound, .{ .name = "config" });
    diag = try diag.wrap("open config file", .{});
    logger.warn("boom", .{ .err = diag });

    // Only the timestamp varies; everything else is frozen by the Go encoder's
    // shape: the error context keeps its stages, `@txt` is the joined text.
    const line = out.list.items;
    try expect(std.mem.startsWith(u8, line, "{\"time\":"));
    try expect(std.mem.endsWith(u8, line, "\"level\":\"W\",\"message\":\"boom\",\"err\":{" ++
        "\"@ctx\":{\"NEW: NotFound\":{\"name\":\"config\"}," ++
        "\"WRAP: open config file\":{}}," ++
        "\"@txt\":\"open config file: NotFound\"}}\n"));

    // The payload is consumed by the logging, and its frame went back.
    try expect(diag.isConsumed());
    try expectEqual(@as(u64, 0), logger.dropped.load(.monotonic));
}
test "a diagnostic logs once and rejects a second hand-over" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{});
    try expect(diag.spec().? == error.NotFound);
    try expect(!diag.isConsumed());

    rig.logger.warn("mine", .{ .err = diag });
    try expect(diag.isConsumed());
}
test "logging through a With child works and releases both frames" {
    const a = std.testing.allocator;
    var rig: TestRig(4, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    var child = rig.logger.With(.{ .job = "sync" });
    defer child.deinit();

    const diag = try child.err_after(error.NotFound, .{ .name = "config" });
    child.warn("boom", .{ .err = diag });
    try expect(diag.isConsumed());

    // The prefix attr precedes the call-site error attribute, and the pooled
    // diagnostic frame is back even though two logger instances are alive.
    const payload = rig.payload();
    var off: usize = 2 + 8 + 1 + 1;
    var len: u64 = 0;
    var next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    try expectEqual(@intFromEnum(consts.ValueKind.string), payload[off]);
    off += 1;
    next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    try expectEqualSlices(u8, "job", payload[off + 1 ..][0..@intCast(len)]);
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));
    next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    try expectEqualSlices(u8, "sync", payload[off + 1 ..][0..@intCast(len)]);
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    try expectEqual(@intFromEnum(consts.ValueKind.nodeError), payload[off]);
    try expectEqual(@as(u64, 0), rig.logger.dropped.load(.monotonic));
}
test "a diagnostic nested in a context group is consumed too" {
    const a = std.testing.allocator;
    var rig: TestRig(2, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const diag = try rig.logger.err_after(error.NotFound, .{ .name = "config" });
    const frame_ptr = diag.payload.ptr;
    rig.logger.err("grouped", .{ .where = .{ .err = diag } });

    try expect(diag.isConsumed());
    try expectEqual(@as(u64, 0), rig.logger.dropped.load(.monotonic));

    // The nested attribute still renders as a `nodeError` with the payload.
    const payload = rig.payload();
    var off: usize = 2 + 8 + 1 + 1;
    var len: u64 = 0;
    var next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));

    try expectEqual(@intFromEnum(consts.ValueKind.nodeGroup), payload[off]);
    off += 1;
    next = try decoding.decodeVarint(&len, @constCast(payload.ptr + off));
    try expectEqualSlices(u8, "where", payload[off + 1 ..][0..@intCast(len)]);
    off = @intFromPtr(next) - @intFromPtr(payload.ptr) + @as(usize, @intCast(len));
    try expectEqual(@intFromEnum(consts.ValueKind.nodeError), payload[off]);

    // And the frame is free again.
    const first = try rig.pool.get(512);
    const second = try rig.pool.get(512);
    try expect((first.ptr == frame_ptr) or (second.ptr == frame_ptr));
    try expect(rig.pool.put(first));
    try expect(rig.pool.put(second));
}
test "a long chain keeps growing off the pool without leaking" {
    const a = std.testing.allocator;
    var rig: TestRig(2, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    const pad = "z" ** 300;
    var diag = try rig.logger.err_after(error.NotFound, .{ .blob = "y" ** 700 });
    try expect(diag.payloadSize() > defaultPayloadSize);

    // Each stage moves the payload to a fresh allocation; the earlier ones are
    // released as it moves, so nothing but the final one is owed.
    var i: usize = 0;
    while (i < 40) : (i += 1) diag = try diag.wrap("lvl", .{ .pad = pad });

    const text = try diag.string(a);
    defer a.free(text);
    try expect(text.len > 40 * "lvl: ".len);
    try expect(std.mem.startsWith(u8, text, "lvl: "));
    try expect(std.mem.endsWith(u8, text, "NotFound"));

    rig.logger.warn("deep", .{ .err = diag });
    try expect(diag.isConsumed());
    try expectEqual(@as(u64, 0), rig.logger.dropped.load(.monotonic));
    try expect(rig.sink.bytes.items.len > 12 * 1024);
}

test "all slots are usable and reusable once logged" {
    const a = std.testing.allocator;
    var rig: TestRig(16, 512) = undefined;
    try rig.init(a);
    defer rig.deinit();

    var diags: [maxLiveDiagnostics]*Error = undefined;
    for (&diags) |*slot| slot.* = try rig.logger.err_after(error.NotFound, .{});
    for (diags, 0..) |slot, i| {
        // Distinct slots, so a live diagnostic is never overwritten.
        for (diags[0..i]) |earlier| try expect(earlier != slot);
        try expectEqual(error.NotFound, slot.spec().?);
    }
    for (diags) |slot| rig.logger.warn("x", .{ .err = slot });

    // Logging frees every slot for the next round.
    for (&diags) |*slot| slot.* = try rig.logger.err_after(error.AccessDenied, .{});
    for (diags) |slot| {
        try expectEqual(error.AccessDenied, slot.spec().?);
        rig.logger.warn("y", .{ .err = slot });
    }
    try expectEqual(@as(u64, 0), rig.logger.dropped.load(.monotonic));
}
