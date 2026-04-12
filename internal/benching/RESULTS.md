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

or, side-by-side

| Test             | BinLog      | ZeroLog     | Ratio (2nd/1st) |
|------------------|-------------|-------------|-----------------|
| short            | 45.30 ns/op | 59.09 ns/op | 1.30x           |
| mid              | 46.62 ns/op | 62.00 ns/op | 1.33x           |
| longer           | 51.32 ns/op | 64.94 ns/op | 1.27x           |
| long             | 63.81 ns/op | 68.96 ns/op | 1.08x           |
| escape           | 44.56 ns/op | 59.66 ns/op | 1.34x           |
| WorstCaseForBlog | 137.9 ns/op | 113.4 ns/op | 0.82x           |
| RealLog          | 61.05 ns/op | 72.30 ns/op | 1.18x           |
| RealErrorLog     | 218.1 ns/op | 602.4 ns/op | 2.76x           |
| Ctx3             | 385.4 ns/op | 401.0 ns/op | 1.04x           |

Factors that inherently slows things down for blog:

- CRC32 computation. It is 5-15 ns tax depending on the length of the payload. May be more for larger events.
  Still worth it: when a couple of bits rotted within an event we lose a log record with blog. 
  And we may lose the entire rest of log with CBOR.
- FluentAPI on ZeroLog wins with large contexts (WorstCase thing). 
  This is an IR tax to pay for variadic style API I intentionally follow for "stick to business" semantics.


**System**

| goos  | goarch | cpu                                  | pkg      |
|-------|--------|--------------------------------------|----------|
| linux | amd64  | 12th Gen Intel(R) Core(TM) i7-12700K | benching |

**Comparison: BinLog vs ZeroLog**

| Test             | BinLog      | ZeroLog     | Ratio (2nd/1st) |
|------------------|-------------|-------------|-----------------|
| short            | 52.57 ns/op | 66.86 ns/op | 1.27x           |
| mid              | 57.28 ns/op | 69.04 ns/op | 1.21x           |
| longer           | 64.12 ns/op | 69.55 ns/op | 1.08x           |
| long             | 74.72 ns/op | 71.48 ns/op | 0.96x           |
| escape           | 53.58 ns/op | 68.19 ns/op | 1.27x           |
| WorstCaseForBlog | 169.5 ns/op | 137.1 ns/op | 0.81x           |
| RealLog          | 79.55 ns/op | 85.61 ns/op | 1.08x           |
| RealErrorLog     | 279.7 ns/op | 1022 ns/op  | 3.65x           |
| Ctx3             | 463.0 ns/op | 496.2 ns/op | 1.07x           |


## Against zerolog with JSON.

**System**

| goos   | goarch | cpu          | pkg      |
|--------|--------|--------------|----------|
| darwin | arm64  | Apple M4 Pro | benching |

**Comparison: BinLog vs ZeroLog**

| Test             | BinLog      | ZeroLog     | Ratio (2nd/1st) |
|------------------|-------------|-------------|-----------------|
| short            | 44.16 ns/op | 81.29 ns/op | 1.84x           |
| mid              | 45.58 ns/op | 92.15 ns/op | 2.02x           |
| longer           | 51.04 ns/op | 113.3 ns/op | 2.22x           |
| long             | 65.10 ns/op | 150.1 ns/op | 2.31x           |
| escape           | 44.38 ns/op | 103.1 ns/op | 2.32x           |
| WorstCaseForBlog | 134.5 ns/op | 173.8 ns/op | 1.29x           |
| RealLog          | 61.87 ns/op | 106.6 ns/op | 1.72x           |
| RealErrorLog     | 210.6 ns/op | 678.3 ns/op | 3.22x           |
| Ctx3             | 385.3 ns/op | 664.7 ns/op | 1.73x           |

and here are the Intel results:

**System**

| goos  | goarch | cpu                                  | pkg      |
|-------|--------|--------------------------------------|----------|
| linux | amd64  | 12th Gen Intel(R) Core(TM) i7-12700K | benching |

**Comparison: BinLog vs ZeroLog**

| Test             | BinLog      | ZeroLog     | Ratio (2nd/1st) |
|------------------|-------------|-------------|-----------------|
| short            | 53.04 ns/op | 102.8 ns/op | 1.94x           |
| mid              | 57.23 ns/op | 118.1 ns/op | 2.06x           |
| longer           | 64.43 ns/op | 130.7 ns/op | 2.03x           |
| long             | 74.65 ns/op | 160.5 ns/op | 2.15x           |
| escape           | 53.79 ns/op | 139.4 ns/op | 2.59x           |
| WorstCaseForBlog | 182.4 ns/op | 211.7 ns/op | 1.16x           |
| RealLog          | 80.08 ns/op | 134.0 ns/op | 1.67x           |
| RealErrorLog     | 283.0 ns/op | 1139 ns/op  | 4.02x           |
| Ctx3             | 487.3 ns/op | 832.9 ns/op | 1.71x           |