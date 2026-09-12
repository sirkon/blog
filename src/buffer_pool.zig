const std = @import("std");
const mutex = @import("mutex.zig");

/// A fixed-frame free-list pool with a heap fallback.
///
/// `get` hands out a frame when the request fits and a frame is free,
/// otherwise it falls back to the backing allocator. `put` recovers the
/// owning frame from the slice address alone and returns it to the free
/// list; slices that do not belong to the pool are freed on the heap.
///
/// With `threadsafe == true` the free list is guarded by a `mutex.Mutex`
/// (a thin libc-backed pthread mutex) created by `init`. With
/// `threadsafe == false` the mutex is comptime-eliminated.
pub fn BufferPool(comptime threadsafe: bool) type {
    return struct {
        const Self = @This();

        /// Number of frames. Power of two, validated in `init`.
        size: u32,
        /// Bytes per frame. Power of two and >= 512, validated in `init`.
        frameSize: u32,
        /// `size * frameSize` contiguous bytes holding every frame.
        backing: []u8,
        /// Frame indices in initial hand-out order; kept for seeding and
        /// leak diagnostics.
        ready: []u32,
        /// Head of the free list, -1 when empty.
        first: i32,
        /// `next[idx]` is the successor of frame `idx`, -1 at the tail.
        next: []i32,
        /// Backing allocator for the heap fallback.
        allocator: std.mem.Allocator,
        /// Only present when `threadsafe`; guards the free list.
        mutex: if (threadsafe) mutex.Mutex else void,

        pub fn init(
            allocator: std.mem.Allocator,
            size: u32,
            frameSize: u32,
        ) !Self {
            if (size == 0 or (size & (size - 1)) != 0) return error.InvalidConfig;
            if (frameSize < 512 or (frameSize & (frameSize - 1)) != 0) return error.InvalidConfig;

            const backing = try allocator.alloc(u8, @as(usize, size) * frameSize);
            errdefer allocator.free(backing);
            const ready = try allocator.alloc(u32, size);
            errdefer allocator.free(ready);
            const next = try allocator.alloc(i32, size);
            errdefer allocator.free(next);

            var i: u32 = 0;
            while (i < size) : (i += 1) {
                ready[i] = i;
                next[i] = if (i + 1 < size) @intCast(i + 1) else -1;
            }

            return .{
                .size = size,
                .frameSize = frameSize,
                .backing = backing,
                .ready = ready,
                .first = 0,
                .next = next,
                .allocator = allocator,
                .mutex = if (threadsafe) mutex.Mutex.init() else {},
            };
        }

        pub fn deinit(self: *Self) void {
            var free_count: u32 = 0;
            var cur = self.first;
            while (cur >= 0) : (cur = self.next[@intCast(cur)]) {
                free_count += 1;
            }
            std.debug.assert(free_count == self.size);

            if (threadsafe) self.mutex.deinit();
            self.allocator.free(self.backing);
            self.allocator.free(self.ready);
            self.allocator.free(self.next);
        }

        /// Returns a buffer of exactly `size` bytes. Prefers a frame from the
        /// free list (LIFO) when the request fits, otherwise falls back to the
        /// backing allocator.
        pub fn get(self: *Self, size: usize) std.mem.Allocator.Error![]u8 {
            if (size <= self.frameSize) {
                self.lock();
                const head = self.first;
                if (head >= 0) {
                    const idx: u32 = @intCast(head);
                    self.first = self.next[idx];
                    self.unlock();
                    return self.backing[@as(usize, idx) * self.frameSize ..][0..size];
                }
                self.unlock();
            }
            return self.allocator.alloc(u8, size);
        }

        /// Releases `buf`. Returns `true` when it belonged to a frame and was
        /// put back on the free list, `false` when it was freed on the heap.
        pub fn put(self: *Self, buf: []u8) bool {
            const base = @intFromPtr(self.backing.ptr);
            const addr = @intFromPtr(buf.ptr);
            if (addr >= base and addr < base + self.backing.len) {
                const shift: u6 = @intCast(@ctz(self.frameSize));
                const idx: usize = (addr - base) >> shift;
                self.lock();
                self.next[idx] = self.first;
                self.first = @intCast(idx);
                self.unlock();
                return true;
            }
            self.allocator.free(buf);
            return false;
        }

        inline fn lock(self: *Self) void {
            if (threadsafe) self.mutex.lock();
        }

        inline fn unlock(self: *Self) void {
            if (threadsafe) self.mutex.unlock();
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "lifo reuse and frame identity" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool(false).init(allocator, 4, 512);
    defer pool.deinit();

    const a = try pool.get(10);
    const b = try pool.get(10);
    try expect(a.ptr != b.ptr);

    try expect(pool.put(a));
    const c = try pool.get(10);
    try expectEqual(a.ptr, c.ptr);

    try expect(pool.put(b));
    try expect(pool.put(c));

    // All frames back: deinit's assertion and the allocator leak check agree.
}

test "config validation" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, BufferPool(false).init(allocator, 3, 512));
    try std.testing.expectError(error.InvalidConfig, BufferPool(false).init(allocator, 4, 256));
    try std.testing.expectError(error.InvalidConfig, BufferPool(false).init(allocator, 0, 512));

    var pool = try BufferPool(false).init(allocator, 1, 512);
    defer pool.deinit();
}

test "heap fallback when request exceeds the frame" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool(false).init(allocator, 2, 512);
    defer pool.deinit();

    const big = try pool.get(2048);
    try expect(!pool.put(big));
}

test "heap fallback on exhaustion" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool(false).init(allocator, 2, 512);
    defer pool.deinit();

    const a = try pool.get(64);
    const b = try pool.get(64);
    const c = try pool.get(64);
    try expect(c.ptr != a.ptr and c.ptr != b.ptr);

    try expect(pool.put(a));
    try expect(pool.put(b));
    try expect(!pool.put(c));
}

test "put accepts an interior pointer" {
    const allocator = std.testing.allocator;
    var pool = try BufferPool(false).init(allocator, 2, 512);
    defer pool.deinit();

    const a = try pool.get(64);
    try expect(pool.put(a[16..]));

    const b = try pool.get(64);
    try expectEqual(a.ptr, b.ptr);
    try expect(pool.put(b));
}

test "threads hammer the pool" {
    const allocator = std.testing.allocator;

    var pool = try BufferPool(true).init(allocator, 64, 512);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *BufferPool(true)) void {
            var i: usize = 0;
            while (i < 20_000) : (i += 1) {
                const buf = p.get(128) catch @panic("get failed");
                buf[0] = @truncate(i);
                _ = p.put(buf);
            }
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&pool});
    for (threads) |t| t.join();
}
