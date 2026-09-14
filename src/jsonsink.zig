//! JSONL sink internals: cursors, dialect constants and budgets.
//!
//! This module is the single-pass port of the Rust reference transformer
//! `blog-rs/src/log_transfomer_into_json.rs` (`LogTransfomerJSON`). It walks a
//! record payload once, with a bounds-checked read cursor, and writes compact
//! JSON as it goes. It does **not** use `viewer.parseRecord`, `ParsedRecord`
//! or the `Node` model: that two-pass path belongs to `PrettySink`.
//!
//! M1 covers the `In`/`Out` cursors, the pessimistic per-element budget table
//! and the growth policy. The record walk (`renderRecord`) is layered on top
//! in later milestones.

const std = @import("std");
const flate = std.compress.flate;
const buffer_pool = @import("buffer_pool.zig");
const consts = @import("consts.zig");
const render = @import("render.zig");
const viewer = @import("viewer.zig");
const jsonescape = @import("jsonescape");

/// The pool type every sink consumes; same alias as `writer.BufferPool`.
pub const BufferPool = buffer_pool.BufferPool(false);

pub const ParseError = viewer.ParseError;

/// JSON output dialect constants (Rust `log_transfomer_into_json_consts.rs`,
/// with the level/location spellings settled in the plan's deviations D2/D3).
pub const json = struct {
    pub const time = "\"time\"";
    pub const level = "\"level\"";
    pub const location = "\"location\"";
    pub const message = "\"message\"";
    pub const stacktrace = "\"stacktrace\"";
    pub const error_ctx = "{\"@ctx\":{";
    pub const error_txt = ",\"@txt\":";
    pub const error_loc = "\"@loc\":";
    pub const stage_ctx = "\"CTX\":{";
    pub const stage_new = "NEW: ";
    pub const stage_wrap = "WRAP: ";
    pub const level_trace = "\"T\"";
    pub const level_debug = "\"D\"";
    pub const level_info = "\"I\"";
    pub const level_warn = "\"W\"";
    pub const level_error = "\"E\"";
    pub const level_panic = "\"P\"";
    pub const level_unknown = "UNKNOWN(";
};

/// Pessimistic per-element budgets (plan §6.2). Before writing each basic
/// value the cursor ensures at least this many bytes; a passed check must
/// never under-write, so the task table's one-byte-short entries for `i32`,
/// `u32` and `u64` are widened to their true worst case.
pub const budgets = struct {
    pub const bool_: usize = 5;
    pub const i8_: usize = 4;
    pub const i16_: usize = 6;
    pub const i32_: usize = 11; // "-2147483648"
    pub const i64_: usize = 20; // "-9223372036854775808"
    pub const u8_: usize = 3;
    pub const u16_: usize = 5;
    pub const u32_: usize = 10; // "4294967295"
    pub const u64_: usize = 20; // "18446744073709551615"
    pub const f32_: usize = 16;
    pub const f64_: usize = 32;
    /// Bare nanoseconds (OQ1: bare number, `timestamp` value fits u64).
    pub const time_: usize = 20;
    /// `"level":` plus the 12-byte worst value `"UNKNOWN(255)"`.
    pub const level_: usize = 22;
    /// `"location":"` + escaped file + `:` + up to 20 digits + `"`.
    pub const location_prefix: usize = 12; // "\"location\":"
    pub const location_suffix: usize = 1 + 20 + 1; // ':' line '"'
    pub const message_: usize = 10; // "\"message\":"
    pub const stacktrace_: usize = 13; // "\"stacktrace\":"
    /// Context stage openers `"NEW: <k>":{` / `"WRAP: <k>":{`.
    pub const stage_prefix: usize = 7; // "NEW: " / "WRAP: " including quotes
    pub const group_end_erd = 9; // ,"@txt":
    pub const ctx_time: usize = 20;
    pub const ctx_duration: usize = 30; // "5124095h34m33.709551615s"
    pub const ctx_ivar: usize = 20;
    pub const ctx_uvar: usize = 20;
    pub const base64_quotes: usize = 2;

    /// Escaped quoted string: logical worst `6*len + 2` plus the 64-byte
    /// kernel slack `jsonescape` requires for full-width vector stores.
    pub fn string(len: usize) usize {
        return 6 * len + 64;
    }

    /// Base64 standard encoding of `n` bytes, quoted.
    pub fn base64(n: usize) usize {
        return 4 * (n + 2) / 3 + base64_quotes;
    }
};

/// Initial reserve for one record: 150% more space than the payload length
/// (2.5x total), floored so tiny records still get a workable buffer.
pub fn initialCapacity(payload_len: usize) usize {
    return @max(payload_len + payload_len * 3 / 2, 128);
}

/// Required scratch capacity for `jsonescape`'s escape kernels: logical
/// worst case `6 * len + 2` plus 64 bytes of slack.
fn escapeCapacity(len: usize) usize {
    return (len *| 6) +| 64;
}

