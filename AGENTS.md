# AGENTS.md

Binary logging library with **two parallel implementations of the same wire
format**: a Go library (`github.com/sirkon/blog`) and a self-contained Zig
module + CLI (`src/`). Both encode byte-for-byte compatible log records; the
Go viewer can read a Zig log and vice versa.

The repo also produces a human-readable viewer for the binary output (the
records are unreadable binary without it).

## Toolchain

Managed by `mise.toml`: **Go 1.26.2** and **Zig 0.16**. Use these exact
versions; the Zig code targets 0.16 std APIs (`std.process.Init`, `std.Io`,
`std.Io.Writer.Allocating`, `std.ArrayList.empty`) and will not compile on 0.14.

## Commands

| Task | Command |
|---|---|
| Go build | `go build ./...` |
| Go tests | `go test ./...` |
| Go vet | `go vet ./...` |
| Zig build (CLI -> `zig-out/bin/blog`) | `zig build` |
| Zig tests | `zig build test` |
| Run Zig CLI | `zig build run` |
| Benchmarks vs zerolog | `cd internal/benching && go test -bench .` |

`internal/benching` and `internal/cmd/logging` are **separate Go modules**
(own `go.mod`), so the root `go test ./...` does not touch them. `benching`
has `replace github.com/sirkon/blog => ../..`; `logging` does not and resolves
the library from the module cache.

### Known-failing checks (pre-existing, do not "fix" incidentally)

- `go test ./...` fails in the root package (`TestNewJSONWriter` golden diff)
  and in `internal/core` (`TestRegression`, `ExampleWrapError` error-text
  expectations).
- `go vet ./...` reports two warnings: `internal/core/attr_serialize.go:24`
  (8-bit shift) and `viewer_pretty_render_tree.go:41` (self-assignment).
- `zig build test` reports 122/122 tests passing but exits non-zero: the
  `src/main.zig` test leaks its pool/sink (7 allocations). Owned by
  `deinit`, not called in that test.

## Wire format (the contract both sides must honor)

A record is a self-framing byte string:

```
0xFF | CRC32C(payload) as u32 LE | 0xFE | uvarint(len(payload)) | payload
```

Payload layout, in order:

```
version u16 LE (= 1)
time    i64 LE (UnixNano)
level   u8        (10 trace, 20 debug, 30 info, 40 warn, 50 err, 60 panic)
location: 0x00, or uvarint(len(file)) | file | uvarint(line)
custom  (Go only: Logger.appendCustom, static per fork; empty in this repo)
msg     uvarint(len) | msg
prefix  (Go: Logger.With payload; Zig: Logger.With prefix)
attrs   (serialized key/value nodes)
```

CRC is **CRC32C / Castagnoli**, identical in both implementations
(`hash/crc32.Castagnoli` in Go, `src/crc32c.zig` in Zig). The Zig CRC has an
inline-asm path for x86_64 that is enabled **only in `ReleaseFast`** (a
compiler workaround) and a `crc32cx` path on aarch64; every other target falls
back to `std.hash.crc.Crc32Iscsi`. Keep the fallback working, it is what tests
run under.

`ValueKind` numbers are frozen. Go guards each value with a compile-time array
index assert in `internal/core/attr_value_kind.go`; Zig mirrors them in
`src/consts.zig`. Changing a number breaks wire compatibility and, on the Go
side, fails to compile.

Attribute values are serialized as `kind u8 | key | value`, where the key is
either a length-prefixed string or, when `kind >> 8 != 0`, a registered
predefined-key index (`PredefinedKeyCode`). The upper bits of `attr.kind`
carry that known-key code, which is why `attr_serialize.go` shifts by 8.

## Repo layout

**Go side**

- Root package `blog`: public aliases and re-exports (`Logger`, `Attr`
  constructors, `NewLogger`, `NewSyncWriter`, `LogPanic*`, level constants).
  Package split is deliberate: `internal/core` holds the implementation,
  `beer` is the public error API, and the root package is a thin facade.
- `beer/` - public structured-error API. `beer.Error` is a type alias of
  `core.Error`; `beer.New/Wrap/Just/Spec` mirror `core.NewError/WrapError/
  JustError/Spec`. Use this package in user-facing example code.
