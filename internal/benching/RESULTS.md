# Bench blog vs zerolog.

I do this testing with buffering output emulation when the syscall cost is shared by numerous
buffer writes. I ignore the syscall altogether and just make a memcpy of payload built into
a buffer.

## Against zerolog with CBOR.

**System**

| goos   | goarch | cpu          | pkg      |
|--------|--------|--------------|----------|
| darwin | arm64  | Apple M4 Pro | benching |

**Results**

| Benchmark                           | Iterations | ns/op       | B/op     | allocs/op    |
|-------------------------------------|------------|-------------|----------|--------------|
| BenchmarkBinLog/short               | 26555036   | 45.08 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/mid                 | 24984579   | 46.58 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/longer              | 23299273   | 51.65 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/long                | 19194932   | 62.90 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/escape              | 27088672   | 43.99 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/short              | 20595789   | 58.59 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/mid                | 19807018   | 60.85 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/longer             | 19340176   | 62.49 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/long               | 18328060   | 66.77 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/escape             | 19671740   | 59.85 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/blog    | 8719630    | 137.7 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/zerolog | 10623201   | 112.3 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/blog               | 19002010   | 63.08 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/zerolog            | 16671460   | 71.35 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealErrorLog/blog          | 5689182    | 207.3 ns/op | 592 B/op | 2 allocs/op  |
| BenchmarkRealErrorLog/zerolog       | 2130339    | 558.1 ns/op | 832 B/op | 14 allocs/op |
| BenchmarkBinLogCtx3                 | 3005066    | 405.9 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLogCtx3                | 2924299    | 409.5 ns/op | 0 B/op   | 0 allocs/op  |

Looks nice, right? Quicker than top of the line lib. Unfortunately, not so nice on Intel, meaning the target platform.
No, it is quick here as well. But the CRC32 thing I compute for reliability slows things down a bit:

```shell
❯ go test -bench=. -cpu 1  -tags binary_log | benchfmt md
```

**System**

| goos  | goarch | cpu                                  | pkg      |
|-------|--------|--------------------------------------|----------|
| linux | amd64  | 12th Gen Intel(R) Core(TM) i7-12700K | benching |

**Results**

| Benchmark                           | Iterations | ns/op       | B/op     | allocs/op    |
|-------------------------------------|------------|-------------|----------|--------------|
| BenchmarkBinLog/short               | 19695277   | 53.32 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/mid                 | 21063266   | 57.21 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/longer              | 18552622   | 64.26 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/long                | 16185788   | 74.20 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/escape              | 22307642   | 53.82 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/short              | 19008963   | 62.57 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/mid                | 18331288   | 64.22 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/longer             | 18139684   | 64.90 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/long               | 17599312   | 67.42 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/escape             | 18663783   | 63.72 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/blog    | 7287872    | 165.2 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/zerolog | 9368173    | 127.9 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/blog               | 15224050   | 78.71 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/zerolog            | 15656210   | 75.87 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealErrorLog/blog          | 4252406    | 282.2 ns/op | 592 B/op | 2 allocs/op  |
| BenchmarkRealErrorLog/zerolog       | 1000000    | 1014 ns/op  | 832 B/op | 14 allocs/op |
| BenchmarkBinLogCtx3                 | 2594637    | 464.6 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLogCtx3                | 2583954    | 463.1 ns/op | 0 B/op   | 0 allocs/op  |

CRC32 tax slows things down. Basically, the wider the payload, the slower the blog because of not that
fast CRC32 computation on it as I have seen during profiling. Still quick enough and, that's important,
reliable. One broken record is just one broken record thanks to format. You'll have troubles
with CBOR in this case.

## Against zerolog with JSON.

**System**

| goos   | goarch | cpu          | pkg      |
|--------|--------|--------------|----------|
| darwin | arm64  | Apple M4 Pro | benching |

**Results**

| Benchmark                           | Iterations | ns/op       | B/op     | allocs/op    |
|-------------------------------------|------------|-------------|----------|--------------|
| BenchmarkBinLog/short               | 25346467   | 44.60 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/mid                 | 26017599   | 46.27 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/longer              | 23034637   | 51.70 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/long                | 18912330   | 63.34 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/escape              | 27744702   | 44.17 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/short              | 14273784   | 83.13 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/mid                | 12903502   | 93.24 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/longer             | 10456923   | 116.5 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/long               | 7318567    | 165.5 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/escape             | 11435082   | 103.8 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/blog    | 8672649    | 137.2 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/zerolog | 6981853    | 168.9 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/blog               | 18966522   | 62.67 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/zerolog            | 11251533   | 105.1 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealErrorLog/blog          | 5675106    | 206.7 ns/op | 592 B/op | 2 allocs/op  |
| BenchmarkRealErrorLog/zerolog       | 1799848    | 669.2 ns/op | 832 B/op | 14 allocs/op |
| BenchmarkBinLogCtx3                 | 2951659    | 407.0 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLogCtx3                | 1734714    | 679.9 ns/op | 0 B/op   | 0 allocs/op  |

and here are the Intel results:

**System**

| goos  | goarch | cpu                                  | pkg      |
|-------|--------|--------------------------------------|----------|
| linux | amd64  | 12th Gen Intel(R) Core(TM) i7-12700K | benching |

**Results**

| Benchmark                           | Iterations | ns/op       | B/op     | allocs/op    |
|-------------------------------------|------------|-------------|----------|--------------|
| BenchmarkBinLog/short               | 20460490   | 54.00 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/mid                 | 20874595   | 57.61 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/longer              | 18491712   | 64.79 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/long                | 16092429   | 74.70 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkBinLog/escape              | 22185975   | 54.18 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/short              | 12011266   | 99.09 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/mid                | 10359259   | 115.2 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/longer             | 9243702    | 128.9 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/long               | 7741206    | 155.4 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLog/escape             | 8834079    | 136.0 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/blog    | 6831591    | 175.5 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkWorstCaseForBinLog/zerolog | 5855564    | 204.6 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/blog               | 14692437   | 81.62 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealLog/zerolog            | 9036188    | 132.0 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkRealErrorLog/blog          | 4223503    | 283.6 ns/op | 592 B/op | 2 allocs/op  |
| BenchmarkRealErrorLog/zerolog       | 1000000    | 1132 ns/op  | 832 B/op | 14 allocs/op |
| BenchmarkBinLogCtx3                 | 2498659    | 479.8 ns/op | 0 B/op   | 0 allocs/op  |
| BenchmarkZeroLogCtx3                | 1462959    | 819.9 ns/op | 0 B/op   | 0 allocs/op  |