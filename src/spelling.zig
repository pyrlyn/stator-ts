//! tsc's getSpellingSuggestion, which decides between "Cannot find name" and "Did you mean".
const std = @import("std");

/// The closest candidate of similar length. Ties go to the first one seen, as in tsc.
pub fn best(a: std.mem.Allocator, name: []const u8, candidates: []const []const u8) ?[]const u8 {
    const len: f64 = @floatFromInt(name.len);
    const max_len_diff: usize = @intFromFloat(@max(2, @floor(len * 0.34)));
    var best_distance = @floor(len * 0.4) + 1;
    var found: ?[]const u8 = null;
    var scratch: []f64 = &.{};
    for (candidates) |x| {
        if (x.len > name.len + max_len_diff or name.len > x.len + max_len_diff) continue;
        if (std.mem.eql(u8, x, name)) continue;
        // Short names only count when they differ by case: anyone notices the rest.
        if (x.len < 3 and !std.ascii.eqlIgnoreCase(x, name)) continue;
        if (scratch.len < (x.len + 1) * 2) scratch = a.alloc(f64, (x.len + 1) * 2) catch return found;
        const dist = distance(name, x, best_distance - 0.1, scratch) orelse continue;
        best_distance = dist;
        found = x;
    }
    return found;
}

/// Levenshtein with a case-only change costing 0.1 and any other substitution costing 2.
fn distance(s1: []const u8, s2: []const u8, max: f64, scratch: []f64) ?f64 {
    var previous = scratch[0 .. s2.len + 1];
    var current = scratch[s2.len + 1 .. (s2.len + 1) * 2];
    const big = max + 0.01;
    for (previous, 0..) |*v, i| v.* = @floatFromInt(i);
    for (s1, 1..) |c1, i| {
        const row: f64 = @floatFromInt(i);
        const width: f64 = @floatFromInt(s2.len);
        const min_j: usize = @intFromFloat(@ceil(if (row > max) row - max else 1));
        const max_j: usize = @intFromFloat(@floor(if (width > max + row) max + row else width));
        current[0] = row;
        var col_min = row;
        for (1..@min(min_j, s2.len + 1)) |j| current[j] = big;
        var j = min_j;
        while (j <= max_j) : (j += 1) {
            const c2 = s2[j - 1];
            const substitution = previous[j - 1] + @as(f64, if (std.ascii.toLower(c1) == std.ascii.toLower(c2)) 0.1 else 2);
            const dist = if (c1 == c2) previous[j - 1] else @min(previous[j] + 1, current[j - 1] + 1, substitution);
            current[j] = dist;
            col_min = @min(col_min, dist);
        }
        j = max_j + 1;
        while (j <= s2.len) : (j += 1) current[j] = big;
        if (col_min > max) return null;
        std.mem.swap([]f64, &previous, &current);
    }
    const res = previous[s2.len];
    return if (res > max) null else res;
}

test "suggestions follow tsc's distance" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const list = [_][]const u8{ "console", "Console", "consul" };
    try std.testing.expectEqualStrings("Console", best(arena.allocator(), "console", &list).?);
    try std.testing.expect(best(arena.allocator(), "zzzzzz", &list) == null);
}
