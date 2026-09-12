//! log viewer renderer: parsed record -> human readable bytes.

const std = @import("std");
const flate = std.compress.flate;
const jsonescape = @import("jsonescape");
const viewer = @import("viewer.zig");

const TREE_ITEM_INTR = "\u{251C}\u{2500} "; // "|- "
const TREE_ITEM_FIN = "\u{2514}\u{2500} "; // "`- "
const PIPE = "\u{2502}  "; // "|  "
const SPACER = "   ";
const TIME_FALLBACK = "????-??-?? ??:??:??.???";
const MAX_SECS: i64 = 253402300799; // 9999-12-31T23:59:59Z

/// ANSI color table, one-to-one with Rust `ColorProfile`. All slices are
/// empty in `.plain`, which is what tests use.
pub const ColorProfile = struct {
    reset: []const u8,
    bold: []const u8,
    time: []const u8,
    trace: []const u8,
    debug: []const u8,
    info: []const u8,
    warn: []const u8,
    err: []const u8,
    panic: []const u8,
    levelu: []const u8,
    loc: []const u8,
    link: []const u8,
    st_dots: []const u8,
    st_text: []const u8,
    key: []const u8,
    err_key: []const u8,
    err_meta: []const u8,
    err_stage: []const u8,
    ctx: []const u8,

    pub const plain = ColorProfile{
        .reset = "",
        .bold = "",
        .time = "",
        .trace = "",
        .debug = "",
        .info = "",
        .warn = "",
        .err = "",
        .panic = "",
        .levelu = "",
        .loc = "",
        .link = "",
        .st_dots = "",
        .st_text = "",
        .key = "",
        .err_key = "",
        .err_meta = "",
        .err_stage = "",
        .ctx = "",
    };

    pub const light = ColorProfile{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .time = "\x1b[95m",
        .trace = "\x1b[90m",
        .debug = "\x1b[36m",
        .info = "\x1b[32m",
        .warn = "\x1b[33m",
        .err = "\x1b[31m",
        .panic = "\x1b[1;41;97m",
        .levelu = "\x1b[1;41;97m",
        .loc = "\x1b[38;5;240m",
        .link = "\x1b[38;5;248m",
        .st_dots = "\x1b[38;5;252m",
        .st_text = "\x1b[38;5;240m",
        .key = "\x1b[38;5;31m",
        .err_key = "\x1b[38;5;203m",
        .err_meta = "\x1b[38;2;255;140;0m",
        .err_stage = "\x1b[38;2;255;165;0m",
        .ctx = "\x1b[38;5;238m",
    };

    pub const dark = ColorProfile{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .time = "\x1b[35m",
        .trace = "\x1b[90m",
        .debug = "\x1b[36m",
        .info = "\x1b[32m",
        .warn = "\x1b[33m",
        .err = "\x1b[31m",
        .panic = "\x1b[1;41;97m",
        .levelu = "\x1b[1;41;97m",
        .loc = "\x1b[38;5;244m",
        .link = "\x1b[38;5;236m",
        .st_dots = "\x1b[38;5;236m",
        .st_text = "\x1b[38;5;245m",
        .key = "\x1b[38;5;109m",
        .err_key = "\x1b[38;5;203m",
        .err_meta = "\x1b[38;2;255;140;0m",
        .err_stage = "\x1b[38;2;255;165;0m",
        .ctx = "\x1b[38;5;252m",
    };
};

/// Rendering knobs; mirrors the Rust `LogRender` defaults (`expand_context_since`
/// is 4 here, reproducing "compact JSON while fewer than 4 keys").
pub const RenderOptions = struct {
    /// Arrays with at least this many items render expanded, one per line.
    expand_array_since: usize = 8,
    /// Contexts with at least this many elements render as a tree.
    expand_context_since: usize = 4,
    /// Records nested deeper than this fall back to compact JSON.
    max_tree_depth: usize = 16,
    /// Offset applied to timestamps before formatting. Zig has no portable TZ
    /// database, so local time is expressed as a fixed offset (seconds east of
    /// UTC). The CLI sets this from the environment; tests pin it.
    tz_offset_seconds: i64 = 0,
};

/// True when the context tail should be a tree rather than compact JSON.
/// Port of Rust `need_tree` with the drifted threshold plus an explicit group
/// term so a group always forces the tree form.
pub fn needsTree(rec: *const viewer.ParsedRecord, options: RenderOptions) bool {
    return (rec.ctx_size >= options.expand_context_since or
        rec.has_errors or
        rec.has_groups) and rec.group_depth <= options.max_tree_depth;
}

/// Per-record tree error bookkeeping (Rust `render_tree` locals).
const TreeState = struct {
    error_text_len: usize = 0,
    error_text_off: usize = 0,
    is_embed_error: bool = false,
    error_depth: u64 = 0,
};

