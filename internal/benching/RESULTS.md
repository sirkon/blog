# Bench blog vs zerolog.

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

## Against zerolog vs JSON.

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