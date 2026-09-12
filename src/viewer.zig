//! log viewer: wire payload -> node tree.
//!
//! This module is the Zig port of the Rust reference viewer parse path
//! (`blog-rs/src/log_parser_parse.rs`, `log_parser_node.rs`,
//! `log_parser_tree_builder.rs`, `log_parser.rs::make_record`). It turns a
//! record payload (`version..ctx`, i.e. the bytes after the log framing) into
//! a flat array of `Node`s plus the header fields, ready for rendering.
//!
//! The wire vocabulary is `consts.ValueKind` (the new Go/Zig numbering). The
//! Rust `ValueKind` numbering predates it; the dispatch below is the single
//! place where the two are bridged. See `TASK-ZIG-TREE-VIEWER.md` §8.
//!
//! `parseRecord` is bounds-checked and allocation-fallible: unlike the logger
//! hot path, the viewer may over-read nothing and always validates lengths.

const std = @import("std");
const consts = @import("consts.zig");

pub const ParseError = std.mem.Allocator.Error || error{
    Truncated,
    VarintOverflow,
    VersionNotSupported,
    UnknownValueKind,
};

/// Render-side node kind, split into three regions just like the Rust
/// `NodeKind`: values (0..63), slices (64..127), hierarchy roots (128..255).
pub const NodeKind = enum(u32) {
    // Values.
    bool,
    time,
    dur,
    int,
    ivar,
    i8,
    i16,
    i32,
    i64,
    uint,
    uvar,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    str,
    bytes,
    err_txt,
    err_txt_fragment,
    err_loc,
    err_embed_text,

    // Slices.
    bools,
    ints,
    i8s,
    i16s,
    i32s,
    i64s,
    uints,
    u8s,
    u16s,
    u32s,
    u64s,
    f32s,
    f64s,
    strs,

    // Roots.
    group,
    err,
    err_embed,
    err_stage_new,
    err_stage_wrap,
    err_stage_ctx,
    group_end,

    /// Nodes that open a prefix level (Rust `is_group`).
    pub fn isGroup(self: NodeKind) bool {
        return switch (self) {
            .group, .err, .err_embed, .err_stage_new, .err_stage_wrap, .err_stage_ctx => true,
            else => false,
        };
    }
};

pub const Location = struct {
    len: usize,
    off: usize,
    line: u64,
};

/// One parsed context element. Offsets are relative to the record payload.
/// `val_len`/`val_off` are two halves of an opaque value: for 64-bit values
/// the pair is `low | (high << 32)` (Rust `Node::val_as_u64`); for byte ranges
/// it is `(len, off)`; for small scalars it is the scalar itself in `val_off`.
pub const Node = extern struct {
    kind: NodeKind,
    is_last: u32,
    key_len: u32,
    key_off: u32,
    val_len: u32,
    val_off: u32,

    pub inline fn valAsU64(self: Node) u64 {
        return @as(u64, self.val_len) | (@as(u64, self.val_off) << 32);
    }
};

/// Accumulates nodes for one record. Reused across records: `reset` keeps the
/// backing capacity.
pub const TreeBuilder = struct {
    ctrl: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(usize) = .empty,
    last: isize = -1,
    off: usize = 0,

    pub fn deinit(self: *TreeBuilder, allocator: std.mem.Allocator) void {
        self.ctrl.deinit(allocator);
        self.stack.deinit(allocator);
    }

    pub fn reset(self: *TreeBuilder) void {
        self.ctrl.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        self.last = -1;
        self.off = 0;
    }

    pub fn ctrlLen(self: *const TreeBuilder) u32 {
        return @intCast(self.ctrl.items.len);
    }

    pub fn add(
        self: *TreeBuilder,
        allocator: std.mem.Allocator,
        kind: NodeKind,
        key_len: u32,
        key_off: u32,
        val_len: u32,
        val_off: u32,
    ) ParseError!void {
        try self.ctrl.append(allocator, .{
            .kind = kind,
            .is_last = 0,
            .key_len = key_len,
            .key_off = key_off,
            .val_len = val_len,
            .val_off = val_off,
        });
    }
};

/// Parsed header + node tree of one record (port of `LogParser` + `make_record`).
pub const ParsedRecord = struct {
    time: u64 = 0,
    level: u8 = 0,
    loc: ?Location = null,
    msg_len: usize = 0,
    msg_off: usize = 0,
    builder: TreeBuilder = .{},

    /// Decision inputs for the compact-JSON vs tree choice (Rust
    /// `ctx_size` / `has_errors` plus the explicit group flag).
    ctx_size: usize = 0,
    has_errors: bool = false,
    has_groups: bool = false,
    group_depth: usize = 0,

    pub fn deinit(self: *ParsedRecord, allocator: std.mem.Allocator) void {
        self.builder.deinit(allocator);
    }

    /// Resets header/depth state and empties the builder, keeping capacity.
    pub fn reset(self: *ParsedRecord) void {
        self.builder.reset();
        self.time = 0;
        self.level = 0;
        self.loc = null;
        self.msg_len = 0;
        self.msg_off = 0;
        self.ctx_size = 0;
        self.has_errors = false;
        self.has_groups = false;
        self.group_depth = 0;
    }
};

