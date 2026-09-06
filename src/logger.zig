const std = @import("std");
const builtin = @import("builtin");
const consts = @import("consts.zig");
const encoding = @import("encoding.zig");
// Import your fresh native custom uring package!
const iouring = @import("iouring.zig");

/// 🌟 This is just a temporary call-site stack formatter (formerly LoggerContext).
/// It knows nothing about buffers, IO, or rings—just writes bytes.
const LogFrame = struct {
    dst: [*]u8,
    cur: [*]u8,

    pub inline fn init(buffer_ptr: [*]u8) LogFrame {
        return .{
            .dst = buffer_ptr,
            .cur = buffer_ptr + 16, // Skip 16-byte gap for WAL framing header
        };
    }

    pub inline fn appendField(self: *LogFrame, comptime name: []const u8, value: anytype) void {
        const T = @TypeOf(value);

        const kind: consts.ValueKind = comptime block: {
            break :block switch (@typeInfo(T)) {
                .bool => .bool,
                .int => |info| if (info.signedness == .signed) {
                    // 🌟 FIXED: Using clean block evaluation or explicit switches to avoid ignored literal errors
                    break :block if (info.bits <= 8) .int8 else if (info.bits <= 16) .int16 else if (info.bits <= 32) .int32 else .int64;
                } else {
                    break :block if (info.bits <= 8) .uint8 else if (info.bits <= 16) .uint16 else if (info.bits <= 32) .uint32 else .uint64;
                },
                .float => |info| if (info.bits == 32) .float32 else .float64,
                .@"struct" => .nodeGroup,
                .pointer => |ptrInfo| if (ptrInfo.size == .slice) {
                    const Child = ptrInfo.child;
                    break :block switch (@typeInfo(Child)) {
                        .bool => .sliceBool,
                        .int => |info| if (info.signedness == .signed) {
                            break :block if (info.bits <= 8) .sliceInt8 else if (info.bits <= 16) .sliceInt16 else if (info.bits <= 32) .sliceInt32 else .sliceInt64; // fix slice mapping & typo
                        } else {
                            break :block if (info.bits <= 8) .sliceUint8 else if (info.bits <= 16) .sliceUint16 else if (info.bits <= 32) .sliceUint32 else .sliceUint64;
                        },
                        .float => |info| if (info.bits == 32) .sliceFloat32 else .sliceFloat64,
                        else => @compileError("Unsupported slice item: " ++ @typeName(Child)),
                    };
                } else if (ptrInfo.size == .one and (ptrInfo.child == u8 or switch (@typeInfo(ptrInfo.child)) {
                    .array => |arr| arr.child == u8,
                    else => false,
                })) {
                    break :block .string;
                } else {
                    @compileError("Unsupported pointer type: " ++ @typeName(T));
                },
                else => @compileError("Unsupported record field type: " ++ @typeName(T)),
            };
        };

        // 🌟 Also fixed a small type-typo here: self.cur is a pointer [*]u8,
        // assigning self.cur[0] = kind is cleaner, then doing pointer arithmetic.
        self.cur[0] = @intFromEnum(kind);
        self.cur += 1;

        self.cur = encoding.appendVarint(self.cur, name.len);
        @memcpy(self.cur[0..name.len], name);
        self.cur += name.len;

        switch (@typeInfo(T)) {
            .@"struct" => {
                const sub_info = @typeInfo(T);
                inline for (sub_info.@"struct".fields) |f| {
                    self.appendField(f.name, @field(value, f.name));
                }
                self.cur[0] = @intFromEnum(consts.ValueKind.nodeGroupEnd);
                self.cur += 1;
            },
            else => {
                self.cur = encoding.append(self.cur, value);
            },
        }
    }

    pub inline fn render(self: *LogFrame) struct { ptr: [*]const u8, len: usize } {
        // 1. Calculate exactly how many bytes of useful payload we wrote (from offset 16 onwards)
        const payload_len = @intFromPtr(self.cur) - @intFromPtr(self.dst + 16);

        // 2. 🌟 EXACT GO COMPATIBLE WIDTH CALCULATION:
        // bits.Len64(u64(payload_len)) in Go is exactly (64 - @clz(payload_len)) in Zig!
        // If payload_len is 0, @clz is 64, so bits_len is 0.
        const bits_len: usize = if (payload_len == 0) 0 else 64 - @clz(payload_len);

        // (bits_len + 6) / 7 is the exact size of Go's binary.Uvarint in bytes
        const uvarint_size = (bits_len + 6) / 7;

        // Total header width matching Go: 1 (0xFF) + 4 (CRC) + 1 (0xFE) + uvarint_size
        const width = 6 + uvarint_size;

        // 3. Start the frame strictly at offset 16 - width, just like data := record[16-width:]
        const result_ptr = self.dst + (16 - width);

        // Index 0: Frame sync byte
        result_ptr[0] = 0xFF;

        // 4. Slice the raw payload strictly from offset 16 to compute Castagnoli checksum
        const payload_slice = self.dst[16..][0..payload_len];
        const checksum = crc32cSoftware(payload_slice);

        // Index 1..4: Write calculated CRC32C (4 bytes, Little Endian)
        @memcpy(result_ptr[1..5], std.mem.asBytes(&checksum));

        // Index 5: Frame length block token
        result_ptr[5] = 0xFE;

        // Index 6+: Append payload length uvarint.
        // It will write exactly uvarint_size bytes, sealing the gap perfectly up to offset 16!
        _ = encoding.appendVarint(result_ptr + 6, payload_len);

        // Total frame size is the dynamic width + payload_len
        return .{
            .ptr = result_ptr,
            .len = width + payload_len,
        };
    }
};

