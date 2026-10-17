//! `blog` CLI: renders binary log files with the `PrettySink` viewer.
//!
//! Reads one or more log files (or standard input when none is given) and
//! prints each record as a human-readable header + context tree (or compact
//! JSON context), mirroring the Rust reference viewer and the Go `zighelper`.

const std = @import("std");
const Io = std.Io;
const blog = @import("blog");

pub fn main(init: std.process.Init) !void {
    var pool: blog.BufferPool = undefined;
    try pool.init(init.arena.allocator(), 4096, 4096);
    var writer: blog.FdWriter = undefined;
    writer.init(1);
    var sink: blog.PrettySink(blog.FdWriter) = undefined;
    sink.init(init.arena.allocator(), blog.ColorProfile.dark, &writer);
    var logger: blog.Logger(blog.BufferPool, blog.PrettySink(blog.FdWriter)) = undefined;
    logger.init(&pool, &sink);
    var diag = try logger.err_new("new error", .{ .key11 = 1, .key21 = "Hello!" });
    diag = try diag.wrap("wrap", .{ .key21 = 2, .key22 = "World" });
    diag = try diag.with(.{ .key31 = 3 });
    logger.warn("msg", .{ .diag = diag });
}

test "test output" {
    const expected: []const u8 =
        "2026-10-15 21:31:29.584  WARN msg \n" ++
        "└─ diag: \n" ++
        "   ├─ @context\n" ++
        "   │  ├─ NEW: new error\n" ++
        "   │  │  ├─ key11: 1\n" ++
        "   │  │  └─ key21: Hello!\n" ++
        "   │  ├─ WRAP: wrap\n" ++
        "   │  │  ├─ key21: 2\n" ++
        "   │  │  └─ key22: World\n" ++
        "   │  └─ CTX\n" ++
        "   │     └─ key31: 3\n" ++
        "   └─ @text: wrap: new error\n";

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    var pool: blog.BufferPool = undefined;
    try pool.init(std.testing.allocator, 4096, 4096);
    defer pool.deinit();

    var sink: blog.PrettySink(std.Io.Writer) = undefined;
    sink.init(std.testing.allocator, blog.ColorProfile.plain, &aw.writer);
    defer sink.deinit();

    var logger: blog.Logger(blog.BufferPool, blog.PrettySink(std.Io.Writer)) = undefined;
    logger.init(&pool, &sink);
    defer logger.deinit();

    var diag = try logger.err_new("new error", .{ .key11 = 1, .key21 = "Hello!" });
    diag = try diag.wrap("wrap", .{ .key21 = 2, .key22 = "World" });
    diag = try diag.with(.{ .key31 = 3 });
    logger.warn("msg", .{ .diag = diag });

    const got = try aw.toOwnedSlice();
    defer std.testing.allocator.free(got);

    // Need to change time value as it is differs for sure.
    @memcpy(got[0..23], expected[0..23]);
    std.testing.expectEqualSlices(u8, expected, got) catch {
        std.debug.panic(
            \\--- Expected:
            \\{s}
            \\
            \\--- Actual:
            \\{s}
        , .{ expected, got });
    };
}
