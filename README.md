# blog

Binary logging.

## Installation.

```shell
go get github.com/sirkon/blog
```

## Logging output.

Logging output is binary and cannot be viewed directly. But there's a viewer for development where you can see
them:

```
2026-03-14 05:44:40.284 TRACE ./blog/internal/playground/main.go:53 trace check  {}
2026-03-14 05:44:40.284 DEBUG ./blog/internal/playground/main.go:54 debug check  {}
2026-03-14 05:44:40.284 INFO  ./blog/internal/playground/main.go:55 no errors  {"text": "Hello World!", "int": 12}
2026-03-14 05:44:40.284 WARN  ./blog/internal/playground/main.go:59 warning check
└─ err: EOF
2026-03-14 05:44:40.284 ERROR ./blog/internal/playground/main.go:60 test
├─ text: Hello World!
├─ time: 2026-03-14T05:44:40.284283+03:00
├─ math
│  ├─ pi: 3.141592653589793
│  ├─ e: 2.718281828459045
│  └─ combo: 3.141592653589793, 2.718281828459045
├─ duration: 406µs
├─ err: EOF
├─ words: "I", "am", "waiting", "for", "the", "spring"
└─ err-with-ctx
   ├─ @context
   │  ├─ WRAP: wrap 1
   │  │  ├─ @location: ./blog/internal/playground/main.go:46
   │  │  └─ tag: tag1
   │  ├─ CTX
   │  │  ├─ @location: ./blog/internal/playground/main.go:47
   │  │  └─ key: 12
   │  ├─ WRAP: wrap 2
   │  │  ├─ @location: ./blog/internal/playground/main.go:48
   │  │  └─ bool: true
   │  └─ WRAP: wrap 3
   │     ├─ @location: ./blog/internal/playground/main.go:50
   │     ├─ tag: "quoted tag value"
   │     └─ bytes: base64.AQID
   └─ @text: foreign wrap 2: wrap 3: foreign wrap 1: wrap 2: wrap 1: EOF
2026-03-14 05:44:40.285 PANIC ./blog/logger.go:31 {"recovered": 0}
.... goroutine 1 [running]:
.... runtime/debug.Stack()
.... 	/Users/d.cheremisov/.local/share/mise/installs/go/1.26.0/src/runtime/debug/stack.go:26 +0x64
.... main.main.func1()
.... 	./blog/internal/playground/main.go:42 +0x58
.... panic({0x100c996c0?, 0x100bc33f8?})
.... 	/Users/d.cheremisov/.local/share/mise/installs/go/1.26.0/src/runtime/panic.go:860 +0x12c
.... main.main()
.... 	./blog/internal/playground/main.go:75 +0xb5c
```

for the code in [playground](./internal/playground/main.go). Well, it is actually better in here, with ANSI
coloring.

## Usage.

The library can (and should) use local [blog/beer](./beer) errors library for error processing.
Because of:

1. Superior structured context you can have.
2. Superior performance over "standard" error processing as a text.

It has its specifics though, where it follows the protocol:

- If you func have 2+ points of error return, you wrap any outer error with an annotation.
- You either log an error or return it. Never both. You won't lose any detail – you can always append a context to an
  error itself the same way you would do this for logging.
- You never reuse an error instance. You only log or return or check for details through `errors.Is`, `errors.AsType`,
  `beer.IsSpec`, `beer.AsSpec`. The last two are an alternative approaches to wrapping which allows using `beer.Error`
  as a domain specific one directly. By "specking" it with a certain typed payload.

## Performance.

Since `beer.Error` provides nice rich context I use `fmt.Errorf` with text context which also includes it through
text interpolation. And it obviously got slower from it. The only alternative is to log with structured context
at each return, but it is slower as you can see in [sirkon/error](https://github.com/sirkon/errors) benchmarks.
Or, you can pass an error without any context:

### System.

| goos  | goarch | cpu                                  | pkg                    |
|-------|--------|--------------------------------------|------------------------|
| linux | amd64  | 12th Gen Intel(R) Core(TM) i7-12700K | github.com/sirkon/blog |

### Results

## Results

| Benchmark                               | Iterations | ns/op       | B/op     | allocs/op   |
|-----------------------------------------|------------|-------------|----------|-------------|
| BenchmarkBlog                           | 1628018    | 742.5 ns/op | 632 B/op | 3 allocs/op |
| BenchmarkTxtContext                     | 658639     | 1877 ns/op  | 491 B/op | 9 allocs/op |
| BenchmarkTxtNoContext                   | 1000000    | 1250 ns/op  | 208 B/op | 6 allocs/op |
| BenchmarkBlogTxtContext                 | 1000000    | 1198 ns/op  | 483 B/op | 9 allocs/op |
| BenchmarkBlogTxtNoContext               | 1607630    | 747.5 ns/op | 201 B/op | 6 allocs/op |
| BenchmarkBufferWriteCost/beer           | 4492250    | 265.7 ns/op | 632 B/op | 3 allocs/op |
| BenchmarkBufferWriteCost/txt-no-context | 3464002    | 344.4 ns/op | 201 B/op | 6 allocs/op |
| BenchmarkWriteCost                      | 3219346    | 367.5 ns/op | —        | —           |

Remember, we have something like this for "TxtContext"

```json
{
  "time": "2026-02-21T23:29:56.447285+03:00",
  "level": "ERROR",
  "msg": "failed to do something",
  "err": "context pi[3.141592653589793] e[2.718281828459045]: check error count[333] is-wrap-layer[true]: this is an error bytes[[1 2 3]] text-bytes[Hello World!]"
}
```

and

```json
{
  "time": "2026-02-21T23:29:56.447285+03:00",
  "level": "ERROR",
  "msg": "failed to do something",
  "err": "context: check error: this is an error"
}
```

vs

Blog having something like this

```
2026-03-14 08:00:14.366 ERROR failed to do something  
└─ err
   ├─ @context
   │  ├─ NEW: this is an error
   │  │  ├─ @location: ./blog/internal/playground/main.go:74
   │  │  ├─ bytes: base64.AQID
   │  │  └─ text-bytes: Hello World!
   │  ├─ WRAP: check error
   │  │  ├─ @location: ./blog/internal/playground/main.go:77
   │  │  ├─ count: 333
   │  │  └─ is-wrap-layer: true
   │  └─ CTX
   │     ├─ @location: ./blog/internal/playground/main.go:80
   │     ├─ pi: 3.141592653589793
   │     └─ e: 2.718281828459045
   └─ @text: check error: this is an error
```

In other words, we store more information and manage to save 0.5μs compared to an info which is basically useless. And
save 1μs vs an approach that tries to mimic this rich structure but is still lacks some info and loses in
representation. And `BenchmarkBlogTxtNoContext` vs `BenchmarkBlog` shows why you better stick to `beer.Error`: it
has all that nice info, and it is still built faster than a simple wrap bringing no details.

Some more benching against Zerolog with both JSON and CBOR encoding is [here](./internal/benching/RESULTS.md)