/// 🌟 THE REAL LOGGER CONTEXT (Your original entity!)
/// Manages pools, wave bitmaps, connects high-level logging gates with CustomURing IO.
pub const LoggerContext = struct {
    const Self = @This();

    log_allocator: SlotAllocator(128, 2048),
    ctx_allocator: SlotAllocator(64, 512),
    log_fd: std.posix.fd_t,
    ring: *iouring.RawRing, // Points to your custom zero-syscall ring!

    pub fn init(log_buf: []u8, ctx_buf: []u8, ring_ptr: *iouring.RawRing, fd: std.posix.fd_t) Self {
        return .{
            .log_allocator = SlotAllocator(128, 2048).init(log_buf),
            .ctx_allocator = SlotAllocator(64, 512).init(ctx_buf),
            .ring = ring_ptr,
            .log_fd = fd,
        };
    }

    /// The result returned by the dispatcher to high-level loggers.
    /// It wraps either a zero-copy fast-path index or a fallback blocking heap chunk.
    pub const LogBufferResult = union(enum) {
        /// Fast Path: Global slot index within the 256KiB pool shared with io_uring.
        stdbuf: u32,

        /// Slow Path Fallback: Contains a block of memory directly allocated from the heap.
        heap: struct {
            allocator: std.mem.Allocator,
            buf: []u8,
        },
    };

    pub inline fn get(self: *Self, required_size: usize, heap_allocator: std.mem.Allocator) !LogBufferResult {
        if (required_size <= 2048) {
            if (self.log_allocator.allocSlot()) |slot_idx| {
                return LogBufferResult{ .stdbuf = @intCast(slot_idx) };
            }
        }
        const buf = try heap_allocator.alloc(u8, required_size);
        return LogBufferResult{ .heap = .{ .allocator = heap_allocator, .buf = buf } };
    }

    pub inline fn release(self: *Self, slot_index: u32) void {
        self.log_allocator.freeSlot(slot_index);
    }

    pub inline fn submitSQ(self: *Self, data_ptr: [*]const u8, len: usize, user_data: u64) !void {
        // Leverages your custom lock-free SQ advancement loop from iouring.zig
        std.debug.print("push write of {} bytes", .{len});
        try self.ring.pushSQ(self.log_fd, data_ptr, len, user_data);
    }
};