/// Rendering state, reused across records. Holds the color profile, the tree
/// prefix bitmap and the error text stack.
pub const Renderer = struct {
    const Self = @This();

    pub const ErrRef = struct { len: usize, off: usize };

    allocator: std.mem.Allocator,
    profile: ColorProfile,
    options: RenderOptions = .{},
    /// Active background color re-applied after every reset (Rust `color_back`).
    color_back: ?[]const u8 = null,
    err_stack: std.ArrayList(ErrRef) = .empty,
    /// Scratch buffer for the gzip stacktrace decode (Rust `LogRender::buf`).
    scratch: std.ArrayList(u8) = .empty,
    tree_prefix: u64 = 0,
    tree_depth: isize = 0,

    pub fn init(allocator: std.mem.Allocator, profile: ColorProfile) Self {
        return .{ .allocator = allocator, .profile = profile };
    }

    pub fn deinit(self: *Self) void {
        self.err_stack.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    /// Render one record: header first (always), then the context tail.
    pub fn render(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        rec: *const viewer.ParsedRecord,
    ) !void {
        // Mirrors Rust `LogParser::make_record` state reset.
        self.err_stack.clearRetainingCapacity();
        self.tree_prefix = 0;
        self.tree_depth = 0;
        self.color_back = null;

        try self.renderTime(dst, rec.time);
        const is_panic = try self.renderLevel(dst, rec.level);
        try self.renderLocation(dst, payload, rec.loc);

        if (!is_panic) {
            try self.renderMessage(dst, payload, rec);
            try self.colorSetBackCtx(dst);
            if (needsTree(rec, self.options)) {
                try self.renderTree(dst, payload, rec);
            } else {
                try self.renderJsonContext(dst, payload, rec);
            }
            try self.colorResetBack(dst);
            return;
        }

        try self.colorSetBackCtx(dst);
        try self.renderJsonContext(dst, payload, rec);
        try self.colorResetBack(dst);
        try self.renderStacktrace(dst, payload, rec);
    }

    /// Panic body: the message is a gzip stream. Decode it and emit every line
    /// prefixed with the `st_dots` color + `.... ` + the `st_text` color, then a
    /// trailing reset. On decode failure the error text is emitted the same way
    /// (Rust `render_stacktrace`).
    fn renderStacktrace(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        rec: *const viewer.ParsedRecord,
    ) !void {
        const msg = payload[rec.msg_off..][0..rec.msg_len];

        var fixed = std.Io.Reader.fixed(msg);
        var decoder: flate.Decompress = .init(&fixed, .gzip, &[_]u8{});
        self.scratch.clearRetainingCapacity();
        decoder.reader.appendRemainingUnlimited(self.allocator, &self.scratch) catch {
            try self.append(dst, self.profile.err);
            self.scratch.clearRetainingCapacity();
            const name = if (decoder.err) |err| @errorName(err) else "gzip decode failed";
            try self.scratch.appendSlice(self.allocator, name);
            try self.colorReset(dst);
        };

        const haystack = self.scratch.items;
        var start: usize = 0;
        for (haystack, 0..) |c, pos| {
            if (c != '\n') continue;
            try self.append(dst, self.profile.st_dots);
            try self.append(dst, ".... ");
            try self.append(dst, self.profile.st_text);
            try self.append(dst, haystack[start..pos]);
            try self.append(dst, "\n");
            start = pos + 1;
        }
        if (start < haystack.len) {
            try self.append(dst, self.profile.st_dots);
            try self.append(dst, ".... ");
            try self.append(dst, self.profile.st_text);
            try self.append(dst, haystack[start..]);
            try self.append(dst, "\n");
        }
        try self.colorReset(dst);
    }

    // -----------------------------------------------------------------------
    // Header.
    // -----------------------------------------------------------------------

    fn renderTime(self: *Self, dst: *std.ArrayList(u8), nanos: u64) !void {
        try self.append(dst, self.profile.time);
        try appendTime(self.allocator, dst, nanos, self.options.tz_offset_seconds);
        try self.colorReset(dst);
    }

    /// Returns true for PANIC (Rust `render_level`).
    fn renderLevel(self: *Self, dst: *std.ArrayList(u8), level: u8) !bool {
        var is_panic = false;
        switch (level) {
            10 => {
                try self.append(dst, " ");
                try self.append(dst, self.profile.trace);
                try self.append(dst, "TRACE");
                try self.colorReset(dst);
            },
            20 => {
                try self.append(dst, " ");
                try self.append(dst, self.profile.debug);
                try self.append(dst, "DEBUG");
                try self.colorReset(dst);
            },
            30 => {
                try self.append(dst, "  ");
                try self.append(dst, self.profile.info);
                try self.append(dst, "INFO");
                try self.colorReset(dst);
            },
            40 => {
                try self.append(dst, "  ");
                try self.append(dst, self.profile.warn);
                try self.append(dst, "WARN");
                try self.colorReset(dst);
            },
            50 => {
                try self.append(dst, " ");
                try self.append(dst, self.profile.err);
                try self.append(dst, "ERROR");
                try self.colorReset(dst);
            },
            60 => {
                is_panic = true;
                try self.append(dst, " ");
                try self.append(dst, self.profile.panic);
                try self.append(dst, "PANIC");
                try self.colorReset(dst);
            },
            else => {
                try self.append(dst, self.profile.levelu);
                if (level < 10) {
                    try self.append(dst, "   !");
                    try dst.append(self.allocator, '0' + level);
                } else if (level < 100) {
                    try self.append(dst, "  !");
                    try dst.append(self.allocator, '0' + level / 10);
                    try dst.append(self.allocator, '0' + level % 10);
                } else {
                    try self.append(dst, " !");
                    try dst.append(self.allocator, '0' + level / 100);
                    try dst.append(self.allocator, '0' + (level % 100) / 10);
                    try dst.append(self.allocator, '0' + level % 10);
                }
                try self.colorReset(dst);
            },
        }
        try self.append(dst, " ");
        return is_panic;
    }

    fn renderLocation(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        loc: ?viewer.Location,
    ) !void {
        const l = loc orelse return;
        try self.append(dst, self.profile.loc);
        try self.append(dst, "(");
        try self.append(dst, payload[l.off..][0..l.len]);
        try self.append(dst, ":");
        try appendUint(self.allocator, dst, l.line);
        try self.append(dst, ") ");
        try self.colorReset(dst);
    }

    fn renderMessage(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        rec: *const viewer.ParsedRecord,
    ) !void {
        try self.append(dst, self.profile.bold);
        try self.append(dst, payload[rec.msg_off..][0..rec.msg_len]);
        try self.append(dst, " ");
        try self.colorReset(dst);
    }

    // -----------------------------------------------------------------------
    // Colors.
    // -----------------------------------------------------------------------

    fn append(self: *Self, dst: *std.ArrayList(u8), bytes: []const u8) !void {
        try dst.appendSlice(self.allocator, bytes);
    }

    fn colorReset(self: *Self, dst: *std.ArrayList(u8)) !void {
        try self.append(dst, self.profile.reset);
        if (self.color_back) |back| try self.append(dst, back);
    }

    fn colorSetBackCtx(self: *Self, dst: *std.ArrayList(u8)) !void {
        self.color_back = self.profile.ctx;
        try self.append(dst, self.profile.ctx);
    }

    fn colorResetBack(self: *Self, dst: *std.ArrayList(u8)) !void {
        self.color_back = null;
        try self.append(dst, self.profile.reset);
    }

    // -----------------------------------------------------------------------
    // Tree.
    // -----------------------------------------------------------------------

    fn bitAt(depth: isize) u64 {
        return @as(u64, 1) << @intCast(depth);
    }

    fn pushPrefix(self: *Self, is_last: bool) void {
        if (is_last) {
            self.tree_prefix &= ~bitAt(self.tree_depth);
        } else {
            self.tree_prefix |= bitAt(self.tree_depth);
        }
        self.tree_depth += 1;
    }

    fn popPrefix(self: *Self) void {
        self.tree_depth -= 1;
        self.tree_prefix &= ~bitAt(self.tree_depth);
    }

    fn treePrefix(self: *Self, dst: *std.ArrayList(u8), last: bool) !void {
        try self.append(dst, self.profile.link);
        try self.appendPrefixBitmap(dst);
        try self.append(dst, if (last) TREE_ITEM_FIN else TREE_ITEM_INTR);
        try self.colorReset(dst);
    }

    /// Alignment half of a tree prefix: for each open level, `"│  "` when the
    /// level continues else `"   "`. Byte-identical to the Rust lookup table.
    fn appendPrefixBitmap(self: *Self, dst: *std.ArrayList(u8)) !void {
        const depth: usize = @intCast(self.tree_depth);
        var i: usize = 0;
        while (i < depth) : (i += 1) {
            const set = (self.tree_prefix >> @intCast(i)) & 1 != 0;
            try self.append(dst, if (set) PIPE else SPACER);
        }
    }

    fn renderTree(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        rec: *const viewer.ParsedRecord,
    ) !void {
        var st = TreeState{};

        try self.append(dst, "\n");
        for (rec.builder.ctrl.items) |node| {
            const is_last = node.is_last != 0;
            switch (node.kind) {
                .err_txt_fragment => {
                    if (!st.is_embed_error) try self.err_stack.append(self.allocator, .{
                        .len = node.key_len,
                        .off = node.key_off,
                    });
                    continue;
                },
                .err_embed_text => {
                    st.error_text_len = node.val_len;
                    st.error_text_off = node.val_off;
                    continue;
                },
                .err_loc => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.err_meta);
                    try self.append(dst, "@location: ");
                    try self.colorReset(dst);
                },
                .err_stage_new => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.err_stage);
                    try self.append(dst, "NEW: ");
                    try self.append(dst, payload[node.key_off..][0..node.key_len]);
                    try self.append(dst, "\n");
                    if (!st.is_embed_error) try self.err_stack.append(self.allocator, .{
                        .len = node.key_len,
                        .off = node.key_off,
                    });
                    st.error_depth += 1;
                    self.pushPrefix(false);
                    continue;
                },
                .err_stage_wrap => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.err_stage);
                    try self.append(dst, "WRAP: ");
                    try self.append(dst, payload[node.key_off..][0..node.key_len]);
                    if (!st.is_embed_error) try self.err_stack.append(self.allocator, .{
                        .len = node.key_len,
                        .off = node.key_off,
                    });
                    try self.append(dst, "\n");
                    self.pushPrefix(false);
                    st.error_depth += 1;
                    continue;
                },
                .err_stage_ctx => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.err_stage);
                    try self.append(dst, "CTX");
                    try self.append(dst, "\n");
                    self.pushPrefix(false);
                    st.error_depth += 1;
                    continue;
                },
                .group_end => {
                    self.popPrefix();
                    if (st.error_depth == 0) continue;
                    st.error_depth -= 1;
                    if (st.error_depth > 0) continue;
                    try self.treePrefix(dst, true);
                    self.popPrefix();
                    try self.append(dst, self.profile.err_key);
                    try self.append(dst, "@text: ");
                    try self.append(dst, self.profile.err);
                    if (st.is_embed_error) {
                        try self.append(dst, payload[st.error_text_off..][0..st.error_text_len]);
                    } else {
                        var i = self.err_stack.items.len;
                        var first = true;
                        while (i > 0) {
                            i -= 1;
                            if (!first) try self.append(dst, ": ");
                            first = false;
                            const x = self.err_stack.items[i];
                            try self.append(dst, payload[x.off..][0..x.len]);
                        }
                    }
                    try self.colorReset(dst);
                    try self.append(dst, "\n");
                    continue;
                },
                .err, .err_embed, .err_txt => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.err_key);
                    try self.append(dst, payload[node.key_off..][0..node.key_len]);
                    try self.append(dst, ": ");
                    try self.colorReset(dst);
                },
                else => {
                    try self.treePrefix(dst, is_last);
                    try self.append(dst, self.profile.key);
                    try self.append(dst, payload[node.key_off..][0..node.key_len]);
                    try self.append(dst, ": ");
                    try self.colorReset(dst);
                },
            }

            try self.renderTreeValue(dst, payload, node, &st);
        }
    }

    fn renderTreeValue(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        node: viewer.Node,
        st: *TreeState,
    ) !void {
        const val_len: usize = node.val_len;
        const val_off: usize = node.val_off;
        switch (node.kind) {
            .bool => {
                try self.append(dst, if (node.val_off != 0) "true" else "false");
                try self.append(dst, "\n");
            },
            .time => {
                try self.renderTime(dst, node.valAsU64());
                try self.append(dst, "\n");
            },
            .dur => {
                // Rust quirk: duration in tree mode appends no newline.
                try appendGoDuration(self.allocator, dst, node.valAsU64());
            },
            .int, .i64, .ivar => {
                try appendInt(self.allocator, dst, @bitCast(node.valAsU64()));
                try self.append(dst, "\n");
            },
            .i8, .i16, .i32 => {
                try appendInt(self.allocator, dst, @intCast(node.val_off));
                try self.append(dst, "\n");
            },
            .uint, .uvar, .u64 => {
                try appendUint(self.allocator, dst, node.valAsU64());
                try self.append(dst, "\n");
            },
            .u8, .u16, .u32 => {
                try appendUint(self.allocator, dst, node.val_off);
                try self.append(dst, "\n");
            },
            .f32 => {
                try appendFloat(self.allocator, dst, f64, @floatCast(@as(f32, @bitCast(node.val_off))));
                try self.append(dst, "\n");
            },
            .f64 => {
                try appendFloat(self.allocator, dst, f64, @bitCast(node.valAsU64()));
                try self.append(dst, "\n");
            },
            .str => {
                try self.append(dst, payload[val_off..][0..val_len]);
                try self.append(dst, "\n");
            },
            .bytes, .u8s => {
                try self.append(dst, "base64.");
                try appendBase64(self, dst, payload[val_off..][0..val_len]);
                try self.append(dst, "\n");
            },
            .err_txt => {
                try self.append(dst, self.profile.err);
                try self.append(dst, payload[val_off..][0..val_len]);
                try self.colorReset(dst);
                try self.append(dst, "\n");
            },
            .err_loc => {
                try self.append(dst, self.profile.loc);
                try self.append(dst, keyBytes(payload, node));
                try self.append(dst, ":");
                try appendUint(self.allocator, dst, node.val_off);
                try self.colorReset(dst);
                try self.append(dst, "\n");
            },
            .bools => try self.renderTreeSlice(dst, payload, node, bool),
            .ints, .i64s => try self.renderTreeSlice(dst, payload, node, i64),
            .i8s => try self.renderTreeSlice(dst, payload, node, i8),
            .i16s => try self.renderTreeSlice(dst, payload, node, i16),
            .i32s => try self.renderTreeSlice(dst, payload, node, i32),
            .uints, .u64s => try self.renderTreeSlice(dst, payload, node, u64),
            .u16s => try self.renderTreeSlice(dst, payload, node, u16),
            .u32s => try self.renderTreeSlice(dst, payload, node, u32),
            .f32s => try self.renderTreeSlice(dst, payload, node, f32),
            .f64s => try self.renderTreeSlice(dst, payload, node, f64),
            .strs => try self.renderTreeSlice(dst, payload, node, Str),
            .group => {
                if (groupIsEmpty(node)) {
                    try self.append(dst, "{}\n");
                } else {
                    try self.append(dst, "\n");
                }
                self.pushPrefix(node.is_last != 0);
            },
            .err, .err_embed => {
                st.is_embed_error = node.kind == .err_embed;
                st.error_depth += 1;
                try self.append(dst, "\n");
                self.pushPrefix(node.is_last != 0);
                try self.treePrefix(dst, false);
                try self.append(dst, self.profile.err_meta);
                try self.append(dst, "@context");
                try self.colorReset(dst);
                try self.append(dst, "\n");
                self.pushPrefix(false);
            },
            .err_stage_new, .err_stage_wrap, .err_stage_ctx, .group_end => {},
            .err_txt_fragment, .err_embed_text => {},
        }
    }

    /// A slice item marker: strings are length-prefixed raw bytes.
    const Str = struct {};

    fn renderTreeSlice(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        node: viewer.Node,
        comptime T: type,
    ) !void {
        const len: usize = node.val_len;
        var off: usize = node.val_off;
        if (len < self.options.expand_array_since) {
            // Intentionally a single colon here: the key branch already wrote
            // `": "` (Rust emits a doubled colon; this port does not).
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (i > 0) try self.append(dst, ", ");
                off = try self.appendTreeSliceItem(dst, payload, off, T);
            }
            try self.append(dst, "\n");
            return;
        }

        self.pushPrefix(node.is_last != 0);
        try self.append(dst, "\n");
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try self.treePrefix(dst, i == len - 1);
            try appendUint(self.allocator, dst, i);
            try self.append(dst, ": ");
            off = try self.appendTreeSliceItem(dst, payload, off, T);
            try self.append(dst, "\n");
        }
        self.tree_depth -= 1;
    }

    fn appendTreeSliceItem(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        off: usize,
        comptime T: type,
    ) !usize {
        if (T == Str) {
            const l = try viewer.readUvarint(payload, off);
            const start = off + l.size;
            try self.append(dst, payload[start..][0..@intCast(l.val)]);
            return start + @as(usize, @intCast(l.val));
        }
        if (T == bool) {
            try self.append(dst, if (payload[off] != 0) "true" else "false");
            return off + 1;
        }
        const n = @sizeOf(T);
        const raw = std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), payload[off..][0..n], .little);
        const v: T = @bitCast(raw);
        switch (T) {
            i8, i16, i32, i64 => try appendInt(self.allocator, dst, @intCast(v)),
            u8, u16, u32, u64 => try appendUint(self.allocator, dst, @intCast(v)),
            f32, f64 => try appendFloat(self.allocator, dst, T, v),
            else => unreachable,
        }
        return off + n;
    }

    // -----------------------------------------------------------------------
    // Compact JSON context.
    // -----------------------------------------------------------------------

    fn renderJsonContext(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        rec: *const viewer.ParsedRecord,
    ) !void {
        const nodes = rec.builder.ctrl.items;
        if (nodes.len == 0) {
            try self.append(dst, "{}\n");
            return;
        }

        try self.append(dst, "{");
        var old = false;
        var is_embed_err = false;
        var embed_err_len: usize = 0;
        var embed_err_off: usize = 0;
        var in_err_depth: isize = 0;

        for (nodes) |node| {
            const val_len: usize = node.val_len;
            const val_off: usize = node.val_off;

            switch (node.kind) {
                .err_embed_text => {
                    embed_err_len = node.val_len;
                    embed_err_off = node.val_off;
                },
                .err_txt_fragment => {
                    if (!is_embed_err) try self.err_stack.append(self.allocator, .{
                        .len = node.key_len,
                        .off = node.key_off,
                    });
                },
                .group_end => {
                    try self.append(dst, "}");
                    if (in_err_depth == 0) continue;
                    in_err_depth -= 1;
                    if (in_err_depth != 0) continue;
                    try self.append(dst, ", \"@text\": \"");
                    if (self.err_stack.items.len > 0) {
                        var i = self.err_stack.items.len;
                        var first = true;
                        while (i > 0) {
                            i -= 1;
                            if (!first) try self.append(dst, ": ");
                            first = false;
                            const x = self.err_stack.items[i];
                            try self.escapeContent(dst, payload[x.off..][0..x.len]);
                        }
                        self.err_stack.clearRetainingCapacity();
                    } else {
                        try self.escapeContent(dst, payload[embed_err_off..][0..embed_err_len]);
                    }
                    try self.append(dst, "\"}");
                    old = true;
                    continue;
                },
                else => {
                    if (old) try self.append(dst, ", ");
                    old = true;
                    switch (node.kind) {
                        .err_stage_new => {
                            try self.renderJsonKeyWithPrefix(dst, "NEW: ", keyBytes(payload, node));
                            in_err_depth += 1;
                        },
                        .err_stage_wrap => {
                            try self.renderJsonKeyWithPrefix(dst, "WRAP: ", keyBytes(payload, node));
                            in_err_depth += 1;
                        },
                        .err_stage_ctx => {
                            try self.renderJsonKey(dst, "CTX");
                            in_err_depth += 1;
                        },
                        else => try self.renderJsonKey(dst, keyBytes(payload, node)),
                    }
                    try self.append(dst, ": ");
                },
            }

            switch (node.kind) {
                .bool => try self.append(dst, if (node.val_off != 0) "true" else "false"),
                .time => {
                    try self.append(dst, "\"");
                    try self.renderTime(dst, node.valAsU64());
                    try self.append(dst, "\"");
                },
                .dur => {
                    try self.append(dst, "\"");
                    try appendGoDuration(self.allocator, dst, node.valAsU64());
                    try self.append(dst, "\"");
                },
                .int, .i64, .ivar => try appendInt(self.allocator, dst, @bitCast(node.valAsU64())),
                .i8, .i16, .i32 => try appendInt(self.allocator, dst, @intCast(node.val_off)),
                .uint, .uvar, .u64 => try appendUint(self.allocator, dst, node.valAsU64()),
                .u8, .u16, .u32 => try appendUint(self.allocator, dst, node.val_off),
                .f32 => try appendFloat(self.allocator, dst, f64, @floatCast(@as(f32, @bitCast(node.val_off)))),
                .f64 => try appendFloat(self.allocator, dst, f64, @bitCast(node.valAsU64())),
                .str => try self.escapeString(dst, payload[val_off..][0..val_len]),
                .bytes, .u8s => {
                    try self.append(dst, "\"");
                    try appendBase64(self, dst, payload[val_off..][0..val_len]);
                    try self.append(dst, "\"");
                },
                .err_txt => try self.escapeString(dst, payload[val_off..][0..val_len]),
                .err_loc => {
                    try self.append(dst, "\"");
                    try self.append(dst, keyBytes(payload, node));
                    try self.append(dst, ":");
                    try appendUint(self.allocator, dst, node.val_off);
                    try self.append(dst, "\"");
                },
                .bools => try self.renderJsonSlice(dst, payload, node, bool),
                .ints, .i64s => try self.renderJsonSlice(dst, payload, node, i64),
                .i8s => try self.renderJsonSlice(dst, payload, node, i8),
                .i16s => try self.renderJsonSlice(dst, payload, node, i16),
                .i32s => try self.renderJsonSlice(dst, payload, node, i32),
                .uints, .u64s => try self.renderJsonSlice(dst, payload, node, u64),
                .u16s => try self.renderJsonSlice(dst, payload, node, u16),
                .u32s => try self.renderJsonSlice(dst, payload, node, u32),
                .f32s => try self.renderJsonSlice(dst, payload, node, f32),
                .f64s => try self.renderJsonSlice(dst, payload, node, f64),
                .strs => try self.renderJsonSlice(dst, payload, node, Str),
                .group => {
                    try self.append(dst, "{");
                    old = false;
                },
                .err => {
                    is_embed_err = false;
                    in_err_depth += 1;
                    self.err_stack.clearRetainingCapacity();
                    try self.append(dst, "{\"@context\": {");
                    old = false;
                },
                .err_embed => {
                    is_embed_err = true;
                    in_err_depth += 1;
                    self.err_stack.clearRetainingCapacity();
                    try self.append(dst, "{\"@context\": {");
                    old = false;
                },
                .err_stage_new, .err_stage_wrap, .err_stage_ctx => {
                    try self.append(dst, "{");
                    old = false;
                    if (node.kind != .err_stage_ctx) try self.err_stack.append(self.allocator, .{
                        .len = node.key_len,
                        .off = node.key_off,
                    });
                },
                .err_txt_fragment, .err_embed_text, .group_end => {},
            }
        }
        try self.append(dst, "}\n");
    }

    fn renderJsonSlice(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        node: viewer.Node,
        comptime T: type,
    ) !void {
        const len: usize = node.val_len;
        var off: usize = node.val_off;
        try self.append(dst, "[");
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try self.append(dst, ", ");
            off = try self.appendJsonSliceItem(dst, payload, off, T);
        }
        try self.append(dst, "]");
    }

    fn appendJsonSliceItem(
        self: *Self,
        dst: *std.ArrayList(u8),
        payload: []const u8,
        off: usize,
        comptime T: type,
    ) !usize {
        if (T == Str) {
            const l = try viewer.readUvarint(payload, off);
            const start = off + l.size;
            try self.escapeString(dst, payload[start..][0..@intCast(l.val)]);
            return start + @as(usize, @intCast(l.val));
        }
        if (T == bool) {
            try self.append(dst, if (payload[off] != 0) "true" else "false");
            return off + 1;
        }
        const n = @sizeOf(T);
        const raw = std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), payload[off..][0..n], .little);
        const v: T = @bitCast(raw);
        switch (T) {
            i8, i16, i32, i64 => try appendInt(self.allocator, dst, @intCast(v)),
            u8, u16, u32, u64 => try appendUint(self.allocator, dst, @intCast(v)),
            f32, f64 => try appendFloat(self.allocator, dst, T, v),
            else => unreachable,
        }
        return off + n;
    }

    // -----------------------------------------------------------------------
    // Small helpers.
    // -----------------------------------------------------------------------

    fn escapeString(self: *Self, dst: *std.ArrayList(u8), src: []const u8) !void {
        try self.escapeInto(dst, src, true);
    }

    /// Writes a compact-JSON key (`"key"`, quotes included) in the same color
    /// the tree uses for keys.
    fn renderJsonKey(self: *Self, dst: *std.ArrayList(u8), key: []const u8) !void {
        try self.append(dst, self.profile.key);
        try self.escapeString(dst, key);
        try self.colorReset(dst);
    }

    /// Like `renderJsonKey`, but for the synthetic error-stage keys whose
    /// prefix (`NEW: ` / `WRAP: `) is part of the quoted key.
    fn renderJsonKeyWithPrefix(
        self: *Self,
        dst: *std.ArrayList(u8),
        prefix: []const u8,
        key: []const u8,
    ) !void {
        try self.append(dst, self.profile.key);
        try self.append(dst, "\"");
        try self.append(dst, prefix);
        try self.escapeContent(dst, key);
        try self.append(dst, "\"");
        try self.colorReset(dst);
    }

    fn escapeContent(self: *Self, dst: *std.ArrayList(u8), src: []const u8) !void {
        try self.escapeInto(dst, src, false);
    }

    /// Escapes `src` with the SIMD JSON escaper into a reserved chunk of `dst`.
    /// `jsonescape` requires `6 * src.len + 64` writable bytes and returns a
    /// cursor past the written bytes; the list length is advanced to match.
    fn escapeInto(self: *Self, dst: *std.ArrayList(u8), src: []const u8, quoted: bool) !void {
        var slack: [512]u8 = undefined;
        if (src.len <= (slack.len - 64) / 6) return self.escapeIntoBuf(dst, src, quoted, &slack);
        const buf = try self.allocator.alloc(u8, try escapeCapacity(src.len));
        defer self.allocator.free(buf);
        return self.escapeIntoBuf(dst, src, quoted, buf);
    }

    fn escapeIntoBuf(
        self: *Self,
        dst: *std.ArrayList(u8),
        src: []const u8,
        quoted: bool,
        buf: []u8,
    ) !void {
        const end = if (quoted)
            jsonescape.escapeInto(buf.ptr, src)
        else
            jsonescape.escapeIntoUnquote(buf.ptr, src);
        try dst.appendSlice(self.allocator, buf[0 .. @intFromPtr(end) - @intFromPtr(buf.ptr)]);
    }
};

