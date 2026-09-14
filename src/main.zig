//! `blog` CLI: renders binary log files with the `PrettySink` viewer.
//!
//! Reads one or more log files (or standard input when none is given) and
//! prints each record as a human-readable header + context tree (or compact
//! JSON context), mirroring the Rust reference viewer and the Go `zighelper`.

const std = @import("std");
const Io = std.Io;
const blog = @import("blog");

const usage =
    \\Usage: blog [options] [file ...]
    \\
    \\Renders a binary log produced by the logger as a human-readable tree.
    \\With no file arguments the log is read from standard input; a "-" file
    \\argument also means standard input.
    \\
    \\Options:
    \\  --json            emit one compact JSON object per record (JSONL)
    \\  --dark            dark-terminal colors (default)
    \\  --light           light-terminal colors
    \\  --no-color        disable ANSI colors
    \\  --tz-offset N     timestamp offset from UTC, in seconds
    \\  -h, --help        print this help
    \\
;

/// Parsed command line.
const Command = struct {
    files: []const []const u8 = &.{},
    profile: blog.ColorProfile = blog.ColorProfile.dark,
    /// Explicit timestamp offset; when null the process-local offset is used.
    tz_offset: ?i64 = null,
    /// Emit one compact JSON object per record instead of a tree.
    json: bool = false,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    const cmd = parseArgs(arena, if (argv.len > 0) argv[1..] else argv) catch {
        printUsage(.stderr(), io) catch {};
        std.process.exit(2);
    };
    if (cmd.help) {
        try printUsage(.stdout(), io);
        return;
    }

    run(io, init.gpa, cmd, init.environ_map.get("TZ"), init.environ_map.get("TZDIR")) catch |err| {
        var err_buffer: [256]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(.stderr(), io, &err_buffer);
        stderr_writer.interface.print("blog: {s}\n", .{@errorName(err)}) catch {};
        stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(
    io: Io,
    gpa: std.mem.Allocator,
    cmd: Command,
    tz_env: ?[]const u8,
    tzdir: ?[]const u8,
) !void {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const Pool = blog.buffer_pool.BufferPool(false);
    var pool = try Pool.init(gpa, 64, 16 * 1024);
    defer pool.deinit();

    var dropped: u64 = 0;
    if (cmd.json) {
        var sink = blog.JsonSink(Io.Writer).init(gpa, out);
        defer sink.deinit();
        try streamFiles(io, gpa, cmd, &sink, &pool);
        dropped = sink.dropped.load(.monotonic);
    } else {
        var sink = blog.PrettySink(Io.Writer).init(gpa, cmd.profile, out);
        defer sink.deinit();
        sink.options = .{
            .tz_offset_seconds = cmd.tz_offset orelse localUtcOffsetSeconds(io, gpa, tz_env, tzdir),
        };
        try streamFiles(io, gpa, cmd, &sink, &pool);
        dropped = sink.dropped.load(.monotonic);
    }

    if (dropped != 0) {
        var err_buffer: [256]u8 = undefined;
        var stderr_writer: Io.File.Writer = .init(.stderr(), io, &err_buffer);
        stderr_writer.interface.print(
            "blog: dropped {d} unreadable record(s)\n",
            .{dropped},
        ) catch {};
        stderr_writer.interface.flush() catch {};
    }

    try out.flush();
}

/// Streams standard input (or each file argument) through `sink`.
fn streamFiles(
    io: Io,
    gpa: std.mem.Allocator,
    cmd: Command,
    sink: anytype,
    pool: anytype,
) !void {
    if (cmd.files.len == 0) {
        const data = try readStdin(io, gpa);
        defer gpa.free(data);
        _ = try renderStream(sink, pool, data);
        return;
    }
    for (cmd.files) |path| {
        const data = if (std.mem.eql(u8, path, "-"))
            try readStdin(io, gpa)
        else
            try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(data);
        _ = try renderStream(sink, pool, data);
    }
}

/// Splits `data` into `0xFF [CRC×4] 0xFE [uvarint len] payload` frames and
/// renders each with `sink`, which writes straight to its destination writer.
/// Records that fail to parse or fail CRC verification are counted in
/// `sink.dropped` and otherwise skipped. Returns the number of frames seen.
fn renderStream(
    sink: anytype,
    pool: anytype,
    data: []const u8,
) !usize {
    var off: usize = 0;
    var count: usize = 0;
    while (off < data.len) {
        if (data.len - off < 6) return error.TruncatedLog;
        if (data[off] != 0xFF or data[off + 5] != 0xFE) return error.CorruptLog;

        const len = try blog.viewer.readUvarint(data, off + 6);
        const frame_len = 6 + len.size + @as(usize, @intCast(len.val));
        if (frame_len > data.len - off) return error.TruncatedLog;

        const buf = try pool.get(frame_len);
        @memcpy(buf, data[off..][0..frame_len]);
        _ = sink.write(pool, buf) catch {};
        count += 1;
        off += frame_len;
    }
    return count;
}

/// Reads the whole of standard input into a heap buffer owned by the caller.
fn readStdin(io: Io, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [16 * 1024]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .unlimited);
}

/// Offset of the process-local time zone from UTC, in seconds.
///
/// Resolves the `TZ` environment variable when it names a zoneinfo file or
/// region (`:Europe/Moscow`, `/etc/localtime`, `UTC`); otherwise falls back to
/// `/etc/localtime`. Returns 0 (UTC) when nothing can be read or parsed.
fn localUtcOffsetSeconds(
    io: Io,
    allocator: std.mem.Allocator,
    tz_env: ?[]const u8,
    tzdir: ?[]const u8,
) i64 {
    if (tz_env) |raw| {
        var spec = raw;
        if (spec.len > 0 and spec[0] == ':') spec = spec[1..];
        if (std.mem.eql(u8, spec, "UTC") or std.mem.eql(u8, spec, "GMT")) return 0;
        if (spec.len > 0) {
            if (spec[0] == '/') {
                if (offsetFromFile(io, allocator, spec)) |off| return off;
            } else {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                if (tzdir) |dir| {
                    if (std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, spec })) |path| {
                        if (offsetFromFile(io, allocator, path)) |off| return off;
                    } else |_| {}
                }
                for ([_][]const u8{ "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/etc/zoneinfo" }) |root| {
                    if (std.fmt.bufPrint(&buffer, "{s}/{s}", .{ root, spec })) |path| {
                        if (offsetFromFile(io, allocator, path)) |off| return off;
                    } else |_| {}
                }
            }
        }
    }
    return offsetFromFile(io, allocator, "/etc/localtime") orelse 0;
}