const Uvarint = struct { val: u64, size: usize };

/// Bounds-checked LEB128 decode. The logger hot path uses `decoding.zig`'s
/// unconditional 8/16-byte reader; records handed to the viewer need not be
/// padded, so this reader never reads past `bytes.len`.
pub fn readUvarint(bytes: []const u8, off: usize) ParseError!Uvarint {
    var res: u64 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (off + i >= bytes.len) return error.Truncated;
        const b = bytes[off + i];
        if (i == 9 and (b & 0x7F) > 1) return error.VarintOverflow;
        res |= @as(u64, b & 0x7F) << @intCast(i * 7);
        if (b & 0x80 == 0) return .{ .val = res, .size = i + 1 };
    }
    return error.VarintOverflow;
}

const Varint = struct { val: i64, size: usize };

/// Bounds-checked zigzag varint decode.
pub fn readVarint(bytes: []const u8, off: usize) ParseError!Varint {
    const u = try readUvarint(bytes, off);
    const val = @as(i64, @bitCast(u.val >> 1)) ^ -@as(i64, @bitCast(u.val & 1));
    return .{ .val = val, .size = u.size };
}

inline fn readIntLe(comptime T: type, bytes: []const u8, off: usize) ParseError!T {
    const n = @sizeOf(T);
    if (off + n > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[off..][0..n], .little);
}

const Prev = union(enum) {
    whatever,
    end: usize,
};

fn markAsLast(rec: *ParsedRecord, prev: Prev) void {
    const items = rec.builder.ctrl.items;
    switch (prev) {
        .end => |idx| {
            const curlen = rec.builder.ctrlLen();
            const x = &items[idx];
            x.val_len = curlen - x.val_len;
            x.is_last = 1;
        },
        .whatever => {
            if (items.len == 0) return;
            const idx = items.len - 1;
            const curlen = rec.builder.ctrlLen();
            const x = &items[idx];
            if (!x.kind.isGroup()) {
                x.is_last = 1;
            } else {
                x.val_len = curlen - x.val_len;
            }
        },
    }
}

/// Parse a record payload into `rec`. `payload` starts at the version field
/// (the log start marker, CRC and length are framing, handled by the sink).
pub fn parseRecord(
    allocator: std.mem.Allocator,
    payload: []const u8,
    rec: *ParsedRecord,
) ParseError!void {
    rec.reset();

    if (payload.len < 11) return error.Truncated;
    const version = std.mem.readInt(u16, payload[0..2], .little);
    if (version != consts.version) return error.VersionNotSupported;

    rec.time = std.mem.readInt(u64, payload[2..10], .little);
    rec.level = payload[10];
    var off: usize = 11;

    // Location: a zero flag byte, or uvarint(file.len) + file + uvarint(line).
    if (off >= payload.len) return error.Truncated;
    if (payload[off] == 0) {
        off += 1;
        rec.loc = null;
    } else {
        const fl = try readUvarint(payload, off);
        const file_off = off + fl.size;
        const file_end = file_off + @as(usize, @intCast(fl.val));
        if (file_end > payload.len) return error.Truncated;
        off = file_end;
        const ln = try readUvarint(payload, off);
        off += ln.size;
        rec.loc = .{ .len = @intCast(fl.val), .off = file_off, .line = ln.val };
    }

    // Message: uvarint(len) + bytes.
    const ml = try readUvarint(payload, off);
    rec.msg_len = @intCast(ml.val);
    rec.msg_off = off + ml.size;
    off = rec.msg_off + rec.msg_len;
    if (off > payload.len) return error.Truncated;

    try parseCtx(allocator, payload, off, rec);
}

