const std = @import("std");
const sm = @import("coroutines").state_machine;

/// Checkers recurse deeply on real type graphs; the default thread stack is far too small.
pub const stack_size = 256 * 1024 * 1024;

/// `requested` when positive, else the CPU count (4 when it cannot be read).
pub fn jobCount(requested: usize) usize {
    if (requested > 0) return requested;
    return std.Thread.getCpuCount() catch 4;
}

/// How many workers a pass gets. Each pass spawns and joins its own, so nothing here holds a
/// thread or needs shutting down.
pub const ThreadPool = struct {
    jobs: usize,

    pub fn init(jobs: usize) ThreadPool {
        return .{ .jobs = std.math.clamp(jobs, 1, sm.max_threads) };
    }

    /// Number of distinct `worker` indices a task may see.
    pub fn width(p: *const ThreadPool) usize {
        return p.jobs;
    }
};

test "width stays within what a pass can spawn" {
    try std.testing.expectEqual(@as(usize, 1), ThreadPool.init(0).width());
    try std.testing.expectEqual(@as(usize, 16), ThreadPool.init(16).width());
    try std.testing.expectEqual(@as(usize, sm.max_threads), ThreadPool.init(sm.max_threads + 1).width());
}
