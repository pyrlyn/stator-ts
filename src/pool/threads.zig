const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Checkers recurse deeply on real type graphs; the default thread stack is far too small.
pub const stack_size = 256 * 1024 * 1024;

pub fn jobCount(requested: usize) usize {
    if (requested > 0) return requested;
    return std.Thread.getCpuCount() catch 4;
}

pub const Task = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, worker: usize) void,
};

threadlocal var on_worker = false;

/// One set of big-stack threads for the whole process. They sleep between tasks, so the many
/// short parallel passes of a run do not pay for a spawn, a stack mapping and a join each.
pub const ThreadPool = struct {
    io: Io,
    threads: []std.Thread,
    task: Task = undefined,
    /// Workers sleep on this; every new task moves it on by one.
    generation: std.atomic.Value(u32) = .init(0),
    /// Workers still inside the current task; the caller sleeps on this.
    pending: std.atomic.Value(u32) = .init(0),
    stopping: bool = false,

    pub fn init(a: Allocator, io: Io, jobs: usize) !*ThreadPool {
        const p = try a.create(ThreadPool);
        const threads = try a.alloc(std.Thread, jobs);
        p.* = .{ .io = io, .threads = threads };
        var spawned: usize = 0;
        for (threads, 0..) |*t, i| {
            // A failed spawn only costs parallelism.
            t.* = std.Thread.spawn(.{ .stack_size = stack_size }, worker, .{ p, i }) catch break;
            spawned += 1;
        }
        p.threads = threads[0..spawned];
        return p;
    }

    pub fn deinit(p: *ThreadPool) void {
        p.stopping = true;
        _ = p.generation.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.generation.raw, std.math.maxInt(u32));
        for (p.threads) |t| t.join();
    }

    /// Number of distinct `worker` indices a task may see.
    pub fn width(p: *const ThreadPool) usize {
        return @max(1, p.threads.len);
    }

    /// Runs `task` once on every worker and returns when all are done. The caller only waits,
    /// because its own stack is the small default one.
    pub fn run(p: *ThreadPool, task: Task) void {
        // Waiting from inside a worker would wait on that worker forever.
        if (p.threads.len == 0 or on_worker) return task.run(task.ctx, 0);
        p.task = task;
        p.pending.store(@intCast(p.threads.len), .release);
        _ = p.generation.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.generation.raw, std.math.maxInt(u32));
        while (true) {
            const left = p.pending.load(.acquire);
            if (left == 0) return;
            p.io.futexWaitUncancelable(u32, &p.pending.raw, left);
        }
    }

    fn worker(p: *ThreadPool, index: usize) void {
        on_worker = true;
        var seen: u32 = 0;
        while (true) {
            const now = p.generation.load(.acquire);
            if (now == seen) {
                p.io.futexWaitUncancelable(u32, &p.generation.raw, seen);
                continue;
            }
            seen = now;
            if (p.stopping) return;
            p.task.run(p.task.ctx, index);
            if (p.pending.fetchSub(1, .acq_rel) == 1) p.io.futexWake(u32, &p.pending.raw, 1);
        }
    }
};

test "a task reaches every worker, repeatedly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tp = try ThreadPool.init(arena.allocator(), std.testing.io, 4);
    defer tp.deinit();
    var hits = std.atomic.Value(u32).init(0);
    const count = struct {
        fn f(ctx: *anyopaque, _: usize) void {
            const h: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
            _ = h.fetchAdd(1, .monotonic);
        }
    }.f;
    for (0..200) |_| tp.run(.{ .ctx = &hits, .run = count });
    try std.testing.expectEqual(@as(u32, @intCast(200 * tp.width())), hits.load(.monotonic));
}