fn parseCtx(
    allocator: std.mem.Allocator,
    payload: []const u8,
    start_off: usize,
    rec: *ParsedRecord,
) ParseError!void {
    const cap = payload.len;
    var off = start_off;
    var prev: Prev = .whatever;

    while (off < cap) {
        rec.group_depth = rec.builder.stack.items.len;

        const kind = std.enums.fromInt(consts.ValueKind, payload[off]) orelse
            return error.UnknownValueKind;
        off += 1;

        switch (kind) {
            .nodeContext => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .err_stage_ctx, 0, 0, rec.builder.ctrlLen(), 0);
                prev = .whatever;
                continue;
            },
            .nodePhantomContext => {
                prev = .whatever;
                continue;
            },
            .nodeGroupEnd => {
                markAsLast(rec, prev);
                const start = rec.builder.stack.pop() orelse return error.Truncated;
                try rec.builder.add(allocator, .group_end, 0, 0, 0, 0);
                prev = .{ .end = start };
                continue;
            },
            else => {},
        }

        // Key: first byte nonzero -> uvarint(len) + literal key; zero ->
        // predefined key index (Zig logger emits none, so the value is unused).
        if (off >= cap) return error.Truncated;
        var key_len: u32 = 0;
        var key_off: u32 = 0;
        if (payload[off] != 0) {
            const k = try readUvarint(payload, off);
            key_len = @intCast(k.val);
            key_off = @intCast(off + k.size);
            off += k.size + @as(usize, @intCast(k.val));
        } else {
            const k = try readUvarint(payload, off + 1);
            key_len = 0;
            key_off = @intCast(k.val);
            off += k.size + 1;
        }

        prev = .whatever;

        switch (kind) {
            .nodeNew => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .err_stage_new, key_len, key_off, rec.builder.ctrlLen(), 0);
            },
            .nodeWrap => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .err_stage_wrap, key_len, key_off, rec.builder.ctrlLen(), 0);
            },
            .nodeLocation => {
                const line = try readUvarint(payload, off);
                off += line.size;
                try rec.builder.add(allocator, .err_loc, key_len, key_off, 0, @intCast(line.val));
            },
            .nodeForeignErrorText => {
                try rec.builder.add(allocator, .err_txt_fragment, key_len, key_off, 0, 0);
            },
            .nodeError => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .err, key_len, key_off, rec.builder.ctrlLen(), 0);
                rec.ctx_size += 1;
                rec.has_errors = true;
            },
            .nodeErrorEmbed => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .err_embed, key_len, key_off, rec.builder.ctrlLen(), 0);

                const text = try readUvarint(payload, off);
                off += text.size;
                try rec.builder.add(allocator, .err_embed_text, 0, 0, @intCast(text.val), @intCast(off));
                off += @intCast(text.val);

                rec.ctx_size += 1;
                rec.has_errors = true;
            },
            .nodeGroup => {
                try rec.builder.stack.append(allocator, rec.builder.ctrl.items.len);
                try rec.builder.add(allocator, .group, key_len, key_off, rec.builder.ctrlLen(), 0);
                rec.ctx_size += 1;
                rec.has_groups = true;
            },
            .nodeContext, .nodePhantomContext, .nodeGroupEnd => unreachable,

            .bool => {
                if (off >= cap) return error.Truncated;
                try rec.builder.add(allocator, .bool, key_len, key_off, 0, payload[off]);
                off += 1;
                rec.ctx_size += 1;
            },
            .time => {
                const v = try readIntLe(u64, payload, off);
                try rec.builder.add(allocator, .time, key_len, key_off, @truncate(v), @truncate(v >> 32));
                off += 8;
                rec.ctx_size += 1;
            },
            .duration => {
                const v = try readIntLe(u64, payload, off);
                try rec.builder.add(allocator, .dur, key_len, key_off, @truncate(v), @truncate(v >> 32));
                off += 8;
                rec.ctx_size += 1;
            },
            .ivar => {
                const v = try readVarint(payload, off);
                const uv: u64 = @bitCast(v.val);
                try rec.builder.add(allocator, .ivar, key_len, key_off, @truncate(uv), @truncate(uv >> 32));
                off += v.size;
                rec.ctx_size += 1;
            },
            .int8 => {
                if (off >= cap) return error.Truncated;
                const sv: i8 = @bitCast(payload[off]);
                try rec.builder.add(allocator, .i8, key_len, key_off, 0, @bitCast(@as(i32, sv)));
                off += 1;
                rec.ctx_size += 1;
            },
            .int16 => {
                const v = try readIntLe(u16, payload, off);
                try rec.builder.add(allocator, .i16, key_len, key_off, 0, v);
                off += 2;
                rec.ctx_size += 1;
            },
            .int32 => {
                const v = try readIntLe(u32, payload, off);
                try rec.builder.add(allocator, .i32, key_len, key_off, 0, v);
                off += 4;
                rec.ctx_size += 1;
            },
            .int64 => {
                const v = try readIntLe(u64, payload, off);
                try rec.builder.add(allocator, .i64, key_len, key_off, @truncate(v), @truncate(v >> 32));
                off += 8;
                rec.ctx_size += 1;
            },
            .uvar => {
                const v = try readUvarint(payload, off);
                try rec.builder.add(allocator, .uvar, key_len, key_off, @truncate(v.val), @truncate(v.val >> 32));
                off += v.size;
                rec.ctx_size += 1;
            },
            .uint8 => {
                if (off >= cap) return error.Truncated;
                try rec.builder.add(allocator, .u8, key_len, key_off, 0, payload[off]);
                off += 1;
                rec.ctx_size += 1;
            },
            .uint16 => {
                const v = try readIntLe(u16, payload, off);
                try rec.builder.add(allocator, .u16, key_len, key_off, 0, v);
                off += 2;
                rec.ctx_size += 1;
            },
            .uint32 => {
                const v = try readIntLe(u32, payload, off);
                try rec.builder.add(allocator, .u32, key_len, key_off, 0, v);
                off += 4;
                rec.ctx_size += 1;
            },
            .uint64 => {
                const v = try readIntLe(u64, payload, off);
                try rec.builder.add(allocator, .u64, key_len, key_off, @truncate(v), @truncate(v >> 32));
                off += 8;
                rec.ctx_size += 1;
            },
            .float32 => {
                const v = try readIntLe(u32, payload, off);
                try rec.builder.add(allocator, .f32, key_len, key_off, 0, v);
                off += 4;
                rec.ctx_size += 1;
            },
            .float64 => {
                const v = try readIntLe(u64, payload, off);
                try rec.builder.add(allocator, .f64, key_len, key_off, @truncate(v), @truncate(v >> 32));
                off += 8;
                rec.ctx_size += 1;
            },
            .string => {
                off = try varthing(allocator, payload, off, .str, key_len, key_off, rec);
                rec.ctx_size += 1;
            },
            .errorRaw => {
                off = try varthing(allocator, payload, off, .err_txt, key_len, key_off, rec);
                rec.ctx_size += 1;
            },
            .sliceBool => {
                off = try slice(allocator, payload, off, .bools, key_len, key_off, 1, rec);
                rec.ctx_size += 1;
            },
            .sliceInt8 => {
                off = try slice(allocator, payload, off, .i8s, key_len, key_off, 1, rec);
                rec.ctx_size += 1;
            },
            .sliceInt16 => {
                off = try slice(allocator, payload, off, .i16s, key_len, key_off, 2, rec);
                rec.ctx_size += 1;
            },
            .sliceInt32 => {
                off = try slice(allocator, payload, off, .i32s, key_len, key_off, 4, rec);
                rec.ctx_size += 1;
            },
            .sliceInt64 => {
                off = try slice(allocator, payload, off, .ints, key_len, key_off, 8, rec);
                rec.ctx_size += 1;
            },
            .sliceUint8 => {
                off = try slice(allocator, payload, off, .u8s, key_len, key_off, 1, rec);
                rec.ctx_size += 1;
            },
            .sliceUint16 => {
                off = try slice(allocator, payload, off, .u16s, key_len, key_off, 2, rec);
                rec.ctx_size += 1;
            },
            .sliceUint32 => {
                off = try slice(allocator, payload, off, .u32s, key_len, key_off, 4, rec);
                rec.ctx_size += 1;
            },
            .sliceUint64 => {
                off = try slice(allocator, payload, off, .uints, key_len, key_off, 8, rec);
                rec.ctx_size += 1;
            },
            .sliceFloat32 => {
                off = try slice(allocator, payload, off, .f32s, key_len, key_off, 4, rec);
                rec.ctx_size += 1;
            },
            .sliceFloat64 => {
                off = try slice(allocator, payload, off, .f64s, key_len, key_off, 8, rec);
                rec.ctx_size += 1;
            },
            .sliceString => {
                const count = try readUvarint(payload, off);
                off += count.size;
                const start = off;
                var i: usize = 0;
                while (i < count.val) : (i += 1) {
                    const s = try readUvarint(payload, off);
                    const end = off + s.size + @as(usize, @intCast(s.val));
                    if (end > cap) return error.Truncated;
                    off = end;
                }
                try rec.builder.add(allocator, .strs, key_len, key_off, @intCast(count.val), @intCast(start));
                rec.ctx_size += 1;
            },
        }
    }

    markAsLast(rec, prev);
}