/// Bounds-checked read cursor over a record payload. Every read returns a
/// parse error on truncation instead of reading past the frame (D8).
pub const In = struct {
    bytes: []const u8,
    off: usize = 0,

    /// Reads one byte and advances.
    pub fn byte(self: *In) ParseError!u8 {
        if (self.off >= self.bytes.len) return error.Truncated;
        const b = self.bytes[self.off];
        self.off += 1;
        return b;
    }

    /// Reads one little-endian fixed-width integer and advances.
    pub fn intLe(self: *In, comptime T: type) ParseError!T {
        const n = @sizeOf(T);
        if (self.off + n > self.bytes.len) return error.Truncated;
        const v = std.mem.readInt(T, self.bytes[self.off..][0..n], .little);
        self.off += n;
        return v;
    }

    /// Reads an LEB128 uvarint and advances. Wraps `viewer.readUvarint`.
    pub fn uvarint(self: *In) ParseError!u64 {
        const r = try viewer.readUvarint(self.bytes, self.off);
        self.off += r.size;
        return r.val;
    }

    /// Reads a zigzag varint and advances. Wraps `viewer.readVarint`.
    pub fn varint(self: *In) ParseError!i64 {
        const r = try viewer.readVarint(self.bytes, self.off);
        self.off += r.size;
        return r.val;
    }

    /// Borrows `len` bytes and advances.
    pub fn take(self: *In, len: usize) ParseError![]const u8 {
        if (self.off + len > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.off..][0..len];
        self.off += len;
        return s;
    }
};

/// Budget-checked write cursor over a pool buffer. `ensure` grows the buffer
/// (amortized doubling, old storage returned to the pool) whenever the
/// reserve runs out.
pub const Out = struct {
    pool: *BufferPool,
    buf: []u8,
    pos: usize = 0,

    /// Makes at least `need` bytes writable at `pos`, growing if required.
    pub fn ensure(self: *Out, need: usize) std.mem.Allocator.Error!void {
        if (self.buf.len - self.pos >= need) return;
        const new_cap = @max(self.pos + need, 2 * self.buf.len);
        const new_buf = try self.pool.get(new_cap);
        @memcpy(new_buf[0..self.pos], self.buf[0..self.pos]);
        _ = self.pool.put(self.buf);
        self.buf = new_buf;
    }

    /// Returns the finished bytes to the pool.
    pub fn release(self: *Out) void {
        _ = self.pool.put(self.buf);
    }

    pub fn written(self: *const Out) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn byte(self: *Out, b: u8) std.mem.Allocator.Error!void {
        try self.ensure(1);
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub fn raw(self: *Out, s: []const u8) std.mem.Allocator.Error!void {
        try self.ensure(s.len);
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    pub fn int(self: *Out, v: i64) std.mem.Allocator.Error!void {
        try self.ensure(budgets.i64_);
        const s = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{v}) catch unreachable;
        self.pos += s.len;
    }

    pub fn uint(self: *Out, v: u64) std.mem.Allocator.Error!void {
        try self.ensure(budgets.u64_);
        const s = std.fmt.bufPrint(self.buf[self.pos..], "{d}", .{v}) catch unreachable;
        self.pos += s.len;
    }

    /// ryu shortest float; NaN becomes the quoted `"NaN"`, matching Rust.
    pub fn float(self: *Out, comptime T: type, v: T) std.mem.Allocator.Error!void {
        if (std.math.isNan(v)) return self.raw("\"NaN\"");
        try self.ensure(if (T == f32) budgets.f32_ else budgets.f64_);
        const dst = self.buf[self.pos..];
        // `ryuFormat` writes the shortest form into the tail but returns a
        // static literal for `inf`/`-inf`/`0.0`/`-0.0`; copy only the latter.
        const s = render.ryuFormat(dst, T, v);
        if (@intFromPtr(s.ptr) != @intFromPtr(dst.ptr)) {
            @memcpy(dst[0..s.len], s);
        }
        self.pos += s.len;
    }

    /// Appends a quoted go-duration, e.g. `"342h56m7.890101121s"`.
    pub fn duration(self: *Out, nanos: u64) std.mem.Allocator.Error!void {
        try self.ensure(budgets.ctx_duration);
        self.buf[self.pos] = '"';
        self.pos += 1;
        var tmp: [64]u8 = undefined;
        const s = render.goDuration(&tmp, nanos);
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
        self.buf[self.pos] = '"';
        self.pos += 1;
    }

    /// Appends `src` as a JSON-escaped, quoted string.
    pub fn escaped(self: *Out, src: []const u8) std.mem.Allocator.Error!void {
        try self.ensure(escapeCapacity(src.len));
        const end = jsonescape.escapeInto(self.buf.ptr + self.pos, src);
        self.pos = @intFromPtr(end) - @intFromPtr(self.buf.ptr);
    }

    /// Appends `src` as a JSON-escaped string without quotes (for keys whose
    /// prefix already lives inside the quotes).
    pub fn escapedUnquoted(self: *Out, src: []const u8) std.mem.Allocator.Error!void {
        try self.ensure(escapeCapacity(src.len));
        const end = jsonescape.escapeIntoUnquote(self.buf.ptr + self.pos, src);
        self.pos = @intFromPtr(end) - @intFromPtr(self.buf.ptr);
    }

    /// Appends a raw JSON boolean literal.
    pub fn boolean(self: *Out, v: bool) std.mem.Allocator.Error!void {
        try self.raw(if (v) "true" else "false");
    }

    /// Appends `src` as a standard-base64, quoted string.
    pub fn quotedBase64(self: *Out, src: []const u8) std.mem.Allocator.Error!void {
        try self.ensure(budgets.base64(src.len));
        self.buf[self.pos] = '"';
        self.pos += 1;
        const encoder = std.base64.standard.Encoder;
        const encoded = encoder.encode(self.buf[self.pos..][0..encoder.calcSize(src.len)], src);
        self.pos += encoded.len;
        self.buf[self.pos] = '"';
        self.pos += 1;
    }
};

/// Writes the value of the header `"level"` field: a single-letter quoted
/// level, or the quoted `"UNKNOWN(<n>)"` fallback (plan D2/§4.2).
fn writeLevel(out: *Out, level: u8) ParseError!void {
    const literal: ?[]const u8 = switch (level) {
        @intFromEnum(consts.logLevel.trace) => json.level_trace,
        @intFromEnum(consts.logLevel.debug) => json.level_debug,
        @intFromEnum(consts.logLevel.info) => json.level_info,
        @intFromEnum(consts.logLevel.warning) => json.level_warn,
        @intFromEnum(consts.logLevel.err) => json.level_error,
        @intFromEnum(consts.logLevel.panic) => json.level_panic,
        else => null,
    };
    if (literal) |lit| return out.raw(lit);

    try out.byte('"');
    try out.raw(json.level_unknown);
    try out.uint(level);
    try out.byte(')');
    try out.byte('"');
}

/// Reference to a payload fragment kept for the `"@txt"` error join
/// (Rust `err_frags` / `render.zig` `ErrRef`): offset and length inside the
/// current record payload.
pub const ErrRef = struct { len: usize, off: usize };

/// Per-record render state owned by the sink (plan §7.2). `err_stack` reuses
/// its allocation across records; `scratch` holds the gunzipped stacktrace
/// and the `": "` join for error text.
pub const Ctx = struct {
    allocator: std.mem.Allocator,
    err_stack: std.ArrayList(ErrRef) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Ctx {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ctx) void {
        self.err_stack.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }
};

/// Reads a common-layout key (plan §4.5): a `0` byte followed by a predefined
/// key code, or a nonzero first byte that starts the `uvarint(len) + bytes`
/// literal-key form. Writes the escaped quoted key and its `:`.
fn readKeyBytes(in: *In) ParseError![]const u8 {
    if (in.off >= in.bytes.len) return error.Truncated;
    if (in.bytes[in.off] != 0) {
        const len = try in.uvarint();
        return try in.take(@intCast(len));
    }
    _ = try in.byte();
    const code = try in.uvarint();
    // Only the `INVALID` predefined key (code 0) exists; any other code is a
    // parse error and drops the record (Rust `predefined_key_safe`).
    if (code != 0) return error.UnknownValueKind;
    return "INVALID";
}

fn readKey(in: *In, out: *Out) ParseError!void {
    const key = try readKeyBytes(in);
    try out.escaped(key);
    try out.byte(':');
}

/// Reads a key in the always-literal form `uvarint(len) + bytes`, used by the
/// error-stage and location nodes (the Rust transformer reads these directly,
/// without the predefined-key fallback of the common layout).
fn readLiteralKey(in: *In) ParseError![]const u8 {
    const len = try in.uvarint();
    return try in.take(@intCast(len));
}

fn renderIntSlice(in: *In, out: *Out, comptime T: type) ParseError!void {
    const count = try in.uvarint();
    try out.byte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try out.byte(',');
        const v = try in.intLe(T);
        if (@typeInfo(T).int.signedness == .signed) {
            try out.int(v);
        } else {
            try out.uint(v);
        }
    }
    try out.byte(']');
}

