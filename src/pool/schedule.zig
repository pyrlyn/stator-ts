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

/// Cuts `weights` into at most `most` contiguous runs of similar weight, none lighter than
/// `least` but the last. Fixed for fixed input.
pub fn runsByWeight(a: Allocator, weights: []const u64, most: usize, least: u64) ![]Range {
    var total: u64 = 0;
    for (weights) |w| total += w;
    const per_run = @max(total / most + 1, least);
    var runs: std.ArrayList(Range) = .empty;
    var start: usize = 0;
    var load: u64 = 0;
    for (weights, 0..) |w, i| {
        load += w;
        if (load < per_run and i + 1 < weights.len) continue;
        try runs.append(a, .{ .start = start, .end = i + 1 });
        start = i + 1;
        load = 0;
    }
    return runs.items;
}

test "cursor hands out every index once" {
    var c = Cursor{ .total = 10, .chunk = 3 };
    var seen: [10]u8 = @splat(0);
    while (c.claim()) |r| for (r.start..r.end) |i| {
        seen[i] += 1;
    };
    for (seen) |s| try std.testing.expectEqual(@as(u8, 1), s);
}

test "runs cover every index in order and balance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runs = try runsByWeight(arena.allocator(), &.{ 90, 10, 10, 10, 10, 10, 10, 10, 10, 10 }, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqual(Range{ .start = 0, .end = 2 }, runs[0]);
    try std.testing.expectEqual(Range{ .start = 2, .end = 10 }, runs[1]);
}

test "a light input stays in fewer runs than it could have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try runsByWeight(a, &.{ 10, 10, 10 }, 8, 100)).len);
    const runs = try runsByWeight(a, &.{ 10, 10, 10 }, 8, 20);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqual(@as(usize, 3), runs[1].end);
}

test "never more runs than asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 2), (try runsByWeight(a, &.{ 7, 7, 7 }, 3, 1)).len);
    try std.testing.expectEqual(@as(usize, 3), (try runsByWeight(a, &.{ 1, 1, 1 }, 64, 1)).len);
}
