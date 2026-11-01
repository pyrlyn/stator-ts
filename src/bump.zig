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
/// Enough for an ordinary run of files, which is most of them.
const retained_chunks = 4;
const class_count = @bitSizeOf(usize);
const block_alignment: Alignment = .@"8";
/// How far down a class to look. A block of the next class always fits, so this only saves waste.
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
        for (low..@min(low + 2, class_count)) |class| {
            var link = &b.free_blocks[class];
            var left: usize = if (class == low) class_probes else 1;
            while (link.*) |x| : (link = &x.next) {
                if (x.len >= len and al.check(@intFromPtr(x))) {
                    link.* = x.next;
                    return @ptrCast(x);
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
        b.keep(b.at, b.limit - b.at);
        const c = if (b.cur) |x| x.next orelse blk: {
            const n = b.mapped(chunk_len) orelse return null;
            x.next = n;
            break :blk n;
        } else blk: {
            const n = b.mapped(chunk_len) orelse return null;
            b.first = n;
            break :blk n;
        };
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
            if (@intFromPtr(m.ptr) + m.len == b.at) b.at = @intFromPtr(m.ptr) + len;
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
