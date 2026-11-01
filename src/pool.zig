const std = @import("std");
pub const threads = @import("pool/threads.zig");
pub const schedule = @import("pool/schedule.zig");

pub const ThreadPool = threads.ThreadPool;
pub const jobCount = threads.jobCount;

fn dispatch(tp: *ThreadPool, count: usize, chunk: usize, ctx: anytype, comptime work: anytype) void {
    if (count == 0) return;
    const Job = struct {
        cursor: schedule.Cursor,
        ctx: @TypeOf(ctx),

        fn run(raw: *anyopaque, worker: usize) void {
            const j: *@This() = @ptrCast(@alignCast(raw));
            while (j.cursor.claim()) |r| for (r.start..r.end) |i| work(j.ctx, worker, i);
        }
    };
    var job = Job{ .cursor = .{ .total = count, .chunk = chunk }, .ctx = ctx };
    tp.run(.{ .ctx = &job, .run = Job.run });
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tp = try ThreadPool.init(arena.allocator(), std.testing.io, 8);
    defer tp.deinit();
    var seen = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** 64;
    const visit = struct {
        fn f(s: *[64]std.atomic.Value(u32), _: usize, i: usize) void {
            _ = s[i].fetchAdd(1, .monotonic);
        }
    }.f;
    parallelFor(tp, seen.len, &seen, visit);
    parallelForEach(tp, seen.len, &seen, visit);
    for (&seen) |*v| try std.testing.expectEqual(@as(u32, 2), v.load(.monotonic));
}

test "a nested call runs inline instead of waiting on itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tp = try ThreadPool.init(arena.allocator(), std.testing.io, 2);
    defer tp.deinit();
    var hits = std.atomic.Value(u32).init(0);
    const Ctx = struct { tp: *ThreadPool, hits: *std.atomic.Value(u32) };
    parallelForEach(tp, 4, &Ctx{ .tp = tp, .hits = &hits }, struct {
        fn outer(c: *const Ctx, _: usize, _: usize) void {
            parallelForEach(c.tp, 3, c.hits, inner);
        }
        fn inner(h: *std.atomic.Value(u32), _: usize, _: usize) void {
            _ = h.fetchAdd(1, .monotonic);
        }
    }.outer);
    try std.testing.expectEqual(@as(u32, 12), hits.load(.monotonic));
}