fn keyBytes(payload: []const u8, node: viewer.Node) []const u8 {
    if (node.kind == .err_loc) return "@location";
    return payload[node.key_off..][0..node.key_len];
}

/// Required scratch capacity for `jsonescape`'s escape kernels: the logical
/// worst case `6 * len + 2` plus 64 bytes of slack for full-width vector stores.
fn escapeCapacity(src_len: usize) !usize {
    return std.math.add(usize, try std.math.mul(usize, src_len, 6), 64);
}

fn groupIsEmpty(node: viewer.Node) bool {
    if (node.kind == .err_embed) return node.val_len -% 2 == 0;
    return node.val_len -% 1 == 0;
}

fn appendInt(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), v: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try dst.appendSlice(allocator, s);
}

fn appendUint(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), v: u64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try dst.appendSlice(allocator, s);
}

fn appendFloat(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [64]u8 = undefined;
    try dst.appendSlice(allocator, ryuFormat(&buf, T, v));
}

/// Shortest round-trip float formatting matching Rust `ryu::Buffer::format`,
/// including its `.0` suffix on integral values and `NaN`/`inf` spellings.
fn ryuFormat(buf: []u8, comptime T: type, value: T) []const u8 {
    if (std.math.isNan(value)) return "NaN";
    const neg = std.math.signbit(value);
    if (value == 0) return if (neg) "-0.0" else "0.0";
    if (std.math.isInf(value)) return if (neg) "-inf" else "inf";

    const bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
    const d = std.fmt.float.binaryToDecimal(
        u64,
        @as(u64, bits),
        std.math.floatMantissaBits(T),
        std.math.floatExponentBits(T),
        std.math.floatMantissaBits(T) - std.math.floatFractionalBits(T) != 0,
        &std.fmt.float.Backend64_TablesFull,
    );

    var digits_buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{d.mantissa}) catch unreachable;
    const length: isize = @intCast(digits.len);
    const kk: isize = length + d.exponent;

    const max_int_kk: isize = if (@bitSizeOf(T) == 32) 13 else 16;
    const frac_min: isize = if (@bitSizeOf(T) == 32) -5 else -4;

    var out: usize = 0;
    if (d.sign) {
        buf[out] = '-';
        out += 1;
    }

    if (d.exponent >= 0 and kk <= max_int_kk) {
        @memcpy(buf[out..][0..digits.len], digits);
        out += digits.len;
        var i = length;
        while (i < kk) : (i += 1) {
            buf[out] = '0';
            out += 1;
        }
        buf[out] = '.';
        out += 1;
        buf[out] = '0';
        out += 1;
    } else if (kk > 0 and kk <= max_int_kk) {
        const split: usize = @intCast(kk);
        @memcpy(buf[out..][0..split], digits[0..split]);
        out += split;
        buf[out] = '.';
        out += 1;
        @memcpy(buf[out..][0 .. digits.len - split], digits[split..]);
        out += digits.len - split;
    } else if (kk >= frac_min and kk <= 0) {
        buf[out] = '0';
        out += 1;
        buf[out] = '.';
        out += 1;
        var i: isize = 0;
        while (i < -kk) : (i += 1) {
            buf[out] = '0';
            out += 1;
        }
        @memcpy(buf[out..][0..digits.len], digits);
        out += digits.len;
    } else if (length == 1) {
        @memcpy(buf[out..][0..digits.len], digits);
        out += digits.len;
        buf[out] = 'e';
        out += 1;
        writeExponent(buf, &out, kk - 1);
    } else {
        buf[out] = digits[0];
        out += 1;
        buf[out] = '.';
        out += 1;
        @memcpy(buf[out..][0 .. digits.len - 1], digits[1..]);
        out += digits.len - 1;
        buf[out] = 'e';
        out += 1;
        writeExponent(buf, &out, kk - 1);
    }
    return buf[0..out];
}