/// uvarint(len) + bytes; stores the byte range in `val_len`/`val_off`.
fn varthing(
    allocator: std.mem.Allocator,
    payload: []const u8,
    off: usize,
    kind: NodeKind,
    key_len: u32,
    key_off: u32,
    rec: *ParsedRecord,
) ParseError!usize {
    const l = try readUvarint(payload, off);
    const val_off = off + l.size;
    const end = val_off + @as(usize, @intCast(l.val));
    if (end > payload.len) return error.Truncated;
    try rec.builder.add(allocator, kind, key_len, key_off, @intCast(l.val), @intCast(val_off));
    return end;
}

/// uvarint(count) + count fixed-size items; stores `(count, off)`.
fn slice(
    allocator: std.mem.Allocator,
    payload: []const u8,
    off: usize,
    kind: NodeKind,
    key_len: u32,
    key_off: u32,
    item_size: usize,
    rec: *ParsedRecord,
) ParseError!usize {
    const l = try readUvarint(payload, off);
    const val_off = off + l.size;
    const count: usize = @intCast(l.val);
    const span = std.math.mul(usize, count, item_size) catch return error.Truncated;
    const end = val_off + span;
    if (end > payload.len) return error.Truncated;
    if (count > std.math.maxInt(u32)) return error.Truncated;
    try rec.builder.add(allocator, kind, key_len, key_off, @intCast(count), @intCast(val_off));
    return end;
}

