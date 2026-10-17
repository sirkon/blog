# blog Zig SDK usage reference

Practical usage guide for the **public Zig surface** of this repository. The
whole Zig side is one module named `blog`, rooted at `src/root.zig`. Everything
reachable from `root.zig` is the contract; everything else in `src/` is
implementation detail even when a file is technically importable by path.

> The Go packages (`github.com/sirkon/blog`, `beer`, `internal/*`) are a separate
> implementation of the same wire format and are out of scope here, except where
> a behavioral divergence matters. See `AGENTS-SDK-GO.md` for that side.

---

## Table of contents

- [Install and wiring](#install-and-wiring)
- [What root.zig exports](#what-rootzig-exports)
- [Quick start](#quick-start)
- [Buffer pools](#buffer-pools)
- [Logger reference](#logger-reference)
- [Attribute reference](#attribute-reference)
- [Sinks and downstream writers](#sinks-and-downstream-writers)
- [Rich diagnostics](#rich-diagnostics)
- [Viewer and renderer](#viewer-and-renderer)
- [Low-level primitives](#low-level-primitives)
- [Gotchas](#gotchas)
- [Complete example](#complete-example)

---

## Install and wiring

Requires **Zig 0.16** (`minimum_zig_version` in `build.zig.zon`). The code targets
0.16 std APIs (`std.process.Init`, `std.Io`, `std.Io.Writer.Allocating`,
`std.ArrayList.empty`) and will not compile on 0.14.

```shell
zig fetch --save=blog <url-or-path-to-this-package>
```

```zig
const blog = @import("blog");
```

Two packaging facts that leak into user code:

- The module is declared with **`link_libc = true`** (`build.zig`), because
  `src/mutex.zig` wraps `pthread_mutex_t` by hand and `SyncWriter` and the
  thread-safe pool need it. Any target you build the module for must therefore
  have libc available.
- The module has one dependency, `jsonescape`, used only by `jsonsink.zig`. The
  package resolves it from `build.zig.zon`, so `zig fetch --save=blog ...` is
  normally all you need.

Build/test commands live in `AGENTS.md`; the ones you will use most:

| Task | Command |
|---|---|
| Build the CLI (`zig-out/bin/blog`) | `zig build` |
| Run the Zig test suite | `zig build test` |
| Run the CLI | `zig build run -- <args>` |

`zig build test` currently reports **122/122 tests passing but exits non-zero**:
the `src/main.zig` test leaks its pool/sink (7 allocations). That is a
pre-existing, known failure owned by a missing `deinit`, not by anything you
write.

---

## What root.zig exports

Module consumers only see declarations reachable from `src/root.zig`. The
public surface, by area:

| Export | What it is |
|---|---|
| `blog.BufferPoolFactory` | `buffer_pool.BufferPool` - comptime `fn(bool) type` factory |
| `blog.BufferPool` | `BufferPoolFactory(false)` - the concrete non-thread-safe pool |
| `blog.buffer_pool` | The whole `buffer_pool.zig` module (for `BufferPool(true)`) |
| `blog.Logger` | `logger.Logger(Pool, Sink)` comptime factory |
| `blog.logger` | The whole `logger.zig` module (`headerWidth`) |
| `blog.writer` | The whole `writer.zig` module (base of every sink) |
| `blog.MemorySink` | In-memory capture sink, concrete type |
| `blog.FdWriter` | Raw POSIX fd downstream writer, concrete type |
| `blog.FileSink` | `fn(Writer) type` - frames to a downstream writer |
| `blog.SyncWriter` | `fn(Writer) type` - mutex-serialized downstream writer |
| `blog.PrettySink` | `fn(Writer) type` - human-readable tree/JSON sink |
| `blog.JsonSink` | `fn(Writer) type` - compact JSONL sink |
| `blog.WriteError` | `error{WriteFailed}` |
| `blog.Error` | `errors.Error` = `Diag(BufferPool)`, the concrete diagnostic type |
| `blog.errors` | The whole `error.zig` module (`Diag`, `isDiag`, `maxLiveDiagnostics`) |
| `blog.ColorProfile` | `render.ColorProfile` |
| `blog.RenderOptions` | `render.RenderOptions` |
| `blog.render` | The whole `render.zig` module (`Renderer`, fixtures) |
| `blog.ParsedRecord` | `viewer.ParsedRecord` |
| `blog.viewer` | The whole `viewer.zig` module (`parseRecord`, `PB`, `NodeKind`) |
| `blog.consts` | Wire vocabulary (`version`, `logLevel`, `ValueKind`, `MinimalInt`) |
| `blog.crc32c` | `hardwareCrc32C` |

`encoding.zig`, `decoding.zig`, `jsonsink.zig` and `mutex.zig` are **not**
re-exported and are imported only by the `test` block in `root.zig`, so they are
not part of the consumer-visible surface. `jsonsink` types reach callers only
through the `JsonSink` factory, and `encoding`/`decoding` are internal to the
logger, diagnostics and viewer.

If you add a new source file to the module, it must be re-exported from
`root.zig` **and** added to the `test` block there, otherwise it is invisible to
consumers and to `zig build test`.

---

## Quick start

```zig
const std = @import("std");
const blog = @import("blog");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Pool: size must be a power of two, frameSize a power of two >= 512.
    var pool: blog.BufferPool = undefined;
    try pool.init(allocator, 64, 16 * 1024);
    defer pool.deinit();

    // 2. Sink. MemorySink captures records in memory; FdWriter + PrettySink
    //    renders them for humans.
    var sink: blog.MemorySink = undefined;
    sink.init(allocator);
    defer sink.deinit();

    // 3. Logger is comptime-parameterized over both; no vtables on the hot path.
    var logger: blog.Logger(blog.BufferPool, blog.MemorySink) = undefined;
    logger.init(&pool, &sink);

    logger.info("hello", .{ .n = @as(u32, 7) });

    var child = logger.With(.{ .job = "sync" });
    defer child.deinit(); // returns the pinned prefix frame
    child.warn("child record", .{ .x = @as(i16, -3) });
}
```

Records are **binary**. To see them, stream the same bytes through
`PrettySink` (tree) or `JsonSink` (JSONL) instead of `MemorySink`.

---

## Buffer pools

`BufferPool(comptime threadsafe: bool)` is a fixed-frame free list with a heap
fallback. Every `Logger`, `MemorySink`, `FileSink`, `SyncWriter`, `PrettySink`
and `JsonSink` is typed against the concrete `BufferPool` =
`BufferPool(false)`, so a thread-safe pool only helps if you log from multiple
threads through the *same* logger value guarded elsewhere.

```zig
var pool: blog.BufferPool = undefined;
try pool.init(allocator, 64, 16 * 1024);
defer pool.deinit();
```

```zig
pub fn init(self: *Self, allocator: std.mem.Allocator, size: u32, frameSize: u32) !void
pub fn deinit(self: *Self) void
pub fn get(self: *Self, size: usize) std.mem.Allocator.Error![]u8
pub fn put(self: *Self, buf: []u8) bool
```

- `size` must be **nonzero and a power of two**; `frameSize` must be **a power of
  two and >= 512**. Otherwise `init` returns `error.InvalidConfig`.
- `get(n)` returns a frame when `n <= frameSize` and a frame is free, otherwise
  allocates on the heap. The returned slice is **exactly `n` bytes** and is a
  subview of the frame, so the frame is returned by address alone.
- `put(buf)` returns `true` when the slice belonged to a frame (the slice may be
  an *interior* pointer; the frame is recovered by truncating the address), and
  `false` when it was heap-allocated and was freed.
- `deinit` **asserts that every frame is back on the free list**. A leaked record
  surfaces as an assertion failure, and under `std.testing.allocator` as a leak.

For the thread-safe variant, use the factory directly:

```zig
const Pool = blog.BufferPoolFactory(true);
var pool: Pool = undefined;
try pool.init(allocator, 64, 16 * 1024);
defer pool.deinit();
```

Note that `Logger(Pool, Sink)` is then instantiated with `Pool` rather than
`blog.BufferPool`, and `Sink.write` must accept `*Pool`, so all sinks that are
typed against `writer.BufferPool` (`MemorySink`, `FileSink(W)`, `PrettySink(W)`,
`JsonSink(W)`) will **not** compose with it. In practice the thread-safe pool is
for custom sinks.

---

## Logger reference

```zig
pub fn Logger(comptime Pool: type, comptime Sink: type) type
```

Construction and teardown:

```zig
var logger: blog.Logger(Pool, Sink) = undefined;
logger.init(&pool, &sink);
defer logger.deinit(); // releases the With prefix frame and unlogged diagnostics
```

`init` takes `*Pool` and `*Sink`; both are **borrowed** and must outlive the
logger. `Logger` has public fields (`pool`, `sink`, `prefix_alloc`, `prefix`,
`slots`) but treat them as read-only, `prefix` is deliberately a subview of
`prefix_alloc` so `put` can recover the allocation.

### Levels

```zig
logger.trace("...", .{});
logger.debug("...", .{});
logger.info ("...", .{});
logger.warn ("...", .{}); // note: the method is `warn`, the enum value is `warning`
logger.err  ("...", .{}); // `err`, not `error`
logger.panic("...", .{});
```

Every level method is:

```zig
pub fn info(self: *Self, comptime msg: []const u8, attrs: anytype) void
```

Three consequences worth internalizing:

1. **`msg` is a comptime parameter.** A string literal, or any comptime-known
   `[]const u8`, works; a runtime-built string does not. Put dynamic text in
   `attrs` instead.
2. **The call returns `void`.** There is no error channel and no `Enabled` check.
   A record that cannot be built or written is **dropped** and the logger's
   `dropped` counter is incremented.
3. `attrs` must be an anonymous struct. `.{ .key = value }`; `attrs` is never
   nullable, but `.{}` is the idiomatic "no attributes".

Zig has no varargs on the level methods, so the Go-style `log.Info(ctx, msg,
attr1, attr2)` does not exist. Nest attributes in groups instead.

### Child loggers

```zig
var child = logger.With(.{ .job = "sync", .shard = @as(u8, 3) });
defer child.deinit();

child.info("tick", .{ .n = @as(u32, 1) });
// emits job=sync, shard=3, then n=1
```

- `With` returns a **new logger value (a copy)** whose records carry `attrs` as a
  prefix, encoded once into a single pooled frame that the child pins for its
  lifetime.
- The child **must** be `deinit`ed; that is what returns the prefix frame. The
  pool's leak assertion will catch a missing `deinit`.
- A prefix frame is *not* extended in place. `logger.With(...).With(...)` copies
  the whole prefix again, so build the deepest prefix once at startup rather
  than re-wrapping per request.
- `With` rejects a diagnostic-valued attribute at **compile time**
  (`comptime std.debug.assert(!hasDiagnostics(...))`), because a prefix is copied
  once per record and a diagnostic is log-once.
- If the pool cannot provide the prefix frame, `With` does not fail: it drops the
  record accounting and returns an *empty* logger value with a zero-length
  prefix. Silent, but it only happens under exhaustion.

### Locations

`writeRecord` always writes a `0x00` location byte, so **the Zig logger does not
record call sites**. `Location` in the wire format is populated only by rich
diagnostics built with `err_after_loc` / `err_new_loc` / `wrap_loc` /
`with_loc`, or by a Go producer.

There is also **no level filter** and no `OptionLogFromLevel` equivalent: every
call reaches the sink. Filter at the sink or in your own caller.

### Message and payload layout (for reference)

`payload_len = 2 (version) + 8 (time) + 1 (level) + 1 (location) +
uvarint(msg_len) + msg_len + prefix.len + attrs_size`. The header in front is
`0xFF | CRC32C(payload) as u32 LE | 0xFE | uvarint(payload_len)`; `headerWidth`
computes its size. This is frozen by the golden frame test in `logger.zig`
(timestamp pinned to `0x0102030405060708`) and must stay byte-identical to the Go
encoder.

---

## Attribute reference

`attrs` is an anonymous struct. Each field becomes one `kind u8 | key |
value` node on the wire, in declaration order; there is no separate
"constructor" layer like Go's `blog.Str(...)`. The field **type** selects the
kind, resolved at comptime - which means unsupported types are a
`@compileError`, not a runtime surprise.

| Zig type | Wire kind | Rendered as |
|---|---|---|
| `bool` | `bool` | `true` / `false` |
| `i8`/`i16`/`i32`/`i64`, `u8`/`u16`/`u32`/`u64` | matching `intN`/`uintN` | decimal |
| `comptime_int` literal (`.{ .n = 12 }`) | **minimal width**, via `consts.intKind` | decimal |
| `f32` / `f64` | `float32` / `float64` | ryu shortest form |
| string literal, `*const [N:0]u8` | `string` | quoted text |
| `[]const u8` / `[]u8` | **`sliceUint8`** | `base64.…` |
| `[]const u16`, `[]u32`, … , `[]const i64` | matching `sliceXN` | array |
| `[]const f32` / `[]const f64` | `sliceFloat32/64` | array |
| `[]const bool` | `sliceBool` | array |
| `[N]T` fixed array | same as the corresponding `[]T` slice | array |
| anonymous struct value | `nodeGroup` … `nodeGroupEnd` | nested tree |
| `*Diag(Pool)` (a diagnostic) | `nodeError` | error node |

Supported element types for slices and fixed arrays: `bool`, `i8..i64`,
`u8..u64`, `f32`, `f64`. Anything else - notably `[]const []const u8` - is a
`@compileError` ("Slices of type ... are not supported by the rules"), even
though the wire vocabulary reserves a `sliceString` kind for it. To log a list of
strings from Zig, flatten it (join into one string) or emit one attribute per
element; only a Go producer will ever write a real `sliceString`.

`comptime_int` deserves a note: `.{ .count = 12 }` logs as a `u8`, `.{ .count =
-1 }` as an `i8`, `.{ .count = 70000 }` as a `u32`. You only get the wide form if
you ask for it (`@as(u64, 12)`). `consts.MinimalInt`, `consts.minimalInt` and
`consts.intKind` are exported if you want to reason about it directly, or log the
same shape from your own encoder.

### Strings vs byte slices (the biggest surprise)

A string **literal** has type `*const [N:0]u8` (a one-element pointer to an
array) and encodes as `ValueKind.string`. A `[]const u8` **variable**, even one
holding the same printable text, encodes as `ValueKind.sliceUint8` and renders as
base64:

```zig
const verb: []const u8 = "sync";
logger.info("x", .{ .a = verb, .b = "sync" });
// a: "c3luYw=="  (byte slice, base64)
// b: sync        (string literal)
```

If you want printable text, either pass the literal directly or, for dynamic
text, pass a sentinel-terminated `*const [N:0]u8` slice - not a plain `[]const
u8`. This differs from Go's `blog.Bytes`, which sniffs the content; the Zig side
decides purely from the type.

### Groups

```zig
logger.info("request", .{
    .http = .{ .method = "GET", .status = @as(u16, 200) },
    .db = .{ .took = @as(i64, 3_000_000) }, // nanoseconds, no `duration` kind in Zig
});
```

Nested anonymous structs give you `nodeGroup` nodes; there is no explicit
`Group(...)` helper and no separate key argument - the field name is the group
key. An empty group is legal and encodes as a group with zero fields.

There is **no `time`/`duration` attribute in the Zig logger**: those kinds exist
in the wire vocabulary (`consts.ValueKind.time`/`.duration`, and the Go API uses
them), and the viewer renders them, but nothing on the Zig attribute path emits
them. Encode nanoseconds as an integer.

### Keys

Field names are keys. They are comptime-known, so an empty or dynamic key cannot
occur through the logger API. Keys are length-prefixed and never truncated.

---

## Sinks and downstream writers

There are two distinct comptime contracts. Confusing them is the most common
source of compile errors.

### Sink contract (what a `Logger` writes into)

```zig
pub fn write(self: *Self, pool: *BufferPool, buf: []const u8) WriteError!usize
```

- `write` **takes ownership of `buf`**. On every return path, success or failure,
  a synchronous sink must `pool.put(@constCast(buf))`.
- `pool` is always the concrete `writer.BufferPool`, never generic.
- A failing sink returns `error.WriteFailed`; the logger counts that as a dropped
  record on its own `dropped` counter.
- A sink needs no `dropped` field to work with the logger: the drop accounting
  lives on the logger. The built-in renderer sinks (`PrettySink`/`JsonSink`)
  carry their own `dropped` field for the frames they reject themselves
  (unreadable input), and the CLI reads it to report skipped records.

### Downstream writer contract (what a sink wraps)

```zig
pub fn write(self: *Writer, bytes: []const u8) E!usize
```

Any error set is accepted; a short write is retried by the wrapping sink, and a
failing write becomes `error.WriteFailed` upstream. `FileSink`, `SyncWriter`,
`PrettySink` and `JsonSink` are comptime factories that `assertWriter` this at
comptime, so a wrong signature is a compile error with a readable message. The
`E!usize` return is the count written; `std.Io.Writer` satisfies the contract as
is, which is why tests pass a `std.Io.Writer.Allocating`.

### Ready-made sinks

```zig
/// Concrete: capture every record in memory. Used by tests.
var sink: blog.MemorySink = undefined;
sink.init(allocator);
defer sink.deinit();          // frees `sink.bytes`
_ = sink.bytes.items;         // all frames concatenated
_ = logger.dropped.load(.monotonic);
```

```zig
/// Concrete: raw POSIX fd, all bytes written, retries short writes and EINTR.
var w: blog.FdWriter = undefined;
w.init(file.handle); // or std.posix.STDOUT_FILENO
_ = try w.write("bytes");
```

`FdWriter` **borrows** the descriptor; it never opens, duplicates or closes it.

```zig
/// FileSink(W): forwards each frame to `W`, keeps `last_error`, counts `written`.
var downstream: blog.FdWriter = undefined;
downstream.init(1);
var sink: blog.FileSink(blog.FdWriter) = undefined;
sink.init(&downstream);
```

```zig
/// SyncWriter(W): serializes concurrent calls with a libc mutex.
var synced: blog.SyncWriter(blog.FdWriter) = undefined;
synced.init(&downstream);
defer synced.deinit(); // destroys the mutex
```

`SyncWriter` is itself a valid downstream writer, so
`FileSink(SyncWriter(W)).init(&synced)` composes. Wrap the downstream writer in
`SyncWriter` whenever more than one thread can reach the sink, so partial frames
cannot interleave. Never copy a `SyncWriter` after taking its address: the mutex
lives inline and must keep a stable address.

```zig
/// PrettySink(W): verify the frame, parse it, render tree or compact JSON.
var out: blog.FdWriter = undefined;
out.init(1);
var sink: blog.PrettySink(blog.FdWriter) = undefined;
sink.init(allocator, blog.ColorProfile.dark, &out);
defer sink.deinit();
sink.options = .{ .tz_offset_seconds = 3 * 3600 }; // public field, set any time
sink.profile = blog.ColorProfile.plain;            // public field
```

```zig
/// JsonSink(W): one compact JSON object per record, newline-terminated.
var sink: blog.JsonSink(std.Io.Writer) = undefined;
sink.init(allocator, &out.writer);
defer sink.deinit();
```

Both renderer sinks drop any record that fails framing, CRC or parsing, bumping
`dropped`, and write nothing. Both take ownership of `buf` and always return it
to the pool.

`verifyFrame(frame) ![]const u8` is exported from `blog.writer` if you want the
validation without the rendering: it checks `0xFF [CRC32C×4 LE] 0xFE [uvarint
len] payload`, rejects trailing bytes, and returns the payload slice.

---

## Rich diagnostics

`error.zig` is the Zig counterpart of Go's `beer.Error`: a diagnostic
accumulates a self-describing payload as the stack unwinds and is handed to a
logger attribute exactly once.

```zig
var diag = try logger.err_after(error.NotFound, .{ .name = file_name });
diag = try diag.wrap("open config file", .{ .attempt = @as(u8, 2) });
diag = try diag.with(.{ .uid = @as(u32, 42) });
logger.warn("cannot start", .{ .err = diag });
```

### Starting

```zig
pub fn err_after(self: *Self, err_value: anyerror, ctx: anytype) !*Error
pub fn err_new(self: *Self, msg: []const u8, ctx: anytype) !*Error
pub fn err_after_loc(self: *Self, err_value: anyerror, loc: std.builtin.SourceLocation, ctx: anytype) !*Error
pub fn err_new_loc(self: *Self, loc: std.builtin.SourceLocation, msg: []const u8, ctx: anytype) !*Error
```

- `err_after` / `err_new` (`_log` are aliases of the `_loc` variants) return a
  `*Error` owned by the logger, or `error.OutOfMemory`.
- `err_after` keeps the Zig error value: `diag.spec()` returns it as `?anyerror`.
  `err_new` is spec-less (`spec()` returns `null`) - use it for invariant
  violations with no certain code.
- The `_loc` variants take a `std.builtin.SourceLocation`, normally
  `@src()`, and encode a `@location: file:line` node inside that stage.
- `ctx` must be an anonymous struct; anything else is a `@compileError`
  ("blog.Error context must be an anonymous struct").

### Growing

```zig
pub fn wrap(self: *Self, msg: []const u8, ctx: anytype) !*Self
pub fn with(self: *Self, ctx: anytype) !*Self
pub fn wrap_loc(self: *Self, loc: std.builtin.SourceLocation, msg: []const u8, ctx: anytype) !*Self
pub fn with_loc(self: *Self, loc: std.builtin.SourceLocation, ctx: anytype) !*Self
```

`wrap` adds a labelled stage; `with` adds a message-less `CTX` stage. Every
earlier stage is preserved, and each stage grows the payload into a fresh
exactly-sized allocation, releasing the previous one.

### Inspecting

```zig
pub fn spec(self: *const Self) ?anyerror
pub fn payloadSize(self: *const Self) usize
pub fn payloadSlice(self: *const Self) []const u8
pub fn string(self: *const Self, allocator: std.mem.Allocator) ![]const u8 // caller frees
pub fn isConsumed(self: *const Self) bool
```

`string` renders the stages joined with `": "` in reverse order
(`"outer: inner"`), matching Go's `Error()`.

### Logging (and the terminal rule)

```zig
logger.warn("msg", .{ .err = diag }); // consumes it
```

Handing a `*Error` to any level method - directly or nested inside a group,
which is walked recursively - copies its payload into the record and
**consumes** the diagnostic: the frame goes back to the pool and the diagnostic
becomes terminal.

- Log a diagnostic **exactly once**. `wrap`/`with`/`payloadSlice` on a consumed
  diagnostic touch the dead payload and fault (a `fault()` that resets `SIGSEGV`
  to default, so the OS reports it as a fault, not a Zig panic).
- `payloadSize`/`payloadSlice`/`string`/`wrap`/`with` all validate liveness in
  Debug and ReleaseSafe. ReleaseFast and ReleaseSmall compile the check out and
  rely on the NULL payload to segfault.
- Every method is safe to call on an already-released diagnostic (the dead
  payload makes `release` idempotent), which is what makes `deinit` cleanup
  trivial.

### Slots and lifetimes

- The storage lives in a **fixed array of `maxLiveDiagnostics = 8` slots inside
  the logger that started the diagnostic**. There is no allocator-created
  diagnostic and no way to move one to another logger.
- Starting a 9th live diagnostic **panics**: "too many live blog.Error
  diagnostics; log them before starting new ones".
- Logging frees the slot for reuse; `logger.deinit()` releases every unlogged
  diagnostic so a started-but-never-logged diagnostic cannot leak the frame.

---

## Viewer and renderer

`viewer.zig` turns a record payload into a header plus a flat `Node` array;
`render.zig` renders that into tree text or compact JSON. This layer is what
`PrettySink` uses; you only need it directly for tooling and tests.

```zig
pub fn parseRecord(allocator, payload: []const u8, rec: *ParsedRecord) ParseError!void
```

- `payload` starts at the version field; the `0xFF`/CRC/length framing is the
  sink's concern (`verifyFrame` strips it).
- `parseRecord` is bounds-checked and allocation-fallible; unlike the logger hot
  path it never over-reads. Errors: `Truncated`, `VarintOverflow`,
  `VersionNotSupported`, `UnknownValueKind`, plus `Allocator.Error`.
- `ParsedRecord` is reusable: `reset()` empties the builder but keeps capacity,
  and `parseRecord` calls it for you. `deinit(allocator)` frees the builder.
- `ParsedRecord` exposes `time`, `level`, `loc`, `msg_len`, `msg_off`, `builder`,
  and the render decision inputs `ctx_size`, `has_errors`, `has_groups`,
  `group_depth`.
- `PB` is the public byte-level payload builder the tests use to fabricate
  fixtures without a logger (`header`, `headerLoc`, `msg`, `key`, `strField`,
  `uvarint`, `le`, `raw`, `byte`).

```zig
var renderer: blog.render.Renderer = undefined;
renderer.init(allocator, blog.ColorProfile.plain);
defer renderer.deinit();

var dst: std.ArrayList(u8) = .empty; // caller-owned; freed by the caller
defer dst.deinit(allocator);
try renderer.render(&dst, payload, &rec);
```

`Renderer.render` clears its own per-record state on entry, so one `Renderer` can
be reused across records. Its `profile` and `options` are public fields.

### Renderer knobs

```zig
pub const RenderOptions = struct {
    expand_array_since: usize = 8,   // arrays this long render one item per line
    expand_context_since: usize = 4, // contexts this long become a tree
    max_tree_depth: usize = 16,      // deeper records fall back to compact JSON
    tz_offset_seconds: i64 = 0,      // fixed offset; Zig has no TZ database
};
```

`needsTree(rec, options)` is exported for callers that want the decision without
the render. A group or any error node always forces the tree form.

### Color profiles

`ColorProfile.plain` (all-empty ANSI table - what tests use), `.light` and
`.dark`. If you build your own, every field must be set; the behavior of an
undefined color field is a compile error, not garbage output (Zig requires all
fields).

### JSONL dialect (`JsonSink`)

- Levels are single letters: `"T"`, `"D"`, `"I"`, `"W"`, `"E"`, `"P"`, and
  `"UNKNOWN(<n>)"` otherwise.
- `"time"` is a **bare nanosecond integer**, unlike Go's RFC3339 string.
- `"location"` is `"file:line"` and is omitted when absent.
- A panic record becomes `"stacktrace":<raw gunzipped text>`, appended
  **unescaped and unquoted**.
- Byte slices (`sliceUint8`) become standard-base64 quoted strings; the new wire
  format has no `Bytes` kind.
- Errors render as `"@ctx":{...},"@txt":"outer: inner"`.
- The per-record output buffer starts at `jsonsink.initialCapacity(payload_len)`
  (1.5x the payload, floored at 128) and doubles, returning the old buffer to the
  pool.

---

## Low-level primitives

Exported for tests, custom tooling and fixtures; not needed for normal use.

```zig
// Wire vocabulary.
blog.consts.version;                    // 1
blog.consts.logLevel;                   // trace=10 .. panic=60
blog.consts.ValueKind;                  // frozen numbers, guards wire compat
blog.consts.MinimalInt(x);              // comptime fn(comptime_int) type
blog.consts.intKind(x);                 // comptime fn(comptime_int) ValueKind

// CRC32C / Castagnoli. Identical to Go's hash/crc32.Castagnoli.
blog.crc32c.hardwareCrc32C(payload);

// Framing helpers.
blog.writer.verifyFrame(frame);         // -> payload, checks CRC and length
blog.logger.headerWidth(payload_len);
```

The varint helpers (`encoding.appendVarint`, `encoding.append`,
`encoding.getStructEncodedSize`, `decoding.decodeVarint`) are real but **not
reachable from the module root**: `encoding.zig` and `decoding.zig` are test-only
imports in `root.zig`. To use them today you have to re-export them from
`root.zig` (or import the files by path inside this package).

The CRC implementation has an inline-asm path for x86_64 that is enabled **only
in `ReleaseFast`** (a compiler workaround) and a `crc32cx` path on aarch64;
everything else falls back to `std.hash.crc.Crc32Iscsi`. The fallback is what
the tests exercise, so keep it working.

`decoding.decodeVarint` **requires a little-endian target** (`@compileError`
otherwise) and reads up to 8 bytes unconditionally past the varint, so it must
only be used on the logger's own padded buffers. Use `blog.viewer.readUvarint`
for untrusted input; it is bounds-checked.

The CLI (`src/main.zig`) is currently a **smoke test**, not the real CLI: the
uncommitted `git show HEAD:src/main.zig` version has full argument parsing
(`--json`, `--dark`/`--light`/`--no-color`, `--tz-offset`, file or `-` stdin).
Do not rely on CLI behavior from the working tree.

---

## Gotchas

### The level method is `err`, and the enum value is `warning`

```zig
logger.err("...", .{});              // method
blog.consts.logLevel.warning;        // enum value, renders as WARN
```

`LevelError`-style names from Go do not exist here.

### `msg` must be comptime

```zig
logger.info("literal", .{});        // fine
logger.info(allocated, .{});        // compile error
logger.info("...", .{ .text = allocated }); // put dynamic text in an attribute
```

### A `[]const u8` is bytes, a literal is a string

Covered above; this is the single most likely way to get base64 where you wanted
text.

### No `time` or `duration` attributes from Zig

The kinds exist and render correctly, but nothing on the Zig attribute path emits
them. Use integers or preformatted strings.

### No call-site locations from the Zig logger

`writeRecord` always writes the `0x00` location byte. Only diagnostic `_loc`
variants (and Go producers) fill it.

### The Zig logger never returns an error

Records are dropped on pool failure or sink failure, and the logger's `dropped`
counter is bumped. Check `logger.dropped.load(.monotonic)` if you care. The CLI
prints a warning to stderr when it is nonzero after a run.

### Diagnostics are log-once and slot-bound

- 8 live diagnostics per logger; the 9th panics.
- Use after log (or double log) faults by dereferencing NULL; in Debug and
  ReleaseSafe a `live` flag catches it first.
- A diagnostic cannot be used as a `With` prefix (compile error) and cannot be
  moved to another logger value.
- Always `defer logger.deinit()` so a started-but-unlogged diagnostic returns its
  frame.

### `With` pins a frame for the child's entire lifetime

Forget `child.deinit()` and the pool's leak assertion (or `std.testing.allocator`)
fires. Building prefixes lazily per request copies the whole prefix each time.

### Sinks own the buffer, on every path

A custom sink that forgets `pool.put` on its error path will trip the pool's
leak assertion later, far from the bug. `defer _ =
pool.put(@constCast(buf));` is the pattern every built-in sink uses.

### A custom sink needs nothing but `write`

The drop accounting lives on the logger, so a custom sink only has to expose the
`write` method (and release `buf`). A `dropped` field is optional and only
meaningful when the sink rejects frames on its own.

### The thread-safe pool does not compose with the built-in sinks

Everything is typed against the concrete `BufferPool` =
`BufferPoolFactory(false)`. `BufferPoolFactory(true)` only helps with custom
sinks.

### `MemorySink` concatenates every frame

There is no per-record index and no framing validation; split on `0xFF`/`0xFE`
yourself, or use `verifyFrame` per frame.

### `deinit` asserts on leaked frames

`BufferPool.deinit` walks the free list and asserts it holds every frame. Under
`std.testing.allocator` a leak also fails the test. This is a feature: it turns
forgotten `put`/`deinit` calls into test failures.

### Debug-only safety nets disappear in release builds

The diagnostic `live` flag and every check that reads it are compiled out in
ReleaseFast/ReleaseSmall. A use-after-log then relies on the NULL payload
segfaulting rather than on an explicit fault.

### `zig build test` exits non-zero even on success

122/122 pass, then the `src/main.zig` test leaks its pool/sink (7 allocations).
Pre-existing and owned by a missing `deinit` in that smoke test.

### Adding a source file means touching `root.zig` twice

Re-export the declaration and add `_ = @import("new_file.zig");` to the `test`
block, or it is invisible to consumers and untested.

---

## Complete example

A program that wires a pretty renderer, logs a child record, builds a rich
diagnostic and inspects it:

```zig
const std = @import("std");
const blog = @import("blog");

fn loadConfig(logger: anytype, path: []const u8) !void {
    var diag = try logger.err_after(error.FileNotFound, .{ .path = path });
    diag = try diag.wrap_loc(@src(), "open config file", .{ .attempt = @as(u8, 2) });
    diag = try diag.with(.{ .uid = @as(u32, 42) });
    logger.warn("cannot start", .{ .err = diag });
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Pool: 4096 frames of 4 KiB. Both must be powers of two; frameSize >= 512.
    var pool: blog.BufferPool = undefined;
    try pool.init(allocator, 4096, 4096);
    defer pool.deinit();

    // Render straight to stdout.
    var fd: blog.FdWriter = undefined;
    fd.init(std.posix.STDOUT_FILENO);
    var sink: blog.PrettySink(blog.FdWriter) = undefined;
    sink.init(allocator, blog.ColorProfile.dark, &fd);
    defer sink.deinit();
    sink.options = .{ .tz_offset_seconds = 3 * 3600 };

    var logger: blog.Logger(blog.BufferPool, blog.PrettySink(blog.FdWriter)) = undefined;
    logger.init(&pool, &sink);

    logger.info("server started", .{
        .addr = "127.0.0.1:8080",
        .workers = @as(u8, 4),          // comptime_int -> u8 on the wire
        .ports = [4]u16{ 80, 443, 8080, 8443 },
        .ratio = @as(f64, 0.75),
    });

    var child = logger.With(.{ .job = "sync" });
    defer child.deinit();
    child.debug("tick", .{ .shard = @as(u32, 7) });

    try loadConfig(&logger, "/etc/app.json");

    if (logger.dropped.load(.monotonic) != 0) {
        std.debug.print("dropped {d} record(s)\n", .{logger.dropped.load(.monotonic)});
    }

    // A diagnostic built by hand, inspected before it is logged.
    var diag = try logger.err_new("disk failure", .{ .device = "/dev/sda" });
    const text = try diag.string(allocator);
    defer allocator.free(text);
    std.debug.print("diag renders as: {s} ({d} bytes payload)\n", .{ text, diag.payloadSize() });
    logger.err("io error", .{ .err = diag });
    std.debug.assert(diag.isConsumed());
}
```

For JSONL instead of a tree, swap the sink and keep everything else:

```zig
var sink: blog.JsonSink(blog.FdWriter) = undefined;
sink.init(allocator, &fd);
defer sink.deinit();
var logger: blog.Logger(blog.BufferPool, blog.JsonSink(blog.FdWriter)) = undefined;
logger.init(&pool, &sink);
```

For the raw binary log (to be rendered later by a viewer), hand any downstream
writer to `FileSink`, or `SyncWriter(FileSink)` when several threads log.