fn writeExponent(buf: []u8, out: *usize, e: i64) void {
    var v = e;
    if (v < 0) {
        buf[out.*] = '-';
        out.* += 1;
        v = -v;
    }
    var tmp: [8]u8 = undefined;
    var n: usize = 0;
    var u: u64 = @intCast(v);
    if (u == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        while (u > 0) : (u /= 10) {
            tmp[n] = '0' + @as(u8, @intCast(u % 10));
            n += 1;
        }
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        buf[out.*] = tmp[i];
        out.* += 1;
    }
}

/// Go-style duration rendering.
fn appendGoDuration(allocator: std.mem.Allocator, dst: *std.ArrayList(u8), nanos: u64) !void {
    if (nanos == 0) {
        try dst.appendSlice(allocator, "0s");
        return;
    }
    if (nanos < 1_000) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}ns", .{nanos}) catch unreachable;
        try dst.appendSlice(allocator, s);
        return;
    }
    if (nanos < 1_000_000) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\u{B5}s", .{nanos / 1_000}) catch unreachable;
        try dst.appendSlice(allocator, s);
        return;
    }
    if (nanos < 1_000_000_000) {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}ms", .{nanos / 1_000_000}) catch unreachable;
        try dst.appendSlice(allocator, s);
        return;
    }

    var seconds = nanos / 1_000_000_000;
    const n = nanos % 1_000_000_000;
    const hours = seconds / 3600;
    seconds %= 3600;
    const minutes = seconds / 60;
    seconds %= 60;

    var buf: [64]u8 = undefined;
    if (hours > 0) {
        const s = std.fmt.bufPrint(&buf, "{d}h", .{hours}) catch unreachable;
        try dst.appendSlice(allocator, s);
    }
    if (minutes > 0) {
        const s = std.fmt.bufPrint(&buf, "{d}m", .{minutes}) catch unreachable;
        try dst.appendSlice(allocator, s);
    }
    if (seconds > 0 or n > 0) {
        if (n == 0) {
            const s = std.fmt.bufPrint(&buf, "{d}s", .{seconds}) catch unreachable;
            try dst.appendSlice(allocator, s);
        } else {
            var frac_buf: [16]u8 = undefined;
            const frac_full = std.fmt.bufPrint(&frac_buf, "{d}", .{1_000_000_000 + n}) catch unreachable;
            const fraction = frac_full[1..];
            var end: usize = 9;
            while (end > 0 and fraction[end - 1] == '0') end -= 1;
            const head = std.fmt.bufPrint(&buf, "{d}.", .{seconds}) catch unreachable;
            try dst.appendSlice(allocator, head);
            try dst.appendSlice(allocator, fraction[0..end]);
            try dst.appendSlice(allocator, "s");
        }
    }
}