const testing = std.testing;

/// Byte-level payload builder. Encodes the same wire layout the Go encoder in
/// `internal/core/attr_serialize.go` and `logger.go` produce. Public so the
/// renderer/writer tests can build fixtures without the logger.
pub const PB = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *PB, a: std.mem.Allocator) void {
        self.list.deinit(a);
    }

    pub fn byte(self: *PB, a: std.mem.Allocator, v: u8) !void {
        try self.list.append(a, v);
    }

    pub fn raw(self: *PB, a: std.mem.Allocator, s: []const u8) !void {
        try self.list.appendSlice(a, s);
    }

    pub fn le(self: *PB, a: std.mem.Allocator, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.list.appendSlice(a, &b);
    }

    pub fn uvarint(self: *PB, a: std.mem.Allocator, v: u64) !void {
        var x = v;
        while (x >= 0x80) {
            try self.list.append(a, @as(u8, @truncate(x)) | 0x80);
            x >>= 7;
        }
        try self.list.append(a, @intCast(x));
    }

    pub fn header(self: *PB, a: std.mem.Allocator, time: u64, level: u8) !void {
        try self.le(a, u16, consts.version);
        try self.le(a, u64, time);
        try self.byte(a, level);
        try self.byte(a, 0); // no location
    }

    pub fn headerLoc(self: *PB, a: std.mem.Allocator, time: u64, level: u8, file: []const u8, line: u64) !void {
        try self.le(a, u16, consts.version);
        try self.le(a, u64, time);
        try self.byte(a, level);
        try self.uvarint(a, file.len);
        try self.raw(a, file);
        try self.uvarint(a, line);
    }

    pub fn msg(self: *PB, a: std.mem.Allocator, m: []const u8) !void {
        try self.uvarint(a, m.len);
        try self.raw(a, m);
    }

    /// kind byte + uvarint(len(key)) + key bytes.
    pub fn key(self: *PB, a: std.mem.Allocator, kind: consts.ValueKind, k: []const u8) !void {
        try self.byte(a, @intFromEnum(kind));
        try self.uvarint(a, k.len);
        try self.raw(a, k);
    }

    pub fn strField(self: *PB, a: std.mem.Allocator, k: []const u8, v: []const u8) !void {
        try self.key(a, .string, k);
        try self.uvarint(a, v.len);
        try self.raw(a, v);
    }
};

fn nodeAt(rec: *const ParsedRecord, i: usize) Node {
    return rec.builder.ctrl.items[i];
}

fn payloadOf(rec: *const ParsedRecord, payload: []const u8, n: Node) []const u8 {
    _ = rec;
    return payload[n.val_off .. n.val_off + n.val_len];
}

test "parse message-only record" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 0x0102030405060708, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "just a message");

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expectEqual(@as(u64, 0x0102030405060708), rec.time);
    try testing.expectEqual(@intFromEnum(consts.logLevel.info), rec.level);
    try testing.expect(rec.loc == null);
    try testing.expectEqualSlices(u8, "just a message", payloadOf(&rec, pb.list.items, .{
        .kind = .str,
        .is_last = 0,
        .key_len = 0,
        .key_off = 0,
        .val_len = @intCast(rec.msg_len),
        .val_off = @intCast(rec.msg_off),
    }));
    try testing.expectEqual(@as(usize, 0), rec.builder.ctrl.items.len);
    try testing.expectEqual(@as(usize, 0), rec.ctx_size);
}

test "parse header location" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    const file = "/Users/me/alchemy_test.go";
    try pb.headerLoc(a, 42, @intFromEnum(consts.logLevel.warning), file, 265);
    try pb.msg(a, "m");

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expect(rec.loc != null);
    const loc = rec.loc.?;
    try testing.expectEqualSlices(u8, file, pb.list.items[loc.off .. loc.off + loc.len]);
    try testing.expectEqual(@as(u64, 265), loc.line);
}

