//! Zig logger benchmarks, installed as `zig-out/bin/bench`.
//!
//! Pass the target duration per case as the first argument, in seconds
//! (default 1.0).

const std = @import("std");
const Io = std.Io;
const blog = @import("blog");

pub fn main(init: std.process.Init) !void {
    const argv = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    return runBenchmarks(init, argv[1..]);
}

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const frozen = buf;
        return &frozen;
    }
}

const mid_msg = repeat("A", 64);

const no_ctx_payload = .{
    .{ "short", repeat("A", 16) },
    .{ "mid", repeat("A", 64) },
    .{ "longer", repeat("A", 128) },
    .{ "long", repeat("A", 256) },
    .{ "escape", repeat("abcdedf\"", 4) },
};

const BenchSink = struct {
    buf: [16384]u8 = undefined,

    pub fn write(self: *BenchSink, pool: *blog.BufferPool, buf: []const u8) blog.WriteError!usize {
        const n = @min(buf.len, self.buf.len);
        @memcpy(self.buf[0..n], buf[0..n]);
        _ = pool.put(@constCast(buf));
        return buf.len;
    }
};

const BenchLogger = blog.Logger(blog.BufferPool, BenchSink);

const GoPcg = struct {
    hi: u64,
    lo: u64,

    fn init(seed1: u64, seed2: u64) GoPcg {
        return .{ .hi = seed1, .lo = seed2 };
    }

    fn next(self: *GoPcg) struct { hi: u64, lo: u64 } {
        const mul_hi: u64 = 2549297995355413924;
        const mul_lo: u64 = 4865540595714422341;
        const inc_hi: u64 = 6364136223846793005;
        const inc_lo: u64 = 1442695040888963407;

        const product = @as(u128, self.lo) * mul_lo;
        var hi: u64 = @truncate(product >> 64);
        var lo: u64 = @truncate(product);
        hi +%= self.hi *% mul_lo +% self.lo *% mul_hi;

        const add = @addWithOverflow(lo, inc_lo);
        lo = add[0];
        hi = hi +% inc_hi +% add[1];

        self.hi = hi;
        self.lo = lo;
        return .{ .hi = hi, .lo = lo };
    }

    fn uint64(self: *GoPcg) u64 {
        const cheap_mul: u64 = 0xda942042e4dd58b5;
        const step = self.next();
        var hi = step.hi;
        hi ^= hi >> 32;
        hi *%= cheap_mul;
        hi ^= hi >> 48;
        hi *%= (step.lo | 1);
        return hi;
    }

    fn int(self: *GoPcg) i64 {
        return @intCast(self.uint64() & std.math.maxInt(i64));
    }

    fn float64(self: *GoPcg) f64 {
        const mask: u64 = (1 << 53) - 1;
        return @as(f64, @floatFromInt(self.uint64() & mask)) / 9007199254740992.0;
    }
};

fn poisson(rng: *GoPcg, lambda: f64) i64 {
    if (lambda <= 0) return 0;

    const limit = @exp(-lambda);
    var k: i64 = 0;
    var p: f64 = 1.0;
    while (p > limit) {
        k += 1;
        p *= rng.float64();
    }
    return k - 1;
}

const Ctx3Entry = struct {
    int: i64,
    count: i64,
    str: []const u8,
};

fn ctx3Payload(allocator: std.mem.Allocator) ![]Ctx3Entry {
    const result = try allocator.alloc(Ctx3Entry, 5);
    var rng = GoPcg.init(0, std.math.maxInt(u64));
    for (result) |*entry| {
        entry.int = rng.int();
        entry.count = poisson(&rng, 21);
        const len: usize = @intCast(poisson(&rng, 10));
        const str = try allocator.alloc(u8, len);
        @memset(str, 'A');
        entry.str = str;
    }
    return result;
}

fn NoCtx(comptime msg: []const u8) type {
    return struct {
        pub const Ctx = void;

        pub fn run(logger: *BenchLogger, _: Ctx) !void {
            logger.err(msg, .{});
        }
    };
}