/// `2006-01-02 15:04:05.000`.
/// Zig has no portable TZ database, so the caller supplies a fixed offset.
fn appendTime(
    allocator: std.mem.Allocator,
    dst: *std.ArrayList(u8),
    nanos: u64,
    offset_seconds: i64,
) !void {
    const t: i64 = @bitCast(nanos);
    const utc_secs = @divTrunc(t, std.time.ns_per_s);
    const nsecs = @rem(t, std.time.ns_per_s);
    const secs = utc_secs + offset_seconds;
    if (nsecs < 0 or secs < 0 or secs > MAX_SECS) {
        try dst.appendSlice(allocator, TIME_FALLBACK);
        return;
    }

    const millis: u64 = @intCast(@divTrunc(nsecs, std.time.ns_per_ms));
    const epoch_now = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day_seconds = epoch_now.getDaySeconds();
    const year_day = epoch_now.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var buf: [64]u8 = undefined;
    var out: usize = 0;
    const year = std.fmt.bufPrint(buf[out..], "{d}", .{year_day.year}) catch unreachable;
    out += year.len;
    buf[out] = '-';
    out += 1;
    try appendPad(dst, &buf, &out, 2, month_day.month.numeric());
    buf[out] = '-';
    out += 1;
    try appendPad(dst, &buf, &out, 2, @as(u32, month_day.day_index) + 1);
    buf[out] = ' ';
    out += 1;
    try appendPad(dst, &buf, &out, 2, day_seconds.getHoursIntoDay());
    buf[out] = ':';
    out += 1;
    try appendPad(dst, &buf, &out, 2, day_seconds.getMinutesIntoHour());
    buf[out] = ':';
    out += 1;
    try appendPad(dst, &buf, &out, 2, day_seconds.getSecondsIntoMinute());
    buf[out] = '.';
    out += 1;
    try appendPad(dst, &buf, &out, 3, millis);
    try dst.appendSlice(allocator, buf[0..out]);
}