fn renderFloatSlice(in: *In, out: *Out, comptime T: type) ParseError!void {
    const Bits = if (T == f32) u32 else u64;
    const count = try in.uvarint();
    try out.byte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try out.byte(',');
        try out.float(T, @bitCast(try in.intLe(Bits)));
    }
    try out.byte(']');
}

fn renderBoolSlice(in: *In, out: *Out) ParseError!void {
    const count = try in.uvarint();
    try out.byte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try out.byte(',');
        try out.boolean((try in.byte()) != 0);
    }
    try out.byte(']');
}

fn renderStringSlice(in: *In, out: *Out) ParseError!void {
    const count = try in.uvarint();
    try out.byte('[');
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try out.byte(',');
        const len = try in.uvarint();
        try out.escaped(try in.take(@intCast(len)));
    }
    try out.byte(']');
}

/// Writes the value half of a common-layout context element (plan §4.5 value
/// switch). Reads exactly the bytes the wire kind occupies.
fn writeCtxValue(in: *In, out: *Out, kind: consts.ValueKind) ParseError!void {
    switch (kind) {
        .bool => try out.boolean((try in.byte()) != 0),
        .time => try out.uint(try in.intLe(u64)),
        .duration => try out.duration(try in.intLe(u64)),
        .ivar => try out.int(try in.varint()),
        .int8 => try out.int(try in.intLe(i8)),
        .int16 => try out.int(try in.intLe(i16)),
        .int32 => try out.int(try in.intLe(i32)),
        .int64 => try out.int(try in.intLe(i64)),
        .uvar => try out.uint(try in.uvarint()),
        .uint8 => try out.uint(try in.intLe(u8)),
        .uint16 => try out.uint(try in.intLe(u16)),
        .uint32 => try out.uint(try in.intLe(u32)),
        .uint64 => try out.uint(try in.intLe(u64)),
        .float32 => try out.float(f32, @bitCast(try in.intLe(u32))),
        .float64 => try out.float(f64, @bitCast(try in.intLe(u64))),
        .string, .errorRaw => {
            const len = try in.uvarint();
            try out.escaped(try in.take(@intCast(len)));
        },
        .sliceBool => try renderBoolSlice(in, out),
        .sliceInt8 => try renderIntSlice(in, out, i8),
        .sliceInt16 => try renderIntSlice(in, out, i16),
        .sliceInt32 => try renderIntSlice(in, out, i32),
        .sliceInt64 => try renderIntSlice(in, out, i64),
        .sliceUint16 => try renderIntSlice(in, out, u16),
        .sliceUint32 => try renderIntSlice(in, out, u32),
        .sliceUint64 => try renderIntSlice(in, out, u64),
        .sliceFloat32 => try renderFloatSlice(in, out, f32),
        .sliceFloat64 => try renderFloatSlice(in, out, f64),
        .sliceString => try renderStringSlice(in, out),
        // The new wire format has no `Bytes` kind; `[]byte` arrives as a
        // `sliceUint8` and renders as a standard-base64 string (plan D4).
        .sliceUint8 => {
            const len = try in.uvarint();
            try out.quotedBase64(try in.take(@intCast(len)));
        },
        else => return error.UnknownValueKind,
    }
}