- `internal/core/` - implementation: `Logger` (record encoding via `sync.Pool`
  buffers, CRC over the payload, `WriteSyncer` output), `Attr`/`Value`
  (slog-style inline representation using `unsafe` pointers to avoid
  interfaces), the `Error` type, options, and the **viewer** (wire decoder +
  `RecordViewer`/`RecordContextVisitor` interfaces).
- Root-level `viewer_*.go` - the render-side visitors: `PrettyWriter` (tree),
  `JSONWriter` (compact JSONL), and the packed-node tree they share. Files
  suffixed `_littlendian` / `_node_littleendian` are guarded by
  `//go:build arm64 || amd64 || riscv64`.
- `internal/alchemy/` - generated 10k-call golden sample plus checked-in
  `.bin` fixtures on disk. Note `*.bin` is gitignored, so those fixtures are
  local only; regenerate with the generator below if missing.
- `internal/playground/` - manual demo (`go run ./internal/playground
  [light|dark|json]`), the reference for README output.
- `internal/cmd/zighelper/` - stdin -> pretty-rendered stdout; reads frames,
  re-aligns on partial input, and rejects trailing bytes.
- `internal/cmd/logging/` - code generator (`sirkon/gogh`) that overwrites
  `internal/alchemy/alchemy.go` with 10k randomized log calls. Run manually
  from its own directory (`go run .`); it `chdir`s to the repo root itself.

**Zig side** (`src/`)

- `root.zig` - the module entry point. It **must** re-export every public
  declaration (module consumers only see declarations reachable from here) and
  its `test` block imports all modules so `zig build test` covers them; a new
  source file needs to be added there too.
- `logger.zig` - the logger engine, comptime-parameterized over `Pool` and
  `Sink` (`Logger(Pool, Sink)`), record encoding, and host header writes.
  Level methods take a **comptime** `msg`.
- `error.zig` - `Diag(Pool)` rich diagnostics, the Zig counterpart of Go's
  `*Error`. Also defines `BufferPool`/`Error` aliases, the terminal
  `deadPayload` (NULL pointer) and `fault()`.
- `writer.zig` - `BufferPool`, sinks (`MemorySink`, `FileSink`, `SyncWriter`,
  `PrettySink`, `JsonSink`, `FdWriter`) and `verifyFrame`. The header comment
  documents the sink ownership contract precisely.
- `buffer_pool.zig` - `BufferPool(threadsafe)` free-list pool with heap
  fallback and leak assertion in `deinit`.
- `consts.zig` - wire vocabulary (`version`, `logLevel`, `ValueKind`) and the
  comptime-minimal-integer helpers (`MinimalInt`, `minimalInt`, `intKind`).
- `encoding.zig` / `decoding.zig` - comptime-driven record writer (`Frame`)
  and varint decoding. `getStructEncodedSize` unwinds the attribute type at
  comptime to precompute the exact byte size, so **attributes must be an
  anonymous struct of supported field types**; unsupported types are a
  `@compileError`.
- `viewer.zig` - Zig port of the Rust reference viewer parse path: wire payload
  -> flat `Node` array + `ParsedRecord`. This is the *canonical* Zig parse;
  `render.zig` renders it.
- `render.zig` - tree/JSON renderer (`Renderer`, `ColorProfile`,
  `RenderOptions`) plus the golden fixtures that mirror
  `blog-rs/src/testdata/*.bin`.
- `jsonsink.zig` - compact JSONL sink; uses the `jsonescape` dependency.
- `main.zig` - CLI. **Current state:** the working tree replaced the real CLI
  (arg parsing, `--json`, `--dark/--light/--no-color`, `--tz-offset`, file/`-`
  stdin handling) with a single smoke test that renders one hardcoded record.
  The uncommitted `git show HEAD:src/main.zig` version has the full CLI, and
  README still advertises `blog --json`. Restore from HEAD before relying on
  CLI behavior.
- `mutex.zig` - thin libc `pthread_mutex_t` wrapper. Requires `link_libc`
  (already set in `build.zig` for the module).

## Zig-specific conventions and gotchas

- **Sink contract**: `pub fn write(self: *Self, pool: *BufferPool, buf:
  []const u8) WriteError!usize` takes **ownership** of `buf` and must return
  it with `pool.put(@constCast(buf))` on every path, including failure.
  Asynchronous sinks would defer the `put`; every sink here is synchronous.
