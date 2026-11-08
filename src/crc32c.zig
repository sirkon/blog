const std = @import("std");
const builtin = @import("builtin");

/// Reflected CRC-32C (Castagnoli) polynomial `0x1edc6f41`.
const poly: u32 = 0x82f63b78;

/// Granularities of the three interleaved crc32q streams on x86_64, in words,
/// largest first. Three independent streams hide the 3-cycle latency of the
/// instruction; they are merged afterwards by advancing the first one over the
/// bytes consumed by the other two. A greedy pick of the largest span that fits
/// keeps the number of merges as low as possible.
const span_menu = [_]usize{ 512, 128, 16, 8, 4 };

/// Data below this length is not brought to an 8-byte boundary first: for short
/// input the alignment prologue costs more than the aligned loads save.
const align_from = 3 * 128 * 8;

const merge_tables: [span_menu.len][4][256]u32 = blk: {
    var tables: [span_menu.len][4][256]u32 = undefined;
    for (span_menu, 0..) |span_words, index| tables[index] = mergeTable(span_words * 8);
    break :blk tables;
};

const byte_table = lookupTable();

/// Включаем ассемблер ТОЛЬКО в режиме ReleaseFast под x86_64,
/// чтобы обойти баг компилятора Zig с обработкой MIR в Debug/ReleaseSafe.
const x86_asm = builtin.target.cpu.arch == .x86_64 and builtin.mode == .fast;

/// На ARM64 компилятор обрабатывает MIR отлично в любом режиме сборки
const arm_asm = builtin.target.cpu.arch == .aarch64;

/// Кроссплатформенный аппаратный CRC-32C (Castagnoli).
pub fn hardwareCrc32C(data: []const u8) u32 {
    return rawCrc32C(0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

/// CRC-32C (Castagnoli) over `a ++ b`, where `acc` is the CRC-32C of the block
/// `a` and `data` is the block `b`. `composedCrc32C(hardwareCrc32C(a), b)` is
/// always equal to `hardwareCrc32C(a ++ b)`, which makes it an iterative CRC
/// over a sequence of blocks. `acc == 0` stands for an empty `a`, since the CRC
/// of an empty block is zero.
///
/// The CRC register is a linear feedback shift register: the CRC of a block is
/// its final register state, so feeding more bytes to the very same register
/// gives the CRC of the concatenation. The only thing `composedCrc32C` has to
/// do is to undo the output inversion applied by `hardwareCrc32C` and to apply
/// it again at the end.
pub fn composedCrc32C(acc: u32, data: []const u8) u32 {
    return rawCrc32C(acc ^ 0xFFFFFFFF, data) ^ 0xFFFFFFFF;
}

/// Advances the raw (non-inverted) CRC-32C register state by `data`.
fn rawCrc32C(state: u32, data: []const u8) u32 {
    if (x86_asm) return rawCrc32CX86(state, data);
    if (arm_asm) return rawCrc32CArm(state, data);
    return rawCrc32CTable(state, data);
}

fn rawCrc32CX86(state: u32, data: []const u8) u32 {
    var crc: u64 = state;
    var rest = data;

    if (rest.len >= align_from) {
        // Bring the data to an 8-byte boundary so every word below is loaded
        // aligned; the leading bytes go through crc32b.
        if (@intFromPtr(rest.ptr) & 7 != 0) {
            var crc32: u32 = @truncate(crc);
            while (rest.len > 0 and @intFromPtr(rest.ptr) & 7 != 0) : (rest = rest[1..]) {
                const val = rest[0];
                asm volatile ("crc32b %[val], %[crc]"
                    : [crc] "+r" (crc32),
                    : [val] "rm" (val),
                );
            }
            crc = crc32;
        }
        const runs = crcRuns(8, crc, rest);
        crc = runs.crc;
        rest = runs.rest;
    } else {
        // Short input: the unaligned word loads are cheaper than the prologue.
        const runs = crcRuns(1, crc, rest);
        crc = runs.crc;
        rest = runs.rest;
    }

    var crc32: u32 = @truncate(crc);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const val = rest[i];
        asm volatile ("crc32b %[val], %[crc]"
            : [crc] "+r" (crc32),
            : [val] "rm" (val),
        );
    }
    return crc32;
}

/// Runs the interleaved streams over whole words, largest span first, and
/// leaves the leftover bytes (0 to 7 of them) in the returned slice.
fn crcRuns(comptime align_bytes: usize, crc_in: u64, rest_in: []const u8) struct { crc: u64, rest: []const u8 } {
    var crc = crc_in;
    var words: [*]align(align_bytes) const u64 = @ptrCast(@alignCast(rest_in.ptr));
    var count = rest_in.len / 8;

    inline for (span_menu) |span_words| {
        while (count >= 3 * span_words) {
            crc = spannedBlock(align_bytes, span_words, crc, words);
            words += 3 * span_words;
            count -= 3 * span_words;
        }
    }

    while (count > 0) : (count -= 1) {
        const val = words[0];
        asm volatile ("crc32q %[val], %[crc]"
            : [crc] "+r" (crc),
            : [val] "rm" (val),
        );
        words += 1;
    }

    return .{ .crc = crc, .rest = rest_in[rest_in.len & ~@as(usize, 7) ..] };
}

/// Consumes `3 * span_words` words from the front of `words` with three
/// interleaved crc32q streams, each covering a contiguous `span_words`-word
/// run, and merges them back into a single register state.
fn spannedBlock(
    comptime align_bytes: usize,
    comptime span_words: usize,
    crc_in: u64,
    words_in: [*]align(align_bytes) const u64,
) u64 {
    var crc0: u64 = crc_in;
    var crc1: u64 = 0;
    var crc2: u64 = 0;
    var words = words_in;
    var step: usize = 0;
    while (step < span_words) : (step += 1) {
        const val0 = words[0];
        const val1 = words[span_words];
        const val2 = words[2 * span_words];
        asm volatile (
            \\crc32q %[val0], %[crc0]
            \\crc32q %[val1], %[crc1]
            \\crc32q %[val2], %[crc2]
            : [crc0] "+r" (crc0),
              [crc1] "+r" (crc1),
              [crc2] "+r" (crc2),
            : [val0] "rm" (val0),
              [val1] "rm" (val1),
              [val2] "rm" (val2),
        );
        words += 1;
    }

    const table = mergeTableFor(span_words);
    crc0 = merge(table, @truncate(crc0)) ^ crc1;
    crc0 = merge(table, @truncate(crc0)) ^ crc2;
    return crc0;
}

/// The merge tables of `span_words`, i.e. of a stream covering that many words.
fn mergeTableFor(comptime span_words: usize) *const [4][256]u32 {
    inline for (span_menu, 0..) |span, index| {
        if (span == span_words) return &merge_tables[index];
    }
    @compileError("no merge table for this span");
}

fn rawCrc32CArm(state: u32, data: []const u8) u32 {
    var crc: u32 = state;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        const val = std.mem.readInt(u64, data[i..][0..8], .native);
        asm ("crc32cx %[crc], %[crc], %[val]"
            : [crc] "+r" (crc),
            : [val] "r" (val),
        );
    }
    while (i < data.len) : (i += 1) {
        const val: u32 = data[i];
        asm ("crc32cb %[crc], %[crc], %[val]"
            : [crc] "+r" (crc),
            : [val] "r" (val),
        );
    }
    return crc;
}