fn appendPad(dst: *std.ArrayList(u8), buf: []u8, out: *usize, width: usize, value: u64) !void {
    _ = dst;
    const s = std.fmt.bufPrint(buf[out.*..], "{d:0>[1]}", .{ value, width }) catch unreachable;
    out.* += s.len;
}

fn appendBase64(self: *Renderer, dst: *std.ArrayList(u8), src: []const u8) !void {
    if (src.len == 0) return;
    const size = std.base64.standard.Encoder.calcSize(src.len);
    const tmp = try self.allocator.alloc(u8, size);
    defer self.allocator.free(tmp);
    const encoded = std.base64.standard.Encoder.encode(tmp, src);
    try self.append(dst, encoded);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

const consts = @import("consts.zig");
const testing = std.testing;

fn renderInto(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    payload: []const u8,
    options: RenderOptions,
) !void {
    var rec = viewer.ParsedRecord{};
    defer rec.deinit(a);
    try viewer.parseRecord(a, payload, &rec);
    var r = Renderer.init(a, .plain);
    r.options = options;
    defer r.deinit();
    try r.render(out, payload, &rec);
}

/// gzip-compress `plain` into a freshly allocated slice, mirroring the Go
/// logger's panic message (the Rust fixture `panic.bin` carries the same).
fn gzipAlloc(a: std.mem.Allocator, plain: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(a, plain.len + 64);
    defer aw.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var cmp: flate.Compress = try .init(&aw.writer, &window, .gzip, .fastest);
    try cmp.writer.writeAll(plain);
    try cmp.finish();
    return aw.toOwnedSlice();
}

test "tree prefix bitmap" {
    const Sample = struct { stack: []const bool, want: []const u8 };
    const samples = [_]Sample{
        .{ .stack = &.{}, .want = "" },
        .{ .stack = &.{true}, .want = "\u{2502}  " },
        .{ .stack = &.{false}, .want = "   " },
        .{ .stack = &.{ true, true, false }, .want = "\u{2502}  \u{2502}     " },
        .{ .stack = &.{ false, true, true }, .want = "   \u{2502}  \u{2502}  " },
        .{ .stack = &.{ true, false, false, false, false, false, false, false, false }, .want = "\u{2502}                          " },
        .{ .stack = &.{ true, true }, .want = "\u{2502}  \u{2502}  " },
    };

    const a = testing.allocator;
    for (samples) |s| {
        var bitmap: u64 = 0;
        for (s.stack, 0..) |b, i| {
            if (b) bitmap |= @as(u64, 1) << @intCast(i);
        }
        var r = Renderer.init(a, .plain);
        defer r.deinit();
        r.tree_prefix = bitmap;
        r.tree_depth = @intCast(s.stack.len);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try r.appendPrefixBitmap(&out);
        try testing.expectEqualStrings(s.want, out.items);
    }
}

test "float formatting matches ryu" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3.141592653589793", ryuFormat(&buf, f64, 3.141592653589793));
    try testing.expectEqualStrings("2.718281828459045", ryuFormat(&buf, f64, 2.718281828459045));
    try testing.expectEqualStrings("5e-324", ryuFormat(&buf, f64, 5e-324));
    try testing.expectEqualStrings("1e-45", ryuFormat(&buf, f64, 1e-45));
    try testing.expectEqualStrings("0.5", ryuFormat(&buf, f64, 0.5));
    try testing.expectEqualStrings("0.75", ryuFormat(&buf, f64, 0.75));
    try testing.expectEqualStrings("NaN", ryuFormat(&buf, f64, std.math.nan(f64)));
    try testing.expectEqualStrings("1e-45", ryuFormat(&buf, f32, @as(f32, 1e-45)));
}

test "duration formatting" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendGoDuration(a, &out, 1_234_567_890_101_121);
    try testing.expectEqualStrings("342h56m7.890101121s", out.items);
}

test "time formatting with fixed offset" {
    const a = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendTime(a, &out, 1_773_974_798_041_168_000, 3 * 3600);
    try testing.expectEqualStrings("2026-03-20 05:46:38.041", out.items);
}

test "compact json context: message only" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "just a message");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings("1970-01-01 00:00:00.000  INFO just a message {}\n", out.items);
}

test "compact json context: three flat keys" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "a message with the short flat context");
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.strField(a, "string", "Hello World!");
    try pb.key(a, .float64, "pi");
    try pb.le(a, u64, @bitCast(@as(f64, 3.141592653589793)));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO a message with the short flat context " ++
            "{\"int\": 4, \"string\": \"Hello World!\", \"pi\": 3.141592653589793}\n",
        out.items,
    );
}

test "fourth key switches compact json to tree" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");
    try pb.key(a, .int64, "a");
    try pb.le(a, u64, 1);
    try pb.key(a, .int64, "b");
    try pb.le(a, u64, 2);
    try pb.key(a, .int64, "c");
    try pb.le(a, u64, 3);
    try pb.key(a, .int64, "d");
    try pb.le(a, u64, 4);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO m \n" ++
            "\u{251C}\u{2500} a: 1\n" ++
            "\u{251C}\u{2500} b: 2\n" ++
            "\u{251C}\u{2500} c: 3\n" ++
            "\u{2514}\u{2500} d: 4\n",
        out.items,
    );
}

test "tree golden: slices" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "a message with loads of slices");

    try pb.key(a, .sliceBool, "bool");
    try pb.uvarint(a, 6);
    for ([_]u8{ 1, 0, 1, 1, 1, 0 }) |v| try pb.byte(a, v);

    try pb.key(a, .sliceInt64, "int64");
    try pb.uvarint(a, 3);
    for ([_]i64{ -9223372036854775808, -1, 9223372036854775807 }) |v| {
        try pb.le(a, u64, @bitCast(v));
    }

    try pb.key(a, .sliceUint64, "uint64");
    try pb.uvarint(a, 3);
    for ([_]u64{ 0, 1, 18446744073709551615 }) |v| try pb.le(a, u64, v);

    try pb.key(a, .sliceFloat32, "float32");
    try pb.uvarint(a, 3);
    for ([_]f32{ 0.5, 0.75, 1e-45 }) |v| try pb.le(a, u32, @bitCast(v));

    try pb.key(a, .sliceFloat64, "float64");
    try pb.uvarint(a, 4);
    for ([_]f64{ 3.141592653589793, 2.718281828459045, 5e-324, std.math.nan(f64) }) |v| {
        try pb.le(a, u64, @bitCast(v));
    }

    try pb.key(a, .sliceString, "string");
    try pb.uvarint(a, 3);
    for ([_][]const u8{ "Hello World!", "Hello Galaxy!", "Hello Universe!" }) |s| {
        try pb.uvarint(a, s.len);
        try pb.raw(a, s);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO a message with loads of slices \n" ++
            "\u{251C}\u{2500} bool: true, false, true, true, true, false\n" ++
            "\u{251C}\u{2500} int64: -9223372036854775808, -1, 9223372036854775807\n" ++
            "\u{251C}\u{2500} uint64: 0, 1, 18446744073709551615\n" ++
            "\u{251C}\u{2500} float32: 0.5, 0.75, 1e-45\n" ++
            "\u{251C}\u{2500} float64: 3.141592653589793, 2.718281828459045, 5e-324, NaN\n" ++
            "\u{2514}\u{2500} string: Hello World!, Hello Galaxy!, Hello Universe!\n",
        out.items,
    );
}

test "tree golden: empty and nested groups" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "a message and a group");

    try pb.key(a, .nodeGroup, "empty");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    try pb.key(a, .nodeGroup, "group");
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.strField(a, "string", "Hello World!");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    try pb.key(a, .nodeGroup, "outer");
    try pb.key(a, .nodeGroup, "inner");
    try pb.key(a, .int64, "int1");
    try pb.le(a, u64, @bitCast(@as(i64, 5)));
    try pb.strField(a, "string1", "I'm here");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.key(a, .int64, "int");
    try pb.le(a, u64, @bitCast(@as(i64, 4)));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO a message and a group \n" ++
            "\u{251C}\u{2500} empty: {}\n" ++
            "\u{251C}\u{2500} group: \n" ++
            "\u{2502}  \u{251C}\u{2500} int: 4\n" ++
            "\u{2502}  \u{2514}\u{2500} string: Hello World!\n" ++
            "\u{2514}\u{2500} outer: \n" ++
            "   \u{251C}\u{2500} inner: \n" ++
            "   \u{2502}  \u{251C}\u{2500} int1: 5\n" ++
            "   \u{2502}  \u{2514}\u{2500} string1: I'm here\n" ++
            "   \u{2514}\u{2500} int: 4\n",
        out.items,
    );
}