/// High-Level Logger Engine. Built on top of LoggerContext dispatcher.
pub const Logger = struct {
    const Self = @This();

    /// Points to the real per-core memory/IO controller
    log_ctx: *LoggerContext,

    slot_index: ?usize = null,
    prefix_ptr: ?[*]const u8 = null,
    prefix_len: usize = 0,

    pub fn init(log_ctx: *LoggerContext) Self {
        return .{ .log_ctx = log_ctx };
    }

    pub fn deinit(self: *Self) void {
        if (self.slot_index) |idx| {
            self.log_ctx.ctx_allocator.freeSlot(idx);
            self.slot_index = null;
            self.prefix_ptr = null;
            self.prefix_len = 0;
        }
    }

    inline fn writeLog(self: *Self, comptime level: consts.logLevel, comptime msg: []const u8, attrs: anytype) !void {
        const msg_len = msg.len;
        const attrs_size = encoding.getStructEncodedSize(attrs);
        const total_size = 16 + 2 + 8 + 1 + 1 + encoding.varintSize(msg_len) + msg_len + self.prefix_len + attrs_size;

        const buf_res = try self.log_ctx.get(total_size, std.heap.page_allocator);
        const base_ptr = switch (buf_res) {
            .stdbuf => |idx| self.log_ctx.log_allocator.getSlotPointer(idx),
            .heap => |h| h.buf.ptr,
        };

        // Create our lightweight formatting canvas on stack
        var frame = LogFrame.init(base_ptr);

        const version: u16 = consts.version;
        @memcpy(frame.cur[0..2], std.mem.asBytes(&version));
        frame.cur += 2;

        // 🌟 TOTAL SYSCALL WARFARE: Call sys_clock_gettime directly via kernel ABI
        // CLOCK_REALTIME is always 0 in Linux ABI
        const CLOCK_REALTIME: usize = 0;

        // Native kernel timespec layout (2 numbers: seconds and nanoseconds)
        var raw_ts = struct { tv_sec: isize, tv_nsec: isize }{ .tv_sec = 0, .tv_nsec = 0 };

        // Invoke native Linux syscall via inline assembly macros provided by Zig
        _ = std.os.linux.syscall2(.clock_gettime, CLOCK_REALTIME, @intFromPtr(&raw_ts));

        const timestamp = (@as(u64, @intCast(raw_ts.tv_sec)) * 1_000_000_000) + @as(u64, @intCast(raw_ts.tv_nsec));

        @memcpy(frame.cur[0..8], std.mem.asBytes(&timestamp));
        frame.cur += 8;

        frame.cur[0] = @intFromEnum(level);
        frame.cur += 1;

        frame.cur[0] = 0; // Location placeholder skip
        frame.cur += 1;

        frame.cur = encoding.appendVarint(frame.cur, msg_len);
        @memcpy(frame.cur[0..msg_len], msg);
        frame.cur += msg_len;

        if (self.prefix_len > 0) {
            @memcpy(frame.cur[0..self.prefix_len], self.prefix_ptr.?);
            frame.cur += self.prefix_len;
        }

        const structInfo = @typeInfo(@TypeOf(attrs));
        inline for (structInfo.@"struct".fields) |field| {
            frame.appendField(field.name, @field(attrs, field.name));
        }

        const output = frame.render();
        const user_data: u64 = switch (buf_res) {
            .stdbuf => |idx| @intCast(idx),
            .heap => |h| @intFromPtr(h.buf.ptr) | (@as(u64, 1) << 63),
        };

        try self.log_ctx.submitSQ(output.ptr, output.len, user_data);
    }

    pub fn Trace(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.trace, msg, attrs);
    }
    pub fn Debug(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.debug, msg, attrs);
    }
    pub fn Info(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.info, msg, attrs);
    }
    pub fn Warn(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.warning, msg, attrs);
    }
    pub fn Error(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.err, msg, attrs);
    }
    pub fn Panic(self: *Self, comptime msg: []const u8, attrs: anytype) !void {
        try self.writeLog(.panic, msg, attrs);
    }

    pub fn With(self: *Self, attrs: anytype) !Logger {
        const slot_idx = self.log_ctx.ctx_allocator.allocSlot() orelse return error.ContextPoolSaturated;
        const prefix_ptr = self.log_ctx.ctx_allocator.getSlotPointer(slot_idx);

        var frame = LogFrame.init(prefix_ptr);
        const structInfo = @typeInfo(@TypeOf(attrs));
        inline for (structInfo.@"struct".fields) |field| {
            frame.appendField(field.name, @field(attrs, field.name));
        }

        const prefix_len = @intFromPtr(frame.cur) - @intFromPtr(prefix_ptr + 16);

        return Logger{
            .log_ctx = self.log_ctx,
            .slot_index = slot_idx,
            .prefix_ptr = prefix_ptr + 16,
            .prefix_len = prefix_len,
        };
    }
};

