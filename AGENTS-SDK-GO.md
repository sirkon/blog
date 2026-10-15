# blog Go SDK usage reference

Practical usage guide for the **public** Go surface of this module. Only two
packages are importable by consumers:

- `github.com/sirkon/blog` (package `blog`) - logger, attribute constructors,
  writers.
- `github.com/sirkon/blog/beer` (package `beer`) - the structured error API.

Everything under `internal/` is implementation detail and is **not** part of the
contract, even where the root package re-exports types from it. The Zig module
(`src/`) is a separate implementation of the same wire format and is out of
scope here.

---

## Table of contents

- [Install](#install)
- [Quick start](#quick-start)
- [Logger reference](#logger-reference)
- [Attribute reference](#attribute-reference)
- [Writers and output](#writers-and-output)
- [Panic logging](#panic-logging)
- [Structured errors (`beer`)](#structured-errors-beer)
- [Sentinels and standard error interop](#sentinels-and-standard-error-interop)
- [Error handling protocol](#error-handling-protocol)
- [Gotchas](#gotchas)
- [Complete example](#complete-example)

---

## Install

```shell
go get github.com/sirkon/blog
```

```go
import (
    "github.com/sirkon/blog"
    "github.com/sirkon/blog/beer"
)
```

Requires Go >= 1.26 (generic `errors.AsType` is used). See `mise.toml`.

---

## Quick start

```go
package main

import (
    "context"
    "os"

    "github.com/sirkon/blog"
    "github.com/sirkon/blog/beer"
)

func main() {
    // 1. Pick an output. PrettyWriter renders the binary records for humans.
    //    Use blog.NewJSONWriter(os.Stdout) for JSONL instead.
    w := blog.NewPrettyWriter(os.Stdout).WithDarkTerminal()

    // 2. Create the logger. It is cheap to create; keep one per program.
    log, err := blog.NewLogger(
        w,
        blog.OptionLogLocations(),            // record file:line of each call
        blog.OptionLogFromLevel(blog.LevelInfo), // drop trace/debug
    )
    if err != nil {
        panic(err)
    }

    ctx := context.Background()

    log.Info(ctx, "server started", blog.Str("addr", ":8080"))

    // 3. Errors carry structured context; log them with blog.Err.
    if err := loadConfig("app.json"); err != nil {
        log.Error(ctx, "cannot start", blog.Err(err))
    }
}

func loadConfig(path string) error {
    err := openFile(path)
    if err != nil {
        return beer.Wrap(err, "open config file").Str("path", path)
    }
    return nil
}
```

Running this writes **binary** frames to `os.Stdout`. That is expected: the
`PrettyWriter`/`JSONWriter` decode them as they pass through, so what you see is
human-readable text. A raw file sink would need a viewer (`internal/cmd/zighelper`
reads a binary stream and pretty-renders it, useful for `docker logs` pipelines).

---

## Logger reference

`blog.Logger` is an alias for an internal type; it has no exported fields and
must be created with `blog.NewLogger`.

```go
func NewLogger(w core.WriteSyncer, options ...core.OptionApplier) (*Logger, error)
```

- `w` is any `io.Writer` (the parameter type is an internal interface whose only
  method is `Write`, so `io.Writer`, `*os.File`, `bytes.Buffer`, a sink, or a
  `PrettyWriter`/`JSONWriter` all satisfy it).
- The writer **must be safe for concurrent use**; every `Write` call gets a fully
  framed record, and multiple goroutines may log concurrently. Use
  `blog.NewSyncWriter(w)` if `w` is not concurrency-safe itself.
- `NewLogger` returns an error only when an option fails to apply (e.g. an
  invalid level in `OptionLogFromLevel`), so a failure is a programming error.

### Levels

```go
log.Trace(ctx, msg, attrs...)  // blog.LevelTrace   (10)
log.Debug(ctx, msg, attrs...)  // blog.LevelDebug   (20)
log.Info(ctx, msg, attrs...)   // blog.LevelInfo    (30)
log.Warn(ctx, msg, attrs...)   // blog.LevelWarning (40)
log.Error(ctx, msg, attrs...)  // blog.LevelError   (50)

// Panic (60) is only reachable via blog.LogPanic, there is no log.Panic method.
```

Exported constants:

```go
blog.LevelTrace
blog.LevelDebug
blog.LevelInfo
blog.LevelWarning   // note: "Warning", not "Warn"
blog.LevelError
```

There is **no** exported panic level constant, and `OptionLogFromLevel` rejects
anything outside trace..error. The numeric values are frozen and mirrored by the
Zig side; do not rely on them beyond `OptionLogFromLevel`.

### Options

```go
blog.OptionLogLocations()            // include file:line of the logging call
blog.OptionLogFromLevel(blog.LevelDebug) // minimum level to emit
```

`OptionLogFromLevel` takes effect *before* any work is done: calls below the
threshold return immediately without touching the buffer pool.

### Child logger

```go
child := log.With(blog.Str("job", "sync"), blog.Int("shard", 3))
child.Info(ctx, "tick") // emits job=sync, shard=3 on every record
```

`With` returns a **new** logger value (a copy) whose prefix is prepended to every
record. The prefix is copied and then extended with each `With`, so building a
deep chain copies the whole prefix each time. For hot paths stamp the immutable
fields once at startup and pass per-call context as explicit attrs.

`context.Context` is accepted but unused by the core logger. Passing `nil` works
at runtime, but linters will flag it (`SA1012`); prefer `context.Background()`
or `context.TODO()`. It is a hook for forks that override `appendCustom`.

---

## Attribute reference

`blog.Attr` is an alias to an internal struct with **unexported** fields, so an
`Attr` cannot be constructed with a composite literal. Always use a constructor.

| Constructor | Kind on the wire | Notes |
|---|---|---|
| `blog.Bool(key, v)` | bool | |
| `blog.Time(key, v)` | time | stored as `UnixNano`; monotonic clock and location are lost |
| `blog.Duration(key, v)` | duration | stored as int64 nanoseconds |
| `blog.Int(key, v)` / `Int8/16/32/64` | int64 / int8.. | `Int` and `Int64` both map to int64 |
| `blog.Uint(key, v)` / `Uint8/16/32/64` | uint64 / uint8.. | `Uint` and `Uint64` both map to uint64 |
| `blog.Flt32(key, v)` / `blog.Flt64(key, v)` | float32/float64 | IEEE bits |
| `blog.Str(key, v)` | string | |
| `blog.Stg(key, v)` | string | calls `v.String()` **eagerly**, at attr creation |
| `blog.Bytes(key, v)` | string **or** []byte | see gotcha below |
| `blog.Error(key, err)` | error node | embeds a `*beer.Error`, or the raw error text |
| `blog.Err(err)` | error node, key `"err"` | shortcut for `blog.Error("err", err)` |
| `blog.Group(key, attrs...)` | group | nested tree node |

Slices (all map to the corresponding slice kind):

```go
blog.Bools(key, []bool)
blog.Ints(key, []int)        // -> []int64
blog.Int8s/Int16s/Int32s/Int64s
blog.Uints(key, []uint)      // -> []uint64
blog.Uint8s/Uint16s/Uint32s/Uint64s
blog.Flt32s/Flt64s
blog.Strs(key, []string)
```

### Grouping

```go
log.Info(ctx, "request",
    blog.Group("http",
        blog.Str("method", "GET"),
        blog.Int("status", 200),
    ),
    blog.Group("db",
        blog.Duration("took", 3*time.Millisecond),
    ),
)
```

### Keys

- Keys must be **non-empty**. Every constructor does `_ = key[0]`, so an empty
  literal key panics immediately rather than producing a corrupt record.
- `blog.Err` is the one constructor without a key parameter (it fixes `"err"`).
- Keys longer than 16 MiB are truncated at serialization; this is a safety net,
  not a feature.

---

## Writers and output

Two renderers are exported. Both are `io.Writer`s intended to be handed directly
to `NewLogger`; both are **mutex-guarded** and safe for concurrent use, and both
decode the binary frame inline before writing text.

### PrettyWriter

```go
func NewPrettyWriter(w io.Writer) *PrettyWriter
func (g *PrettyWriter) WithDarkTerminal() *PrettyWriter
func (g *PrettyWriter) WithLightTerminal() *PrettyWriter
func (g *PrettyWriter) Write(p []byte) (int, error)
```

Human-readable tree output. No ANSI colors unless you opt in:

```go
w := blog.NewPrettyWriter(os.Stdout)          // plain
w.WithLightTerminal()                          // colored for a light background
w.WithDarkTerminal()                           // colored for a dark background
```

Both `With*` methods mutate and return the same pointer, so they are
frequently chained. Pick one before handing the writer to the logger.

### JSONWriter

```go
func NewJSONWriter(w io.Writer) *JSONWriter
func (g *JSONWriter) Write(p []byte) (int, error)
```

One compact JSON object per record (JSONL). A `panic` record expands into one
line per stack frame. This is the machine-readable counterpart of
`PrettyWriter`:

```json
{"time":"2026-03-14T05:44:40.284283+03:00","level":"ERROR","loc":{"file":"main.go","line":63},"msg":"test","err":"EOF"}
```

Binary `[]byte` values are base64-encoded; `time`/`duration` are rendered as
strings; errors become a nested `@context` object plus `@text`.

### Raw output

If you need the binary frames themselves (the actual log file), pass any plain
`io.Writer` - `*os.File`, a buffered writer behind `blog.NewSyncWriter`, a
network sink - to `NewLogger`. There is no exported "raw viewer"; reading binary
logs back is a separate concern (see `internal/cmd/zighelper` for the pattern:
scan `0xFF | crc32 u32 | 0xFE | uvarint(len) | payload` frames and feed each
frame to `PrettyWriter.Write`).

### SyncWriter

```go
func NewSyncWriter(w io.Writer) core.WriteSyncer
```

Wraps any `io.Writer` in a mutex so it can back a `Logger`. Not needed for
`PrettyWriter`/`JSONWriter` (they lock internally) nor for a writer that is
already concurrency-safe.

---

## Panic logging

```go
func LogPanic(ctx context.Context, log *Logger, stacktrace []byte, info Attr)
func LogPanicInfo(v any) Attr
```

`LogPanic` writes a `PANIC`-level record whose message is the **gzip-compressed**
stack trace. `LogPanicInfo` converts a `recover()` value into an attribute
(everything falls back to `%#v`), so non-error panics are still useful. Both
viewers transparently gunzip the message and prefix each frame with `....`.

Standard recovery boilerplate:

```go
defer func() {
    r := recover()
    if r == nil {
        return
    }
    info := blog.LogPanicInfo(r)
    blog.LogPanic(context.Background(), log, debug.Stack(), info)
}()
```

`LogPanic` is the **only** way to emit at panic level; there is no
`log.Panic(...)` method and `OptionLogFromLevel` cannot be set to panic.

---

## Structured errors (`beer`)

`beer.Error` is a type alias (so it *is* the same type the logger understands)
implementing `error`. It carries structured key/value context per layer instead
of only a flattened message.

```go
func New(msg string) *Error
func Newf(format string, a ...any) *Error
func Wrap(err error, msg string) *Error
func Wrapf(err error, format string, a ...any) *Error
func Just(err error) *Error
func Spec(err error, spec any) *Error
func AsSpec[T any](err error) (T, bool)
func IsSpec[T any](err error) bool
```

- `New` starts a fresh error.
- `Wrap` adds a labelled layer ("wrap node").
- `Just` adds an unlabelled context layer (`CTX`) without a message.
- `Spec` attaches a typed domain payload; see below.

### Adding context

Every layer exposes the same fluent setters as the attribute constructors:

```go
err := beer.New("disk failure").
    Str("device", "/dev/sda").
    Bytes("raw", sector).
    Bool("retryable", false)

err = beer.Wrap(err, "read sector").
    Int64("lba", 4096).
    Duration("took", elapsed)

err = beer.Just(err).
    Flt64("threshold", 0.75)

log.Error(ctx, "io error", blog.Err(err))
```

Available methods on `*beer.Error` (all return the receiver): `Bool`, `Time`,
`Duration`, `Int`, `Int8..Int64`, `Uint`, `Uint8..Uint64`, `Flt32`, `Flt64`,
`Str`, `Stg`, `Bytes`, and the slice forms `Bools`, `Ints`, `Int8s`, `Int16s`,
`Int32s`, `Int64s`, `Uints`, `Uint8s`, `Uint16s`, `Uint32s`, `Uint64s`,
`Flt32s`, `Flt64s`, `Strs`.

### Rendering

`Error()` reconstructs `"outer: ... : inner"` from the serialized payload. When
foreign (non-`beer`) wrappers are interleaved the payload can no longer rebuild
the message on its own, and the type records that in a `sufficient` flag; in
that case the foreign wrapper's own `Error()` text is stitched back in. You do
not manage this - it is internal - but it explains why the same chain can render
slightly differently depending on where `fmt.Errorf` was used:

```text
trivial: check error 3: check error 2: check error 1: error
typical: check error 3: check error 2: check error 1: root check: EOF
complex: check error 3: check error 2: check error 1: root check: EOF
```

### Specs (domain-specific tagging)

Rather than defining a custom error type (which loses the context machinery),
attach a typed value:

```go
var ErrNotFound = beer.NewSentinel("not found")

type NotFound struct{ Key string }

err := beer.Wrap(ErrNotFound, "lookup").Str("table", "users")
err = beer.Spec(err, NotFound{Key: "u42"})

if beer.IsSpec[NotFound](err) {
    spec, _ := beer.AsSpec[NotFound](err) // spec.Key == "u42"
}

if errors.Is(err, ErrNotFound) { // sentinel still reachable through the chain
    // ...
}
```

`AsSpec[T]` walks the chain (including foreign wrappers) and returns the first
value that type-asserts to `T`; `IsSpec[T]` compares by `reflect.TypeOf`, so
prefer `IsSpec` when the spec is not comparable or when you only need a yes/no.
Both search specs attached at any depth.

---

## Sentinels and standard error interop

```go
func NewSentinel(msg string) error
func NewSentinelf(format string, a ...any) error
func Is(err error, target error) bool
func AsType[E error](err error) (E, bool)
```

`NewSentinel` returns a plain (non-`beer`) error so it stays cheap and usable as
a package-level marker. Reach it through a `beer` chain with `errors.Is` /
`beer.Is`; extract a typed error anywhere in the chain with `errors.AsType` /
`beer.AsType`.

`beer.Is` and `beer.AsType` are thin mirrors of the stdlib functions and exist
mostly for symmetry; the stdlib versions work identically on these errors.

---

## Error handling protocol

The library is opinionated. Follow these rules:

1. **Wrap at each return site when a function has 2+ error returns.** Add the
   annotation and any useful context as attrs.
2. **Either log an error or return it, never both.** You never lose detail: a
   returned error can be annotated exactly like a log record, and the logger
   renders the whole chain when it is finally logged.
3. **Never reuse an error instance.** Log it, return it, or inspect it
   (`errors.Is`, `errors.AsType`, `beer.IsSpec`, `beer.AsSpec`) - then stop
   touching it. See the aliasing gotcha below for why.
4. **Prefer `beer.Error` over `fmt.Errorf` for context.** `fmt.Errorf` text
   interpolation produces a flat string; `beer` produces a tree the viewer
   renders as nested nodes.

---

## Gotchas

### `Wrap`/`Just`/`Spec` mutate and return the same pointer

When the input is already a `*beer.Error`, `Wrap` appends to its payload and
returns **the same pointer**, not a copy:

```go
a := beer.New("boom")
b := beer.Wrap(a, "layer")

a == b      // true  -- same instance
a.Error()   // "layer: boom"  -- a changed too
```

So `err = beer.Wrap(err, "...")` is fine, but keeping the previous value around
expecting it unchanged is not. This is the mechanical reason for rule 3 above.
(A foreign error, or a `*beer.Error` reached through a foreign wrapper, does
produce a new instance; the in-place path is specifically the direct `*Error`
case.)

### `errors.Is` against a `*beer.Error` target always returns false

`(*beer.Error).Is` deliberately returns `false` when the target is a
`*beer.Error`:

```go
// Do NOT do this:
if errors.Is(err, otherBeerErr) { ... } // always false if otherBeerErr is *beer.Error

// Do one of these instead:
if beer.IsSpec[SomeTag](err) { ... }
if errors.Is(err, mySentinel) { ... } // sentinel is a plain error, works
```

`Unwrap` and `As` work normally, so `errors.AsType[*beer.Error]` and
`errors.Is(err, io.EOF)` behave as expected.

### Keys must be non-empty

All attr constructors panic on an empty literal key (a deliberate early
`key[0]` guard). Dynamic keys that can be empty must be validated or defaulted
by the caller.

### `Attr` cannot be built by hand

The type has unexported fields. Use the constructors. Its `Kind()` method returns
an internal `ValueKind` type that consumers **cannot name** (it lives in
`internal/core`), so treat `Kind()` as debugging-only.

### `blog.Bytes` may encode as a string *or* as `[]byte`

If the payload is all printable runes / whitespace it is encoded as a string;
otherwise as a byte slice (rendered base64). The same Go value can therefore
appear as `"abc"` or `"YWJj"` depending on content. Do not rely on
`blog.Bytes` always producing a byte-slice rendering.

### `blog.Time` drops monotonic time and location

The value is stored as `UnixNano()` and reconstructed with `time.Unix(0, n)`,
i.e. in local time. Round-trip equality with the original `time.Time` is not
guaranteed.

### `blog.Stg` and `blog.Error` evaluate eagerly

`Stg` calls `String()` when the attribute is created, and `Error` captures the
foreign error's text at attribute creation. Do not use them inside a level that
may be filtered out if the call is expensive - the level check happens in
`logLevel`, but attribute construction happens at the call site, i.e. **before**
the call.

### Attribute construction cost is paid even when the level is filtered

Because attrs are function arguments, they are built before `Info`/`Debug` sees
them. Guard hot debug paths yourself:

```go
if log.Enabled(blog.LevelDebug) { ... } // NOT available: no such method
```

There is no `Enabled` method; wrap verbose logging in your own `if` on a level
variable you keep in the application, or accept the construction cost.

### Global location capture is not thread-safe

`beer.InsertLocationsOn()` / `beer.InsertLocationsOff()` flip a package-level
`bool` with no synchronization, and `LogPanic`/`New`/`Wrap` read it from
arbitrary goroutines. Set it once, during init, before any logging. It is
**off by default** and intended for debugging only - it adds a `runtime.Caller`
to every error construction and inflates payloads. Tests turn it off in
`TestMain`.

### Viewers are stateful and not reusable across goroutines manually

`PrettyWriter`/`JSONWriter` keep internal parse state and guard it with their own
mutex. Do not call their `Write` with a frame you built yourself and expect it to
be interleaved safely with records coming from a logger sharing the same writer -
just hand the writer to the logger. Never copy a writer value by dereferencing it
(`*w`), the embedded mutex must not be copied.

### Write errors are swallowed inside the logger

If the configured writer's `Write` fails, `logLevel` prints a diagnostic to
`os.Stdout` (via `fmt.Printf`) and continues; the logging call does not report
the failure. Monitor your sink separately. Likewise the renderers print to
`os.Stderr` on their own write failure.

### Log records are not guaranteed time-ordered

Two goroutines may serialize concurrently, so a record started earlier can land
later. Sort by the embedded timestamp if ordering matters to you.

### Size and pooling knobs are internal

There is no exported buffer size, pool size, or "max record size" option. Records
up to 64 KiB are retained in the pool; larger buffers are dropped. Keep individual
records well under that to stay allocation-free.

---

## Complete example

A runnable program using the whole public surface:

```go
package main

import (
    "context"
    "errors"
    "fmt"
    "io"
    "os"
    "runtime/debug"
    "time"

    "github.com/sirkon/blog"
    "github.com/sirkon/blog/beer"
)

var ErrConfigMissing = beer.NewSentinel("config missing")

type BadField struct{ Name string }

func main() {
    log, err := blog.NewLogger(
        blog.NewPrettyWriter(os.Stdout).WithDarkTerminal(),
        blog.OptionLogLocations(),
        blog.OptionLogFromLevel(blog.LevelTrace),
    )
    if err != nil {
        panic(err)
    }

    defer func() {
        if r := recover(); r != nil {
            blog.LogPanic(context.Background(), log, debug.Stack(), blog.LogPanicInfo(r))
        }
    }()

    ctx := context.Background()

    log.Info(ctx, "starting",
        blog.Str("version", "1.0.0"),
        blog.Time("since", time.Now()),
    )

    child := log.With(blog.Str("component", "loader"))
    if err := load(child, ctx, "app.json"); err != nil {
        // Logged once, here, at the edge. Not returned further.
        child.Error(ctx, "loading failed", blog.Err(err))
    }
}

func load(log *blog.Logger, ctx context.Context, path string) error {
    if path == "" {
        return beer.Wrap(ErrConfigMissing, "empty path").Str("field", "path")
    }

    data, err := read(path)
    if err != nil {
        err = beer.Wrap(err, "read file").
            Str("path", path).
            Int("bytes", len(data))
        return beer.Spec(err, BadField{Name: "size"})
    }

    log.Debug(ctx, "parsed", blog.Int("bytes", len(data)))
    return nil
}

func read(path string) ([]byte, error) {
    switch path {
    case "app.json":
        return []byte(`{"ok":true}`), nil
    case "empty.json":
        return nil, io.EOF
    case "bad.json":
        return nil, fmt.Errorf("unexpected token at %d", 3) // foreign error
    default:
        return nil, os.ErrNotExist
    }
}
```

And the consumer side of the spec:

```go
err := load(log, ctx, "empty.json") // pretend this failed

// T is the exact type passed to beer.Spec. Here: the value type BadField.
if bad, ok := beer.AsSpec[BadField](err); ok {
    fmt.Println("bad field:", bad.Name)
}
if beer.IsSpec[BadField](err) {
    // same question, no value needed
}
if errors.Is(err, ErrConfigMissing) {
    // the sentinel is still reachable through the beer chain
}
```

---

## Module layout (for orientation)

| Path | Role |
|---|---|
| `blog` (root) | Public facade: `Logger`, `NewSyncWriter`, attr constructors, `PrettyWriter`, `JSONWriter`, `LogPanic*`, level constants |
| `blog/beer` | Public structured-error API |
| `internal/core` | Implementation: logger engine, `Attr`/`Value`, `Error`, viewer |
| `internal/playground` | Manual demo (`go run ./internal/playground [light|dark|json]`) - the reference for README output |
| `internal/cmd/zighelper` | stdin binary stream -> pretty stdout; shows how to consume raw logs |
| `internal/benching` | Separate module with zerolog comparison benchmarks |