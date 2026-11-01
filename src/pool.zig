const std = @import("std");
const sm = @import("coroutines").state_machine;
pub const threads = @import("pool/threads.zig");
pub const schedule = @import("pool/schedule.zig");

pub const ThreadPool = threads.ThreadPool;
pub const jobCount = threads.jobCount;

fn dispatch(tp: *ThreadPool, count: usize, chunk: usize, ctx: anytype, comptime work: anytype) void {
    if (count == 0) return;
    // More workers from inside a worker would multiply threads and big stacks.
    if (sm.currentWorker()) |worker| {
        for (0..count) |i| work(ctx, worker, i);
        return;
    }
    const Item = struct {
        ctx: @TypeOf(ctx),
        index: usize,

        pub fn step(item: *@This()) sm.Step {
            work(item.ctx, sm.currentWorker().?, item.index);
            return .done;
        }
    };
    const a = std.heap.smp_allocator;
    const items = a.alloc(Item, count) catch @panic("out of memory");
    defer a.free(items);
    for (items, 0..) |*item, i| item.* = .{ .ctx = ctx, .index = i };
    // The caller only waits, because its own stack is the small default one.
    const opts: sm.ParallelOptions = .{ .threads = tp.width(), .chunk = chunk, .stack_size = threads.stack_size, .caller_works = false };
    sm.runParallel(Item, items, opts) catch unreachable;
}

/// Runs `work(ctx, worker, index)` for every index, in chunks: for many small items.
pub fn parallelFor(tp: *ThreadPool, count: usize, ctx: anytype, comptime work: anytype) void {
    dispatch(tp, count, schedule.chunkSize(count, tp.width()), ctx, work);
}

/// Like `parallelFor`, one index at a time: for items slow enough that a chunk could strand them.
pub fn parallelForEach(tp: *ThreadPool, count: usize, ctx: anytype, comptime work: anytype) void {
    dispatch(tp, count, 1, ctx, work);
}

test {
    _ = threads;
    _ = schedule;
}

test "parallelFor visits every index once" {
    var tp = ThreadPool.init(8);
    var seen: [64]std.atomic.Value(u32) = @splat(.init(0));
    const visit = struct {
        fn f(s: *[64]std.atomic.Value(u32), _: usize, i: usize) void {
            _ = s[i].fetchAdd(1, .monotonic);
        }
    }.f;
    parallelFor(&tp, seen.len, &seen, visit);
    parallelForEach(&tp, seen.len, &seen, visit);
    for (&seen) |*v| try std.testing.expectEqual(@as(u32, 2), v.load(.monotonic));
}

test "every pass runs off the calling thread, on a worker within the width" {
    const Ctx = struct { caller: std.Thread.Id, width: usize, bad: std.atomic.Value(u32) = .init(0) };
    for ([_]usize{ 1, 4 }) |jobs| {
        var tp = ThreadPool.init(jobs);
        var c = Ctx{ .caller = std.Thread.getCurrentId(), .width = tp.width() };
        parallelForEach(&tp, 32, &c, struct {
            fn f(x: *Ctx, worker: usize, _: usize) void {
                if (std.Thread.getCurrentId() == x.caller or worker >= x.width) _ = x.bad.fetchAdd(1, .monotonic);
            }
        }.f);
        try std.testing.expectEqual(@as(u32, 0), c.bad.load(.monotonic));
    }
}

test "a nested call runs inline on its own worker" {
    var tp = ThreadPool.init(2);
    var hits = std.atomic.Value(u32).init(0);
    const Ctx = struct { tp: *ThreadPool, hits: *std.atomic.Value(u32) };
    parallelForEach(&tp, 4, &Ctx{ .tp = &tp, .hits = &hits }, struct {
        fn outer(c: *const Ctx, worker: usize, _: usize) void {
            parallelForEach(c.tp, 3, &Inner{ .hits = c.hits, .worker = worker }, inner);
        }
        const Inner = struct { hits: *std.atomic.Value(u32), worker: usize };
        fn inner(c: *const Inner, worker: usize, _: usize) void {
            if (worker == c.worker) _ = c.hits.fetchAdd(1, .monotonic);
        }
    }.outer);
    try std.testing.expectEqual(@as(u32, 12), hits.load(.monotonic));
}