/// Single-pass context walk (port of `transform_json_ctx_v1`, plan §4.5).
/// `old` is the needs-comma flag, initialized true so the first element
/// supplies its own `,` separator after the message. `error_depth`, `err_stack`,
/// `is_embed_error` and `embed_text` carry the error bookkeeping across the
/// walk.
fn renderContext(in: *In, out: *Out, ctx: *Ctx) ParseError!void {
    var old = true;
    var error_depth: usize = 0;
    var is_embed_error = false;
    var embed_text: ErrRef = .{ .len = 0, .off = 0 };

    while (in.off < in.bytes.len) {
        const raw = try in.byte();
        const kind = std.enums.fromInt(consts.ValueKind, raw) orelse return error.UnknownValueKind;

        switch (kind) {
            .nodePhantomContext => continue,
            .nodeContext => {
                if (old) try out.byte(',');
                try out.raw(json.stage_ctx);
                old = false;
                error_depth += 1;
                continue;
            },
            .nodeNew, .nodeWrap => {
                if (old) try out.byte(',');
                const key = try readLiteralKey(in);
                if (!is_embed_error) try ctx.err_stack.append(ctx.allocator, .{ .len = key.len, .off = in.off - key.len });
                try out.byte('"');
                try out.raw(if (kind == .nodeNew) json.stage_new else json.stage_wrap);
                try out.escapedUnquoted(key);
                try out.raw("\":{");
                old = false;
                error_depth += 1;
                continue;
            },
            .nodeForeignErrorText => {
                const key = try readLiteralKey(in);
                if (!is_embed_error) try ctx.err_stack.append(ctx.allocator, .{ .len = key.len, .off = in.off - key.len });
                continue;
            },
            .nodeLocation => {
                if (old) try out.byte(',');
                old = true;
                const key = try readLiteralKey(in);
                const line = try in.uvarint();
                try out.raw(json.error_loc);
                try out.byte('"');
                try out.escapedUnquoted(key);
                try out.byte(':');
                try out.uint(line);
                try out.byte('"');
                continue;
            },
            .nodeGroupEnd => {
                old = true;
                if (error_depth == 0) {
                    try out.byte('}');
                    continue;
                }
                error_depth -= 1;
                if (error_depth > 0) {
                    try out.byte('}');
                    continue;
                }
                try out.byte('}');
                try out.raw(json.error_txt);
                if (is_embed_error) {
                    try out.escaped(in.bytes[embed_text.off..][0..embed_text.len]);
                } else {
                    try writeErrText(out, ctx, in.bytes);
                }
                try out.byte('}');
                continue;
            },
            else => {
                if (old) try out.byte(',');
                old = true;
                try readKey(in, out);
                switch (kind) {
                    .nodeGroup => {
                        try out.byte('{');
                        old = false;
                    },
                    .nodeError => {
                        try out.raw(json.error_ctx);
                        old = false;
                        error_depth += 1;
                        is_embed_error = false;
                        ctx.err_stack.clearRetainingCapacity();
                    },
                    .nodeErrorEmbed => {
                        try out.raw(json.error_ctx);
                        old = false;
                        error_depth += 1;
                        is_embed_error = true;
                        const len = try in.uvarint();
                        const off = in.off;
                        _ = try in.take(@intCast(len));
                        embed_text = .{ .len = @intCast(len), .off = off };
                    },
                    else => try writeCtxValue(in, out, kind),
                }
            },
        }
    }
}

/// Joins the collected error fragments in reverse order with `": "` and writes
/// them as one escaped quoted string (the `"@txt"` value).
fn writeErrText(out: *Out, ctx: *Ctx, payload: []const u8) ParseError!void {
    ctx.scratch.clearRetainingCapacity();
    var i = ctx.err_stack.items.len;
    var first = true;
    while (i > 0) {
        i -= 1;
        if (!first) try ctx.scratch.appendSlice(ctx.allocator, ": ");
        first = false;
        const x = ctx.err_stack.items[i];
        try ctx.scratch.appendSlice(ctx.allocator, payload[x.off..][0..x.len]);
    }
    try out.escaped(ctx.scratch.items);
}

/// Decodes the gzip stacktrace carried by a PANIC message into `ctx.scratch`.
/// On decode failure the error name is stored instead (plan D10). Returns the
/// bytes to append after `"stacktrace":` (raw, unescaped, unquoted, D5).
fn decodeStacktrace(ctx: *Ctx, msg: []const u8) ![]const u8 {
    var fixed = std.Io.Reader.fixed(msg);
    var decoder: flate.Decompress = .init(&fixed, .gzip, &[_]u8{});
    ctx.scratch.clearRetainingCapacity();
    decoder.reader.appendRemainingUnlimited(ctx.allocator, &ctx.scratch) catch {
        ctx.scratch.clearRetainingCapacity();
        const name = if (decoder.err) |err| @errorName(err) else "gzip decode failed";
        try ctx.scratch.appendSlice(ctx.allocator, name);
    };
    return ctx.scratch.items;
}