/// A hyper-optimized, single-threaded rolling wave slot allocator for Event Loop tasks.
/// 0 atomics anywhere. Total memory lifecycle is managed within a single CPU core.
pub fn SlotAllocator(comptime total_slots: usize, comptime slot_size: usize) type {
    comptime {
        if (total_slots % 64 != 0) {
            @compileError("total_slots must be a multiple of 64.");
        }
        const words = total_slots / 64;
        if ((words & (words - 1)) != 0) {
            @compileError("Number of 64-bit words must be a power of 2 for fast wrapping.");
        }
    }

    const words_count = total_slots / 64;
    const bitmap_len_mask = words_count - 1;

    return struct {
        const Self = @This();

        /// Single unified bitmap for both allocating and releasing slots
        bitmap: [words_count]u64 = std.mem.zeroes([words_count]u64),

        /// Flat contiguous byte buffer backing the slots
        storage: []u8,

        /// Rolling wave counter tracking the current word pointer index (monotonically increases)
        wave: usize = 0,

        /// High-speed tracking counter to instantly detect absolute saturation
        free_count: usize = total_slots,

        pub fn init(buffer: []u8) Self {
            std.debug.assert(buffer.len >= total_slots * slot_size);
            return .{ .storage = buffer };
        }

        /// Allocates a free slot index using a single-threaded rolling wave.
        /// Fully branchless word-skipping path. Returns null only on absolute saturation.
        pub inline fn allocSlot(self: *Self) ?usize {
            if (self.free_count == 0) return null;

            const base_ptr: [*]u64 = @ptrCast(&self.bitmap);

            while (true) {
                // Calculate wrapped word index via fast bitwise AND
                const word_idx = self.wave & bitmap_len_mask;

                // 🌟 FIX: Access raw pointer memory directly via index [word_idx]
                // and invert it using the unyielding bitwise NOT operator '~'
                const w = ~base_ptr[word_idx];

                // Find the first free bit index using hardware TZCNT instruction (via @ctz in Zig)
                const empty_bit_idx = @ctz(w);

                if (empty_bit_idx < 64) {
                    // --- THE HOT PATH (Pure CPU registers, 0 overhead) ---
                    const global_slot_idx = (word_idx << 6) + empty_bit_idx;

                    // Occupy the slot bit in the bitmap directly via index access
                    base_ptr[word_idx] |= (@as(u64, 1) << @intCast(empty_bit_idx));
                    self.free_count -= 1;

                    return global_slot_idx;
                }

                // --- THE WAVE (Every slot in this word is taken) ---
                self.wave += 1;
            }
        }

        /// Instantly releases a slot bit by index.
        /// Called inside the same Event Loop thread when CQ processes io_uring completion.
        pub inline fn freeSlot(self: *Self, index: usize) void {
            const word_idx = index / 64;
            const bit_idx = index % 64;

            // Clear the bit directly to 0, making the slot immediately free
            self.bitmap[word_idx] &= ~(@as(u64, 1) << @intCast(bit_idx));

            self.free_count += 1;
        }

        /// Returns a direct raw pointer to the start of the specific slot memory block
        pub inline fn getSlotPointer(self: *Self, index: usize) [*]u8 {
            return self.storage.ptr + (index * slot_size);
        }
    };
}

const linux = std.os.linux;
const posix = std.posix;

// Global pre-allocated memory slices for our thread-local core logger pools.
// Placed in static storage to guarantee absolute 0 runtime allocation costs.
var test_log_pool_storage: [128 * 2048]u8 = undefined;
var test_ctx_pool_storage: [64 * 512]u8 = undefined;

// ============================================================================
// INTEGRATION DUMP TEST (SRUSHCHIY V STDOUT)
// ============================================================================

pub fn initTestFileLoggerContext(ring: *iouring.RawRing, file_path: []const u8) !LoggerContext {
    ring.* = try iouring.RawRing.init(1024, null);

    // 🌟 IMMORTAL SYSCALL OPENAT: Open/Create real file for SQPOLL writing
    // Flags: O_WRONLY (1) | O_CREAT (64) | O_TRUNC (512)
    const AT_FDCWD: i32 = -100;
    const flags: u32 = 1 | 64 | 512;
    const mode: u32 = 0o644; // RW for user, R for group/others

    // Convert slice to null-terminated string safely for syscall
    var path_buf: [256]u8 = undefined;
    @memcpy(path_buf[0..file_path.len], file_path);
    path_buf[file_path.len] = 0;

    const open_res = linux.syscall4(.openat, @bitCast(@as(isize, AT_FDCWD)), @intFromPtr(&path_buf), flags, mode);
    if (linux.errno(open_res) != .SUCCESS) return error.FileOpenFailed;
    const log_fd: posix.fd_t = @intCast(open_res);

    return LoggerContext.init(
        &test_log_pool_storage,
        &test_ctx_pool_storage,
        ring,
        log_fd,
    );
}

