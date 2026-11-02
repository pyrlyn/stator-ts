//! JSDoc is how a JavaScript file writes types. Each annotation goes where TypeScript would have
//! it, so the checker keeps one rule for both. A type that starts before the declaration it
//! belongs to came from a comment, which is how a caller that must tell the two apart does.
//!
//! Not modeled: `@template`, `@typedef`, `@overload`, `@callback`, the names JSDoc reads
//! differently from TypeScript (`Object`, `String`, `Array.<T>`), and the errors tsc gives a
//! comment (TS8024 for a tag no parameter answers).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const parser = @import("parser.zig");

const Tag = struct {
    kind: enum { type, param, returns, readonly },
    open: u32,
    close: u32,
    /// The parameter's name, empty when the tag gave none.
    name: []const u8 = "",
    bracketed: bool = false,
};

/// The comment that names a declaration's types: tsc keeps only the last one before it.
fn lastComment(src: []const u8, start: u32) ?ast.Span {
    var at: usize = @min(start, src.len);
    while (true) {
        while (at > 0 and std.ascii.isWhitespace(src[at - 1])) at -= 1;
        if (at >= 2 and src[at - 2] == '*' and src[at - 1] == '/') {
            const open = std.mem.lastIndexOf(u8, src[0 .. at - 2], "/*") orelse return null;
            if (open + 2 < src.len and src[open + 2] == '*' and at - open > 4)
                return .{ .start = @intCast(open + 3), .end = @intCast(at - 2) };
            at = open;
            continue;
        }
        const line = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
        const comment = std.mem.indexOf(u8, src[line..at], "//") orelse return null;
        if (std.mem.trim(u8, src[line .. line + comment], " \t\r").len != 0) return null;
        at = line;
    }
}