/// Renders one record payload (version field onward) as a single compact JSON
/// object, without a trailing newline. Header walk + context (plan M2/M3); the
/// JSONL newline and framing are the sink's concern. `ctx` carries the reusable
/// error/scratch state; it is reset per record.
pub fn renderRecord(out: *Out, ctx: *Ctx, payload: []const u8) ParseError!void {
    var in = In{ .bytes = payload };
    ctx.err_stack.clearRetainingCapacity();

    const version = try in.intLe(u16);
    if (version != consts.version) return error.VersionNotSupported;

    try out.byte('{');
    try out.raw(json.time);
    try out.byte(':');
    try out.uint(try in.intLe(u64)); // OQ1: bare nanoseconds
    try out.byte(',');
    try out.raw(json.level);
    try out.byte(':');
    const level = try in.byte();
    try writeLevel(out, level);
    try out.byte(',');

    // Location: a single zero flag byte, or a uvarint length that reuses the
    // first flag byte (nonzero) followed by the file bytes and a uvarint line.
    if (try in.byte() != 0) {
        in.off -= 1;
        const file_len = try in.uvarint();
        const file = try in.take(@intCast(file_len));
        const line = try in.uvarint();

        try out.raw(json.location);
        try out.byte(':');
        try out.byte('"');
        try out.escapedUnquoted(file);
        try out.byte(':');
        try out.uint(line);
        try out.byte('"');
        try out.byte(',');
    }

    const msg_len = try in.uvarint();
    const msg = try in.take(@intCast(msg_len));
    if (level == @intFromEnum(consts.logLevel.panic)) {
        try out.raw(json.stacktrace);
        try out.byte(':');
        // Raw gunzipped stacktrace, appended unescaped and unquoted (D5).
        try out.raw(try decodeStacktrace(ctx, msg));
    } else {
        try out.raw(json.message);
        try out.byte(':');
        try out.escaped(msg);
    }

    try renderContext(&in, out, ctx);
    try out.byte('}');
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "in cursor reads bounds-checked scalars" {
    const bytes = [_]u8{ 0x05, 0x7F, 0x00, 0x00, 0x00, 0x80, 0x01, 0x2A };
    var in = In{ .bytes = &bytes };

    try expectEqual(@as(u8, 0x05), try in.byte());
    try expectEqual(@as(u16, 0x007F), try in.intLe(u16));
    try expectEqual(@as(u32, 0x01800000), try in.intLe(u32));
    try expectEqual(@as(u8, 0x2A), try in.byte());
    try expect(in.off == bytes.len);
}

test "in cursor uvarint and zigzag varint" {
    // 300 as LEB128; -1 zigzag (=1) then 2 (=-4 zigzag).
    const bytes = [_]u8{ 0xAC, 0x02, 0x01, 0x04 };
    var in = In{ .bytes = &bytes };
    try expectEqual(@as(u64, 300), try in.uvarint());
    try expectEqual(@as(i64, -1), try in.varint());
    try expectEqual(@as(i64, 2), try in.varint());
}

test "in cursor drops truncated reads" {
    const bytes = [_]u8{ 0x01, 0x02 };
    var in = In{ .bytes = &bytes };
    _ = try in.byte();
    _ = try in.byte();
    try std.testing.expectError(error.Truncated, in.byte());

    var short = In{ .bytes = &bytes };
    try std.testing.expectError(error.Truncated, short.intLe(u32));

    var take2 = In{ .bytes = &bytes };
    try std.testing.expectError(error.Truncated, take2.take(3));
    try expectEqualSlices(u8, &bytes, try take2.take(2));
}

test "out cursor writes scalars within budget" {
    const Pool = BufferPool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    var out = Out{ .pool = &pool, .buf = try pool.get(128) };
    defer out.release();

    try out.raw("{\"a\":");
    try out.int(std.math.minInt(i64));
    try out.byte(',');
    try out.uint(std.math.maxInt(u64));
    try out.byte(',');
    try out.float(f64, 3.141592653589793);
    try out.byte(',');
    try out.float(f64, std.math.nan(f64));
    try out.byte(',');
    try out.duration(1_234_567_890_101_121);
    try out.byte('}');

    try expectEqualSlices(
        u8,
        "{\"a\":-9223372036854775808,18446744073709551615,3.141592653589793,\"NaN\",\"342h56m7.890101121s\"}",
        out.written(),
    );
}

test "every integer worst case fits its budget" {
    inline for (.{
        .{ i8, budgets.i8_, std.math.minInt(i8), std.math.maxInt(i8) },
        .{ i16, budgets.i16_, std.math.minInt(i16), std.math.maxInt(i16) },
        .{ i32, budgets.i32_, std.math.minInt(i32), std.math.maxInt(i32) },
        .{ i64, budgets.i64_, std.math.minInt(i64), std.math.maxInt(i64) },
        .{ u8, budgets.u8_, std.math.minInt(u8), std.math.maxInt(u8) },
        .{ u16, budgets.u16_, std.math.minInt(u16), std.math.maxInt(u16) },
        .{ u32, budgets.u32_, std.math.minInt(u32), std.math.maxInt(u32) },
        .{ u64, budgets.u64_, std.math.minInt(u64), std.math.maxInt(u64) },
    }) |case| {
        var lo: [24]u8 = undefined;
        var hi: [24]u8 = undefined;
        const lo_s = std.fmt.bufPrint(&lo, "{d}", .{case[2]}) catch unreachable;
        const hi_s = std.fmt.bufPrint(&hi, "{d}", .{case[3]}) catch unreachable;
        try expect(lo_s.len <= case[1]);
        try expect(hi_s.len <= case[1]);
    }

    var f32_buf: [64]u8 = undefined;
    try expect(render.ryuFormat(&f32_buf, f32, std.math.floatMin(f32)).len <= budgets.f32_);
    try expect(render.ryuFormat(&f32_buf, f32, std.math.floatMax(f32)).len <= budgets.f32_);
    var f64_buf: [64]u8 = undefined;
    try expect(render.ryuFormat(&f64_buf, f64, std.math.floatMin(f64)).len <= budgets.f64_);
    try expect(render.ryuFormat(&f64_buf, f64, std.math.floatMax(f64)).len <= budgets.f64_);
}

test "duration worst case fits its budget" {
    var buf: [64]u8 = undefined;
    const s = render.goDuration(&buf, std.math.maxInt(u64));
    try expect(s.len + 2 <= budgets.ctx_duration);
}

test "escape expansion forces growth from the initial reserve" {
    const Pool = BufferPool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    const payload_len: usize = 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    @memset(payload, 0x01); // each byte escapes to "\u0001": 6 bytes

    const cap = initialCapacity(payload_len);
    try expectEqual(@as(usize, 2560), cap); // 2.5 x

    var out = Out{ .pool = &pool, .buf = try pool.get(cap) };
    defer out.release();
    const first_ptr = out.buf.ptr;

    try out.escaped(payload);

    // 6 * 1024 + 2 quotes; the 2.5x reserve cannot hold it, so growth ran.
    try expectEqual(@as(usize, 6 * payload_len + 2), out.written().len);
    try expect(out.buf.ptr != first_ptr);
    try expect(out.written()[0] == '"');
    try expect(out.written()[out.written().len - 1] == '"');
    try expectEqualSlices(u8, "\\u0001", out.written()[1..7]);
}

test "initial capacity floors tiny records" {
    try expectEqual(@as(usize, 128), initialCapacity(4));
    try expectEqual(@as(usize, 128), initialCapacity(0));
    try expectEqual(@as(usize, 128), initialCapacity(51));
    try expectEqual(@as(usize, 130), initialCapacity(52));
}

test "growth releases the old buffer to the pool" {
    const Pool = BufferPool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    // Both frames: one is the output, the other becomes the grown buffer.
    var out = Out{ .pool = &pool, .buf = try pool.get(64) };
    const small = out.buf;
    try out.raw("x" ** 200);
    try expect(out.buf.ptr != small.ptr);

    // `small` was returned; the next frame-sized get must hand it back.
    const reused = try pool.get(64);
    try expectEqual(small.ptr, reused.ptr);
    try expect(pool.put(reused));

    out.release();
}

test "out cursor reuses a pool frame without growing when it fits" {
    const Pool = BufferPool;
    const allocator = std.testing.allocator;
    var pool = try Pool.init(allocator, 2, 512);
    defer pool.deinit();

    var out = Out{ .pool = &pool, .buf = try pool.get(512) };
    const ptr = out.buf.ptr;
    try out.raw("{\"k\":");
    try out.uint(42);
    try out.byte('}');
    try expectEqual(ptr, out.buf.ptr);
    try expectEqualSlices(u8, "{\"k\":42}", out.written());
    out.release();

    const again = try pool.get(512);
    try expectEqual(ptr, again.ptr);
    try expect(pool.put(again));
}
/// Test helper: renders one payload through a fresh pool buffer.
fn renderTest(pool: *BufferPool, payload: []const u8) ![]const u8 {
    const out = try pool.get(initialCapacity(payload.len));
    var cursor = Out{ .pool = pool, .buf = out };
    errdefer cursor.release();
    var ctx = Ctx.init(std.testing.allocator);
    defer ctx.deinit();
    try renderRecord(&cursor, &ctx, payload);
    return cursor.written();
}

test "header golden: message only" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 1_773_974_798_041_168_000, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "just a message");

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":1773974798041168000,\"level\":\"I\",\"message\":\"just a message\"}",
        got,
    );
}