fn rawCrc32CTable(state: u32, data: []const u8) u32 {
    var crc = state;
    for (data) |byte| {
        const index: u8 = @truncate(crc ^ byte);
        crc = byte_table[index] ^ (crc >> 8);
    }
    return crc;
}

/// Byte-at-a-time table for the reflected Castagnoli polynomial.
fn lookupTable() [256]u32 {
    @setEvalBranchQuota(4000);

    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            crc = if (crc & 1 != 0) (crc >> 1) ^ poly else crc >> 1;
        }
        entry.* = crc;
    }
    return table;
}

/// Applies the operator advancing a register state by `span` zero bytes
/// through four 256-entry tables, one per byte lane.
fn merge(table: *const [4][256]u32, crc: u32) u32 {
    return table[0][crc & 0xFF] ^
        table[1][(crc >> 8) & 0xFF] ^
        table[2][(crc >> 16) & 0xFF] ^
        table[3][crc >> 24];
}

/// Builds the four tables of the operator advancing a register state by
/// `length` zero bytes. Advancing by `k` zero bits multiplies the state by
/// `x^k mod poly`, a linear map over GF(2) that is squared up to `x^length`.
fn mergeTable(comptime length: usize) [4][256]u32 {
    @setEvalBranchQuota(250000);

    var even: [32]u32 = undefined;
    zeroes: {
        var odd: [32]u32 = undefined;

        // The operator for a single zero bit: `odd[0]` is the polynomial, the
        // rest shift a single bit through the remaining positions.
        odd[0] = poly;
        var row: u32 = 1;
        for (1..32) |n| {
            odd[n] = row;
            row <<= 1;
        }

        squareMatrix(&even, &odd);
        squareMatrix(&odd, &even);

        var len = length;
        while (true) {
            squareMatrix(&even, &odd);
            len >>= 1;
            if (len == 0) break :zeroes;
            squareMatrix(&odd, &even);
            len >>= 1;
            if (len == 0) break;
        }

        @memcpy(&even, &odd);
    }

    var table: [4][256]u32 = undefined;
    for (0..256) |n| {
        const value: u32 = @intCast(n);
        table[0][n] = matrixTimes(&even, value);
        table[1][n] = matrixTimes(&even, value << 8);
        table[2][n] = matrixTimes(&even, value << 16);
        table[3][n] = matrixTimes(&even, value << 24);
    }
    return table;
}

