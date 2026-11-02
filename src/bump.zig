//! Bump allocation for one thread, in place of `std.heap.ArenaAllocator`, which takes atomics on
//! every allocation, leaves behind every table that grows, and on reset trades its chunks for one
//! new mapping whose pages all fault again. The whole of a run lives here, so those costs are most
//! of what an allocator can cost.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const chunk_len = 4 * 1024 * 1024;
/// Anything larger gets a mapping of its own, so that a chunk does not end in a long unused tail.
const big_len = chunk_len / 4;
/// A freed block holds its own list entry, and below this it is not worth finding again.
const least_block = 64;
/// Keep one warm window without retaining every worker's high-water mark.
const retained_chunks = 1;
const class_count = @bitSizeOf(usize);
const block_alignment: Alignment = .@"8";
/// Bound the search through similarly sized blocks before splitting a larger one.
const class_probes = 4;

const Chunk = struct {
    next: ?*Chunk,
    len: usize,

    fn start(c: *Chunk) usize {
        return @intFromPtr(c) + @sizeOf(Chunk);
    }

    fn end(c: *Chunk) usize {
        return @intFromPtr(c) + c.len;
    }

    fn slice(c: *Chunk) []align(@alignOf(Chunk)) u8 {
        return @as([*]align(@alignOf(Chunk)) u8, @ptrCast(c))[0..c.len];
    }
};

const Block = struct { next: ?*Block, len: usize };

pub const Bump = struct {
    backing: Allocator,
    first: ?*Chunk = null,
    cur: ?*Chunk = null,
    big: ?*Chunk = null,
    at: usize = 0,
    limit: usize = 0,
    /// Blocks of `2^i` bytes up to the next power of two. Hash tables and lists grow by copying,
    /// and between them they keep asking for sizes something else just gave up.
    free_blocks: [class_count]?*Block = @splat(null),
    available: usize = 0,

    pub fn init(backing: Allocator) Bump {
        return .{ .backing = backing };
    }

    pub fn allocator(b: *Bump) Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Chunks stay mapped with their pages touched, because the next run wants the same again. Only
    /// up to `retained_chunks` of them: runs differ by a factor of ten, and a worker holding on to
    /// the largest it ever had is most of the peak of the whole process.
    pub fn reset(b: *Bump) void {
        while (b.big) |c| {
            b.big = c.next;
            b.backing.free(c.slice());
        }
        b.free_blocks = @splat(null);
        b.available = 0;
        var kept: usize = 0;
        var last: ?*Chunk = null;
        var at = b.first;
        while (at) |c| : (kept += 1) {
            if (kept == retained_chunks) {
                last.?.next = null;
                while (at) |x| {
                    at = x.next;
                    b.backing.free(x.slice());
                }
                break;
            }
            last = c;
            at = c.next;
        }
        b.cur = b.first;
        b.at = if (b.first) |c| c.start() else 0;
        b.limit = if (b.first) |c| c.end() else 0;
    }

    pub fn deinit(b: *Bump) void {
        b.reset();
        while (b.first) |c| {
            b.first = c.next;
            b.backing.free(c.slice());
        }
        b.cur = null;
        b.at = 0;
        b.limit = 0;
    }

    fn classOf(len: usize) usize {
        return std.math.log2_int(usize, len);
    }

    fn reuse(b: *Bump, len: usize, al: Alignment) ?[*]u8 {
        const low = classOf(len);
        var candidates = b.available & (~@as(usize, 0) << @intCast(low));
        while (candidates != 0) {
            const class = @ctz(candidates);
            candidates &= candidates - 1;
            var link = &b.free_blocks[class];
            var left: usize = class_probes;
            while (link.*) |x| : (link = &x.next) {
                const start = @intFromPtr(x);
                const aligned = al.forward(start);
                const prefix = aligned - start;
                const room = x.len;
                if (prefix <= room and len <= room - prefix) {
                    link.* = x.next;
                    if (b.free_blocks[class] == null) b.available &= ~(@as(usize, 1) << @intCast(class));
                    // Splitting keeps a large table useful for several smaller ones.
                    b.keep(start, prefix);
                    b.keep(aligned + len, room - prefix - len);
                    return @ptrFromInt(aligned);
                }
                left -= 1;
                if (left == 0) break;
            }
        }
        return null;
    }

    fn keep(b: *Bump, at: usize, len: usize) void {
        const p = block_alignment.forward(at);
        if (p + least_block > at + len) return;
        const room = at + len - p;
        const class = classOf(room);
        const x: *Block = @ptrFromInt(p);
        x.* = .{ .next = b.free_blocks[class], .len = room };
        b.free_blocks[class] = x;
        b.available |= @as(usize, 1) << @intCast(class);
    }

    fn mapped(b: *Bump, len: usize) ?*Chunk {
        const mem = b.backing.alignedAlloc(u8, .of(Chunk), len) catch return null;
        const c: *Chunk = @ptrCast(mem.ptr);
        c.* = .{ .next = null, .len = len };
        return c;
    }

    /// The window is used up, or the request will not fit a chunk.
    fn fresh(b: *Bump, len: usize, al: Alignment) ?[*]u8 {
        const room = len + al.toByteUnits() + @sizeOf(Chunk);
        if (room > big_len) {
            const c = b.mapped(room) orelse return null;
            c.next = b.big;
            b.big = c;
            return @ptrFromInt(al.forward(c.start()));
        }
        const c = if (b.cur) |x| x.next orelse blk: {
            const n = b.mapped(chunk_len) orelse return null;
            x.next = n;
            break :blk n;
        } else blk: {
            const n = b.mapped(chunk_len) orelse return null;
            b.first = n;
            break :blk n;
        };
        // A failed mapping must leave the current window exclusively owned by the bump cursor.
        b.keep(b.at, b.limit - b.at);
        b.cur = c;
        const p = al.forward(c.start());
        b.at = p + len;
        b.limit = c.end();
        return @ptrFromInt(p);
    }

    fn alloc(ctx: *anyopaque, len: usize, al: Alignment, _: usize) ?[*]u8 {
        const b: *Bump = @ptrCast(@alignCast(ctx));
        if (len >= least_block) if (b.reuse(len, al)) |p| return p;
        const p = al.forward(b.at);
        if (p + len > b.limit) return b.fresh(len, al);
        b.at = p + len;
        return @ptrFromInt(p);
    }

    fn resize(ctx: *anyopaque, m: []u8, _: Alignment, len: usize, _: usize) bool {
        const b: *Bump = @ptrCast(@alignCast(ctx));
        if (len <= m.len) {
            if (@intFromPtr(m.ptr) + m.len == b.at) {
                b.at = @intFromPtr(m.ptr) + len;
            } else {
                b.keep(@intFromPtr(m.ptr) + len, m.len - len);
            }
            return true;
        }
        if (@intFromPtr(m.ptr) + m.len != b.at or @intFromPtr(m.ptr) + len > b.limit) return false;
        b.at = @intFromPtr(m.ptr) + len;
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: Alignment, len: usize, ret: usize) ?[*]u8 {
        return if (resize(ctx, m, al, len, ret)) m.ptr else null;
    }

    fn free(ctx: *anyopaque, m: []u8, _: Alignment, _: usize) void {
        const b: *Bump = @ptrCast(@alignCast(ctx));
        if (@intFromPtr(m.ptr) + m.len == b.at) {
            b.at = @intFromPtr(m.ptr);
            return;
        }
        b.keep(@intFromPtr(m.ptr), m.len);
    }
};

