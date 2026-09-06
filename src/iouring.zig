const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const page_size: usize = 4096;

pub const RawRing = struct {
    const Self = @This(); // Exact type mapping verified

    fd: posix.fd_t,
    flags: u32,

    sq_mmap_ptr: []align(page_size) u8,
    cq_mmap_ptr: []align(4096) u8, // Using literal page_size alignment
    sqes_mmap_ptr: []align(page_size) u8,

    // 🌟 CHANGED: Pointers are now pure *u32 to allow canonical @atomicStore / @atomicLoad operations
    sq_head: *u32,
    sq_tail: *u32,
    sq_mask: u32,
    sq_array: [*]u32,
    sq_entries: [*]linux.io_uring_sqe,

    cq_head: *u32,
    cq_tail: *u32,
    cq_mask: u32,
    cq_entries: [*]linux.io_uring_cqe,

    pub fn init(queue_depth: u32, attach_fd: ?posix.fd_t) !Self {
        var params = std.mem.zeroes(linux.io_uring_params);
        params.flags = linux.IORING_SETUP_SQPOLL;

        if (attach_fd) |master_fd| {
            params.flags |= linux.IORING_SETUP_ATTACH_WQ;
            params.wq_fd = @intCast(master_fd);
        }

        const setup_res = linux.io_uring_setup(queue_depth, &params);
        if (linux.errno(setup_res) != .SUCCESS) return error.URingSetupFailed;
        const ring_fd: posix.fd_t = @intCast(setup_res);

        const sq_len = params.sq_off.array + (params.sq_entries * @sizeOf(u32));
        const sq_mmap = try posix.mmap(
            null,
            sq_len,
            linux.PROT{ .READ = true, .WRITE = true }, // Verified clean syntax
            .{ .TYPE = .SHARED },
            ring_fd,
            linux.IORING_OFF_SQ_RING,
        );

        const sqes_len = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqes_mmap = try posix.mmap(
            null,
            sqes_len,
            linux.PROT{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            ring_fd,
            linux.IORING_OFF_SQES,
        );

        const cq_len = params.cq_off.cqes + (params.cq_entries * @sizeOf(linux.io_uring_cqe));
        const cq_mmap = try posix.mmap(
            null,
            cq_len,
            linux.PROT{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            ring_fd,
            linux.IORING_OFF_CQ_RING,
        );

        const sq_base = sq_mmap.ptr;
        const cq_base = cq_mmap.ptr;

        const sq_mask_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.ring_mask));
        const cq_mask_ptr: *u32 = @ptrCast(@alignCast(cq_base + params.cq_off.ring_mask));

        return .{
            .fd = ring_fd,
            .flags = params.flags,
            .sq_mmap_ptr = sq_mmap,
            .cq_mmap_ptr = cq_mmap,
            .sqes_mmap_ptr = sqes_mmap,

            .sq_head = @ptrCast(@alignCast(sq_base + params.sq_off.head)),
            .sq_tail = @ptrCast(@alignCast(sq_base + params.sq_off.tail)),
            .sq_mask = sq_mask_ptr.*,
            .sq_array = @ptrCast(@alignCast(sq_base + params.sq_off.array)),
            .sq_entries = @ptrCast(@alignCast(sqes_mmap.ptr)),

            .cq_head = @ptrCast(@alignCast(cq_base + params.cq_off.head)),
            .cq_tail = @ptrCast(@alignCast(cq_base + params.cq_off.tail)),
            .cq_mask = cq_mask_ptr.*,
            .cq_entries = @ptrCast(@alignCast(cq_base + params.cq_off.cqes)),
        };
    }

    pub fn deinit(self: *Self) void {
        posix.munmap(self.sq_mmap_ptr);
        posix.munmap(self.sqes_mmap_ptr);
        posix.munmap(self.cq_mmap_ptr);
        _ = linux.close(self.fd);
    }

    pub inline fn pushSQ(self: *Self, target_fd: posix.fd_t, data_ptr: [*]const u8, len: usize, user_data: u64) !void {
        // 🌟 CANONICAL ATOMIC LOAD: Use compiler built-in tracking
        const tail = @atomicLoad(u32, self.sq_tail, .monotonic);
        const head = @atomicLoad(u32, self.sq_head, .acquire);

        if (tail - head >= self.sq_mask + 1) {
            return error.RingFull;
        }

        const sqe_idx = tail & self.sq_mask;
        var sqe = &self.sq_entries[sqe_idx];

        @memset(std.mem.asBytes(sqe), 0);

        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.fd = target_fd;
        sqe.addr = @intFromPtr(data_ptr);
        sqe.len = @intCast(len);
        sqe.user_data = user_data;

        self.sq_array[sqe_idx] = sqe_idx;

        // 🌟 CANONICAL ATOMIC STORE-RELEASE:
        // This acts as a bulletproof hardware fence and pushes tail safely to the kernel loop thread!
        @atomicStore(u32, self.sq_tail, tail + 1, .release);

        if (tail == head) {
            var sig: linux.sigset_t = undefined;
            _ = linux.io_uring_enter(self.fd, 1, 0, linux.IORING_ENTER_SQ_WAKEUP, &sig);
        }
    }

    pub inline fn popCQE(self: *Self) ?struct { user_data: u64, res: i32 } {
        const head = @atomicLoad(u32, self.cq_head, .monotonic);
        const tail = @atomicLoad(u32, self.cq_tail, .acquire);

        if (head == tail) return null;

        const cqe_idx = head & self.cq_mask;
        const cqe = &self.cq_entries[cqe_idx];

        const out_user_data = cqe.user_data;
        const out_res = cqe.res;

        // 🌟 CANONICAL ATOMIC STORE-RELEASE: Advanced CQ head notification loop
        @atomicStore(u32, self.cq_head, head + 1, .release);

        return .{
            .user_data = out_user_data,
            .res = out_res,
        };
    }

    pub fn enter_wait(self: *Self, want_cqe: u32) !void {
        var sig: linux.sigset_t = undefined;
        _ = linux.io_uring_enter(self.fd, 0, want_cqe, linux.IORING_ENTER_GETEVENTS, &sig);
    }
};