test "flat context values" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 7, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.strField(a, "string", "Hello World!");
    const pi: f64 = 3.141592653589793;
    try pb.key(a, .float64, "pi");
    try pb.le(a, u64, @bitCast(pi));

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expectEqual(@as(usize, 3), rec.ctx_size);
    try testing.expect(!rec.has_groups);
    try testing.expect(!rec.has_errors);
    try testing.expectEqual(@as(usize, 3), rec.builder.ctrl.items.len);

    const n0 = nodeAt(&rec, 0);
    try testing.expectEqual(NodeKind.i64, n0.kind);
    try testing.expectEqual(@as(u32, 0), n0.is_last);
    try testing.expectEqualSlices(u8, "int", pb.list.items[n0.key_off .. n0.key_off + n0.key_len]);
    try testing.expectEqual(@as(u64, 4), n0.valAsU64());

    const n1 = nodeAt(&rec, 1);
    try testing.expectEqual(NodeKind.str, n1.kind);
    try testing.expectEqualSlices(u8, "string", pb.list.items[n1.key_off .. n1.key_off + n1.key_len]);
    try testing.expectEqualSlices(u8, "Hello World!", payloadOf(&rec, pb.list.items, n1));

    const n2 = nodeAt(&rec, 2);
    try testing.expectEqual(NodeKind.f64, n2.kind);
    try testing.expectEqual(@as(u32, 1), n2.is_last);
    try testing.expectEqual(@as(u64, @bitCast(pi)), n2.valAsU64());
}

test "groups: empty, populated, nested" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    // empty group
    try pb.key(a, .nodeGroup, "empty");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    // group with two children
    try pb.key(a, .nodeGroup, "group");
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.strField(a, "string", "Hello World!");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    // outer > inner
    try pb.key(a, .nodeGroup, "outer");
    try pb.key(a, .nodeGroup, "inner");
    try pb.key(a, .int64, "int1");
    try pb.le(a, u64, @bitCast(@as(i64, 5)));
    try pb.strField(a, "string1", "I'm here");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expect(rec.has_groups);
    const items = rec.builder.ctrl.items;

    // empty: val_len 1 (self only), is_last set because it is not the last
    // sibling, so its val_len was closed as a plain group.
    try testing.expectEqual(NodeKind.group, nodeAt(&rec, 0).kind);
    try testing.expectEqual(@as(u32, 1), nodeAt(&rec, 0).val_len);
    try testing.expectEqual(@as(u32, 0), nodeAt(&rec, 0).is_last);

    // populated group closed via the end-branch gets its full span.
    try testing.expectEqual(NodeKind.group, nodeAt(&rec, 2).kind);
    try testing.expectEqual(@as(u32, 0), nodeAt(&rec, 2).is_last);

    // group_end markers exist.
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, 1).kind);
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, items.len - 1).kind);

    // Each group contributes one to ctx_size: 3 groups + 6 scalars.
    try testing.expectEqual(@as(usize, 9), rec.ctx_size);
}

test "error with stage + location + attr, double group end" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    try pb.key(a, .nodeError, "err-beer");
    try pb.key(a, .nodeNew, "error");
    try pb.key(a, .nodeLocation, "@location");
    try pb.uvarint(a, 331);
    try pb.strField(a, "new-string", "Hello World!");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expect(rec.has_errors);
    try testing.expectEqual(@as(usize, 2), rec.ctx_size); // err + str

    try testing.expectEqual(NodeKind.err, nodeAt(&rec, 0).kind);
    try testing.expectEqual(NodeKind.err_stage_new, nodeAt(&rec, 1).kind);
    try testing.expectEqual(NodeKind.err_loc, nodeAt(&rec, 2).kind);
    try testing.expectEqual(@as(u32, 331), nodeAt(&rec, 2).val_off);
    try testing.expectEqual(NodeKind.str, nodeAt(&rec, 3).kind);
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, 4).kind);
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, 5).kind);

    // The inner stage closes over its span and marks itself last.
    try testing.expectEqual(@as(u32, 1), nodeAt(&rec, 1).is_last);
    // The outer error closes over the whole span.
    try testing.expectEqual(@as(u32, 1), nodeAt(&rec, 0).is_last);
    try testing.expectEqual(@as(u32, 6), nodeAt(&rec, 0).val_len);
}

test "error embed stores foreign text then payload" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    try pb.key(a, .nodeErrorEmbed, "err-embed");
    const foreign = "foreign text";
    try pb.uvarint(a, foreign.len);
    try pb.raw(a, foreign);
    try pb.key(a, .nodeWrap, "wrap foreign");
    try pb.key(a, .nodeLocation, "@location");
    try pb.uvarint(a, 335);
    try pb.key(a, .bool, "wrap-bool");
    try pb.byte(a, 1);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expect(rec.has_errors);
    try testing.expectEqual(NodeKind.err_embed, nodeAt(&rec, 0).kind);
    const emb = nodeAt(&rec, 1);
    try testing.expectEqual(NodeKind.err_embed_text, emb.kind);
    try testing.expectEqualSlices(u8, foreign, payloadOf(&rec, pb.list.items, emb));
    try testing.expectEqual(NodeKind.err_stage_wrap, nodeAt(&rec, 2).kind);
    try testing.expectEqual(NodeKind.err_loc, nodeAt(&rec, 3).kind);
    try testing.expectEqual(NodeKind.bool, nodeAt(&rec, 4).kind);
    try testing.expectEqual(@as(u32, 1), nodeAt(&rec, 4).val_off);
}

