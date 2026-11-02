//! tsc's `checkFunctionOrConstructorSymbol`: the declarations of one function, method or
//! constructor must form an overload list that ends in a matching implementation.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const project = @import("project.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const expr = @import("expr.zig");
const relate = @import("relate.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Checker = T.Checker;
const oom = T.oom;

/// The modifiers whose agreement tsc checks across overloads.
const Flags = packed struct(u8) {
    @"export": bool = false,
    ambient: bool = false,
    private: bool = false,
    protected: bool = false,
    abstract: bool = false,
    _: u3 = 0,

    fn bits(f: Flags) u8 {
        return @bitCast(f);
    }
};

/// Checks the overload lists `n` belongs to, each once.
pub fn check(c: *Checker, n: *Node) void {
    if (!isOverloadable(n)) return;
    const f = d.fileOf(c, n) orelse return;
    // JavaScript redeclares functions freely.
    if (project.isJs(f.path)) return;
    if (n.data.func.name) |name| if (name.data == .computed_name and !hasLiteralName(name)) return;
    const s = (n.symbol() orelse return).resolve();
    const halves = moduleHalves(c, n) orelse {
        if (once(c, s)) checkSymbol(c, s, n, s.decls);
        return;
    };
    // tsc checks the local symbol, which each module or namespace block keeps for itself and
    // which holds exported and local declarations alike…
    var local = std.ArrayList(*Node).empty;
    for ([_]?*Symbol{ halves.exported, halves.local }) |h| if (h) |x| for (x.resolve().decls) |y| {
        if (y.parent == n.parent and std.mem.indexOfScalar(*Node, local.items, y) == null) local.append(c.a, y) catch oom();
    };
    std.mem.sort(*Node, local.items, {}, struct {
        fn lt(_: void, a: *Node, b: *Node) bool {
            return a.start < b.start;
        }
    }.lt);
    if (local.items.len > 0 and once(c, local.items[0])) checkSymbol(c, s, n, local.items);
    // …then the exported one, across every block that merges into it.
    if (halves.exported) |e| if (e.resolve() == s and once(c, s)) checkSymbol(c, s, n, s.decls);
}

fn once(c: *Checker, key: *const anyopaque) bool {
    const gop = c.overloads_checked.getOrPut(c.a, key) catch oom();
    return !gop.found_existing;
}

const Halves = struct { exported: ?*Symbol, local: ?*Symbol };

/// The binder keeps a module's exported and local declarations of one name in two symbols.
fn moduleHalves(c: *Checker, n: *Node) ?Halves {
    if (n.data.func.kind != .decl) return null;
    const p = n.parent orelse return null;
    const container, const module = switch (p.data) {
        .source_file => .{ p, (d.fileOf(c, n) orelse return null).symbol orelse return null },
        .module_block => blk: {
            const m = p.parent orelse return null;
            break :blk .{ m, m.symbol() orelse return null };
        },
        else => return null,
    };
    const name = n.data.func.name orelse return null;
    if (name.data != .identifier) return null;
    return .{
        .exported = if (module.resolve().exports) |e| e.get(name.data.identifier) else null,
        .local = if (container.locals()) |l| l.get(name.data.identifier) else null,
    };
}

fn hasLiteralName(name: *Node) bool {
    const e = name.data.computed_name.expr;
    return e.data == .string_lit or e.data == .numeric_lit;
}

fn isOverloadable(n: *Node) bool {
    if (n.data != .func) return false;
    const p = n.parent orelse return false;
    return switch (n.data.func.kind) {
        .decl, .ctor => true,
        // Object literal methods are checked as function expressions.
        .method => p.data == .class,
        .method_sig => true,
        else => false,
    };
}

fn checkSymbol(c: *Checker, s: *Symbol, anchor: *Node, decls: []*Node) void {
    const is_ctor = s.flags & F.constructor != 0;
    var some: u8 = 0;
    var all: u8 = 0xff;
    var some_optional = false;
    var all_optional = true;
    var has_overloads = false;
    var body_decl: ?*Node = null;
    var last_non_ambient: ?*Node = null;
    var previous: ?*Node = null;
    var duplicate = false;
    var multiple_ctors = false;
    var funcs = std.ArrayList(*Node).empty;
    for (decls) |n| {
        const ambient = d.isAmbient(c, n);
        const in_type = if (n.parent) |p| p.data == .interface or p.data == .type_literal else false;
        // Ambient declarations may interleave, and mixing ambient with non-ambient is reported
        // on its own.
        if (ambient or in_type) previous = null;
        if (!isOverloadable(n)) continue;
        // tsc gives a function and a method of one name separate symbols, after reporting them.
        if ((n.data.func.kind == .decl) != (anchor.data.func.kind == .decl)) continue;
        funcs.append(c.a, n) catch oom();
        const flags = effectiveFlags(c, n).bits();
        some |= flags;
        all &= flags;
        some_optional = some_optional or n.data.func.question;
        all_optional = all_optional and n.data.func.question;
        const has_body = n.data.func.body != null;
        if (has_body and body_decl != null) {
            if (is_ctor) multiple_ctors = true else duplicate = true;
        } else if (previous) |prev| {
            if (prev.parent == n.parent and nextSibling(prev) != n) reportMissingImplementation(c, prev, is_ctor);
        }
        if (has_body) {
            if (body_decl == null) body_decl = n;
        } else has_overloads = true;
        previous = n;
        if (!ambient and !in_type) last_non_ambient = n;
    }
    if (multiple_ctors) for (funcs.items) |n| expr.err(c, n, 2392, "Multiple constructor implementations are not allowed.");
    if (duplicate) for (funcs.items) |n| expr.err(c, nameOrSelf(n), 2393, "Duplicate function implementation.");
    // Abstract methods need no implementation.
    if (last_non_ambient) |n| if (n.data.func.body == null and !n.data.func.body_missing and !n.mods.abstract and !n.data.func.question) reportMissingImplementation(c, n, is_ctor);
    if (!has_overloads) return;
    checkFlagAgreement(c, funcs.items, body_decl, some, all);
    if (some_optional != all_optional) {
        const canonical = canonicalOverload(funcs.items, body_decl).data.func.question;
        for (funcs.items) |n| if (n.data.func.question != canonical) expr.err(c, nameOrSelf(n), 2386, "Overload signatures must all be optional or required.");
    }
    const impl = body_decl orelse return;
    const impl_sig = d.sigOfDecl(c, impl);
    for (funcs.items, 0..) |n, i| {
        // tsc's `getSignaturesOfSymbol` leaves out an implementation that directly follows an overload.
        if (n.data.func.body != null and i > 0 and funcs.items[i - 1].parent == n.parent and nextSibling(funcs.items[i - 1]) == n) continue;
        if (!relate.implementationFits(c, impl_sig, d.sigOfDecl(c, n))) {
            expr.err(c, nameOrSelf(n), 2394, "This overload signature is not compatible with its implementation signature.");
            break;
        }
    }
}

/// tsc's `getCanonicalOverload`: the implementation when it sits with the first overload.
fn canonicalOverload(overloads: []*Node, impl: ?*Node) *Node {
    if (impl) |x| if (x.parent == overloads[0].parent) return x;
    return overloads[0];
}

fn checkFlagAgreement(c: *Checker, overloads: []*Node, impl: ?*Node, some: u8, all: u8) void {
    if (some ^ all == 0) return;
    const canonical = effectiveFlags(c, canonicalOverload(overloads, impl)).bits();
    for (overloads) |n| {
        const own = effectiveFlags(c, n).bits();
        // Overloads in different files need not agree on `export` or `declare`.
        const in_file = sameFileOverloads(c, overloads, n);
        const file_canonical = effectiveFlags(c, canonicalOverload(in_file, if (impl) |x| if (d.fileOf(c, x) == d.fileOf(c, n)) x else null else null)).bits();
        const deviation: Flags = @bitCast(own ^ canonical);
        const deviation_in_file: Flags = @bitCast(own ^ file_canonical);
        if (deviation_in_file.@"export") {
            expr.err(c, nameOrSelf(n), 2383, "Overload signatures must all be exported or non-exported.");
        } else if (deviation_in_file.ambient) {
            expr.err(c, nameOrSelf(n), 2384, "Overload signatures must all be ambient or non-ambient.");
        } else if (deviation.private or deviation.protected) {
            expr.err(c, nameOrSelf(n), 2385, "Overload signatures must all be public, private or protected.");
        } else if (deviation.abstract) {
            expr.err(c, nameOrSelf(n), 2512, "Overload signatures must all be abstract or non-abstract.");
        }
    }
}

fn sameFileOverloads(c: *Checker, overloads: []*Node, n: *Node) []*Node {
    const f = d.fileOf(c, n);
    var out = std.ArrayList(*Node).empty;
    for (overloads) |x| if (d.fileOf(c, x) == f) out.append(c.a, x) catch oom();
    return out.items;
}

/// tsc's `getEffectiveDeclarationFlags`. Class and interface members are never ambient or
/// exported for this purpose; anything else declared in an ambient export context is exported.
fn effectiveFlags(c: *Checker, n: *Node) Flags {
    var out: Flags = .{
        .@"export" = n.mods.@"export",
        .ambient = n.mods.declare,
        .private = n.mods.private,
        .protected = n.mods.protected,
        .abstract = n.mods.abstract,
    };
    const p = n.parent orelse return out;
    if (p.data == .interface or p.data == .class) return out;
    if (d.isAmbient(c, n)) {
        if (!out.ambient and isExportContext(c, p)) out.@"export" = true;
        out.ambient = true;
    }
    return out;
}

/// tsc's `NodeFlags.ExportContext`: an ambient module or file without export declarations
/// exports everything it declares.
fn isExportContext(c: *Checker, container: *Node) bool {
    const stmts = switch (container.data) {
        .source_file => |x| x.stmts,
        .module_block => |x| blk: {
            const m = container.parent orelse return false;
            if (m.data == .module_decl and m.data.module_decl.is_global) return false;
            break :blk x.stmts;
        },
        else => return false,
    };
    if (!d.isAmbient(c, container)) return false;
    for (stmts) |x| if (x.data == .export_decl or x.data == .export_assign) return false;
    return true;
}

/// tsc's `reportImplementationExpectedError`.
fn reportMissingImplementation(c: *Checker, n: *Node, is_ctor: bool) void {
    const name = n.data.func.name;
    if (name) |x| if (x.data == .identifier and x.data.identifier.len == 0) return;
    // A member whose name failed to parse; a function declaration may have none.
    if (name == null and n.data.func.kind != .decl and n.data.func.kind != .ctor) return;
    if (nextSibling(n)) |next| if (next.data == .func and next.data.func.kind == n.data.func.kind) {
        const next_name = next.data.func.name;
        if (name != null and next_name != null and sameName(name.?, next_name.?)) {
            // Either static and instance members mixed, or the binder already reported a name
            // declared before the overloads.
            if (n.data.func.kind == .method or n.data.func.kind == .method_sig) if (n.mods.static != next.mods.static) {
                if (n.mods.static) {
                    expr.err(c, next_name.?, 2387, "Function overload must be static.");
                } else {
                    expr.err(c, next_name.?, 2388, "Function overload must not be static.");
                }
            };
            return;
        }
        if (next.data.func.body != null) {
            const shown = if (name) |x| nameText(x) orelse "" else "";
            expr.err(c, next_name orelse next, 2389, c.fmt("Function implementation name must be '{s}'.", .{shown}));
            return;
        }
    };
    const at = name orelse n;
    if (is_ctor) {
        expr.err(c, at, 2390, "Constructor implementation is missing.");
    } else if (n.mods.abstract) {
        expr.err(c, at, 2516, "All declarations of an abstract method must be consecutive.");
    } else {
        expr.err(c, at, 2391, "Function implementation is missing or not immediately following the declaration.");
    }
}

fn sameName(a: *Node, b: *Node) bool {
    if (a.data == .private_name or b.data == .private_name) {
        return a.data == .private_name and b.data == .private_name and std.mem.eql(u8, a.data.private_name, b.data.private_name);
    }
    const x = nameText(a) orelse return false;
    const y = nameText(b) orelse return false;
    return std.mem.eql(u8, x, y);
}

fn nameText(n: *Node) ?[]const u8 {
    return switch (n.data) {
        .identifier => |v| v,
        .string_lit, .numeric_lit, .no_subst_template => |v| v,
        .private_name => |v| v,
        .computed_name => |x| switch (x.expr.data) {
            .string_lit, .numeric_lit => |v| v,
            else => null,
        },
        else => null,
    };
}

fn nameOrSelf(n: *Node) *Node {
    return n.data.func.name orelse n;
}

/// The node after `n` in its parent's list, which tsc's `pos == end` test amounts to.
fn nextSibling(n: *Node) ?*Node {
    const p = n.parent orelse return null;
    const list = switch (p.data) {
        .source_file => |x| x.stmts,
        .block => |x| x.stmts,
        .module_block => |x| x.stmts,
        .case_clause => |x| x.stmts,
        .default_clause => |x| x.stmts,
        .class => |x| x.members,
        .interface => |x| x.members,
        .type_literal => |x| x.members,
        else => return null,
    };
    const i = std.mem.indexOfScalar(*Node, list, n) orelse return null;
    return if (i + 1 < list.len) list[i + 1] else null;
}