- **Downstream writer contract**: any struct with `pub fn write(self: *Writer,
  bytes: []const u8) E!usize` can back `FileSink`/`SyncWriter`/`PrettySink`/
  `JsonSink`. The factories `assertWriter` this at comptime, so a wrong
  signature is a compile error, not a runtime one.
- `BufferPoolFactory` is `buffer_pool.BufferPool` (a comptime `fn(bool) type`);
  `blog.BufferPool` is the concrete `BufferPoolFactory(false)`. `init` rejects
  non-power-of-two `size`, and `frameSize < 512` or non-power-of-two.
- `deinit` asserts every frame is back in the free list; leaked records
  surface as a test failure.
- **Diagnostics are never allocator-created** and are terminal once logged:
  `logger.err_after`/`err_new` (+ `_loc`/`_log` variants) hand out pointers
  into a fixed `maxLiveDiagnostics = 8` slot array inside the logger. Exceeding
  it panics. Log each diagnostic exactly once; `logger.deinit()` (and each
  child's) calls `releaseDiagnostics` to return unlogged ones.
- A diagnostic passed to `Logger.With` is rejected at comptime
  (`hasDiagnostics`); prefixes are copied per record.
- `writeRecord` consumes diagnostics *before* entering the sink, and a failed
  or too-large record is dropped (bumping the logger's own `dropped`) rather
  than panicking. A sink with its own `dropped` field counts only the frames it
  rejects itself.
- In Debug/ReleaseSafe a diag carries a `live` flag and faults on misuse; in
  ReleaseFast/ReleaseSmall the checks and the field are compiled away, relying
  on the NULL terminal payload to segfault instead.
- No `std.Io` type is named in `writer.zig` on purpose; concretization happens
  at the call site (CLI passes `FdWriter`, tests pass `std.Io.Writer`).

## Go-specific conventions and gotchas

- `Attr` uses an unexported `kind` plus an `unsafe`-pointer `Value`;
  the constructor functions include a `_ = key[0]` guard so a literal empty key
  panics early. Keep keys non-empty.
- `Bytes` picks `ValueKindString` when the payload is printable/whitespace and
  `ValueKindSliceUint8` otherwise - the same bytes can encode as either kind.
- `core.Error` tracks a `sufficient` flag: once a foreign wrapper is
  interleaved with `*Error` layers the payload alone can no longer reconstruct
  the message, so `Error()` walks the payload for node text and stitches the
  foreign text back in. This logic is delicate and directly mirrored by
  `src/error.zig`; change both together.
- `beer.InsertLocationsOn/Off` (default off) toggles `runtime.Caller` capture
  inside `New/Wrap/Just`. It is debug-only and test code turns it off in
  `TestMain`.
- `LogPanic` gzips the stack trace and stores it as the message; the viewers
  gunzip and prefix each line with `....`.
- The Go viewers are stateful and mutex-guarded; a `PrettyWriter`/`JSONWriter`
  is meant to be the `WriteSyncer` handed to `NewLogger`.

## Testing patterns

- Go: standard `testing`, plus `github.com/alecthomas/assert/v2`. Root-package
  tests exercise the viewer by encoding records with a logger and asserting on
  rendered text/JSON; `internal/core` has `Example*` tests that double as
  golden error-text checks.
- Benchmarks in `bench_test.go` write into temp files (`os.TempDir()`) or
  no-op writers; a 472 MB `beer.bin` may appear in the repo root from them and
  is gitignored.
- Zig: `test` blocks live next to the code they cover and are pulled in via
  `root.zig`. `logger.zig` holds a byte-exact golden frame test (pinned
  timestamp 0x0102030405060708) that freezes the wire format; `render.zig` and
  `jsonsink.zig` build fixtures through `viewer.PB` helpers. Use
  `std.testing.allocator` so leaks fail the build.

## Reference material

- `README.md` - public usage, the Zig module example, viewer output samples,
  and benchmark tables (the source of truth for user-facing claims).
- `.contexts/JSONESCAPE.md` - API notes for the `jsonescape` Zig dependency
  (including the `6 * len + 64` destination-capacity rule) used by
  `jsonsink.zig`.
- `internal/benching/RESULTS.md` - blog vs zerolog numbers.
- The Zig viewer/renderer is a port of a Rust reference implementation
  (`blog-rs`); `src/viewer.zig` and `src/render.zig` cite the exact Rust
  modules and note the one deliberate behavior drift (`needsTree` thresholds).