test "compact json context: bytes are base64" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "a message with bytes field");
    try pb.key(a, .sliceUint8, "data");
    try pb.uvarint(a, 3);
    try pb.raw(a, &[_]u8{ 1, 2, 3 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO a message with bytes field {\"data\": \"AQID\"}\n",
        out.items,
    );
}

test "tree context: bytes are base64" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "a message with bytes field");
    try pb.key(a, .sliceUint8, "data");
    try pb.uvarint(a, 3);
    try pb.raw(a, &[_]u8{ 1, 2, 3 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    // Force the tree form so the bytes value is rendered as an attribute.
    try renderInto(a, &out, pb.list.items, .{ .expand_context_since = 1 });
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO a message with bytes field \n" ++
            "\u{2514}\u{2500} data: base64.AQID\n",
        out.items,
    );
}

test "json escaping matches the Rust dialect" {
    const a = testing.allocator;
    var r = Renderer.init(a, .plain);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try r.escapeString(&out, "a\tb\n\"c\"\\\x01");
    try testing.expectEqualStrings("\"a\\tb\\n\\\"c\\\"\\\\\\u0001\"", out.items);
}

test "json escape delegates to the jsonescape module" {
    const a = testing.allocator;
    const samples = [_][]const u8{
        "",
        "nothing to escape",
        "quote\" backslash\\ \x01\x7f\t\n\r\x08\x0c",
        "unicode \u{1F600} \u{0416}",
        "long " ** 200,
    };

    var r = Renderer.init(a, .plain);
    defer r.deinit();

    for (samples) |s| {
        const want_quoted = try jsonescape.escape(a, s);
        defer a.free(want_quoted);
        const want_raw = try jsonescape.escapeUnquote(a, s);
        defer a.free(want_raw);

        var quoted: std.ArrayList(u8) = .empty;
        defer quoted.deinit(a);
        try r.escapeString(&quoted, s);
        try testing.expectEqualSlices(u8, want_quoted, quoted.items);

        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(a);
        try r.escapeContent(&raw, s);
        try testing.expectEqualSlices(u8, want_raw, raw.items);
    }
}

test "compact json keys are colored like tree keys" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.info));
    try pb.msg(a, "m");
    try pb.strField(a, "k", "v");

    var rec = viewer.ParsedRecord{};
    defer rec.deinit(a);
    try viewer.parseRecord(a, pb.list.items, &rec);

    var r = Renderer.init(a, .dark);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try r.render(&out, pb.list.items, &rec);

    // The dark key color wraps the quoted key, quotes included.
    const p = ColorProfile.dark;
    try testing.expectEqualStrings(
        p.time ++ "1970-01-01 00:00:00.000" ++ p.reset ++
            "  " ++ p.info ++ "INFO" ++ p.reset ++ " " ++
            p.bold ++ "m " ++ p.reset ++
            p.ctx ++ "{" ++
            p.key ++ "\"k\"" ++ p.reset ++ p.ctx ++
            ": \"v\"}\n" ++ p.reset,
        out.items,
    );
}

test "compact json error stage keys are colored like tree keys" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    try pb.key(a, .nodeError, "boom");
    try pb.key(a, .nodeNew, "wrapped");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var rec = viewer.ParsedRecord{};
    defer rec.deinit(a);
    try viewer.parseRecord(a, pb.list.items, &rec);

    var r = Renderer.init(a, .dark);
    defer r.deinit();
    r.options.max_tree_depth = 0; // force the compact-JSON context
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try r.render(&out, pb.list.items, &rec);

    const p = ColorProfile.dark;
    try testing.expectEqualStrings(
        p.time ++ "1970-01-01 00:00:00.000" ++ p.reset ++
            " " ++ p.err ++ "ERROR" ++ p.reset ++ " " ++
            p.bold ++ "errors " ++ p.reset ++
            p.ctx ++ "{" ++
            p.key ++ "\"boom\"" ++ p.reset ++ p.ctx ++
            ": {\"@context\": {" ++
            p.key ++ "\"NEW: wrapped\"" ++ p.reset ++ p.ctx ++
            ": {}}, \"@text\": \"wrapped\"}}\n" ++ p.reset,
        out.items,
    );
}

test "tree context: error bookkeeping" {
    const a = testing.allocator;
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000 ERROR errors \n" ++
            "\u{2514}\u{2500} err-beer: \n" ++
            "   \u{251C}\u{2500} @context\n" ++
            "   \u{2502}  \u{2514}\u{2500} NEW: error\n" ++
            "   \u{2502}  \u{2502}  \u{251C}\u{2500} @location: @location:331\n" ++
            "   \u{2502}  \u{2502}  \u{2514}\u{2500} new-string: Hello World!\n" ++
            "   \u{2514}\u{2500} @text: error\n",
        out.items,
    );
}

test "compact json context: inline error form" {
    const a = testing.allocator;
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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    // A depth budget of 0 forces the compact-JSON path even with errors.
    try renderInto(a, &out, pb.list.items, .{ .max_tree_depth = 0 });
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000 ERROR errors " ++
            "{\"err-beer\": {\"@context\": {\"NEW: error\": " ++
            "{\"@location\": \"@location:331\", \"new-string\": \"Hello World!\"}}, " ++
            "\"@text\": \"error\"}}\n",
        out.items,
    );
}

test "compact json context: slices" {
    const a = testing.allocator;
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
    for ([_]i64{ -1, 0, 1 }) |v| try pb.le(a, u64, @bitCast(v));

    try pb.key(a, .sliceString, "strs");
    try pb.uvarint(a, 2);
    try pb.uvarint(a, 1);
    try pb.raw(a, "a");
    try pb.uvarint(a, 3);
    try pb.raw(a, "b\"c");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO slices " ++
            "{\"bools\": [true, false], \"ints\": [-1, 0, 1], \"strs\": [\"a\", \"b\\\"c\"]}\n",
        out.items,
    );
}

test "location value always renders the @location label" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    try pb.key(a, .nodeError, "boom");
    try pb.key(a, .nodeNew, "error");
    try pb.key(a, .nodeLocation, "/tmp/foo.go");
    try pb.uvarint(a, 42);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    // Rust `Node::key_as_slice` returns `@location` for error locations, so the
    // parsed file name never reaches the output.
    var tree: std.ArrayList(u8) = .empty;
    defer tree.deinit(a);
    try renderInto(a, &tree, pb.list.items, .{});
    try testing.expect(std.mem.indexOf(u8, tree.items, "@location: @location:42\n") != null);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try renderInto(a, &json, pb.list.items, .{ .max_tree_depth = 0 });
    try testing.expect(std.mem.indexOf(u8, json.items, "\"@location\": \"@location:42\"") != null);
}

test "location header renders as (file:line) in both context forms" {
    const a = testing.allocator;

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.headerLoc(a, 0, @intFromEnum(consts.logLevel.warning), "/tmp/app.go", 99);
    try pb.msg(a, "m");
    try pb.key(a, .nodeGroup, "g");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{});
    try testing.expectEqualStrings(
        "1970-01-01 00:00:00.000  WARN (/tmp/app.go:99) m \n" ++
            "\u{2514}\u{2500} g: {}\n",
        out.items,
    );

    var pb2 = viewer.PB{};
    defer pb2.deinit(a);
    try pb2.headerLoc(a, 0, @intFromEnum(consts.logLevel.warning), "/tmp/app.go", 99);
    try pb2.msg(a, "m");

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try renderInto(a, &json, pb2.list.items, .{});
    try testing.expectEqualStrings("1970-01-01 00:00:00.000  WARN (/tmp/app.go:99) m {}\n", json.items);
}

pub const ERRORS_TIME: u64 = 1_776_880_099_371_299_000;
pub const ERRORS_TZ: i64 = 3 * 3600;
pub const ERRORS_FILE = "/home/emacs/Sources/mine/blog/internal/alchemy/alchemy_test.go";

