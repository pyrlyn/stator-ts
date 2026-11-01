const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Range = struct { start: usize, end: usize };

/// Hands out `[0, total)` in chunks, each index exactly once.
pub const Cursor = struct {
    next: std.atomic.Value(usize) = .init(0),
    total: usize,
    chunk: usize,

    pub fn claim(c: *Cursor) ?Range {
        const start = c.next.fetchAdd(c.chunk, .monotonic);
        if (start >= c.total) return null;
        return .{ .start = start, .end = @min(start + c.chunk, c.total) };
    }
};

/// Small enough that a run of slow items still balances, large enough that workers on small
/// items do not all fight over one cache line.
pub fn chunkSize(count: usize, workers: usize) usize {
    return @max(1, count / (workers * 8));
}

/// Cuts `weights` into `runs_per_worker * n` contiguous runs of similar weight, then deals them to
/// `n` groups, heaviest first, each to the lightest group so far. Fixed for fixed input: ties
/// keep input order, and every group lists its indices in deal order.
pub fn partitionByWeight(a: Allocator, weights: []const u64, n: usize, runs_per_worker: usize) ![][]usize {
    var total: u64 = 0;
    for (weights) |w| total += w;
    const per_run = total / (n * runs_per_worker) + 1;
    const Run = struct { start: usize, end: usize, load: u64 };
    var runs: std.ArrayList(Run) = .empty;
    var start: usize = 0;
    var load: u64 = 0;
    for (weights, 0..) |w, i| {
        load += w;
        if (load < per_run and i + 1 < weights.len) continue;
        try runs.append(a, .{ .start = start, .end = i + 1, .load = load });
        start = i + 1;
        load = 0;
    }
    std.mem.sort(Run, runs.items, {}, struct {
        fn less(_: void, l: Run, r: Run) bool {
            if (l.load != r.load) return l.load > r.load;
            return l.start < r.start;
        }
    }.less);
    const lists = try a.alloc(std.ArrayList(usize), n);
    @memset(lists, .empty);
    const loads = try a.alloc(u64, n);
    @memset(loads, 0);
    for (runs.items) |r| {
        const k = std.mem.indexOfMin(u64, loads);
        for (r.start..r.end) |i| try lists[k].append(a, i);
        loads[k] += r.load;
    }
    const out = try a.alloc([]usize, n);
    for (lists, 0..) |l, i| out[i] = l.items;
    return out;
}

test "cursor hands out every index once" {
    var c = Cursor{ .total = 10, .chunk = 3 };
    var seen = [_]u8{0} ** 10;
    while (c.claim()) |r| for (r.start..r.end) |i| {
        seen[i] += 1;
    };
    for (seen) |s| try std.testing.expectEqual(@as(u8, 1), s);
}

test "partition covers every index and balances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const groups = try partitionByWeight(arena.allocator(), &.{ 90, 10, 10, 10, 10, 10, 10, 10, 10, 10 }, 2, 8);
    var seen = [_]u8{0} ** 10;
    var loads = [_]u64{ 0, 0 };
    for (groups, 0..) |g, k| for (g) |i| {
        seen[i] += 1;
        loads[k] += if (i == 0) 90 else 10;
    };
    for (seen) |s| try std.testing.expectEqual(@as(u8, 1), s);
    try std.testing.expectEqual(@as(u64, 90), loads[0]);
    try std.testing.expectEqual(@as(u64, 90), loads[1]);
}