test "header golden: location and context" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.headerLoc(a, 1_773_974_798_041_168_001, @intFromEnum(consts.logLevel.debug), "src/main.zig", 42);
    try pb.msg(a, "ctx");
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.strField(a, "string", "Hello World!");
    const pi: f64 = 3.141592653589793;
    try pb.key(a, .float64, "pi");
    try pb.le(a, u64, @bitCast(pi));

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":1773974798041168001,\"level\":\"D\",\"location\":\"src/main.zig:42\"," ++
            "\"message\":\"ctx\",\"int\":4,\"string\":\"Hello World!\",\"pi\":3.141592653589793}",
        got,
    );
}

test "header golden: every level letter and the unknown fallback" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    const cases = [_]struct { level: u8, want: []const u8, field: []const u8 }{
        .{ .level = 10, .want = "T", .field = "message" },
        .{ .level = 20, .want = "D", .field = "message" },
        .{ .level = 30, .want = "I", .field = "message" },
        .{ .level = 40, .want = "W", .field = "message" },
        .{ .level = 50, .want = "E", .field = "message" },
        // PANIC switches the message field to the raw stacktrace; "m" is not
        // gzip, so the decode-error name lands there (plan D5/D10).
        .{ .level = 60, .want = "P", .field = "stacktrace" },
        .{ .level = 77, .want = "UNKNOWN(77)", .field = "message" },
    };
    for (cases) |case| {
        var pb = viewer.PB{};
        defer pb.deinit(a);
        try pb.header(a, 0, case.level);
        try pb.msg(a, "m");

        const got = try renderTest(&pool, pb.list.items);
        defer _ = pool.put(@constCast(got));

        var want_buf: [64]u8 = undefined;
        const value = if (case.level == 60) "EndOfStream" else "\"m\"";
        const want = std.fmt.bufPrint(&want_buf, "{{\"time\":0,\"level\":\"{s}\",\"{s}\":{s}}}", .{ case.want, case.field, value }) catch unreachable;
        try expectEqualSlices(u8, want, got);
    }
}