/// `mat * vec` over GF(2), with a 32x32 binary `mat` and a 32-bit `vec`.
fn matrixTimes(mat: *const [32]u32, vec: u32) u32 {
    var sum: u32 = 0;
    var v = vec;
    var i: u32 = 0;
    while (v != 0) : (i += 1) {
        if (v & 1 != 0) sum ^= mat[i];
        v >>= 1;
    }
    return sum;
}

/// `dst = dst x src` over GF(2), doubling the number of zero bits the operator
/// advances the state by.
fn squareMatrix(dst: *[32]u32, src: *const [32]u32) void {
    for (dst, src) |*d, s| {
        d.* = matrixTimes(src, s);
    }
}

test "crc32 Castagnoli hardware with the fallback for unsupported arches" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const buf = try arena.allocator().alloc(u8, 133);

    // Правильно захватываем индекс итерации
    for (buf, 0..) |*val, index| {
        val.* = @intCast(index); // или buf[index] = @intCast(index);
    }

    // Теперь внутри буфера честные 0, 1, 2 ... 132
    const crc32c = hardwareCrc32C(buf);
    try std.testing.expectEqual(60592851, crc32c);
}

const stdlib = std.hash.crc.@"CRC-32/ISCSI";

fn concat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const dst = try allocator.alloc(u8, a.len + b.len);
    @memcpy(dst[0..a.len], a);
    @memcpy(dst[a.len..], b);
    return dst;
}

test "crc32c composed handles empty blocks" {
    try std.testing.expectEqual(@as(u32, 0), hardwareCrc32C(""));
    try std.testing.expectEqual(@as(u32, 0), stdlib.hash(""));

    // Both blocks are empty.
    try std.testing.expectEqual(@as(u32, 0), composedCrc32C(0, ""));

    const a = "the quick brown fox jumps over the lazy dog";
    const acc = hardwareCrc32C(a);

    // An empty second block keeps the accumulator as is.
    try std.testing.expectEqual(acc, composedCrc32C(acc, ""));

    // An empty first block: the accumulator is the CRC of an empty block.
    try std.testing.expectEqual(hardwareCrc32C(a), composedCrc32C(0, a));

    // One byte on each side.
    try std.testing.expectEqual(hardwareCrc32C("ab"), composedCrc32C(hardwareCrc32C("a"), "b"));
}

test "crc32c composed matches a single pass over the concatenation" {
    const allocator = std.testing.allocator;

    // Sizes straddling the 8-byte tail, the short-span and the long-span
    // boundaries of the interleaved x86_64 path.
    const cases = [_][2]usize{
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 3, 5 },
        .{ 7, 9 },
        .{ 8, 8 },
        .{ 255, 1 },
        .{ 767, 1 },
        .{ 768, 1 },
        .{ 769, 1 },
        .{ 1, 767 },
        .{ 1, 768 },
        .{ 1, 769 },
        .{ 8191, 1 },
        .{ 24575, 1 },
        .{ 24576, 1 },
        .{ 24577, 1 },
        .{ 300, 40_000 },
        .{ 100_000, 1 },
        .{ 70_000, 130_000 },
    };

    for (cases) |case| {
        const a_len, const b_len = case;

        const a = try allocator.alloc(u8, a_len);
        defer allocator.free(a);
        const b = try allocator.alloc(u8, b_len);
        defer allocator.free(b);
        for (a, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
        for (b, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 11);

        const joined = try concat(allocator, a, b);
        defer allocator.free(joined);

        try std.testing.expectEqual(
            hardwareCrc32C(joined),
            composedCrc32C(hardwareCrc32C(a), b),
        );
    }
}