test "dump high-performance binary wal frame straight to file via native sqpoll" {
    var ring: iouring.RawRing = undefined;
    defer ring.deinit();

    // 1. Bootstrap the LoggerContext dispatcher mapped to a real file log instead of stdout
    const log_file_name = "test_wal.log";
    var log_ctx = try initTestFileLoggerContext(&ring, log_file_name);
    defer _ = linux.close(log_ctx.log_fd); // Close file descriptor on exit

    var logger = Logger.init(&log_ctx);

    var client_logger = try logger.With(.{
        .domain = "gateway-shard",
        .index_id = @as(u32, 77),
    });
    defer client_logger.deinit();

    // 2. Fire the real binary wal frame log event!
    try client_logger.Warn("user payload replication failed", .{
        .user_id = @as(u64, 888222111),
        .ticks_elapsed = @as(u32, 451),
        .payload_chunk = @as([]const u8, "raw_binary_chunk_bytes"),
        .flags = .{
            .is_retry = true,
            .is_corrupted = false,
        },
    });

    // 3. 🌟 THE REAL HYBRID CQ POLL:
    // Instead of raw sleeping, we tightly poll the completion ring.
    // If it's empty, we force the kernel thread to wake up and flush via enter_wait!
    var spin_count: usize = 0;
    var bytes_written_by_kernel: i32 = 0;

    while (true) {
        if (log_ctx.ring.popCQE()) |cqe| {
            // Hot path hit! Kernel finished the IO operation
            bytes_written_by_kernel = cqe.res;

            if (cqe.res < 0) {
                std.debug.print("\n💀 KERNEL IO_URING WRITE ERROR CODE: {d}\n", .{cqe.res});
            } else {
                std.debug.print("\n🚀 SUCCESS! KERNEL WROTE: {d} BYTES TO test_wal.log!\n", .{cqe.res});
            }

            // Clean up our allocated fast-path slot bit
            const is_heap_fallback = (cqe.user_data & (@as(u64, 1) << 63)) != 0;
            if (!is_heap_fallback) {
                const slot_idx: u32 = @intCast(cqe.user_data);
                log_ctx.release(slot_idx);
            }
            break; // We processed our log event completion, exit the test loop safely
        } else {
            spin_count += 1;
            if (spin_count < 2000) {
                _ = std.os.linux.sched_yield();
                continue;
            }

            // Spin limit reached, total silence.
            // Forcefully kick the kernel to process entries and wait for at least 1 event!
            spin_count = 0;
            try log_ctx.ring.enter_wait(1);
        }
    }

    // 4. Non-blocking Completion Queue poll to verify kernel response code
    while (log_ctx.ring.popCQE()) |cqe| {
        // 🌟 DIAGNOSTICS: Check if kernel returned negative error codes inside cqe.res!
        if (cqe.res < 0) {
            std.debug.print("\n💀 KERNEL IO_URING WRITE ERROR CODE: {d}\n", .{cqe.res});
        } else {
            std.debug.print("\n🚀 KERNEL SUCCESSFULLY WROTE: {d} BYTES TO DISK!\n", .{cqe.res});
        }

        const is_heap_fallback = (cqe.user_data & (@as(u64, 1) << 63)) != 0;
        if (!is_heap_fallback) {
            const slot_idx: u32 = @intCast(cqe.user_data);
            log_ctx.release(slot_idx);
        }
    }
}

/// Pre-computes the REFLECTED Castagnoli (CRC32C) lookup table strictly at compile-time.
/// Matches Go's hash/crc32 Castagnoli table logic pixel-for-pixel.
const crc32c_table: [256]u32 = block: {
    @setEvalBranchQuota(4000);

    var table: [256]u32 = undefined;
    // 🌟 GO COMPATIBLE REFLECTED POLYNOMIAL (Bit-reversed 0x1EDC6F41)
    const polynomial: u32 = 0x82F63B78;

    for (0..256) |i| {
        var crc = @as(u32, @intCast(i));
        for (0..8) |_| {
            if ((crc & 1) == 1) {
                crc = (crc >> 1) ^ polynomial;
            } else {
                crc >>= 1;
            }
        }
        table[i] = crc;
    }
    break :block table;
};

/// High-performance Software Castagnoli (CRC32C) calculation loop.
/// Mirroring Go's exact hash/crc32 IEEE/Castagnoli behavior.
pub inline fn crc32cSoftware(data: []const u8) u32 {
    // 🌟 CLASSIC INITIALIZATION (Matches Go internal state)
    var crc: u32 = 0xFFFFFFFF;

    for (data) |byte| {
        // Reflected table lookup step
        const table_idx = @as(u8, @intCast((crc ^ byte) & 0xFF));
        crc = (crc >> 8) ^ crc32c_table[table_idx];
    }

    // 🌟 RETURN INVERTED STATE (Matches Go's final ~crc return block)
    return ~crc;
}