test "header golden: empty context has no trailing comma" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "");

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(u8, "{\"time\":0,\"level\":\"I\",\"message\":\"\"}", got);
}

test "scalar goldens: every integer width and the extremes" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    try pb.key(a, .int8, "i8");
    try pb.byte(a, @bitCast(@as(i8, std.math.minInt(i8))));
    try pb.key(a, .int16, "i16");
    try pb.le(a, i16, std.math.minInt(i16));
    try pb.key(a, .int32, "i32");
    try pb.le(a, i32, std.math.minInt(i32));
    try pb.key(a, .int64, "i64");
    try pb.le(a, i64, std.math.minInt(i64));
    try pb.key(a, .uint8, "u8");
    try pb.byte(a, std.math.maxInt(u8));
    try pb.key(a, .uint16, "u16");
    try pb.le(a, u16, std.math.maxInt(u16));
    try pb.key(a, .uint32, "u32");
    try pb.le(a, u32, std.math.maxInt(u32));
    try pb.key(a, .uint64, "u64");
    try pb.le(a, u64, std.math.maxInt(u64));
    try pb.key(a, .ivar, "ivar");
    try pb.uvarint(a, 1); // zigzag -1
    try pb.key(a, .uvar, "uvar");
    try pb.uvarint(a, 300);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"m\"," ++
            "\"i8\":-128,\"i16\":-32768,\"i32\":-2147483648,\"i64\":-9223372036854775808," ++
            "\"u8\":255,\"u16\":65535,\"u32\":4294967295,\"u64\":18446744073709551615," ++
            "\"ivar\":-1,\"uvar\":300}",
        got,
    );
}

test "scalar goldens: bool, floats, time and duration" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    try pb.key(a, .bool, "b");
    try pb.byte(a, 1);
    try pb.key(a, .float32, "f32");
    try pb.le(a, u32, @bitCast(@as(f32, 1.0e-45)));
    try pb.key(a, .float64, "f64");
    try pb.le(a, u64, @bitCast(@as(f64, 5.0e-324)));
    try pb.key(a, .float64, "nan");
    try pb.le(a, u64, @bitCast(std.math.nan(f64)));
    try pb.key(a, .float64, "inf");
    try pb.le(a, u64, @bitCast(std.math.inf(f64)));
    try pb.key(a, .float64, "negzero");
    try pb.le(a, u64, @bitCast(@as(f64, -0.0)));
    try pb.key(a, .time, "t");
    try pb.le(a, u64, 1_773_974_798_041_168_000);
    try pb.key(a, .duration, "d");
    try pb.le(a, u64, 1_234_567_890_101_121);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"m\"," ++
            "\"b\":true,\"f32\":1e-45,\"f64\":5e-324,\"nan\":\"NaN\",\"inf\":inf," ++
            "\"negzero\":-0.0,\"t\":1773974798041168000,\"d\":\"342h56m7.890101121s\"}",
        got,
    );
}

test "slices: compact, empty, strings, floats and base64" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 4096);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "slices");

    try pb.key(a, .sliceBool, "bools");
    try pb.uvarint(a, 2);
    try pb.byte(a, 1);
    try pb.byte(a, 0);

    try pb.key(a, .sliceInt64, "ints");
    try pb.uvarint(a, 3);
    try pb.le(a, i64, -1);
    try pb.le(a, i64, 0);
    try pb.le(a, i64, 1);

    try pb.key(a, .sliceString, "strs");
    try pb.uvarint(a, 2);
    try pb.uvarint(a, 1);
    try pb.raw(a, "a");
    try pb.uvarint(a, 3);
    try pb.raw(a, "b\"c");

    try pb.key(a, .sliceFloat64, "floats");
    try pb.uvarint(a, 2);
    try pb.le(a, u64, @bitCast(@as(f64, 1.5)));
    try pb.le(a, u64, @bitCast(std.math.nan(f64)));

    try pb.key(a, .sliceUint8, "u8s");
    try pb.uvarint(a, 3);
    try pb.raw(a, "\x01\x02\x03");

    try pb.key(a, .sliceInt32, "empty");
    try pb.uvarint(a, 0);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"slices\"," ++
            "\"bools\":[true,false],\"ints\":[-1,0,1],\"strs\":[\"a\",\"b\\\"c\"]," ++
            "\"floats\":[1.5,\"NaN\"],\"u8s\":\"AQID\",\"empty\":[]}",
        got,
    );
}

test "escaping: control chars, quotes and backslashes round-trip" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");
    try pb.strField(a, "s", "a\tb\n\"c\"\\\x01");

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"m\",\"s\":\"a\\tb\\n\\\"c\\\"\\\\\\u0001\"}",
        got,
    );
}

test "predefined key code 0 renders INVALID while other codes drop" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");
    try pb.byte(a, @intFromEnum(consts.ValueKind.uint64));
    try pb.byte(a, 0); // predefined key form
    try pb.uvarint(a, 0); // code 0 -> "INVALID"
    try pb.le(a, u64, 7);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"m\",\"INVALID\":7}",
        got,
    );

    var bad = viewer.PB{};
    defer bad.deinit(a);
    try bad.header(a, 0, @intFromEnum(consts.logLevel.info));
    try bad.msg(a, "m");
    try bad.byte(a, @intFromEnum(consts.ValueKind.uint64));
    try bad.byte(a, 0);
    try bad.uvarint(a, 9); // unknown predefined code
    try bad.le(a, u64, 7);

    var bc = Ctx.init(a);
    defer bc.deinit();
    const buf = try pool.get(initialCapacity(bad.list.items.len));
    var cursor = Out{ .pool = &pool, .buf = buf };
    defer cursor.release();
    try std.testing.expectError(error.UnknownValueKind, renderRecord(&cursor, &bc, bad.list.items));
}