test "crc32c composed agrees with the stdlib Castagnoli implementation" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0x5eed_1234_5678_9abc);
    const rnd = prng.random();

    const lengths = [_]usize{ 0, 1, 2, 7, 8, 9, 100, 255, 256, 768, 1024, 4096, 8192, 16_384, 24_576, 32_768 };
    for (lengths) |len| {
        const a = try allocator.alloc(u8, len);
        defer allocator.free(a);
        rnd.bytes(a);
        const b = try allocator.alloc(u8, len);
        defer allocator.free(b);
        rnd.bytes(b);

        const joined = try concat(allocator, a, b);
        defer allocator.free(joined);

        // A plain single pass.
        try std.testing.expectEqual(stdlib.hash(joined), hardwareCrc32C(joined));

        // An iterative pass, starting from the CRC of an empty block.
        var expected = stdlib.init();
        expected.update(a);
        expected.update(b);
        try std.testing.expectEqual(expected.final(), composedCrc32C(
            composedCrc32C(0, a),
            b,
        ));
    }
}

/// Contents of a benchmark case: a sequence of chunks packed into one buffer.
const Chunks = struct {
    buf: []u8,
    ends: []usize,

    fn init(allocator: std.mem.Allocator, lengths: []const usize, rnd: std.Random) !Chunks {
        var total: usize = 0;
        for (lengths) |len| total += len;

        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);
        rnd.bytes(buf);

        const ends = try allocator.alloc(usize, lengths.len);
        errdefer allocator.free(ends);
        var offset: usize = 0;
        for (lengths, 0..) |len, i| {
            offset += len;
            ends[i] = offset;
        }

        return .{ .buf = buf, .ends = ends };
    }

    fn deinit(self: Chunks, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        allocator.free(self.ends);
    }

    fn count(self: Chunks) usize {
        return self.ends.len;
    }

    fn at(self: Chunks, index: usize) []const u8 {
        const start: usize = if (index == 0) 0 else self.ends[index - 1];
        return self.buf[start..self.ends[index]];
    }
};

fn lengthsSmall(allocator: std.mem.Allocator, rnd: std.Random) ![]usize {
    const count = 16_384;
    const lengths = try allocator.alloc(usize, count);
    // A shifted exponential distribution with a mean of 96 bytes, so the chunks
    // are 96 to 384 bytes long, 192 bytes on average.
    for (lengths) |*len| {
        const u = rnd.float(f64);
        const tail = -96.0 * @log(1.0 - u);
        len.* = 96 + @as(usize, @intFromFloat(@min(tail, 288.0)));
    }
    return lengths;
}

fn lengthsFixed(allocator: std.mem.Allocator, count: usize, len: usize) ![]usize {
    const lengths = try allocator.alloc(usize, count);
    @memset(lengths, len);
    return lengths;
}

fn oursHardware(chunks: Chunks) u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < chunks.count()) : (i += 1) acc +%= hardwareCrc32C(chunks.at(i));
    return acc;
}

fn oursComposed(chunks: Chunks) u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < chunks.count()) : (i += 1) acc = composedCrc32C(acc, chunks.at(i));
    return acc;
}

fn stdlibHardware(chunks: Chunks) u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < chunks.count()) : (i += 1) acc +%= stdlib.hash(chunks.at(i));
    return acc;
}

fn stdlibComposed(chunks: Chunks) u32 {
    var hasher = stdlib.init();
    var i: usize = 0;
    while (i < chunks.count()) : (i += 1) hasher.update(chunks.at(i));
    return hasher.final();
}

/// The alternative to `composedCrc32C` for small blocks: copy them into 4 KiB
/// staging buffers and hash every full buffer in one go with the stdlib. The
/// last, partially filled buffer is zero padded to 4 KiB and hashed as well.
const BatchHasher = struct {
    const batch_len = 4096;

    staging: [batch_len]u8 = undefined,
    filled: usize = 0,
    acc: u32 = 0,

    fn push(self: *BatchHasher, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const take = @min(batch_len - self.filled, rest.len);
            @memcpy(self.staging[self.filled..][0..take], rest[0..take]);
            self.filled += take;
            rest = rest[take..];
            if (self.filled == batch_len) self.flush();
        }
    }

    fn flush(self: *BatchHasher) void {
        self.acc +%= stdlib.hash(&self.staging);
        self.filled = 0;
    }

    fn finish(self: *BatchHasher) u32 {
        if (self.filled > 0) {
            @memset(self.staging[self.filled..], 0);
            self.flush();
        }
        return self.acc;
    }
};

fn batchedStdlib(chunks: Chunks) u32 {
    var batcher: BatchHasher = .{};
    var i: usize = 0;
    while (i < chunks.count()) : (i += 1) batcher.push(chunks.at(i));
    return batcher.finish();
}

const bench_runs = 100;

