//! A minimal blocking spinlock on `std.atomic.Value`, mirroring nether's
//! src/common/lock.zig. It deliberately avoids std's mutex surface, which has
//! churned across 0.16 builds (std.Thread.Mutex moved / std.atomic.Mutex comes
//! and goes); `std.atomic.Value` + cmpxchg/spinLoopHint are stable.
//!
//! Fit for the supervisor: the only shared state is the pool (a 64-slot scan)
//! and the per-VM bring-up-owner claim. Every critical section is a handful of
//! field writes held for microseconds; the SLOW work (driving a booting VM to
//! serving) runs OUTSIDE the lock. So spinning, not parking, is the right shape.

const std = @import("std");

pub const Lock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // 0 = free, 1 = held

    pub fn tryLock(self: *Lock) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Lock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Lock) void {
        self.state.store(0, .release);
    }
};

test "lock excludes then releases" {
    var l = Lock{};
    l.lock();
    try std.testing.expect(!l.tryLock()); // held
    l.unlock();
    try std.testing.expect(l.tryLock()); // free again
    l.unlock();
}
