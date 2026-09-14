//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const buffer_pool = @import("buffer_pool.zig");

pub const writer = @import("writer.zig");
/// Concrete fixed-frame free-list pool owning all record memory; this is the
/// type every `Logger`, `MemorySink`, `FileSink`, `SyncWriter` and
/// `PrettySink` is typed against. Use it directly:
///
///     var pool = try blog.BufferPool.init(allocator, 64, 16 * 1024);
///     var logger = blog.Logger(blog.BufferPool, blog.MemorySink).init(&pool, &sink);
pub const BufferPool = writer.BufferPool;
/// Comptime pool factory for callers that need the thread-safe variant or a
/// custom frame policy. `BufferPoolFactory(false)` is the concrete
/// `BufferPool`.
pub const BufferPoolFactory = buffer_pool.BufferPool;
/// Captures records for tests and in-memory tooling.
pub const MemorySink = writer.MemorySink;
/// Synchronous writer over a raw POSIX file descriptor (`std.posix.fd_t`).
pub const FdWriter = writer.FdWriter;
/// Comptime file writer factory over a downstream `Sink` type.
/// `Sink` must expose `fn write(self: *Sink, []const u8) E!usize`.
pub const FileSink = writer.FileSink;
/// Comptime factory wrapping a downstream `Sink` in a mutex so concurrent
/// writes are serialized. `Sink` must expose `fn write(self: *Sink, []const u8) E!usize`.
pub const SyncWriter = writer.SyncWriter;
/// Comptime tree-viewer writer factory over a downstream `Sink` type.
pub const PrettySink = writer.PrettySink;
/// Comptime compact-JSONL writer factory over a downstream `Sink` type.
pub const JsonSink = writer.JsonSink;
/// Error returned by any log writer when the downstream write fails.
pub const WriteError = writer.WriteError;

pub const render = @import("render.zig");
/// ANSI color table for the tree viewer.
pub const ColorProfile = render.ColorProfile;
/// Tree-vs-JSON render knobs.
pub const RenderOptions = render.RenderOptions;

pub const logger = @import("logger.zig");
/// High-level logger over a `BufferPool` and a Sink.
pub const Logger = logger.Logger;

pub const viewer = @import("viewer.zig");
/// Parses a log record payload into a header + node tree for rendering.
pub const ParsedRecord = viewer.ParsedRecord;

/// Wire vocabulary shared by the logger and the viewer.
pub const consts = @import("consts.zig");
/// CRC32C used to verify log frames.
pub const crc32c = @import("crc32c.zig");

test {
    _ = @import("buffer_pool.zig");
    _ = @import("writer.zig");
    _ = @import("logger.zig");
    _ = @import("encoding.zig");
    _ = @import("decoding.zig");
    _ = @import("crc32c.zig");
    _ = @import("viewer.zig");
    _ = @import("render.zig");
    _ = @import("jsonsink.zig");
}