/// UTC offset in effect now according to the TZif file at `path`, or null when
/// the file is missing or malformed.
fn offsetFromFile(io: Io, allocator: std.mem.Allocator, path: []const u8) ?i64 {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const bytes = reader.interface.allocRemaining(allocator, .unlimited) catch return null;
    defer allocator.free(bytes);

    var fixed: Io.Reader = .fixed(bytes);
    var tz = std.Tz.parse(allocator, &fixed) catch return null;
    defer tz.deinit();

    return offsetAt(&tz, Io.Clock.real.now(io).toSeconds());
}

/// UTC offset (seconds) in effect at `secs` for a parsed zoneinfo database.
fn offsetAt(tz: *const std.Tz, secs: i64) i64 {
    var chosen: ?std.tz.Timetype = if (tz.timetypes.len > 0) tz.timetypes[0] else null;
    for (tz.transitions) |tr| {
        if (tr.ts > secs) break;
        chosen = tr.timetype.*;
    }
    return if (chosen) |tt| tt.offset else 0;
}

/// Parses arguments (excluding argv[0]). Returns `error.InvalidArguments` on
/// an unknown flag or a malformed `--tz-offset` value.
fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    var cmd = Command{};
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cmd.help = true;
        } else if (std.mem.eql(u8, arg, "--dark")) {
            cmd.profile = blog.ColorProfile.dark;
        } else if (std.mem.eql(u8, arg, "--light")) {
            cmd.profile = blog.ColorProfile.light;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            cmd.profile = blog.ColorProfile.plain;
        } else if (std.mem.eql(u8, arg, "--json")) {
            cmd.json = true;
        } else if (std.mem.eql(u8, arg, "--tz-offset")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cmd.tz_offset = std.fmt.parseInt(i64, args[i], 10) catch return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, arg, "--tz-offset=")) {
            const value = arg["--tz-offset=".len..];
            cmd.tz_offset = std.fmt.parseInt(i64, value, 10) catch return error.InvalidArguments;
        } else if (arg.len > 1 and arg[0] == '-') {
            return error.InvalidArguments;
        } else {
            try files.append(allocator, arg);
        }
    }

    cmd.files = try files.toOwnedSlice(allocator);
    return cmd;
}

fn printUsage(file: Io.File, io: Io) !void {
    var buffer: [1024]u8 = undefined;
    var writer: Io.File.Writer = .init(file, io, &buffer);
    try writer.interface.writeAll(usage);
    try writer.interface.flush();
}