test "foreign error text under a context stage" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    // Mirrors JustError(foreign): [ForeignErrorText, JustContextNode] wrapped
    // by the error attr's double group end.
    try pb.key(a, .nodeError, "err-foreign");
    try pb.key(a, .nodeForeignErrorText, "EOF");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeContext));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    try testing.expect(rec.has_errors);
    try testing.expectEqual(NodeKind.err, nodeAt(&rec, 0).kind);
    try testing.expectEqual(NodeKind.err_txt_fragment, nodeAt(&rec, 1).kind);
    try testing.expectEqualSlices(
        u8,
        "EOF",
        pb.list.items[nodeAt(&rec, 1).key_off .. nodeAt(&rec, 1).key_off + nodeAt(&rec, 1).key_len],
    );
    try testing.expectEqual(NodeKind.err_stage_ctx, nodeAt(&rec, 2).kind);
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, 3).kind);
    try testing.expectEqual(NodeKind.group_end, nodeAt(&rec, 4).kind);
}

test "slices store count and offset" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    try pb.key(a, .sliceInt64, "int64");
    try pb.uvarint(a, 3);
    for ([_]i64{ -9223372036854775808, -1, 9223372036854775807 }) |v| {
        try pb.le(a, u64, @bitCast(v));
    }
    try pb.key(a, .sliceString, "string");
    try pb.uvarint(a, 2);
    try pb.uvarint(a, "Hello World!".len);
    try pb.raw(a, "Hello World!");
    try pb.uvarint(a, "Hello Galaxy!".len);
    try pb.raw(a, "Hello Galaxy!");

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    const n0 = nodeAt(&rec, 0);
    try testing.expectEqual(NodeKind.ints, n0.kind);
    try testing.expectEqual(@as(u32, 3), n0.val_len);
    try testing.expectEqual(@as(i64, -9223372036854775808), @as(i64, @bitCast(std.mem.readInt(u64, pb.list.items[n0.val_off..][0..8], .little))));

    const n1 = nodeAt(&rec, 1);
    try testing.expectEqual(NodeKind.strs, n1.kind);
    try testing.expectEqual(@as(u32, 2), n1.val_len);
    // First item is length-prefixed at val_off.
    const first = try readUvarint(pb.list.items, n1.val_off);
    try testing.expectEqualSlices(u8, "Hello World!", pb.list.items[n1.val_off + first.size ..][0..first.val]);
}

test "readUvarint bounds and overflow" {
    // Truncated continuation.
    try testing.expectError(error.Truncated, readUvarint(&[_]u8{0x80}, 0));
    try testing.expectError(error.Truncated, readUvarint(&[_]u8{}, 0));
    // Ten bytes all with the continuation bit never terminates cleanly.
    const overflow = [_]u8{0x80} ** 10;
    try testing.expectError(error.VarintOverflow, readUvarint(&overflow, 0));
    // Valid one-byte.
    const one = try readUvarint(&[_]u8{0x7f}, 0);
    try testing.expectEqual(@as(u64, 0x7f), one.val);
    try testing.expectEqual(@as(usize, 1), one.size);
}

test "record reuse does not accumulate nodes" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "one");
    try pb.strField(a, "k", "v");

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);
    try testing.expectEqual(@as(usize, 1), rec.builder.ctrl.items.len);
    try testing.expectEqual(@as(usize, 1), rec.ctx_size);

    var pb2 = PB{};
    defer pb2.deinit(a);
    try pb2.header(a, 2, @intFromEnum(consts.logLevel.warning));
    try pb2.msg(a, "two");

    try parseRecord(a, pb2.list.items, &rec);
    try testing.expectEqual(@as(usize, 0), rec.builder.ctrl.items.len);
    try testing.expectEqual(@as(usize, 0), rec.ctx_size);
    try testing.expectEqual(@as(u64, 2), rec.time);
    try testing.expectEqual(@intFromEnum(consts.logLevel.warning), rec.level);
}