fn closingBrace(src: []const u8, open: u32, end: u32) ?u32 {
    var depth: u32 = 0;
    var i = open;
    while (i < end) : (i += 1) switch (src[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

fn skipBlank(src: []const u8, from: u32, end: u32) u32 {
    var i = from;
    while (i < end and (std.ascii.isWhitespace(src[i]) or src[i] == '*')) i += 1;
    return i;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '.' or c >= 0x80;
}

const Tags = struct {
    src: []const u8,
    at: u32,
    end: u32,

    fn next(t: *Tags) ?Tag {
        while (std.mem.indexOfScalarPos(u8, t.src[0..t.end], t.at, '@')) |found| {
            var i: u32 = @intCast(found + 1);
            const word = i;
            while (i < t.end and isNameChar(t.src[i])) i += 1;
            t.at = i;
            const name = t.src[word..i];
            const eql = std.mem.eql;
            // What follows describes the type these declare, not the declaration under the comment.
            if (eql(u8, name, "typedef") or eql(u8, name, "callback")) return null;
            if (eql(u8, name, "readonly")) return .{ .kind = .readonly, .open = 0, .close = 0 };
            if (eql(u8, name, "type")) return t.typed(.type);
            if (eql(u8, name, "returns") or eql(u8, name, "return")) return t.typed(.returns);
            if (eql(u8, name, "param") or eql(u8, name, "arg") or eql(u8, name, "argument")) return t.param();
        }
        return null;
    }

    fn braces(t: *Tags, tag: *Tag) bool {
        const open = skipBlank(t.src, t.at, t.end);
        if (open >= t.end or t.src[open] != '{') return false;
        const close = closingBrace(t.src, open, t.end) orelse return false;
        tag.open = open + 1;
        tag.close = close;
        t.at = close + 1;
        return true;
    }

    fn typed(t: *Tags, kind: @FieldType(Tag, "kind")) ?Tag {
        var tag: Tag = .{ .kind = kind, .open = 0, .close = 0 };
        return if (t.braces(&tag)) tag else t.next();
    }

    fn param(t: *Tags) ?Tag {
        var tag: Tag = .{ .kind = .param, .open = 0, .close = 0 };
        const typed_first = t.braces(&tag);
        var i = skipBlank(t.src, t.at, t.end);
        if (i < t.end and t.src[i] == '[') {
            tag.bracketed = true;
            i = skipBlank(t.src, i + 1, t.end);
        }
        const name = i;
        while (i < t.end and isNameChar(t.src[i])) i += 1;
        tag.name = t.src[name..i];
        t.at = i;
        if (tag.bracketed) {
            const close = std.mem.indexOfScalarPos(u8, t.src[0..t.end], i, ']') orelse return t.next();
            t.at = @intCast(close + 1);
        }
        if (!typed_first and !t.braces(&tag)) return t.next();
        return tag;
    }
};

const Attach = struct {
    a: Allocator,
    src: []const u8,
    names: *std.ArrayList(ast.JsdocName),

    fn tags(x: Attach, host: *const Node) ?Tags {
        const body = lastComment(x.src, host.start) orelse return null;
        return .{ .src = x.src, .at = body.start, .end = body.end };
    }

    fn firstType(x: Attach, host: *const Node) ?*Node {
        var it = x.tags(host) orelse return null;
        while (it.next()) |tag| if (tag.kind == .type) {
            const parsed = parser.parseCommentType(x.a, x.src, tag.open, tag.close) orelse return null;
            return parsed.node;
        };
        return null;
    }

    fn has(x: Attach, host: *const Node, kind: @FieldType(Tag, "kind")) bool {
        var it = x.tags(host) orelse return false;
        while (it.next()) |tag| if (tag.kind == kind) return true;
        return false;
    }

    fn variables(x: Attach, stmt: *Node, list: *Node) void {
        const decls = list.data.var_list.decls;
        if (decls.len == 0) return;
        const v = decls[0].data.var_decl;
        if (v.type == null) v.type = x.firstType(stmt);
        if (v.init) |value| if (value.data == .func) x.function(value, stmt);
    }

    fn function(x: Attach, n: *Node, host: *const Node) void {
        const f = n.data.func;
        var it = x.tags(host) orelse return;
        var position: usize = 0;
        while (it.next()) |tag| switch (tag.kind) {
            .type, .readonly => {},
            .returns => if (f.ret == null and f.kind != .ctor and f.kind != .setter) {
                f.ret = if (parser.parseCommentType(x.a, x.src, tag.open, tag.close)) |t| t.node else null;
            },
            .param => {
                defer position += 1;
                const p = paramFor(f.params, tag.name, position) orelse continue;
                if (p.type != null) continue;
                const parsed = parser.parseCommentType(x.a, x.src, tag.open, tag.close) orelse continue;
                p.type = parsed.node;
                if ((parsed.optional or tag.bracketed) and p.init == null) p.question = true;
            },
        };
    }

    /// A `@template` reaches from its comment to the end of what the comment describes. Nodes that
    /// start together share a comment, and the first, outermost, is the one it describes.
    fn templates(x: Attach, n: *const Node) void {
        const body = lastComment(x.src, n.start) orelse return;
        const items = x.names.items;
        if (items.len > 0) if (items[items.len - 1].scope) |s| if (s.start == body.start) return;
        declaredNames(x.a, x.src, body.start, body.end, .{ .start = body.start, .end = n.end }, x.names);
    }

    fn visit(x: Attach, n: *Node) void {
        switch (n.data) {
            .var_stmt, .func, .class, .property_decl, .property_assign, .expr_stmt, .export_decl, .export_assign => x.templates(n),
            else => {},
        }
        switch (n.data) {
            .var_stmt => |s| x.variables(n, s.list),
            .func => x.function(n, n),
            .property_decl => |p| {
                if (p.type == null) p.type = x.firstType(n);
                if (x.has(n, .readonly)) n.mods.readonly = true;
            },
            .property_assign => |p| if (p.value.data == .func) x.function(p.value, n),
            .paren => n.data.paren.cast = x.firstType(n),
            else => {},
        }
        ast.forEachChild(n, x, visit);
    }
};

/// A pattern has no name to go by, so its tag is the one in the same place.
fn paramFor(params: []*Node, name: []const u8, position: usize) ?*ast.Param {
    for (params) |n| {
        const p = n.data.param;
        if (p.name.data == .identifier and std.mem.eql(u8, p.name.data.identifier, name)) return p;
    }
    if (position < params.len and params[position].data.param.name.data != .identifier) return params[position].data.param;
    return null;
}

/// Gives the declarations under `root` the types their comments name, and returns the type names
/// the comments declare. Runs before parents are set.
pub fn attach(a: Allocator, src: []const u8, root: *Node) []const ast.JsdocName {
    var names: std.ArrayList(ast.JsdocName) = .empty;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "/**")) |open| {
        const end = std.mem.indexOfPos(u8, src, open + 3, "*/") orelse src.len;
        at = end;
        declaredNames(a, src, open + 3, end, null, &names);
    }
    Attach.visit(.{ .a = a, .src = src, .names = &names }, root);
    return names.items;
}

fn skipSpaces(src: []const u8, from: usize, end: usize) usize {
    var i = from;
    while (i < end and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return i;
}

fn identEnd(src: []const u8, from: usize, end: usize) usize {
    var i = from;
    while (i < end and isNameChar(src[i])) i += 1;
    return i;
}

/// The type names a comment body declares. Without `scope`: those of `@typedef`, `@callback` and
/// `@import`, which reach the whole program. With it: those of `@template`, which reach `scope`.
/// The checker models none of them, so a type naming one must not resolve to anything else.
fn declaredNames(a: Allocator, src: []const u8, body: usize, end: usize, scope: ?ast.Span, out: *std.ArrayList(ast.JsdocName)) void {
    const eql = std.mem.eql;
    var i = body;
    while (std.mem.indexOfScalarPos(u8, src[0..end], i, '@')) |found| {
        const word = found + 1;
        i = identEnd(src, word, end);
        const tag = src[word..i];
        const typedef = eql(u8, tag, "typedef") or eql(u8, tag, "callback");
        const template = eql(u8, tag, "template");
        const import = eql(u8, tag, "import");
        if (if (scope == null) !typedef and !import else !template) continue;
        if (import) {
            // `@import { A, B as C } from "m"`, `@import * as N from "m"`, `@import D from "m"`.
            const stop = std.mem.indexOfPos(u8, src[0..end], i, "from") orelse end;
            var j: usize = i;
            while (j < stop) {
                j = skipBlank(src, @intCast(j), @intCast(stop));
                const name_end = identEnd(src, j, stop);
                if (name_end == j) {
                    j += 1;
                    continue;
                }
                const name = src[j..name_end];
                j = name_end;
                const after = skipBlank(src, @intCast(j), @intCast(stop));
                if (std.mem.startsWith(u8, src[after..stop], "as ")) continue;
                if (!eql(u8, name, "as") and !eql(u8, name, "type")) out.append(a, .{ .text = name, .scope = null }) catch oom();
            }
            i = stop;
            continue;
        }
        var j: usize = skipBlank(src, @intCast(i), @intCast(end));
        if (j < end and src[j] == '{') j = (closingBrace(src, @intCast(j), @intCast(end)) orelse continue) + 1;
        while (true) {
            j = skipSpaces(src, j, end);
            if (template and j < end and src[j] == '[') j += 1;
            const name_end = identEnd(src, j, end);
            if (name_end == j) break;
            out.append(a, .{ .text = src[j..name_end], .scope = scope }) catch oom();
            if (!template) break;
            j = skipSpaces(src, name_end, end);
            if (j < end and src[j] == '=') j = std.mem.indexOfScalarPos(u8, src[0..end], j, ']') orelse end;
            if (j < end and src[j] == ']') j = skipSpaces(src, j + 1, end);
            if (j >= end or src[j] != ',') break;
            j += 1;
        }
        i = j;
    }
}

fn oom() noreturn {
    @panic("out of memory");
}

test "a comment's types land on what they describe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = parser.parse(arena.allocator(), "a.js",
        \\/** @type {number} */
        \\const a = 1;
        \\/**
        \\ * @param {string} s
        \\ * @param {number=} n
        \\ * @returns {?boolean}
        \\ */
        \\function f(s, n) {}
    );
    const stmts = file.root.data.source_file.stmts;
    try std.testing.expect(stmts[0].data.var_stmt.list.data.var_list.decls[0].data.var_decl.type != null);
    const f = stmts[1].data.func;
    try std.testing.expect(f.params[0].data.param.type != null);
    try std.testing.expect(f.params[1].data.param.question);
    try std.testing.expect(f.ret.?.data == .union_type);
}