/// New-wire-format port of `blog-rs/src/testdata/errors.bin`, the reference
/// error/location fixture (the Rust bytes use the drifted `ValueKind`
/// numbering). Covers `errorRaw`, nested `nodeError` stages with locations,
/// a foreign-error-text child and an `nodeErrorEmbed`.
pub fn buildErrorsFixture(a: std.mem.Allocator, pb: *viewer.PB) !void {
    try pb.header(a, ERRORS_TIME, @intFromEnum(consts.logLevel.err));
    try pb.msg(a, "errors");

    try pb.key(a, .errorRaw, "err-foreign");
    try pb.uvarint(a, "EOF".len);
    try pb.raw(a, "EOF");

    try pb.key(a, .nodeError, "err-beer");
    try pb.key(a, .nodeNew, "error");
    try pb.key(a, .nodeLocation, ERRORS_FILE);
    try pb.uvarint(a, 331);
    try pb.strField(a, "new-string", "Hello World!");
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.key(a, .nodeWrap, "wrap");
    try pb.key(a, .nodeLocation, ERRORS_FILE);
    try pb.uvarint(a, 332);
    try pb.key(a, .int64, "wrap-int");
    try pb.le(a, u64, 1);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeContext));
    try pb.key(a, .nodeLocation, ERRORS_FILE);
    try pb.uvarint(a, 333);
    try pb.key(a, .float64, "just-pi");
    try pb.le(a, u64, @bitCast(@as(f64, 3.141592653589793)));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    try pb.key(a, .nodeError, "err-foreign-root");
    try pb.key(a, .nodeForeignErrorText, "EOF");
    try pb.key(a, .nodeWrap, "wrap foreign");
    try pb.key(a, .nodeLocation, ERRORS_FILE);
    try pb.uvarint(a, 335);
    try pb.key(a, .bool, "wrap-bool");
    try pb.byte(a, 1);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));

    try pb.key(a, .nodeErrorEmbed, "err-intermixed");
    const embed = "foreign wrap: error";
    try pb.uvarint(a, embed.len);
    try pb.raw(a, embed);
    try pb.key(a, .nodeNew, "error");
    try pb.key(a, .nodeLocation, ERRORS_FILE);
    try pb.uvarint(a, 337);
    try pb.key(a, .time, "new-time");
    try pb.le(a, u64, ERRORS_TIME);
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
    try pb.byte(a, @intFromEnum(consts.ValueKind.nodeGroupEnd));
}

/// New-wire-format port of `blog-rs/src/testdata/panic.bin`: a PANIC record
/// whose message is a gzip stacktrace and whose context is a single flat key.
pub fn buildPanicFixture(a: std.mem.Allocator, pb: *viewer.PB) !void {
    const gz = try gzipAlloc(a, PANIC_STACK);
    defer a.free(gz);
    try pb.header(a, PANIC_TIME, @intFromEnum(consts.logLevel.panic));
    try pb.msg(a, gz);
    try pb.strField(a, "recovered", "this is a panic");
}

test "tree golden: full error and location record" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try buildErrorsFixture(a, &pb);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{ .tz_offset_seconds = ERRORS_TZ });
    try testing.expectEqualStrings(
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
        out.items,
    );
}

test "compact json golden: full error and location record" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try buildErrorsFixture(a, &pb);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    // A depth budget of 0 forces the compact-JSON context even with errors.
    try renderInto(a, &out, pb.list.items, .{ .tz_offset_seconds = ERRORS_TZ, .max_tree_depth = 0 });
    try testing.expectEqualStrings(
        "2026-04-22 20:48:19.371 ERROR errors " ++
            "{\"err-foreign\": \"EOF\", " ++
            "\"err-beer\": {\"@context\": {\"NEW: error\": " ++
            "{\"@location\": \"@location:331\", \"new-string\": \"Hello World!\"}, " ++
            "\"WRAP: wrap\": {\"@location\": \"@location:332\", \"wrap-int\": 1}, " ++
            "\"CTX\": {\"@location\": \"@location:333\", \"just-pi\": 3.141592653589793}}, " ++
            "\"@text\": \"wrap: error\"}, " ++
            "\"err-foreign-root\": {\"@context\": {\"WRAP: wrap foreign\": " ++
            "{\"@location\": \"@location:335\", \"wrap-bool\": true}}, " ++
            "\"@text\": \"wrap foreign: EOF\"}, " ++
            "\"err-intermixed\": {\"@context\": {\"NEW: error\": " ++
            "{\"@location\": \"@location:337\", \"new-time\": \"2026-04-22 20:48:19.371\"}}, " ++
            "\"@text\": \"error\"}}\n",
        out.items,
    );
}

const PANIC_TIME: u64 = 1_776_880_099_375_255_000;
// Stacktrace carried by the reference fixture `blog-rs/src/testdata/panic.bin`
// (decoded from its gzip message).
const PANIC_STACK =
    "goroutine 56 [running]:\n" ++
    "runtime/debug.Stack()\n" ++
    "\t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/runtime/debug/stack.go:26 +0x64\n" ++
    "github.com/sirkon/blog/internal/alchemy.TestAlchemy.func9.1()\n" ++
    "\t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:375 +0x5c\n" ++
    "panic({0x1003449a0?, 0x100383600?})\n" ++
    "\t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/runtime/panic.go:860 +0x12c\n" ++
    "github.com/sirkon/blog/internal/alchemy.TestAlchemy.func9(0x12919acc0?)\n" ++
    "\t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:378 +0x50\n" ++
    "github.com/sirkon/blog/internal/alchemy.TestAlchemy.func10(0x3d65c6a97688?)\n" ++
    "\t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:404 +0x5ac\n" ++
    "testing.tRunner(0x3d65c6a97688, 0x3d65c6b8a7b0)\n" ++
    "\t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/testing/testing.go:2036 +0xc4\n" ++
    "created by testing.(*T).Run in goroutine 34\n" ++
    "\t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/testing/testing.go:2101 +0x3a8\n";

test "panic body renders the gzipped stacktrace with the st_dots prefix" {
    const a = testing.allocator;
    var pb = viewer.PB{};
    defer pb.deinit(a);
    try buildPanicFixture(a, &pb);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{ .tz_offset_seconds = ERRORS_TZ });

    try testing.expectEqualStrings(
        "2026-04-22 20:48:19.375 PANIC {\"recovered\": \"this is a panic\"}\n" ++
            ".... goroutine 56 [running]:\n" ++
            ".... runtime/debug.Stack()\n" ++
            ".... \t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/runtime/debug/stack.go:26 +0x64\n" ++
            ".... github.com/sirkon/blog/internal/alchemy.TestAlchemy.func9.1()\n" ++
            ".... \t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:375 +0x5c\n" ++
            ".... panic({0x1003449a0?, 0x100383600?})\n" ++
            ".... \t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/runtime/panic.go:860 +0x12c\n" ++
            ".... github.com/sirkon/blog/internal/alchemy.TestAlchemy.func9(0x12919acc0?)\n" ++
            ".... \t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:378 +0x50\n" ++
            ".... github.com/sirkon/blog/internal/alchemy.TestAlchemy.func10(0x3d65c6a97688?)\n" ++
            ".... \t/Users/denischeremisov/Sources/mine/blog/internal/alchemy/alchemy_test.go:404 +0x5ac\n" ++
            ".... testing.tRunner(0x3d65c6a97688, 0x3d65c6b8a7b0)\n" ++
            ".... \t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/testing/testing.go:2036 +0xc4\n" ++
            ".... created by testing.(*T).Run in goroutine 34\n" ++
            ".... \t/Users/denischeremisov/.local/share/mise/installs/go/1.26.2/src/testing/testing.go:2101 +0x3a8\n",
        out.items,
    );
}

test "panic body falls back to the decode error name" {
    const a = testing.allocator;

    var pb = viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, PANIC_TIME, @intFromEnum(consts.logLevel.panic));
    try pb.msg(a, "not a gzip stream");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try renderInto(a, &out, pb.list.items, .{ .tz_offset_seconds = ERRORS_TZ });

    try testing.expectEqualStrings(
        "2026-04-22 20:48:19.375 PANIC {}\n" ++
            ".... BadGzipHeader\n",
        out.items,
    );
}