const testing = std.testing;

/// Wraps a payload into a complete log frame, matching the logger encoder.
fn frameInto(dst: []u8, payload: []const u8) void {
    dst[0] = 0xFF;
    std.mem.writeInt(u32, dst[1..5], blog.crc32c.hardwareCrc32C(payload), .little);
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
    return 6 + uvarintLen(payload_len) + payload_len;
}

fn uvarintLen(v: usize) usize {
    var x = v;
    var n: usize = 1;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

test "parse args collects files and flags" {
    const a = testing.allocator;
    const argv = [_][]const u8{ "--no-color", "a.log", "--tz-offset", "10800", "b.log" };
    const cmd = try parseArgs(a, &argv);
    defer a.free(cmd.files);

    try expect(cmd.profile.ctx.len == 0);
    try expectEqual(@as(?i64, 10800), cmd.tz_offset);
    try expectEqual(@as(usize, 2), cmd.files.len);
    try expectEqualStrings("a.log", cmd.files[0]);
    try expectEqualStrings("b.log", cmd.files[1]);
}

test "parse args rejects unknown flags" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidArguments, parseArgs(a, &.{"--bogus"}));
    try testing.expectError(error.InvalidArguments, parseArgs(a, &.{"--tz-offset"}));
}

test "render stream renders consecutive frames" {
    const a = testing.allocator;
    var pb = blog.viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(blog.consts.logLevel.info));
    try pb.msg(a, "hello");

    const size = frameSize(pb.list.items.len);
    const frame_buf = try a.alloc(u8, size);
    defer a.free(frame_buf);
    frameInto(frame_buf, pb.list.items);

    const Pool = blog.buffer_pool.BufferPool(false);
    var pool = try Pool.init(a, 4, 4096);
    defer pool.deinit();

    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();

    var sink = blog.PrettySink(Io.Writer).init(a, .plain, &out.writer);
    defer sink.deinit();

    const count = try renderStream(&sink, &pool, frame_buf);
    try expectEqual(@as(usize, 1), count);
    try expectEqualStrings(
        "1970-01-01 00:00:00.000  INFO hello {}\n",
        out.written(),
    );
    try expectEqual(@as(u64, 0), sink.dropped.load(.monotonic));
}

test "render stream renders consecutive frames as json lines" {
    const a = testing.allocator;
    var pb = blog.viewer.PB{};
    defer pb.deinit(a);
    try pb.header(a, 0, @intFromEnum(blog.consts.logLevel.info));
    try pb.msg(a, "hello");
    try pb.key(a, .int64, "n");
    try pb.le(a, u64, 7);

    const size = frameSize(pb.list.items.len);
    const frame_buf = try a.alloc(u8, size);
    defer a.free(frame_buf);
    frameInto(frame_buf, pb.list.items);

    const Pool = blog.buffer_pool.BufferPool(false);
    var pool = try Pool.init(a, 4, 4096);
    defer pool.deinit();

    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();

    var sink = blog.JsonSink(Io.Writer).init(a, &out.writer);
    defer sink.deinit();

    const count = try renderStream(&sink, &pool, frame_buf);
    try expectEqual(@as(usize, 1), count);
    try expectEqualStrings(
        "{\"time\":0,\"level\":\"I\",\"message\":\"hello\",\"n\":7}\n",
        out.written(),
    );
    try expectEqual(@as(u64, 0), sink.dropped.load(.monotonic));

    const cmd = try parseArgs(a, &.{"--json"});
    defer a.free(cmd.files);
    try expect(cmd.json);
}

test "render stream rejects a truncated log" {
    const a = testing.allocator;
    const Pool = blog.buffer_pool.BufferPool(false);
    var pool = try Pool.init(a, 2, 4096);
    defer pool.deinit();

    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();

    var sink = blog.PrettySink(Io.Writer).init(a, .plain, &out.writer);
    defer sink.deinit();

    try testing.expectError(error.TruncatedLog, renderStream(&sink, &pool, &.{ 0xFF, 0x00 }));
    try testing.expectError(error.CorruptLog, renderStream(&sink, &pool, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE }));
}

test "json escape" {
    const je = @import("jsonescape");

    const hello = try je.escapeUnquote(std.testing.allocator, "Hello" ++ [1]u8{0});
    defer std.testing.allocator.free(hello);
    try std.testing.expectEqualStrings("Hello\\u0000", hello);
}

const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