/// Best of `bench_runs` timed passes over `chunks`.
fn bestNs(io: std.Io, comptime run: fn (Chunks) u32, chunks: Chunks) u64 {
    const clock: std.Io.Clock = .awake;

    var best: u64 = std.math.maxInt(u64);
    var run_index: usize = 0;
    while (run_index < bench_runs) : (run_index += 1) {
        const start = clock.now(io);
        std.mem.doNotOptimizeAway(run(chunks));
        const elapsed: u64 = @intCast(start.durationTo(clock.now(io)).toNanoseconds());
        best = @min(best, elapsed);
    }
    return best;
}

const Slower = enum { gated, informational };

/// Times our implementation and the alternative over the same chunk sequence.
/// Every case is measured before anything is reported, so a failure never
/// hides the numbers of the cases after it.
fn compare(
    io: std.Io,
    comptime label: []const u8,
    bytes: usize,
    chunks: Chunks,
    comptime ours: fn (Chunks) u32,
    comptime theirs: fn (Chunks) u32,
    comptime gate: Slower,
    comptime slower: anyerror,
) ?anyerror {
    const ours_ns = bestNs(io, ours, chunks);
    const alt_ns = bestNs(io, theirs, chunks);

    const ratio = @as(f64, @floatFromInt(ours_ns)) / @as(f64, @floatFromInt(alt_ns));
    const ours_gib_s = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ours_ns));
    const alt_gib_s = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(alt_ns));
    std.debug.print("{s:<16} {d:>9} {d:>9} {d:>6.3}x {d:>8.2} {d:>8.2}\n", .{
        label,
        ours_ns,
        alt_ns,
        ratio,
        ours_gib_s,
        alt_gib_s,
    });

    if (@as(f64, @floatFromInt(ours_ns)) > 1.05 * @as(f64, @floatFromInt(alt_ns))) {
        switch (gate) {
            .gated => return slower,
            .informational => return null,
        }
    }
    return null;
}

test "crc32c benchmarks against the stdlib Castagnoli implementation" {
    if (builtin.mode != .fast) return error.SkipZigTest;

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xdead_beef_cafe_f00d);
    const rnd = prng.random();

    std.debug.print("\ncrc32c, best of {d} runs\n", .{bench_runs});
    std.debug.print(
        "alt = the stdlib Castagnoli, or 4 KiB staging buffers hashed by it for the batched case\n",
        .{},
    );
    std.debug.print("{s:<16} {s:>9} {s:>9} {s:>7} {s:>8} {s:>8}\n", .{
        "case", "ours ns", "alt ns", "ratio", "GiB/s", "alt GiB/s",
    });

    var failure: ?anyerror = null;

    // 16384 chunks of 96 to 384 bytes, 192 bytes on average.
    {
        const lengths = try lengthsSmall(allocator, rnd);
        defer allocator.free(lengths);
        const chunks = try Chunks.init(allocator, lengths, rnd);
        defer chunks.deinit(allocator);

        if (compare(io, "small/hardware", chunks.buf.len, chunks, oursHardware, stdlibHardware, .gated, error.SmallHardwareSlowerThanStdlib)) |err| failure = failure orelse err;
        if (compare(io, "small/composed", chunks.buf.len, chunks, oursComposed, stdlibComposed, .gated, error.SmallComposedSlowerThanStdlib)) |err| failure = failure orelse err;

        // Composed per small chunk against the buffering strategy: pack the
        // same chunks into 4 KiB staging buffers, hash every full buffer with
        // the stdlib and zero pad the last one. This compares two strategies
        // rather than the same operation, so it is reported only.
        if (compare(io, "small/batched", chunks.buf.len, chunks, oursComposed, batchedStdlib, .informational, error.SmallBufferingFasterThanComposed)) |err| failure = failure orelse err;
    }

    // 4096 chunks of 4096 bytes.
    {
        const lengths = try lengthsFixed(allocator, 4096, 4096);
        defer allocator.free(lengths);
        const chunks = try Chunks.init(allocator, lengths, rnd);
        defer chunks.deinit(allocator);

        if (compare(io, "4KiB/composed", chunks.buf.len, chunks, oursComposed, stdlibComposed, .gated, error.Kib4ComposedSlowerThanStdlib)) |err| failure = failure orelse err;
    }

    // 1024 chunks of 16384 bytes.
    {
        const lengths = try lengthsFixed(allocator, 1024, 16_384);
        defer allocator.free(lengths);
        const chunks = try Chunks.init(allocator, lengths, rnd);
        defer chunks.deinit(allocator);

        if (compare(io, "16KiB/composed", chunks.buf.len, chunks, oursComposed, stdlibComposed, .gated, error.Kib16ComposedSlowerThanStdlib)) |err| failure = failure orelse err;
    }

    if (failure) |err| return err;
}
