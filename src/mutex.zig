const std = @import("std");
const c = std.c;

// Import C functions directly from libc by hand
extern "c" fn pthread_mutex_init(mutex: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_destroy(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_lock(mutex: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(mutex: *c.pthread_mutex_t) c_int;

/// A thin, libc-backed mutex (`pthread_mutex_t`).
///
/// The raw object is stored inline, so the `Mutex` must live at a stable
/// address for its whole lifetime; do not copy or move it once it may be
/// contended. There is no reentrancy and no timeout: a blocked `lock` parks
/// the calling thread inside the kernel.
pub const Mutex = struct {
    raw: c.pthread_mutex_t,

    /// Initializes the mutex with default (process-private) attributes.
    ///
    /// Must be paired with `deinit` on the same instance. Pthreads requires the
    /// same memory to be used for init, lock, unlock and destroy, so keep the
    /// returned value where it is.
    pub fn init() Mutex {
        var self = Mutex{
            // Properly zero the memory for the C struct
            .raw = std.mem.zeroes(c.pthread_mutex_t),
        };
        // Initialize the mutex with default attributes (null)
        _ = pthread_mutex_init(&self.raw, null);
        return self;
    }

    /// Destroys the mutex and releases any resources libc attached to it.
    ///
    /// The mutex must be unlocked and have no waiters, and must not be used
    /// afterwards. The memory holding the `Mutex` itself is not freed.
    pub fn deinit(self: *Mutex) void {
        _ = pthread_mutex_destroy(&self.raw);
    }

    /// Acquires the mutex, blocking the calling thread (inside the kernel)
    /// while another thread holds it. There is no timeout, no priority
    /// inheritance and no fairness guarantee.
    pub fn lock(self: *Mutex) void {
        // Regular blocking lock: if busy, the thread sleeps in the OS kernel
        _ = pthread_mutex_lock(&self.raw);
    }

    /// Releases the mutex. Must be called by the thread that locked it.
    pub fn unlock(self: *Mutex) void {
        _ = pthread_mutex_unlock(&self.raw);
    }
};