test "unknown version and unknown kind drop cleanly" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.le(a, u16, 99);
    try pb.le(a, u64, 0);
    try pb.byte(a, 30);
    try pb.byte(a, 0);
    try pb.uvarint(a, 0);

    var c1 = Ctx.init(a);
    defer c1.deinit();
    const buf = try pool.get(initialCapacity(pb.list.items.len));
    var cursor = Out{ .pool = &pool, .buf = buf };
    defer cursor.release();
    try std.testing.expectError(error.VersionNotSupported, renderRecord(&cursor, &c1, pb.list.items));

    var pb2 = viewer.PB{};
    defer pb2.deinit(a);
    try pb2.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb2.msg(a, "m");
    try pb2.byte(a, 200); // not a valid ValueKind

    var c2 = Ctx.init(a);
    defer c2.deinit();
    const buf2 = try pool.get(initialCapacity(pb2.list.items.len));
    var cursor2 = Out{ .pool = &pool, .buf = buf2 };
    defer cursor2.release();
    try std.testing.expectError(error.UnknownValueKind, renderRecord(&cursor2, &c2, pb2.list.items));
}

test "groups: inline, nested and empty" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "groups");
    try pb.key(a, .nodeGroup, "g");
    try pb.key(a, .int64, "x");
    try pb.le(a, i64, 1);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.key(a, .nodeGroup, "outer");
    try pb.key(a, .nodeGroup, "inner");
    try pb.key(a, .bool, "b");
    try pb.byte(a, 1);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.key(a, .nodeGroup, "empty");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"I\",\"message\":\"groups\"," ++
            "\"g\":{\"x\":1},\"outer\":{\"inner\":{\"b\":true}},\"empty\":{}}",
        got,
    );
}

test "errors golden: inline error form" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 1024);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");
    try pb.key(a, .nodeError, "err-beer");
    try pb.key(a, .nodeNew, "error");
    try pb.key(a, .nodeLocation, "@location");
    try pb.uvarint(a, 331);
    try pb.strField(a, "new-string", "Hello World!");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"E\",\"message\":\"errors\"," ++
            "\"err-beer\":{\"@ctx\":{\"NEW: error\":{\"@loc\":\"@location:331\"," ++
            "\"new-string\":\"Hello World!\"}},\"@txt\":\"error\"}}",
        got,
    );
}

test "errors golden: full fixture line" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 8192);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try render.buildErrorsFixture(a, &pb);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":1776880099371299000,\"level\":\"E\",\"message\":\"errors\"," ++
            "\"err-foreign\":\"EOF\"," ++
            "\"err-beer\":{\"@ctx\":{\"NEW: error\":{\"@loc\":\"" ++ render.ERRORS_FILE ++ ":331\"," ++
            "\"new-string\":\"Hello World!\"},\"WRAP: wrap\":{\"@loc\":\"" ++ render.ERRORS_FILE ++ ":332\"," ++
            "\"wrap-int\":1},\"CTX\":{\"@loc\":\"" ++ render.ERRORS_FILE ++ ":333\"," ++
            "\"just-pi\":3.141592653589793}},\"@txt\":\"wrap: error\"}," ++
            "\"err-foreign-root\":{\"@ctx\":{\"WRAP: wrap foreign\":{\"@loc\":\"" ++ render.ERRORS_FILE ++ ":335\"," ++
            "\"wrap-bool\":true}},\"@txt\":\"wrap foreign: EOF\"}," ++
            "\"err-intermixed\":{\"@ctx\":{\"NEW: error\":{\"@loc\":\"" ++ render.ERRORS_FILE ++ ":337\"," ++
            "\"new-time\":1776880099371299000}},\"@txt\":\"foreign wrap: error\"}}",
        got,
    );
}

test "errors: embed text wins over fragment join" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "m");
    try pb.key(a, .nodeErrorEmbed, "err-embed");
    const embed = "foreign wrap: error";
    try pb.uvarint(a, embed.len);
    try pb.raw(a, embed);
    try pb.key(a, .nodeWrap, "wrap foreign");
    try pb.key(a, .nodeLocation, "@location");
    try pb.uvarint(a, 331);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"E\",\"message\":\"m\"," ++
            "\"err-embed\":{\"@ctx\":{\"WRAP: wrap foreign\":{\"@loc\":\"@location:331\"}}," ++
            "\"@txt\":\"foreign wrap: error\"}}",
        got,
    );
}

test "panic golden: raw gunzipped stacktrace field" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 8192);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try render.buildPanicFixture(a, &pb);

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":1776880099375255000,\"level\":\"P\",\"stacktrace\":" ++ render.PANIC_STACK ++
            ",\"recovered\":\"this is a panic\"}",
        got,
    );
}

test "panic: gzip decode failure appends the error name" {
    const a = std.testing.allocator;
    var pool = try BufferPool.init(a, 4, 512);
    defer pool.deinit();

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.panic));
    try pb.msg(a, "not a gzip stream");

    const got = try renderTest(&pool, pb.list.items);
    defer _ = pool.put(@constCast(got));
    try expectEqualSlices(
        u8,
        "{\"time\":0,\"level\":\"P\",\"stacktrace\":BadGzipHeader}",
        got,
    );
}