test "a freed table comes back for the next one" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    const x = try a.alloc(u64, 100);
    const keep_end = try a.alloc(u8, 1);
    a.free(x);
    const y = try a.alloc(u64, 90);
    try std.testing.expectEqual(@intFromPtr(x.ptr), @intFromPtr(y.ptr));
    _ = keep_end;
}

test "reusing a free block preserves its unused suffix" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    const block = try a.alloc(u8, 1024);
    _ = try a.alloc(u8, 1);
    a.free(block);
    const first = try a.alloc(u8, 512);
    const second = try a.alloc(u8, 512);
    try std.testing.expectEqual(@intFromPtr(block.ptr), @intFromPtr(first.ptr));
    try std.testing.expectEqual(@intFromPtr(block.ptr) + first.len, @intFromPtr(second.ptr));
}

test "shrinking an earlier allocation preserves its unused suffix" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    const block = try a.alloc(u8, 1024);
    _ = try a.alloc(u8, 1);
    try std.testing.expect(a.resize(block, 512));
    const tail = try a.alloc(u8, 512);
    try std.testing.expectEqual(@intFromPtr(block.ptr) + 512, @intFromPtr(tail.ptr));
}

test "a much larger free block serves aligned smaller allocations" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    const block = try a.alloc(u8, 4096);
    _ = try a.alloc(u8, 1);
    a.free(block);
    const first = try a.alignedAlloc(u8, .fromByteUnits(256), 256);
    const second = try a.alloc(u8, 512);
    try std.testing.expectEqual(std.mem.alignForward(usize, @intFromPtr(block.ptr), 256), @intFromPtr(first.ptr));
    try std.testing.expectEqual(@intFromPtr(first.ptr) + first.len, @intFromPtr(second.ptr));
    @memset(first, 1);
    @memset(second, 2);
    for (first) |byte| try std.testing.expectEqual(@as(u8, 1), byte);
    b.reset();
    try std.testing.expectEqual(@as(usize, 0), b.available);
}

test "a failed chunk allocation cannot make live allocations overlap" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var b = Bump.init(failing.allocator());
    defer b.deinit();
    const a = b.allocator();
    _ = try a.alloc(u8, 1);
    const tail_len = 128;
    while (b.limit - b.at > tail_len) {
        _ = try a.alloc(u8, @min(big_len / 2, b.limit - b.at - tail_len));
    }
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, tail_len * 2));
    const first = try a.alloc(u8, 64);
    const second = try a.alloc(u8, 1);
    try std.testing.expect(@intFromPtr(second.ptr) >= @intFromPtr(first.ptr) + first.len);
}

test "growing the last allocation stays in place and big blocks get their own mapping" {
    var b = Bump.init(std.testing.allocator);
    defer b.deinit();
    const a = b.allocator();
    var list: std.ArrayList(u32) = .empty;
    try list.ensureTotalCapacity(a, 4);
    const before = list.items.ptr;
    try list.ensureTotalCapacity(a, 40);
    try std.testing.expectEqual(before, list.items.ptr);
    const big = try a.alloc(u8, big_len * 3);
    @memset(big, 1);
    const aligned = try a.alignedAlloc(u8, .@"64", big_len * 2);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
    b.reset();
    const again = try a.alloc(u32, 4);
    try std.testing.expectEqual(@intFromPtr(before), @intFromPtr(again.ptr));
}