test "all basic scalar kinds parse" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    try pb.key(a, .bool, "bool");
    try pb.byte(a, 1);
    try pb.key(a, .time, "time");
    try pb.le(a, u64, 1773974798041168000);
    try pb.key(a, .duration, "duration");
    try pb.le(a, u64, 1_234_567_890_101_121);
    try pb.key(a, .ivar, "ivar");
    try pb.uvarint(a, @bitCast(@as(i64, -1) << 1 ^ (@as(i64, -1) >> 63)));
    try pb.key(a, .uvar, "uvar");
    try pb.uvarint(a, 18446744073709551615);
    try pb.key(a, .int8, "int8");
    try pb.byte(a, @bitCast(@as(i8, -1)));
    try pb.key(a, .int16, "int16");
    try pb.le(a, u16, @bitCast(@as(i16, -1)));
    try pb.key(a, .int32, "int32");
    try pb.le(a, u32, @bitCast(@as(i32, -1)));
    try pb.key(a, .int64, "int64");
    try pb.le(a, u64, @bitCast(@as(i64, -1)));
    try pb.key(a, .uint8, "uint8");
    try pb.byte(a, 255);
    try pb.key(a, .uint16, "uint16");
    try pb.le(a, u16, 65535);
    try pb.key(a, .uint32, "uint32");
    try pb.le(a, u32, 4294967295);
    try pb.key(a, .uint64, "uint64");
    try pb.le(a, u64, 18446744073709551615);
    try pb.key(a, .float32, "float32");
    try pb.le(a, u32, @bitCast(@as(f32, 0.5)));
    try pb.key(a, .float64, "float64");
    try pb.le(a, u64, @bitCast(@as(f64, 2.718281828459045)));
    try pb.strField(a, "string", "s");
    try pb.key(a, .errorRaw, "err");
    try pb.uvarint(a, 3);
    try pb.raw(a, "raw");

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    const expect_kinds = [_]NodeKind{
        .bool, .time, .dur, .ivar, .uvar, .i8,  .i16, .i32,     .i64,
        .u8,   .u16,  .u32, .u64,  .f32,  .f64, .str, .err_txt,
    };
    try testing.expectEqual(expect_kinds.len, rec.builder.ctrl.items.len);
    try testing.expectEqual(@as(usize, expect_kinds.len), rec.ctx_size);
    for (expect_kinds, 0..) |k, i| {
        try testing.expectEqual(k, nodeAt(&rec, i).kind);
    }
    // i8 -1 is sign-extended into val_off, matching the Rust parser.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), nodeAt(&rec, 5).val_off);
}

test "predefined key index is stored as key_off" {
    const a = testing.allocator;
    var pb = PB{};
    defer pb.deinit(a);
    try pb.header(a, 1, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");

    // Zero key marker then the predefined index, then a bool value.
    try pb.byte(a, @intFromEnum(consts.ValueKind.bool));
    try pb.byte(a, 0);
    try pb.uvarint(a, 7);
    try pb.byte(a, 1);

    var rec = ParsedRecord{};
    defer rec.deinit(a);
    try parseRecord(a, pb.list.items, &rec);

    const n = nodeAt(&rec, 0);
    try testing.expectEqual(NodeKind.bool, n.kind);
    try testing.expectEqual(@as(u32, 0), n.key_len);
    try testing.expectEqual(@as(u32, 7), n.key_off);
}

test "parse rejects unsupported version and truncated records" {
    const a = testing.allocator;
    var rec = ParsedRecord{};
    defer rec.deinit(a);

    var pb = PB{};
    defer pb.deinit(a);
    try pb.le(a, u16, consts.version + 1);
    try pb.le(a, u64, 0);
    try pb.byte(a, 0);
    try pb.byte(a, 0);
    try pb.msg(a, "m");
    try testing.expectError(error.VersionNotSupported, parseRecord(a, pb.list.items, &rec));

    try testing.expectError(error.Truncated, parseRecord(a, &.{}, &rec));

    // Header cut right after the level byte (no location flag).
    var header_only = PB{};
    defer header_only.deinit(a);
    try header_only.le(a, u16, consts.version);
    try header_only.le(a, u64, 0);
    try header_only.byte(a, @intFromEnum(consts.logLevel.info));
    try testing.expectEqual(@as(usize, 11), header_only.list.items.len);
    try testing.expectError(error.Truncated, parseRecord(a, header_only.list.items, &rec));

    // Lone value kind byte with no key follows the message.
    var bare_kind = PB{};
    defer bare_kind.deinit(a);
    try bare_kind.header(a, 0, @intFromEnum(consts.logLevel.info));
    try bare_kind.msg(a, "m");
    try bare_kind.byte(a, @intFromEnum(consts.ValueKind.string));
    try testing.expectError(error.Truncated, parseRecord(a, bare_kind.list.items, &rec));

    // Unknown value kind byte.
    var bad_kind = PB{};
    defer bad_kind.deinit(a);
    try bad_kind.header(a, 0, @intFromEnum(consts.logLevel.info));
    try bad_kind.msg(a, "m");
    try bad_kind.byte(a, 200);
    try testing.expectError(error.UnknownValueKind, parseRecord(a, bad_kind.list.items, &rec));

    // Unbalanced group end.
    var extra_end = PB{};
    defer extra_end.deinit(a);
    try extra_end.header(a, 0, @intFromEnum(consts.logLevel.info));
    try extra_end.msg(a, "m");
    try extra_end.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try testing.expectError(error.Truncated, parseRecord(a, extra_end.list.items, &rec));
}