const WorstCase = struct {
    pub const Ctx = void;

    pub fn run(logger: *BenchLogger, _: Ctx) !void {
        logger.err("test", .{
            .i1 = @as(i64, 1),
            .t1 = "1",
            .i2 = @as(i64, 2),
            .t2 = "2",
            .i3 = @as(i64, 3),
            .t3 = "3",
            .i4 = @as(i64, 4),
            .t4 = "4",
            .i5 = std.math.maxInt(i64),
            .t5 = "5",
        });
    }
};

const RealLog = struct {
    pub const Ctx = void;

    pub fn run(logger: *BenchLogger, _: Ctx) !void {
        logger.info("User logged in", .{
            .@"user-id" = "u-9912",
            .ip_address = "192.168.1.15",
        });
    }
};

const ErrorCase = struct {
    pub const Ctx = void;

    pub fn run(logger: *BenchLogger, _: Ctx) !void {
        var diag = try logger.diag_txt("failed to commit stream", .{
            .@"user-role" = "COMMON-USER",
            .method = "service.Method",
            .@"response-code" = "NOT_AUTHORIZED",
        });
        errdefer diag.release();
        try diag.wrap("stream data under service user", .{
            .documents = .{
                .document1 = "document1",
                .document2 = "document2",
            },
            .@"document-class" = "application/text",
        });
        try diag.wrap("merge documents", .{
            .documents = .{
                .document1 = @as(i64, 100000000001),
                .document2 = @as(i64, 200002123123),
            },
        });
        logger.err("failed to merge documents", .{ .err = &diag });
    }
};

const Ctx3 = struct {
    pub const Ctx = []const Ctx3Entry;

    pub fn run(logger: *BenchLogger, payload: Ctx) !void {
        for (payload) |p| {
            logger.err(mid_msg, .{
                .int = p.int,
                .str = p.str,
                .count = p.count,
            });
        }
    }
};

fn benchmark(
    io: Io,
    logger: *BenchLogger,
    comptime name: []const u8,
    comptime Runner: type,
    ctx: Runner.Ctx,
    target_ns: u64,
    records_per_iter: u64,
) !void {
    const warmup_count = 1000;
    var warmup: usize = 0;
    while (warmup < warmup_count) : (warmup += 1) try Runner.run(logger, ctx);

    const clock: Io.Clock = .awake;
    const start = clock.now(io);

    var iters: u64 = 0;
    var batch: u64 = 10_000;
    var elapsed: u64 = 0;
    while (true) {
        var i: u64 = 0;
        while (i < batch) : (i += 1) try Runner.run(logger, ctx);
        iters += batch;

        elapsed = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
        if (elapsed >= target_ns) break;
        if (batch < (1 << 16)) batch *= 2;
    }

    const ns_per_op = elapsed / iters;
    const records_per_sec = iters * records_per_iter * std.time.ns_per_s / elapsed;

    std.debug.print("{s:<20} {d:>12} {d:>14}\n", .{
        name,
        ns_per_op,
        records_per_sec,
    });
}

fn runBenchmarks(init: std.process.Init, args: []const [:0]const u8) !void {
    const target_s: f64 = if (args.len > 0)
        try std.fmt.parseFloat(f64, args[0])
    else
        1.0;
    const target_ns: u64 = @intFromFloat(target_s * std.time.ns_per_s);

    var pool: blog.BufferPool = undefined;
    try pool.init(init.arena.allocator(), 64, 4096);
    defer pool.deinit();

    var sink: BenchSink = .{};
    var logger: BenchLogger = undefined;
    logger.init(&pool, &sink);
    defer logger.deinit();

    const payload = try ctx3Payload(init.arena.allocator());

    std.debug.print(
        "blog zig benchmarks, {d:.2}s per case (ns/op is one iteration, ctx-3 logs 5 records)\n",
        .{target_s},
    );
    std.debug.print("{s:<20} {s:>12} {s:>14}\n", .{
        "name", "ns/op", "records/s",
    });

    inline for (no_ctx_payload) |entry| {
        try benchmark(init.io, &logger, entry[0], NoCtx(entry[1]), {}, target_ns, 1);
    }
    try benchmark(init.io, &logger, "worst-case", WorstCase, {}, target_ns, 1);
    try benchmark(init.io, &logger, "real-log", RealLog, {}, target_ns, 1);
    try benchmark(init.io, &logger, "error", ErrorCase, {}, target_ns, 1);
    try benchmark(init.io, &logger, "ctx-3", Ctx3, payload, target_ns, 5);
}
