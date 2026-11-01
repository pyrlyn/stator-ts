//! From declarations to types: names, symbols, type nodes, members, instantiation, and the
//! type-level operators (keyof, indexed access, conditional, mapped, template).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const lexer = @import("lexer.zig");
const T = @import("types.zig");
const expr = @import("expr.zig");
const relate = @import("relate.zig");
const flow = @import("flow.zig");
const emit = @import("emit.zig");
const checker = @import("checker.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Checker = T.Checker;
const Type = T.Type;
const Obj = T.Obj;
const Prop = T.Prop;
const Sig = T.Sig;
const Mapper = T.Mapper;
const Members = T.Members;
const oom = T.oom;

// ---- names ----

fn matches(c: *Checker, s: *Symbol, meaning: u32) ?*Symbol {
    if (s.flags & meaning != 0) return s;
    if (s.flags & F.alias != 0) {
        const t = c.prog.resolveAlias(s, 0) orelse return s;
        if (t.flags & meaning != 0) return s;
    }
    return null;
}

pub fn resolveName(c: *Checker, from: *Node, name: []const u8, meaning: u32) ?*Symbol {
    var cur: ?*Node = from;
    var last: ?*Node = null;
    while (cur) |n| : ({
        last = n;
        cur = n.parent;
    }) {
        // `T extends [infer T] ? T : T`: the name is taken in the true branch alone.
        const hidden = n.data == .conditional_type and last != n.data.conditional_type.then;
        if (!hidden) if (n.locals) |l| if (l.get(name)) |s| {
            if (matches(c, s, meaning)) |r| {
                // A parameter's own scope does not include the function's return type for values.
                return r;
            }
            if (n.data == .source_file) if (fileOf(c, n)) |f| if (f.symbol) |m| if (m.exports) |e| if (e.get(name)) |x| {
                if (x != s and !binder.isExportSpecifierOnly(x)) if (matches(c, x, meaning)) |r| return r;
            };
        };
        switch (n.data) {
            .module_decl, .enum_decl => if (n.symbol) |sym| if (sym.resolve().exports) |e| if (e.get(name)) |x| {
                if (!binder.isExportSpecifierOnly(x)) if (matches(c, x, meaning)) |r| return r;
            },
            else => {},
        }
    }
    if (c.prog.globals.get(name)) |s| if (matches(c, s, meaning)) |r| return r;
    return null;
}

pub fn fileOf(c: *Checker, n: *Node) ?*ast.File {
    var cur = n;
    while (cur.parent) |p| cur = p;
    return c.prog.by_root.get(cur);
}

pub fn targetOf(c: *Checker, s: *Symbol) ?*Symbol {
    if (s.flags & F.alias == 0) return s.resolve();
    return c.prog.resolveAlias(s, 0);
}

/// `import { join } from 'path'` when the module says `export = path` and `path` is a value:
/// the name is a property of that value's type, not an export.
pub fn importedProperty(c: *Checker, s: *Symbol) ?*Type {
    if (s.flags & F.alias == 0 or s.decls.len == 0) return null;
    const dn = s.decls[0];
    if (dn.data != .import_spec) return null;
    const sf = c.prog.sourceOf(s.file) orelse return null;
    const m = c.prog.moduleOfDecl(sf, dn) orelse return null;
    const eq = c.prog.exportOf(m, "export=") orelse return null;
    const t = targetOf(c, eq) orelse return null;
    if (t.flags & F.value == 0) return null;
    const x = dn.data.import_spec;
    const p = getProp(c, typeOfSymbol(c, t), binder.specName(x.prop_name orelse x.name)) orelse return null;
    return propType(c, p);
}

pub fn exportsOf(c: *Checker, m: *Symbol) []const *Symbol {
    var out = c.newList(*Symbol);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    c.collectExports(m.resolve(), &out, &seen, 0);
    return out.items;
}

// ---- globals ----

pub fn globalSym(c: *Checker, name: []const u8) ?*Symbol {
    return c.prog.globals.get(name);
}

pub fn globalType(c: *Checker, name: []const u8) ?*Type {
    if (c.global_cache.get(name)) |t| return t;
    var out: ?*Type = null;
    if (globalSym(c, name)) |s| {
        if (s.flags & (F.class | F.interface | F.type_alias) != 0) out = declaredType(c, s);
    }
    c.global_cache.put(c.a, name, out) catch oom();
    return out;
}

pub fn initGlobals(c: *Checker) void {
    c.global_array = globalType(c, "Array");
    c.global_readonly_array = globalType(c, "ReadonlyArray");
}

pub fn generic(c: *Checker, name: []const u8, args: []const *Type) *Type {
    const g = globalType(c, name) orelse return c.t_err;
    return refTo(c, g, args);
}

fn refTo(c: *Checker, g: *Type, args: []const *Type) *Type {
    if (g.data != .obj or g.data.obj.tparams.len != args.len) return c.t_err;
    return c.internRef(g, c.dupe(*Type, args), null);
}

pub fn arrayOf(c: *Checker, e: *Type) *Type {
    const g = c.global_array orelse return c.t_err;
    return refTo(c, g, &.{e});
}

pub fn readonlyArrayOf(c: *Checker, e: *Type) *Type {
    const g = c.global_readonly_array orelse return c.t_err;
    return refTo(c, g, &.{e});
}

// ---- reporting helpers shared by type-node resolution ----

pub fn report(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    reportSpan(c, n, n.start, n.end, code, msg);
}

/// tsc reports its size limits at the node being checked, whichever type got that far.
pub fn reportLimit(c: *Checker, code: u32, msg: []const u8) void {
    if (c.current_node) |n| report(c, n, code, msg);
}

pub fn reportSpan(c: *Checker, n: *Node, start: u32, end: u32, code: u32, msg: []const u8) void {
    const f = fileOf(c, n) orelse return;
    if (!c.owned.contains(f)) return;
    const key = c.fmt("{x}:{d}:{d}:{s}", .{ @intFromPtr(f), start, code, msg });
    const gop = c.seen_diags.getOrPut(c.a, key) catch oom();
    if (gop.found_existing) return;
    c.diags.append(c.a, .{ .file = f, .start = start, .len = end -| start, .code = code, .msg = msg }) catch oom();
}

// ---- type parameters ----

pub fn tparamOf(c: *Checker, s0: *Symbol) *Type {
    const s = s0.resolve();
    if (c.declared.get(s)) |t| return t;
    const decl = s.decls[0];
    if (mergedTParam(decl)) |first| {
        const t = tparamOf(c, first);
        c.declared.put(c.a, s, t) catch oom();
        return t;
    }
    const t = c.mk(.{ .param = c.create(T.TParam, .{ .sym = s, .name = s.name, .decl = decl, .is_const = decl.mods.@"const" }) });
    t.vars = true;
    c.declared.put(c.a, s, t) catch oom();
    return t;
}

/// Merged declarations of a class or interface share parameters by position, whatever each calls them.
fn mergedTParam(decl: *Node) ?*Symbol {
    const owner = decl.parent orelse return null;
    const list = declTParams(owner) orelse return null;
    const idx = std.mem.indexOfScalar(*Node, list, decl) orelse return null;
    const sym = (owner.symbol orelse return null).resolve();
    for (sym.decls) |x| {
        if (x == owner) return null;
        const other = declTParams(x) orelse continue;
        if (other.len == 0) continue;
        if (idx >= other.len) return null;
        return other[idx].symbol;
    }
    return null;
}

/// Only one of the merged declarations has to spell a parameter's default.
fn mergedDefault(decl: *Node) ?*Node {
    if (decl.data != .type_param) return null;
    if (decl.data.type_param.default) |k| return k;
    const owner = decl.parent orelse return null;
    const list = declTParams(owner) orelse return null;
    const idx = std.mem.indexOfScalar(*Node, list, decl) orelse return null;
    const sym = (owner.symbol orelse return null).resolve();
    for (sym.decls) |x| {
        const other = declTParams(x) orelse continue;
        if (idx < other.len) if (other[idx].data.type_param.default) |k| return k;
    }
    return null;
}

fn declTParams(n: *Node) ?[]*Node {
    return switch (n.data) {
        .class => |d| d.type_params.items,
        .interface => |d| d.type_params.items,
        else => null,
    };
}

pub fn tparamsFrom(c: *Checker, list: []*Node) []*Type {
    if (list.len == 0) return &.{};
    var out = c.newList(*Type);
    for (list) |p| if (p.symbol) |s| out.append(c.a, tparamOf(c, s)) catch oom();
    return out.items;
}

pub fn constraintOf(c: *Checker, t: *Type) ?*Type {
    const p = t.data.param;
    if (p.constraint_done) return p.constraint;
    p.constraint_done = true;
    if (p.target) |orig| {
        if (constraintOf(c, orig)) |k| p.constraint = instantiate(c, k, p.mapper);
        return p.constraint;
    }
    const d = p.decl orelse return null;
    switch (d.data) {
        .type_param => |x| if (x.constraint) |k| {
            p.constraint = typeFromNode(c, k);
            // `T extends T` style cycles have no usable constraint.
            if (p.constraint == t) p.constraint = null;
        } else if (d.parent) |par| switch (par.data) {
            .infer_type => p.constraint = impliedByPosition(c, par),
            else => {},
        },
        // The key of `{ [K in C]: ... }` is declared on the mapped type itself.
        .mapped_type => |m| p.constraint = typeFromNode(c, m.constraint),
        else => {},
    }
    return p.constraint;
}

/// What the spot of an `infer` asks for: a template span can only ever hold a string, which is
/// also what `${infer A}.x` leaves in `A` when the text does not match.
fn impliedByPosition(c: *Checker, infer: *Node) ?*Type {
    var at = infer.parent;
    while (at) |x| : (at = x.parent) {
        if (x.data != .paren_type) break;
    }
    const grand = at orelse return null;
    return switch (grand.data) {
        .template_type_span => c.t_string,
        .rest_type => arrayOf(c, c.t_unknown),
        .param => |x| if (x.dotdotdot) arrayOf(c, c.t_unknown) else null,
        .named_tuple_member => |x| if (x.dotdotdot) arrayOf(c, c.t_unknown) else null,
        else => null,
    };
}

pub fn defaultOf(c: *Checker, t: *Type) ?*Type {
    const p = t.data.param;
    if (p.default_done) return p.default;
    p.default_done = true;
    if (p.target) |orig| {
        if (defaultOf(c, orig)) |k| p.default = instantiate(c, k, p.mapper);
        return p.default;
    }
    const d = p.decl orelse return null;
    if (mergedDefault(d)) |k| p.default = typeFromNode(c, k);
    return p.default;
}

/// Type parameters in scope at a declaration: instantiating what it declares must map them.
pub fn outerTParams(c: *Checker, n: *Node) []*Type {
    if (c.node_tparams.get(n)) |x| return x;
    var out = c.newList(*Type);
    var cur: ?*Node = n;
    var from: ?*Node = null;
    while (cur) |x| : ({
        from = x;
        cur = x.parent;
    }) {
        const list: []*Node = switch (x.data) {
            .func => |f| f.type_params.items,
            .class => |d| d.type_params.items,
            .interface => |d| d.type_params.items,
            .type_alias => |d| d.type_params.items,
            else => &.{},
        };
        for (tparamsFrom(c, list)) |t| out.append(c.a, t) catch oom();
        switch (x.data) {
            .class, .interface => {
                if (x.symbol) |s| {
                    const d = declaredType(c, s);
                    if (d.data == .obj) if (d.data.obj.this_type) |tt| out.append(c.a, tt) catch oom();
                }
            },
            // Its own key parameter is bound inside it, never by whoever instantiates it.
            .mapped_type => if (x != n) if (x.locals) |l| {
                var it = l.map.valueIterator();
                while (it.next()) |s| out.append(c.a, tparamOf(c, s.*)) catch oom();
            },
            // Its own `infer` names are bound by each resolution, or a recursive use would see the
            // outer level's answers. Nothing ever maps them for the false branch either, which
            // would stay generic forever.
            .conditional_type => |y| if (x != n and from != y.els and from != y.check) if (x.locals) |l| {
                var it = l.map.valueIterator();
                while (it.next()) |s| out.append(c.a, tparamOf(c, s.*)) catch oom();
            },
            else => {},
        }
    }
    c.node_tparams.put(c.a, n, out.items) catch oom();
    return out.items;
}

/// The parameters in scope that a written type can mention. Asking a mapper about the rest would
/// be wasted at best, and at worst fix a parameter that is still being inferred.
fn referencedTParams(c: *Checker, n: *Node) []*Type {
    if (c.node_refs.get(n)) |x| return x;
    const outer = outerTParams(c, n);
    // `type A<T> = { x: 1 }` still names one type per argument, as its alias shows.
    const named = if (n.parent) |p| p.data == .type_alias and p.data.type_alias.type_params.items.len > 0 else false;
    var out = c.newList(*Type);
    for (outer) |p| if (named or possiblyReferenced(p, n)) out.append(c.a, p) catch oom();
    c.node_refs.put(c.a, n, out.items) catch oom();
    return out.items;
}

fn isWrittenType(n: *Node) bool {
    return switch (n.data) {
        .type_literal, .mapped_type => true,
        .func => |f| f.kind == .function_type or f.kind == .constructor_type,
        else => false,
    };
}

fn possiblyReferenced(p: *Type, n: *Node) bool {
    const tp = p.data.param;
    if (!tp.is_this) {
        const container = (tp.decl orelse return true).parent;
        var cur: ?*Node = n;
        while (cur != container) : (cur = cur.?.parent) {
            const x = cur orelse return true;
            switch (x.data) {
                // Anything declared in a body can carry the parameter without spelling it.
                .block => return true,
                .conditional_type => |y| if (mentions(tp, y.extends)) return true,
                else => {},
            }
        }
    }
    return mentions(tp, n);
}

fn mentions(tp: *T.TParam, n: *Node) bool {
    var m = Mention{ .tp = tp };
    m.visit(n);
    return m.found;
}

const Mention = struct {
    tp: *T.TParam,
    found: bool = false,

    fn visit(m: *Mention, n: *Node) void {
        if (m.found) return;
        switch (n.data) {
            .this_type => m.found = m.tp.is_this,
            // What a `typeof` reads can have any of them in its type.
            .type_query => m.found = true,
            .type_ref => |x| if (!m.tp.is_this and x.name.data == .identifier) {
                m.found = std.mem.eql(u8, x.name.data.identifier, m.tp.name);
            },
            else => {},
        }
        ast.forEachChild(n, m, visit);
    }
};

// ---- declared types ----

pub fn declaredType(c: *Checker, s0: *Symbol) *Type {
    const s = s0.resolve();
    if (c.declared.get(s)) |t| return t;
    if (s.flags & F.alias != 0) {
        const t = targetOf(c, s) orelse return c.t_err;
        return if (t == s) c.t_err else declaredType(c, t);
    }
    if (s.flags & (F.class | F.interface) != 0) return declareIface(c, s);
    if (s.flags & F.type_alias != 0) return declareAlias(c, s);
    if (s.flags & F.enum_any != 0) return declareEnum(c, s);
    if (s.flags & F.enum_member != 0) return enumMemberType(c, s);
    if (s.flags & F.type_param != 0) return tparamOf(c, s);
    return c.t_err;
}

fn declareIface(c: *Checker, s: *Symbol) *Type {
    var outer = c.newList(*Type);
    var local = c.newList(*Type);
    var first: ?*Node = null;
    for (s.decls) |d| {
        const list: []*Node = switch (d.data) {
            .class => |x| x.type_params.items,
            .interface => |x| x.type_params.items,
            else => continue,
        };
        if (first == null) first = d;
        if (local.items.len == 0) for (tparamsFrom(c, list)) |t| local.append(c.a, t) catch oom();
    }
    const is_class = s.flags & F.class != 0;
    const t = c.newObj(.{ .kind = .iface, .sym = s, .is_class = is_class });
    c.declared.put(c.a, s, t) catch oom();
    const this_t = c.mk(.{ .param = c.create(T.TParam, .{ .name = "this", .is_this = true, .constraint = t, .constraint_done = true }) });
    this_t.vars = true;
    t.data.obj.this_type = this_t;
    if (first) |d| if (d.parent) |par| {
        for (outerTParams(c, par)) |p| if (!p.data.param.is_this) outer.append(c.a, p) catch oom();
    };
    for (local.items) |p| outer.append(c.a, p) catch oom();
    t.data.obj.tparams = outer.items;
    t.data.obj.local_tparams = local.items;
    return t;
}

fn declareAlias(c: *Checker, s: *Symbol) *Type {
    if (c.declared_resolving.contains(s)) return c.t_err;
    c.declared_resolving.put(c.a, s, {}) catch oom();
    defer _ = c.declared_resolving.remove(s);
    const d = for (s.decls) |x| {
        if (x.data == .type_alias) break x;
    } else return c.t_err;
    const params = aliasParams(c, s);
    if (isIntrinsic(d) and params.len == 1) if (intrinsicAlias(c, s.name, params[0])) |x| {
        c.declared.put(c.a, s, x) catch oom();
        return x;
    };
    const t = typeFromNode(c, d.data.type_alias.type);
    var out = t;
    // Primitive and shared types stay as they are; only a fresh structural type names its alias.
    if (t.alias == null and (t.data == .obj or t.data == .union_ or t.data == .inter or t.data == .cond or t.data == .access)) {
        if (t.data == .obj and t.data.obj.kind != .anon and t.data.obj.kind != .mapped) {
            out = t;
        } else {
            t.alias = c.create(T.Alias, .{ .sym = s, .args = params });
        }
    }
    c.declared.put(c.a, s, out) catch oom();
    return out;
}

fn isIntrinsic(d: *Node) bool {
    const n = d.data.type_alias.type;
    return n.data == .kw_type and n.data.kw_type == .intrinsic;
}

fn intrinsicAlias(c: *Checker, name: []const u8, p: *Type) ?*Type {
    if (std.mem.eql(u8, name, "NoInfer")) return getNoInfer(c, p);
    const kinds = std.StaticStringMap(T.StrMapKind).initComptime(.{
        .{ "Uppercase", .upper },       .{ "Lowercase", .lower },
        .{ "Capitalize", .capitalize }, .{ "Uncapitalize", .uncapitalize },
    });
    return getStringMapping(c, kinds.get(name) orelse return null, p);
}

pub fn getNoInfer(c: *Checker, t: *Type) *Type {
    if (!t.vars or t.data == .noinfer) return t;
    const r = c.mk(.{ .noinfer = t });
    r.vars = true;
    return r;
}

pub fn aliasParams(c: *Checker, s0: *Symbol) []*Type {
    const s = s0.resolve();
    if (c.alias_params.get(s)) |x| return x;
    var out: []*Type = &.{};
    for (s.decls) |d| if (d.data == .type_alias) {
        out = tparamsFrom(c, d.data.type_alias.type_params.items);
    };
    c.alias_params.put(c.a, s, out) catch oom();
    return out;
}

fn parseEnumInit(c: *Checker, n: *Node, owner: *Symbol) T.EnumValue {
    switch (n.data) {
        .numeric_lit => |v| return .{ .num = (emit.parseNumber(v) orelse 0) },
        .string_lit, .no_subst_template => |v| return .{ .str = v },
        .paren => |x| return parseEnumInit(c, x.expr, owner),
        .template_expr => |x| {
            var out = c.newList(u8);
            out.appendSlice(c.a, x.head) catch oom();
            for (x.spans) |sp| {
                const span = sp.data.template_span;
                switch (parseEnumInit(c, span.expr, owner)) {
                    .str => |v| out.appendSlice(c.a, v) catch oom(),
                    .num => |v| out.appendSlice(c.a, c.fmt("{d}", .{v})) catch oom(),
                    .none => return .none,
                }
                out.appendSlice(c.a, span.text) catch oom();
            }
            return .{ .str = out.items };
        },
        .prefix => |x| {
            const v = parseEnumInit(c, x.expr, owner);
            if (v != .num) return .none;
            return switch (x.op) {
                .minus => .{ .num = -v.num },
                .plus => v,
                .tilde => .{ .num = @floatFromInt(~toInt32(v.num)) },
                else => .none,
            };
        },
        .binary => |x| {
            const l = parseEnumInit(c, x.left, owner);
            const r = parseEnumInit(c, x.right, owner);
            if (l == .str and r == .str and x.op == .plus) return .{ .str = c.fmt("{s}{s}", .{ l.str, r.str }) };
            if (l != .num or r != .num) return .none;
            const li = toInt32(l.num);
            const ri = toInt32(r.num);
            return switch (x.op) {
                .plus => .{ .num = l.num + r.num },
                .minus => .{ .num = l.num - r.num },
                .star => .{ .num = l.num * r.num },
                .slash => .{ .num = l.num / r.num },
                .pipe => .{ .num = @floatFromInt(li | ri) },
                .amp => .{ .num = @floatFromInt(li & ri) },
                .caret => .{ .num = @floatFromInt(li ^ ri) },
                .shl => .{ .num = @floatFromInt(li << @as(u5, @truncate(@as(u32, @bitCast(ri))))) },
                .shr => .{ .num = @floatFromInt(li >> @as(u5, @truncate(@as(u32, @bitCast(ri))))) },
                else => .none,
            };
        },
        .identifier => |name| {
            if (owner.exports) |e| if (e.get(name)) |m| return memberValue(c, m, owner, n);
            const s = resolveName(c, n, name, F.value) orelse return .none;
            return memberValue(c, s, owner, n);
        },
        .prop_access => |x| {
            const base = entityOf(c, x.expr) orelse return .none;
            if (base.exports) |e| if (e.get(x.name.data.identifier)) |m| return memberValue(c, m, owner, n);
            return .none;
        },
        .elem_access => |x| {
            if (x.index.data != .string_lit) return .none;
            const base = entityOf(c, x.expr) orelse return .none;
            if (base.exports) |e| if (e.get(x.index.data.string_lit)) |m| return memberValue(c, m, owner, n);
            return .none;
        },
        else => return .none,
    }
}

/// ECMAScript ToInt32: `1 / 0` and `0 / 0` are legal initializers.
fn toInt32(v: f64) i32 {
    if (!std.math.isFinite(v)) return 0;
    const m = @mod(@trunc(v), 4294967296.0);
    return @bitCast(@as(u32, @intFromFloat(m)));
}

fn entityOf(c: *Checker, n: *Node) ?*Symbol {
    switch (n.data) {
        .identifier => |name| {
            const s = resolveName(c, n, name, F.namespace) orelse return null;
            return targetOf(c, s);
        },
        .prop_access => |x| {
            const base = entityOf(c, x.expr) orelse return null;
            const e = base.exports orelse return null;
            return targetOf(c, e.get(x.name.data.identifier) orelse return null);
        },
        else => return null,
    }
}

/// Enum initializers may read other enums' members and `const`s with constant initializers.
fn memberValue(c: *Checker, s0: *Symbol, owner: *Symbol, ref: *Node) T.EnumValue {
    const s = targetOf(c, s0) orelse return .none;
    if (s.flags & F.enum_member != 0) {
        if (unassignedMember(c, s, ref)) |v| return v;
        const t = enumMemberType(c, s);
        if (t.data == .enum_lit) return t.data.enum_lit.value;
        return .none;
    }
    const init = expr.constInit(s) orelse return .none;
    if (c.enum_eval_depth > 16) return .none;
    c.enum_eval_depth += 1;
    defer c.enum_eval_depth -= 1;
    return parseEnumInit(c, init, owner);
}

/// The value tsc settles on for a member the enum has not reached yet, with its error.
fn unassignedMember(c: *Checker, s: *Symbol, ref: *Node) ?T.EnumValue {
    const parent = s.parent orelse return null;
    if (c.declared.contains(s) or !c.declaring_enums.contains(parent)) return null;
    var cur: ?*Node = ref;
    while (cur) |n| : (cur = n.parent) {
        if (n.data == .enum_member and n.symbol == s) {
            report(c, ref, 2565, c.fmt("Property '{s}' is used before being assigned.", .{s.name}));
            return .none;
        }
    }
    report(c, ref, 2651, "A member initializer in a enum declaration cannot reference members declared after it, including members defined in other enums.");
    return .{ .num = 0 };
}

fn enumMemberType(c: *Checker, s: *Symbol) *Type {
    if (c.declared.get(s)) |t| return t;
    const owner = s.parent orelse return c.t_err;
    // A member that reads itself or a later one has no value yet, and asking would restart the enum.
    if (c.declaring_enums.contains(owner)) return c.t_err;
    _ = declaredType(c, owner);
    return c.declared.get(s) orelse c.t_err;
}

fn declareEnum(c: *Checker, s: *Symbol) *Type {
    c.declaring_enums.put(c.a, s, {}) catch oom();
    defer _ = c.declaring_enums.remove(s);
    var types = c.newList(*Type);
    var literal = true;
    for (s.decls) |d| {
        if (d.data != .enum_decl) continue;
        var next: ?f64 = 0;
        for (d.data.enum_decl.members) |m| {
            const ms = m.symbol orelse continue;
            const md = m.data.enum_member;
            var val: T.EnumValue = .none;
            // Earlier members are declared by now, which is what forward references rely on.
            if (md.init) |i| val = parseEnumInit(c, i, s) else if (next) |v| {
                val = .{ .num = v };
            }
            next = if (val == .num) val.num + 1 else null;
            if (val == .none) literal = false;
            const t = c.mk(.{ .enum_lit = c.create(T.EnumLit, .{ .sym = ms, .parent = s, .value = val }) });
            c.declared.put(c.a, ms, t) catch oom();
            types.append(c.a, t) catch oom();
        }
    }
    var out: *Type = undefined;
    if (literal and types.items.len > 0) {
        out = if (types.items.len == 1) types.items[0] else c.getUnion(types.items);
        if (types.items.len > 1) out.enum_sym = s;
    } else {
        out = c.mk(.{ .enum_ = s });
        out.enum_sym = s;
    }
    c.declared.put(c.a, s, out) catch oom();
    return out;
}

pub fn basesOf(c: *Checker, t: *Type) []*Type {
    const o = t.data.obj;
    if (o.bases) |b| return b;
    if (o.bases_resolving) return &.{};
    o.bases_resolving = true;
    defer o.bases_resolving = false;
    var out = c.newList(*Type);
    const s = o.sym orelse return &.{};
    for (s.decls) |d| {
        const heritage: []*Node = switch (d.data) {
            .class => |x| x.heritage,
            .interface => |x| x.heritage,
            else => continue,
        };
        for (heritage) |h| {
            if (h.data != .heritage_clause) continue;
            const hc = h.data.heritage_clause;
            if (d.data == .class and hc.tok != .kw_extends) continue;
            for (hc.types) |e| {
                const b = if (d.data == .class) classBase(c, e) else typeFromNode(c, e);
                if (T.isAny(b)) {
                    o.any_base = true;
                    continue;
                }
                const ok = b.data == .obj or b.data == .inter;
                if (!ok) {
                    o.any_base = true;
                    continue;
                }
                // `{ kind: "a" } & { kind: "b" }` is `never` once reduced, so it has no members to inherit.
                if (d.data == .interface and isNeverReduced(c, b)) {
                    report(c, e, 2312, "An interface can only extend an object type or intersection of object types with statically known members.");
                    continue;
                }
                // Dropping the closing edge is what keeps every walk over bases finite.
                if (basesReach(c, b, t, 0)) {
                    reportCircularBase(c, t, b);
                    continue;
                }
                out.append(c.a, b) catch oom();
            }
        }
    }
    o.bases = out.items;
    return out.items;
}

fn basesReach(c: *Checker, from: *Type, goal: *Type, depth: u32) bool {
    if (from.data != .obj or depth > 256) return false;
    const g = from.data.obj.target orelse from;
    if (g == goal) return true;
    if (g.data != .obj or g.data.obj.kind == .anon) return false;
    for (basesOf(c, g)) |b| if (basesReach(c, b, goal, depth + 1)) return true;
    return false;
}

/// Every class or interface on the cycle gets the error, as in tsc.
fn reportCircularBase(c: *Checker, t: *Type, closing: *Type) void {
    var cur: ?*Type = t;
    var next = closing;
    var steps: u32 = 0;
    while (cur) |x| : (steps += 1) {
        if (x.data != .obj or steps > 256) return;
        const s = x.data.obj.sym orelse return;
        for (s.decls) |n| switch (n.data) {
            .class => |k| if (k.name) |name| report(c, name, 2506, c.fmt("'{s}' is referenced directly or indirectly in its own base expression.", .{s.name})),
            .interface => |k| report(c, k.name, 2310, c.fmt("Type '{s}' recursively references itself as a base type.", .{s.name})),
            else => {},
        };
        const g = next.data.obj.target orelse next;
        if (g == t) return;
        cur = g;
        if (g.data != .obj) return;
        // Follow the base the cycle runs through: a sibling base may be an intersection or a dead end.
        next = for (basesOf(c, g)) |b| {
            if (basesReach(c, b, t, 0)) break b;
        } else return;
    }
}

pub fn classBase(c: *Checker, e: *Node) *Type {
    if (e.data != .expr_with_type_args) return c.t_err;
    const x = e.data.expr_with_type_args;
    if (x.expr.data == .null_lit) return c.t_err;
    if (isEntity(x.expr)) {
        if (entitySymbol(c, x.expr, F.value)) |s| {
            const target = targetOf(c, s) orelse return c.t_err;
            if (target.flags & F.class != 0) {
                return typeRefFromSymbol(c, e, target, x.type_args.items);
            }
        }
    }
    // `extends Mixin(Base)` and friends: whatever construct signature the value has.
    const v = expr.checkExpression(c, x.expr);
    const sigs = ctorSigs(c, v);
    if (sigs.len == 0) return if (T.isAny(v)) v else c.t_err;
    var sig = sigs[0];
    if (sig.tparams.len > 0) {
        if (x.type_args.items.len != sig.tparams.len) return c.t_err;
        const args = c.a.alloc(*Type, sig.tparams.len) catch oom();
        for (x.type_args.items, 0..) |a, i| args[i] = typeFromNode(c, a);
        sig = instSig(c, sig, arrayMapper(c, sig.tparams, args));
    }
    return returnOf(c, sig);
}

fn isEntity(n: *Node) bool {
    return switch (n.data) {
        .identifier => true,
        .prop_access => |x| isEntity(x.expr),
        else => false,
    };
}

pub fn entitySymbol(c: *Checker, n: *Node, meaning: u32) ?*Symbol {
    switch (n.data) {
        .identifier => |name| return resolveName(c, n, name, meaning),
        .prop_access => |x| return memberSym(c, entitySymbol(c, x.expr, F.namespace | F.alias), x.name.data.identifier, meaning),
        .qualified_name => |x| return memberSym(c, entitySymbol(c, x.left, F.namespace | F.alias), x.right.data.identifier, meaning),
        else => return null,
    }
}

fn memberSym(c: *Checker, base: ?*Symbol, name: []const u8, meaning: u32) ?*Symbol {
    const b = targetOf(c, base orelse return null) orelse return null;
    const s = c.prog.exportOf(b, name) orelse return null;
    return matches(c, s, meaning);
}

// ---- type nodes ----

pub fn typeFromNode(c: *Checker, n: *Node) *Type {
    if (c.node_types.get(n)) |t| return t;
    if (c.node_resolving.contains(n)) return c.t_err;
    c.node_resolving.put(c.a, n, {}) catch oom();
    const saved = c.current_node;
    const saved_is_type = c.current_is_type;
    c.current_node = n;
    c.current_is_type = true;
    const t = typeFromNodeWorker(c, n);
    c.current_node = saved;
    c.current_is_type = saved_is_type;
    _ = c.node_resolving.remove(n);
    c.node_types.put(c.a, n, t) catch oom();
    return t;
}

fn typeFromNodeWorker(c: *Checker, n: *Node) *Type {
    switch (n.data) {
        .kw_type => |k| return switch (k) {
            .any => c.t_any,
            .unknown => c.t_unknown,
            .never => c.t_never,
            .void => c.t_void,
            .number => c.t_number,
            .string => c.t_string,
            .boolean => c.t_boolean,
            .bigint => c.t_bigint,
            .symbol => c.t_symbol,
            .object => c.t_nonprim,
            .undefined => c.t_undefined,
            .null => c.t_null,
            .intrinsic => c.t_err,
        },
        .paren_type => |x| return typeFromNode(c, x.type),
        .this_type => return thisTypeAt(c, n),
        .type_ref => |x| return typeFromRef(c, n, x.name, x.type_args.items),
        .expr_with_type_args => |x| return typeFromRef(c, n, x.expr, x.type_args.items),
        .type_query => |x| {
            const t = typeOfQuery(c, x.name);
            return if (x.type_args.items.len > 0) expr.instantiationExpr(c, t, x.type_args.items) else t;
        },
        .type_literal => {
            const t = c.newObj(.{ .kind = .anon, .sym = n.symbol, .node = n });
            t.vars = referencedTParams(c, n).len > 0;
            return t;
        },
        .func => {
            const t = c.newObj(.{ .kind = .anon, .sym = n.symbol, .node = n });
            t.vars = referencedTParams(c, n).len > 0;
            return t;
        },
        .array_type => |x| return arrayOf(c, typeFromNode(c, x.elem)),
        .tuple_type => return tupleFromNode(c, n, false),
        .union_type => |x| {
            const list = c.a.alloc(*Type, x.types.len) catch oom();
            for (x.types, 0..) |e, i| list[i] = typeFromNode(c, e);
            return c.getUnion(list);
        },
        .intersection_type => |x| {
            const list = c.a.alloc(*Type, x.types.len) catch oom();
            for (x.types, 0..) |e, i| list[i] = typeFromNode(c, e);
            const primitive = list[0].data == .string or list[0].data == .number or list[0].data == .bigint;
            const spelled_empty = x.types[list.len - 1].data == .type_literal and x.types[list.len - 1].data.type_literal.members.len == 0;
            return c.intersect(list, list.len == 2 and primitive and spelled_empty);
        },
        .conditional_type => return condFromNode(c, n),
        .infer_type => |x| return if (x.tparam.symbol) |s| tparamOf(c, s) else c.t_err,
        .type_operator => |x| switch (x.op) {
            .kw_keyof => return getIndexType(c, typeFromNode(c, x.type)),
            .kw_readonly => {
                if (x.type.data == .array_type) return readonlyArrayOf(c, typeFromNode(c, x.type.data.array_type.elem));
                if (x.type.data == .tuple_type) return tupleFromNode(c, x.type, true);
                return typeFromNode(c, x.type);
            },
            .kw_unique => {
                const p = n.parent orelse return c.t_symbol;
                const s = declSymbol(p) orelse return c.t_symbol;
                return uniqueSymbol(c, s);
            },
            else => return c.t_err,
        },
        .indexed_access => |x| return getIndexedAccess(c, typeFromNode(c, x.object), typeFromNode(c, x.index)),
        .mapped_type => {
            const t = c.newObj(.{ .kind = .mapped, .sym = n.symbol, .node = n });
            t.vars = referencedTParams(c, n).len > 0;
            return t;
        },
        .literal_type => |x| return literalFromNode(c, x.lit),
        .template_literal_type => |x| {
            var texts = c.newList([]const u8);
            var types = c.newList(*Type);
            texts.append(c.a, x.head) catch oom();
            for (x.spans) |sp| {
                const d = sp.data.template_type_span;
                types.append(c.a, typeFromNode(c, d.type)) catch oom();
                texts.append(c.a, d.text) catch oom();
            }
            return getTemplate(c, texts.items, types.items);
        },
        .import_type => |x| return importType(c, n, x.is_typeof, x.arg, x.qualifier, x.type_args.items),
        .type_predicate => |x| return if (x.asserts) c.t_void else c.t_boolean,
        .named_tuple_member => |x| return typeFromNode(c, x.type),
        .optional_type => |x| return typeFromNode(c, x.type),
        .rest_type => |x| return typeFromNode(c, x.type),
        else => return c.t_err,
    }
}

fn declSymbol(n: *Node) ?*Symbol {
    return switch (n.data) {
        .var_decl, .property_decl, .property_sig => n.symbol,
        else => null,
    };
}

pub fn uniqueSymbol(c: *Checker, s: *Symbol) *Type {
    if (c.uniques.get(s)) |t| return t;
    const t = c.mk(.{ .unique = s });
    c.uniques.put(c.a, s, t) catch oom();
    return t;
}

fn literalFromNode(c: *Checker, n: *Node) *Type {
    return switch (n.data) {
        .string_lit, .no_subst_template => |v| c.strLit(v),
        .numeric_lit => |v| c.numLit((emit.parseNumber(v) orelse 0)),
        .bigint_lit => |v| c.bigLit(v),
        .true_lit => c.t_true,
        .false_lit => c.t_false,
        .null_lit => c.t_null,
        .prefix => |x| blk: {
            const inner = literalFromNode(c, x.expr);
            if (inner.data == .num_lit and x.op == .minus) break :blk c.numLit(-inner.data.num_lit);
            if (inner.data == .big_lit and x.op == .minus) break :blk c.bigLit(c.fmt("-{s}", .{inner.data.big_lit}));
            break :blk inner;
        },
        else => c.t_err,
    };
}

fn thisTypeAt(c: *Checker, n: *Node) *Type {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        switch (x.data) {
            .class, .interface => {
                const s = x.symbol orelse return c.t_err;
                const d = declaredType(c, s);
                if (d.data == .obj) if (d.data.obj.this_type) |t| return t;
                return c.t_err;
            },
            .func => |f| {
                if (f.kind == .decl or f.kind == .expr or f.kind == .function_type) {
                    if (thisParam(x)) |p| if (p.data.param.type) |ann| {
                        if (ann != n) return typeFromNode(c, ann);
                    };
                }
            },
            else => {},
        }
    }
    return c.t_err;
}

pub fn thisParam(fnode: *Node) ?*Node {
    const f = fnode.data.func;
    if (f.params.len == 0) return null;
    const p = f.params[0];
    if (p.data.param.name.data == .identifier and std.mem.eql(u8, p.data.param.name.data.identifier, "this")) return p;
    return null;
}

fn tupleFromNode(c: *Checker, n: *Node, readonly: bool) *Type {
    const items = n.data.tuple_type.elems;
    const elems = c.a.alloc(*Type, items.len) catch oom();
    const flags = c.a.alloc(T.ElemFlag, items.len) catch oom();
    const names = c.a.alloc(?[]const u8, items.len) catch oom();
    for (items, 0..) |e, i| {
        names[i] = null;
        var inner = e;
        var fl = T.ElemFlag.required;
        switch (e.data) {
            .named_tuple_member => |x| {
                names[i] = if (x.name.data == .identifier) x.name.data.identifier else null;
                inner = x.type;
                if (x.question) fl = .optional;
                if (x.dotdotdot) fl = .rest;
            },
            .optional_type => |x| {
                inner = x.type;
                fl = .optional;
            },
            .rest_type => |x| {
                inner = x.type;
                fl = .rest;
            },
            else => {},
        }
        var t = typeFromNode(c, inner);
        if (fl == .rest) {
            if (c.isArrayType(t)) {
                t = t.data.obj.args.?[0];
            } else fl = .variadic;
        }
        elems[i] = t;
        flags[i] = fl;
    }
    return c.makeTuple(elems, flags, readonly, names);
}

fn typeOfQuery(c: *Checker, name: *Node) *Type {
    if (name.data == .identifier) {
        const v = name.data.identifier;
        if (std.mem.eql(u8, v, "this")) return expr.checkThisAt(c, name);
    }
    switch (name.data) {
        .identifier => {
            const s = resolveName(c, name, name.data.identifier, F.value) orelse {
                const v = name.data.identifier;
                if (expr.suggestName(c, name, v, F.value)) |sug| {
                    report(c, name, 2552, c.fmt("Cannot find name '{s}'. Did you mean '{s}'?", .{ v, sug }));
                } else {
                    report(c, name, 2304, c.fmt("Cannot find name '{s}'.", .{v}));
                }
                return c.t_err;
            };
            return expr.flowTypeOfQuery(c, name, s);
        },
        .qualified_name => |x| {
            return expr.memberQuery(c, name, typeOfQuery(c, x.left));
        },
        else => return c.t_err,
    }
}

fn importType(c: *Checker, n: *Node, is_typeof: bool, arg: *Node, qualifier: ?*Node, targs: []*Node) *Type {
    if (arg.data != .literal_type or arg.data.literal_type.lit.data != .string_lit) return c.t_err;
    const f = fileOf(c, n) orelse return c.t_err;
    const sf = c.prog.sourceOf(f) orelse return c.t_err;
    const spec = arg.data.literal_type.lit.data.string_lit;
    const m = c.prog.resolveModuleName(sf, spec) orelse {
        checker.checkModuleRef(c, n, arg.data.literal_type.lit);
        return c.t_unresolved;
    };
    var s: ?*Symbol = c.prog.exportOf(m, "export=") orelse m;
    if (qualifier) |q| s = importMember(c, s, q);
    const target = targetOf(c, s orelse return c.t_err) orelse return c.t_err;
    if (is_typeof) return typeOfSymbol(c, target);
    if (target.flags & F.type == 0) return typeOfSymbol(c, target);
    return typeRefFromSymbol(c, n, target, targs);
}

fn importMember(c: *Checker, base: ?*Symbol, q: *Node) ?*Symbol {
    const b0 = base orelse return null;
    const b = targetOf(c, b0) orelse return null;
    return switch (q.data) {
        .identifier => |v| c.prog.exportOf(b, v),
        .qualified_name => |x| blk: {
            const l = importMember(c, base, x.left) orelse break :blk null;
            const lt = targetOf(c, l) orelse break :blk null;
            break :blk c.prog.exportOf(lt, x.right.data.identifier);
        },
        else => null,
    };
}

pub fn typeRefFromSymbol(c: *Checker, n: *Node, s: *Symbol, targs: []*Node) *Type {
    if (s.flags & (F.class | F.interface) != 0) {
        const g = declaredType(c, s);
        if (g.data != .obj or g.data.obj.kind != .iface) return g;
        const o = g.data.obj;
        const outer_len = o.tparams.len - o.local_tparams.len;
        const min = minArgs(c, o.local_tparams);
        if (o.local_tparams.len == 0) {
            if (targs.len > 0) report(c, refNameNode(n), 2315, c.fmt("Type '{s}' is not generic.", .{s.name}));
            return g;
        }
        if (targs.len < min or targs.len > o.local_tparams.len) {
            if (!isInHeritageOfJsLike(n)) reportArity(c, n, s, o.local_tparams, min);
            return c.t_err;
        }
        const args = c.a.alloc(*Type, o.tparams.len) catch oom();
        for (o.tparams[0..outer_len], 0..) |p, i| args[i] = p;
        fillArgs(c, args[outer_len..], o.local_tparams, targs);
        checkConstraints(c, targs, o.local_tparams, args[outer_len..]);
        return c.internRef(g, args, null);
    }
    if (s.flags & F.type_alias != 0) {
        const params = aliasParams(c, s);
        const min = minArgs(c, params);
        if (params.len == 0) {
            if (targs.len > 0) report(c, refNameNode(n), 2315, c.fmt("Type '{s}' is not generic.", .{s.name}));
            return declaredType(c, s);
        }
        if (targs.len < min or targs.len > params.len) {
            reportArity(c, n, s, params, min);
            return c.t_err;
        }
        const args = c.a.alloc(*Type, params.len) catch oom();
        fillArgs(c, args, params, targs);
        checkConstraints(c, targs, params, args);
        return instantiateAlias(c, s, params, args);
    }
    if (s.flags & F.enum_member != 0) return enumMemberType(c, s);
    return declaredType(c, s);
}

fn isInHeritageOfJsLike(_: *Node) bool {
    return false;
}

fn refNameNode(n: *Node) *Node {
    return switch (n.data) {
        .type_ref => |x| x.name,
        .expr_with_type_args => |x| x.expr,
        else => n,
    };
}

pub fn minArgs(c: *Checker, params: []*Type) usize {
    var m: usize = params.len;
    while (m > 0 and defaultOf(c, params[m - 1]) != null) m -= 1;
    return m;
}

fn reportArity(c: *Checker, n: *Node, s: *Symbol, params: []*Type, min: usize) void {
    var names = c.newList(u8);
    for (params, 0..) |p, i| {
        if (i > 0) names.appendSlice(c.a, ", ") catch oom();
        names.appendSlice(c.a, p.data.param.name) catch oom();
    }
    if (min == params.len) {
        report(c, n, 2314, c.fmt("Generic type '{s}<{s}>' requires {d} type argument(s).", .{ s.name, names.items, params.len }));
    } else {
        report(c, n, 2707, c.fmt("Generic type '{s}<{s}>' requires between {d} and {d} type arguments.", .{ s.name, names.items, min, params.len }));
    }
}

pub fn fillArgs(c: *Checker, out: []*Type, params: []*Type, targs: []*Node) void {
    for (targs, 0..) |a, i| out[i] = typeFromNode(c, a);
    // A literal or mapped type in a default counts every parameter of the declaration as outer,
    // so one left unbound would keep the instance generic and hide its members.
    @memset(out[targs.len..], c.t_unknown);
    const m = arrayMapper(c, params, out);
    for (targs.len..params.len) |i| {
        const d = defaultOf(c, params[i]) orelse continue;
        out[i] = instantiate(c, d, m);
    }
}

/// Waits until declarations are done: `class A extends B<A>` reaches this while resolving
/// `A`'s bases, and relating `A` to a constraint then would see a class with no members.
fn checkConstraints(c: *Checker, nodes: []*Node, params: []*Type, args: []*Type) void {
    if (c.silent == 0) c.pending_constraints.append(c.a, .{ .nodes = nodes, .params = params, .args = args }) catch oom();
}

pub fn verifyConstraints(c: *Checker, p: T.PendingConstraint) void {
    const m = arrayMapper(c, p.params, p.args);
    const params = p.params;
    const args = p.args;
    for (p.nodes, 0..) |n, i| {
        const k = constraintOf(c, params[i]) orelse continue;
        const inst = instantiate(c, k, m);
        if (args[i].vars or inst.vars) continue;
        if (T.isAny(inst) or T.isAny(args[i])) continue;
        if (!relate.isAssignable(c, args[i], inst)) {
            if (expr.reportMissing(c, args[i], inst, n)) continue;
            report(c, n, 2344, c.fmt("Type '{s}' does not satisfy the constraint '{s}'.", .{ expr.show(c, args[i]), expr.show(c, inst) }));
        }
    }
}

pub fn instantiateAlias(c: *Checker, s: *Symbol, params: []*Type, args: []*Type) *Type {
    const key = c.keyOf('A', args.len + 1);
    key[1] = @truncate(@intFromPtr(s) >> 3);
    for (args, 2..) |t, i| key[i] = t.id;
    if (c.instantiation_cache.get(key)) |t| return t;
    const owned = c.a.dupe(u32, key) catch oom();
    const d = declaredType(c, s);
    const t = instantiate(c, d, arrayMapper(c, params, args));
    c.instantiation_cache.put(c.a, owned, t) catch oom();
    return t;
}

fn typeFromRef(c: *Checker, n: *Node, name: *Node, targs: []*Node) *Type {
    const meaning = F.type;
    const s = switch (name.data) {
        .identifier => |v| resolveName(c, n, v, meaning),
        else => entitySymbol(c, name, meaning),
    } orelse return unresolvedType(c, name);
    const target = targetOf(c, s) orelse return c.t_unresolved;
    if (name.data == .identifier and target.flags & F.type_param != 0) return tparamOf(c, target);
    return typeRefFromSymbol(c, n, target, targs);
}

fn unresolvedType(c: *Checker, name: *Node) *Type {
    switch (name.data) {
        .identifier => |v| {
            if (v.len == 0) return c.t_err;
            const value = resolveName(c, name, v, F.value);
            if (value != null and value.?.flags & F.namespace == 0) {
                report(c, name, 2749, c.fmt("'{s}' refers to a value, but is being used as a type here. Did you mean 'typeof {s}'?", .{ v, v }));
            } else if (resolveName(c, name, v, F.namespace) != null) {
                report(c, name, 2709, c.fmt("Cannot use namespace '{s}' as a type.", .{v}));
            } else if (expr.suggestName(c, name, v, F.type)) |s| {
                report(c, name, 2552, c.fmt("Cannot find name '{s}'. Did you mean '{s}'?", .{ v, s }));
            } else {
                report(c, name, 2304, c.fmt("Cannot find name '{s}'.", .{v}));
            }
        },
        .qualified_name => |x| {
            const base = entitySymbol(c, x.left, F.namespace | F.alias);
            if (base) |b| {
                const bt = targetOf(c, b);
                if (bt != null) report(c, x.right, 2694, c.fmt("Namespace '{s}' has no exported member '{s}'.", .{ bt.?.name, x.right.data.identifier }));
            } else if (x.left.data == .identifier) {
                report(c, x.left, 2503, c.fmt("Cannot find namespace '{s}'.", .{x.left.data.identifier}));
            }
        },
        else => {},
    }
    return c.t_unresolved;
}

// ---- mappers and instantiation ----

pub fn arrayMapper(c: *Checker, from: []*Type, to: []*Type) *Mapper {
    std.debug.assert(from.len <= to.len);
    return c.create(Mapper, .{ .array = .{ .from = from, .to = to.ptr } });
}

pub fn compose(c: *Checker, m1: ?*Mapper, m2: ?*Mapper) ?*Mapper {
    if (m1 == null) return m2;
    if (m2 == null) return m1;
    return c.create(Mapper, .{ .composite = .{ .m1 = m1.?, .m2 = m2.? } });
}

pub fn mapType(c: *Checker, m: *Mapper, t: *Type) *Type {
    switch (m.*) {
        .array => |a| {
            for (a.from, 0..) |f, i| if (f == t) return a.to[i];
            return t;
        },
        .composite => |x| {
            const t1 = mapType(c, x.m1, t);
            return if (t1 != t) instantiate(c, t1, x.m2) else mapType(c, x.m2, t);
        },
        .infer => |ctx| return relate.inferMap(c, ctx, t, m),
        .erase => return if (t.data == .param and !t.data.param.is_this) c.t_any else t,
    }
}

fn mapAll(c: *Checker, m: *Mapper, list: []*Type) []*Type {
    const out = c.a.alloc(*Type, list.len) catch oom();
    for (list, 0..) |t, i| out[i] = instantiate(c, t, m);
    return out;
}

/// Instantiation mostly finds types that already exist, and arena memory never comes back, so
/// argument lists that end up thrown away stay on the stack.
const small_list = 16;

fn smallList(c: *Checker, buf: *[small_list]*Type, n: usize) []*Type {
    return if (n <= buf.len) buf[0..n] else c.a.alloc(*Type, n) catch oom();
}

fn mapInto(c: *Checker, m: *Mapper, list: []*Type, buf: *[small_list]*Type) []*Type {
    const out = smallList(c, buf, list.len);
    for (list, 0..) |t, i| out[i] = instantiate(c, t, m);
    return out;
}

pub fn instantiate(c: *Checker, t: *Type, mo: ?*Mapper) *Type {
    const m = mo orelse return t;
    if (!t.vars) return t;
    // The same two limits as tsc, so a runaway type costs one statement rather than the whole run.
    if (c.instantiation_depth >= 100 or c.instantiation_count >= 5_000_000) return c.t_err;
    c.instantiation_count += 1;
    c.instantiation_depth += 1;
    defer c.instantiation_depth -= 1;
    var small: [small_list]*Type = undefined;
    switch (t.data) {
        .param => return mapType(c, m, t),
        .union_ => |u| {
            const out = c.getUnion(mapInto(c, m, u, &small));
            return keepAlias(c, t, out, m);
        },
        .inter => |u| {
            const out = c.getIntersection(mapInto(c, m, u, &small));
            return keepAlias(c, t, out, m);
        },
        .keyof => |x| return getIndexType(c, instantiate(c, x, m)),
        .access => |x| return getIndexedAccess(c, instantiate(c, x.obj, m), instantiate(c, x.index, m)),
        .tmpl => |x| return getTemplate(c, x.texts, mapAll(c, m, x.types)),
        .strmap => |x| return getStringMapping(c, x.kind, instantiate(c, x.ty, m)),
        .noinfer => |x| return getNoInfer(c, instantiate(c, x, m)),
        .cond => return keepAlias(c, t, instCond(c, t, m), m),
        .obj => |o| switch (o.kind) {
            .iface => {
                if (o.tparams.len == 0 and o.this_type == null) return t;
                return c.internRefOrSelf(t, mapInto(c, m, o.tparams, &small));
            },
            .ref => {
                const args = mapInto(c, m, o.args.?, &small);
                const this_arg = if (o.this_arg) |x| instantiate(c, x, m) else null;
                return c.internRef(o.target.?, args, this_arg);
            },
            .tuple => return c.makeTuple(mapAll(c, m, o.elems), o.eflags, o.readonly, o.names),
            .anon, .mapped => return instantiateAnon(c, t, m),
        },
        else => return t,
    }
}

fn keepAlias(c: *Checker, t: *Type, out: *Type, m: *Mapper) *Type {
    // Interned results are shared, so only a type of the same shape may take the alias.
    const same = std.meta.activeTag(t.data) == std.meta.activeTag(out.data) and (out.data == .union_ or out.data == .inter or out.data == .cond);
    if (t.alias != null and out.alias == null and out != c.t_boolean and (same or (t.data == .inter and allMapped(out)))) {
        out.alias = c.create(T.Alias, .{ .sym = t.alias.?.sym, .args = mapAll(c, m, t.alias.?.args) });
    }
    return out;
}

/// `Shape<A | B>` as one union of `Shape`'s own instances: nothing else can intern to it.
fn allMapped(t: *Type) bool {
    if (t.data != .union_) return false;
    for (t.data.union_) |m| if (m.data != .obj or m.data.obj.kind != .mapped) return false;
    return true;
}

fn instantiateAnon(c: *Checker, t: *Type, m: *Mapper) *Type {
    const o = t.data.obj;
    const root = o.target orelse t;
    const decl = root.data.obj.node orelse root.data.obj.literal orelse (if (root.data.obj.sym) |s| (if (s.decls.len > 0) s.decls[0] else null) else null) orelse return if (t.vars) instantiatedSigs(c, t, m) else t;
    const outer = if (isWrittenType(decl)) referencedTParams(c, decl) else outerTParams(c, decl);
    if (outer.len == 0) return t;
    const combined = compose(c, o.mapper, m).?;
    var small: [small_list]*Type = undefined;
    const mapped = smallList(c, &small, outer.len);
    var same = o.target == null;
    for (outer, 0..) |p, i| {
        mapped[i] = mapType(c, combined, p);
        if (mapped[i] != p) same = false;
    }
    if (same) return t;
    if (o.kind == .mapped) if (homomorphicParam(c, root)) |hp| {
        const arg = mapType(c, combined, hp);
        if (arg != hp) if (instantiateHomomorphic(c, root, hp, arg, outer, mapped)) |r| {
            // Inference sees `Shape<A | B>` as one argument, not as `A` and `B` apart.
            if (root.alias != null and r.alias == null and allMapped(r)) {
                r.alias = c.create(T.Alias, .{ .sym = root.alias.?.sym, .args = mapAll(c, combined, root.alias.?.args) });
            }
            return r;
        };
    };
    return anonInstance(c, root, outer, mapped, o);
}

/// `typeof C<T>` has no declaration of its own: only its signatures know the `T`.
fn instantiatedSigs(c: *Checker, t: *Type, m: *Mapper) *Type {
    const src = membersOf(c, t);
    const out = c.emptyMembers();
    out.props = src.props;
    out.indexes = src.indexes;
    out.calls = c.dupe(*Sig, src.calls);
    out.ctors = c.dupe(*Sig, src.ctors);
    for (out.calls) |*s| s.* = instSig(c, s.*, m);
    for (out.ctors) |*s| s.* = instSig(c, s.*, m);
    return c.newObj(.{ .kind = .anon, .members = out });
}

fn anonInstance(c: *Checker, root: *Type, outer: []*Type, mapped: []*Type, o: *Obj) *Type {
    const key = c.keyOf('a', mapped.len + 1);
    key[1] = root.id;
    for (mapped, 2..) |x, i| key[i] = x.id;
    const gop = c.slot(key);
    if (gop.found_existing) return gop.value_ptr.*;
    const r = c.newObj(.{ .kind = o.kind, .sym = o.sym, .node = root.data.obj.node, .target = root, .mapper = arrayMapper(c, outer, c.dupe(*Type, mapped)), .lit = root.data.obj.lit, .was_lit = root.data.obj.was_lit, .literal = root.data.obj.literal, .open = root.data.obj.open, .spread = root.data.obj.spread });
    for (mapped) |x| if (x.vars) {
        r.vars = true;
    };
    // Set before the alias arguments recurse: they can grow the table or come back to this key.
    gop.value_ptr.* = r;
    if (root.alias) |al| {
        const named = c.create(T.Alias, .{ .sym = al.sym, .args = &.{} });
        r.alias = named;
        named.args = mapAll(c, r.data.obj.mapper.?, al.args);
    }
    return r;
}

/// `T` for `{ [K in keyof T]: ... }`, the shape that maps arrays to arrays and unions per member.
fn homomorphicParam(c: *Checker, t: *Type) ?*Type {
    const n = t.data.obj.node orelse return null;
    const k = n.data.mapped_type.constraint;
    if (k.data != .type_operator or k.data.type_operator.op != .kw_keyof) return null;
    const x = typeFromNode(c, k.data.type_operator.type);
    return if (x.data == .param) x else null;
}

fn instantiateHomomorphic(c: *Checker, root: *Type, hp: *Type, arg: *Type, outer: []*Type, mapped: []*Type) ?*Type {
    const with = struct {
        fn f(cc: *Checker, r: *Type, h: *Type, a: *Type, ou: []*Type, ma: []*Type) *Type {
            const m2 = cc.dupe(*Type, ma);
            for (ou, 0..) |p, i| if (p == h) {
                m2[i] = a;
            };
            return instantiateHomomorphicMember(cc, r, a, ou, m2);
        }
    }.f;
    switch (arg.data) {
        .union_ => |u| {
            var parts = c.newList(*Type);
            for (u) |x| parts.append(c.a, with(c, root, hp, x, outer, mapped)) catch oom();
            return c.getUnion(parts.items);
        },
        // `Readonly<unknown>` stays a mapped type, one without keys: it can be spread, `unknown` cannot.
        .any, .err, .unknown => return null,
        .string, .number, .bigint, .symbol, .null, .undefined, .void, .never, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_lit, .enum_ => {
            return arg;
        },
        else => {
            if (c.isArrayType(arg) or T.isTupleType(arg)) return with(c, root, hp, arg, outer, mapped);
            return null;
        },
    }
}

fn instantiateHomomorphicMember(c: *Checker, root: *Type, arg: *Type, outer: []*Type, mapped: []*Type) *Type {
    const n = root.data.obj.node.?;
    const d = n.data.mapped_type;
    const key_param = mappedParam(c, n);
    const template = if (d.type) |x| typeFromNode(c, x) else c.t_any;
    const m = arrayMapper(c, outer, mapped);
    const elem = struct {
        fn f(cc: *Checker, kp: *Type, tmpl: *Type, base: *Mapper, key: *Type) *Type {
            return instantiate(cc, tmpl, compose(cc, base, arrayMapper(cc, cc.dupe(*Type, &.{kp}), cc.dupe(*Type, &.{key}))));
        }
    }.f;
    switch (arg.data) {
        // Nothing to map over: `Required<"fixed">` is `"fixed"`.
        .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_lit, .enum_, .null, .undefined, .void, .never => return arg,
        else => {},
    }
    if (c.isArrayType(arg)) {
        const e = elem(c, key_param, template, m, c.t_number);
        const ro = arg.data.obj.target == c.global_readonly_array;
        const drop = d.readonly_mod == .minus;
        return if (ro and !drop or d.readonly_mod == .kw_readonly or d.readonly_mod == .plus) readonlyArrayOf(c, e) else arrayOf(c, e);
    }
    if (T.isTupleType(arg)) {
        const o = arg.data.obj;
        const out = c.a.alloc(*Type, o.elems.len) catch oom();
        const flags = c.dupe(T.ElemFlag, o.eflags);
        for (0..o.elems.len) |i| {
            out[i] = elem(c, key_param, template, m, c.strLit(c.fmt("{d}", .{i})));
            if (flags[i] == .optional and d.question_mod == .minus) flags[i] = .required;
            if (flags[i] == .required and (d.question_mod == .question or d.question_mod == .plus)) flags[i] = .optional;
        }
        return c.makeTuple(out, flags, (o.readonly and d.readonly_mod != .minus) or d.readonly_mod == .kw_readonly or d.readonly_mod == .plus, o.names);
    }
    return anonInstance(c, root, outer, mapped, root.data.obj);
}

pub fn mappedParam(c: *Checker, n: *Node) *Type {
    const name = n.data.mapped_type.tparam_name;
    if (n.locals) |l| if (name.data == .identifier) if (l.get(name.data.identifier)) |s| return tparamOf(c, s);
    return c.t_err;
}

pub fn instSig(c: *Checker, s: *Sig, m0: *Mapper) *Sig {
    var m = m0;
    var fresh: []*Type = &.{};
    if (s.tparams.len > 0) {
        fresh = c.a.alloc(*Type, s.tparams.len) catch oom();
        for (s.tparams, 0..) |p, i| {
            const o = p.data.param;
            fresh[i] = c.mk(.{ .param = c.create(T.TParam, .{ .sym = o.sym, .name = o.name, .decl = o.decl, .is_const = o.is_const, .target = p }) });
            fresh[i].vars = true;
        }
        m = compose(c, arrayMapper(c, s.tparams, fresh), m).?;
        for (fresh) |p| p.data.param.mapper = m;
    }
    const params = c.dupe(T.SigParam, s.params);
    for (params) |*p| p.ty = null;
    return c.create(Sig, .{
        .decl = s.decl,
        .tparams = fresh,
        .params = params,
        .has_rest = s.has_rest,
        .min_args = s.min_args,
        .this_ty = if (s.this_ty) |t| instantiate(c, t, m) else null,
        .target = s,
        .mapper = m,
        .is_ctor = s.is_ctor,
        .abstract = s.abstract,
    });
}

/// Applies type arguments to a signature's own parameters, leaving a non-generic signature.
pub fn applySig(c: *Checker, s: *Sig, m: *Mapper) *Sig {
    const params = c.dupe(T.SigParam, s.params);
    for (params) |*p| p.ty = null;
    return c.create(Sig, .{
        .decl = s.decl,
        .params = params,
        .has_rest = s.has_rest,
        .min_args = s.min_args,
        .this_ty = if (s.this_ty) |t| instantiate(c, t, m) else null,
        .target = s,
        .mapper = m,
        .is_ctor = s.is_ctor,
        .abstract = s.abstract,
    });
}

fn instProp(c: *Checker, p: *Prop, m: ?*Mapper) *Prop {
    const q = c.create(Prop, p.*);
    q.ty = null;
    q.origin = p;
    q.mapper = m;
    return q;
}

pub fn propType(c: *Checker, p: *Prop) *Type {
    if (p.ty) |t| return t;
    const t = propTypeWorker(c, p);
    p.ty = t;
    return t;
}

fn propTypeWorker(c: *Checker, p: *Prop) *Type {
    if (p.origin) |o| return instantiate(c, propType(c, o), p.mapper);
    if (p.mapped_owner) |owner| return mappedPropType(c, owner, p);
    if (p.sym) |s| return instantiate(c, typeOfSymbol(c, s), p.mapper);
    return c.t_err;
}

pub fn propWriteType(c: *Checker, p: *Prop) *Type {
    if (p.origin) |o| return instantiate(c, propWriteType(c, o), p.mapper);
    if (p.sym) |s| if (s.flags & F.setter != 0) {
        for (s.decls) |d| if (d.data == .func and d.data.func.kind == .setter or d.data == .func and d.data.func.kind == .setter_sig) {
            const f = d.data.func;
            if (f.params.len > 0) return instantiate(c, typeOfParam(c, f.params[0]), p.mapper);
        };
    };
    return propType(c, p);
}

// ---- symbol types ----

pub fn typeOfSymbol(c: *Checker, s0: *Symbol) *Type {
    const s = s0.resolve();
    if (c.sym_types.get(s)) |t| return t;
    if (s.flags & F.alias != 0) {
        const t = targetOf(c, s) orelse return c.t_err;
        if (t == s) return c.t_err;
        const out = typeOfSymbol(c, t);
        c.sym_types.put(c.a, s, out) catch oom();
        return out;
    }
    if (c.sym_resolving.contains(s)) return c.t_err;
    c.sym_resolving.put(c.a, s, {}) catch oom();
    // What a symbol is does not depend on the pass over a call that first asks.
    const skip = c.skip_sensitive;
    c.skip_sensitive = false;
    const t = typeOfSymbolWorker(c, s);
    c.skip_sensitive = skip;
    _ = c.sym_resolving.remove(s);
    c.sym_types.put(c.a, s, t) catch oom();
    return t;
}

fn valueObject(c: *Checker, s: *Symbol) *Type {
    const t = c.newObj(.{ .kind = .anon, .sym = s });
    if (s.decls.len > 0) t.vars = outerTParams(c, s.decls[0]).len > 0;
    return t;
}

/// `class X extends B` with `B: T`: `typeof X` is a `T` too, which is what lets a mixin return it.
fn baseTypeVariable(c: *Checker, s: *Symbol) ?*Type {
    for (s.decls) |n| {
        if (n.data != .class) continue;
        for (n.data.class.heritage) |h| {
            if (h.data != .heritage_clause or h.data.heritage_clause.tok != .kw_extends) continue;
            for (h.data.heritage_clause.types) |e| {
                if (e.data != .expr_with_type_args or !isEntity(e.data.expr_with_type_args.expr)) continue;
                const x = e.data.expr_with_type_args.expr;
                const target = targetOf(c, entitySymbol(c, x, F.value) orelse continue) orelse continue;
                if (target.flags & F.variable == 0) continue;
                const v = expr.checkExpression(c, x);
                if (v.data == .param) return v;
                if (v.data == .inter) for (v.data.inter) |m| if (m.data == .param) return m;
            }
        }
    }
    return null;
}

fn typeOfSymbolWorker(c: *Checker, s: *Symbol) *Type {
    // `const x` merged with a types-only `namespace x` is the variable.
    if (s.flags & F.variable != 0) {
        for (s.decls) |n| if (n.data == .var_decl) return typeOfVarDecl(c, n);
    }
    if (s.flags & (F.function | F.method | F.class | F.value_module) != 0) {
        const v = valueObject(c, s);
        if (s.flags & F.class != 0) if (baseTypeVariable(c, s)) |b| return c.getIntersection(&.{ v, b });
        return if (s.flags & F.optional != 0) addOptional(c, v) else v;
    }
    if (s.flags & F.enum_any != 0) return valueObject(c, s);
    if (s.flags & F.enum_member != 0) return c.freshOf(enumMemberType(c, s));
    if (s.flags & F.accessor != 0) return accessorType(c, s);
    const d = s.value_decl orelse (if (s.decls.len > 0) s.decls[0] else return c.t_err);
    return switch (d.data) {
        .var_decl => typeOfVarDecl(c, d),
        .binding_elem => bindingElemType(c, d),
        .param => typeOfParam(c, d),
        .property_decl => |x| propDecl(c, d, x.type, x.init, x.question),
        .property_sig => |x| blk: {
            const t = if (x.type) |n| typeFromNode(c, n) else c.t_any;
            break :blk if (x.question) addOptional(c, t) else t;
        },
        .func => valueObject(c, s),
        .prop_access, .elem_access => expandoType(c, s),
        else => c.t_err,
    };
}

/// `f.x = 1; f.x = 'a'` declares one property that holds either.
fn expandoType(c: *Checker, s: *Symbol) *Type {
    var parts = c.newList(*Type);
    for (s.decls) |left| {
        const value = left.parent.?.data.binary.right;
        parts.append(c.a, expr.widenInit(c, value, expr.checkSilent(c, value), false)) catch oom();
    }
    return c.getUnion(parts.items);
}

pub fn addOptional(c: *Checker, t: *Type) *Type {
    if (!c.strict_null) return t;
    return c.getUnion(&.{ t, c.t_undefined });
}

fn propDecl(c: *Checker, d: *Node, ann: ?*Node, init: ?*Node, question: bool) *Type {
    var t = if (ann) |n| typeFromNode(c, n) else if (init) |i| expr.widenInit(c, i, expr.checkInit(c, i), d.mods.readonly) else typeFromConstructor(c, d) orelse c.t_any;
    if (question) t = addOptional(c, t);
    return t;
}

/// A property with neither type nor initializer takes what the constructor leaves in `this.x`,
/// unless it only ever gets `null` or `undefined`.
fn typeFromConstructor(c: *Checker, d: *Node) ?*Type {
    if (!c.no_implicit_any or d.mods.static or d.mods.declare) return null;
    const cls = d.parent orelse return null;
    if (cls.data != .class) return null;
    const ctor = for (cls.data.class.members) |m| {
        if (m.data == .func and m.data.func.kind == .ctor and m.data.func.body != null) break m;
    } else return null;
    const ref = expr.thisAccess(c, d.data.property_decl.name, ctor) orelse return null;
    const t = flow.flowType(c, ref, c.t_auto, c.t_undefined, ctor);
    if (t == c.t_auto) return c.t_any;
    const members_of = if (t.data == .union_) t.data.union_ else @as([]const *Type, &.{t});
    for (members_of) |m| if (m.data != .null and m.data != .undefined) return t;
    return null;
}

fn accessorType(c: *Checker, s: *Symbol) *Type {
    var getter: ?*Node = null;
    var setter: ?*Node = null;
    for (s.decls) |d| {
        if (d.data != .func) continue;
        const k = d.data.func.kind;
        if (k == .getter or k == .getter_sig) getter = d else setter = d;
    }
    if (getter) |g| if (g.data.func.ret) |r| return typeFromNode(c, r);
    const param = if (setter) |d| (if (d.data.func.params.len > 0) d.data.func.params[0] else null) else null;
    // An annotation on the setter outranks what the getter's body happens to return.
    if (param) |p| if (p.data.param.type != null) return typeOfParam(c, p);
    if (getter) |g| return if (g.data.func.body != null) returnOf(c, sigOfDecl(c, g)) else c.t_any;
    return if (param) |p| typeOfParam(c, p) else c.t_any;
}

fn typeOfVarDecl(c: *Checker, d: *Node) *Type {
    const v = d.data.var_decl;
    if (v.type) |n| return typeFromNode(c, n);
    const list = d.parent orelse return c.t_err;
    if (list.data == .catch_clause) return if (c.unknown_in_catch) c.t_unknown else c.t_any;
    if (list.data == .var_list) if (list.parent) |p| switch (p.data) {
        .for_of => |x| return expr.widenObjectLiterals(c, expr.iteratedOf(c, x.expr, expr.checkExpression(c, x.expr), x.is_await)),
        .for_in => return c.t_string,
        else => {},
    };
    const is_const = list.data == .var_list and (list.data.var_list.kind == .@"const" or list.data.var_list.kind == .using or list.data.var_list.kind == .await_using);
    // `let x;` and `let x = null` have no type of their own: each read gets what the flow assigned.
    if (!is_const and c.no_implicit_any and v.name.data == .identifier and (v.init == null or isNullish(v.init.?)) and !isReadElsewhere(c, list, d)) {
        // JavaScript is checked by rules of its own that are not modeled, so it stays quiet.
        return if (expr.inJs(c, d)) c.t_err else c.t_auto;
    }
    if (v.init) |i| return padPattern(c, expr.widenInit(c, i, expr.checkInit(c, i), is_const), i, v.name);
    return c.t_err;
}

fn isNullish(n: *Node) bool {
    const x = binder.stripParens(n);
    return x.data == .null_lit or (x.data == .identifier and std.mem.eql(u8, x.data.identifier, "undefined"));
}

pub fn isReadElsewhere(c: *Checker, list: *Node, d: *Node) bool {
    return isExported(list) or isAmbient(c, d);
}

pub fn isAmbient(c: *Checker, d: *Node) bool {
    if (fileOf(c, d)) |f| if (f.is_dts) return true;
    var cur: ?*Node = d;
    while (cur) |n| : (cur = n.parent) if (n.mods.declare) return true;
    return false;
}

fn isExported(list: *Node) bool {
    const st = list.parent orelse return false;
    return st.mods.@"export" or st.mods.declare;
}

/// `{ a = 1 } = {}` declares a property the initializer does not have, and the default is what
/// fills it in, so the type has to know about it.
fn padPattern(c: *Checker, t: *Type, init: *Node, pat: *Node) *Type {
    if (pat.data != .object_pattern or init.data != .object_lit or t.data != .obj) return t;
    var added: ?*Members = null;
    for (pat.data.object_pattern.elems) |el| {
        if (el.data != .binding_elem) continue;
        const e = el.data.binding_elem;
        const i = e.init orelse continue;
        if (e.dotdotdot) continue;
        const name = expr.propNameOf(c, e.prop_name orelse e.name) orelse continue;
        if (getProp(c, t, name) != null) continue;
        const m = added orelse blk: {
            const nm = c.emptyMembers();
            const old = membersOf(c, t);
            var it = old.props.iterator();
            while (it.next()) |x| nm.props.put(c.a, x.key_ptr.*, x.value_ptr.*) catch oom();
            nm.indexes = old.indexes;
            added = nm;
            break :blk nm;
        };
        const ty = expr.widenInit(c, i, expr.checkInit(c, i), false);
        m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = ty, .optional = true })) catch oom();
    }
    return if (added) |m| c.newObj(.{ .kind = .anon, .members = m }) else t;
}

/// A setter's parameter takes its type from the getter of the same property.
pub fn setterGetter(fnode: *Node) ?*Node {
    if (fnode.data.func.kind != .setter and fnode.data.func.kind != .setter_sig) return null;
    const s = fnode.symbol orelse return null;
    for (s.decls) |x| if (x.data == .func and (x.data.func.kind == .getter or x.data.func.kind == .getter_sig)) return x;
    return null;
}

/// A getter that says nothing answers to what its setter says.
pub fn setterAnnotation(c: *Checker, fnode: *Node) ?*Type {
    const f = fnode.data.func;
    if (f.kind != .getter or f.ret != null) return null;
    const s = fnode.symbol orelse return null;
    for (s.decls) |x| {
        if (x.data != .func or (x.data.func.kind != .setter and x.data.func.kind != .setter_sig)) continue;
        const ps = x.data.func.params;
        if (ps.len > 0 and ps[0].data.param.type != null) return typeOfParam(c, ps[0]);
    }
    return null;
}

pub fn typeOfParam(c: *Checker, d: *Node) *Type {
    const p = d.data.param;
    if (p.type) |n| {
        var t = typeFromNode(c, n);
        if (p.question) t = addOptional(c, t);
        return t;
    }
    if (c.param_types.get(d)) |t| return t;
    if (d.parent) |fnode| if (fnode.data == .func) {
        if (setterGetter(fnode)) |g| return returnOf(c, sigOfDecl(c, g));
        expr.assignContext(c, fnode);
        if (c.param_types.get(d)) |t| return t;
    };
    if (p.init) |i| {
        var t = padPattern(c, expr.widenInit(c, i, expr.checkInit(c, i), false), i, p.name);
        if (p.question) t = addOptional(c, t);
        return t;
    }
    if (p.name.data != .identifier) return patternType(c, p.name);
    if (p.dotdotdot) return arrayOf(c, c.t_any);
    return c.t_any;
}

/// The shape a destructuring pattern implies when nothing else types it.
fn patternType(c: *Checker, pat: *Node) *Type {
    switch (pat.data) {
        .object_pattern => |x| {
            const m = c.emptyMembers();
            var open = false;
            for (x.elems) |el| {
                if (el.data != .binding_elem) continue;
                const e = el.data.binding_elem;
                if (e.dotdotdot) continue;
                const key = e.prop_name orelse e.name;
                const name = expr.propNameOf(c, key) orelse {
                    open = true;
                    continue;
                };
                const ty = if (e.init) |i| expr.widenInit(c, i, expr.checkInit(c, i), false) else if (e.name.data != .identifier) patternType(c, e.name) else c.t_any;
                m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = ty, .optional = e.init != null })) catch oom();
            }
            return c.newObj(.{ .kind = .anon, .members = m, .open = open });
        },
        .array_pattern => return arrayOf(c, c.t_any),
        else => return c.t_any,
    }
}

fn bindingElemType(c: *Checker, el: *Node) *Type {
    return bindingElemFrom(c, el, bindingParentType(c, el));
}

pub fn bindingParentType(c: *Checker, el: *Node) *Type {
    const pat = el.parent orelse return c.t_err;
    const owner = pat.parent orelse return c.t_err;
    return switch (owner.data) {
        .var_decl => |v| blk: {
            if (v.type) |n| break :blk typeFromNode(c, n);
            const list = owner.parent orelse break :blk c.t_err;
            if (list.data == .var_list) if (list.parent) |p| switch (p.data) {
                .for_of => |x| break :blk expr.widenObjectLiterals(c, expr.iteratedOf(c, x.expr, expr.checkExpression(c, x.expr), x.is_await)),
                .for_in => break :blk c.t_string,
                else => {},
            };
            if (v.init) |i| break :blk padPattern(c, expr.patternParent(c, expr.checkInit(c, i)), i, v.name);
            break :blk c.t_err;
        },
        .param => typeOfParam(c, owner),
        .binding_elem => bindingElemType(c, owner),
        else => c.t_err,
    };
}

pub fn bindingElemFrom(c: *Checker, el: *Node, parent_t: *Type) *Type {
    const pat = el.parent orelse return c.t_err;
    const e = el.data.binding_elem;
    var t = expr.destructuredType(c, parent_t, pat, el);
    if (syntheticAccess(c, el)) |r| t = @import("flow.zig").flowAt(c, r, r.flow.?, t);
    if (e.init) |i| {
        const init_t = expr.widenInit(c, i, expr.checkInit(c, i), true);
        t = c.getUnion(&.{ expr.removeUndefined(c, t), expr.regularWiden(c, init_t) });
    }
    return t;
}

/// `const { a } = o` reads `o.a` at the initializer, so what is known about `o.a` there carries
/// over. The access does not exist in the source, so it is made up to narrow it like one.
fn syntheticAccess(c: *Checker, el: *Node) ?*Node {
    const pat = el.parent orelse return null;
    const owner = pat.parent orelse return null;
    const from: *Node = switch (owner.data) {
        .binding_elem => syntheticAccess(c, owner) orelse return null,
        .var_decl => |v| binder.stripParens(v.init orelse return null),
        else => return null,
    };
    // Only a reference has anything known about it; a call hands out a new value.
    switch (from.data) {
        .identifier, .this_expr, .prop_access, .elem_access => {},
        else => return null,
    }
    const at = from.flow orelse return null;
    const e = el.data.binding_elem;
    if (e.dotdotdot) return null;
    const name: []const u8 = switch (pat.data) {
        .object_pattern => expr.propNameOf(c, e.prop_name orelse e.name) orelse return null,
        .array_pattern => |p| c.fmt("{d}", .{std.mem.indexOfScalar(*Node, p.elems, el) orelse return null}),
        else => return null,
    };
    const lit = c.create(Node, .{ .start = el.start, .end = el.end, .data = .{ .string_lit = name } });
    const r = c.create(Node, .{ .start = el.start, .end = el.end, .parent = el, .flow = at, .data = .{ .elem_access = .{ .expr = from, .index = lit, .optional = false } } });
    lit.parent = r;
    return r;
}

// ---- signatures ----

pub fn sigOfDecl(c: *Checker, d: *Node) *Sig {
    if (c.sig_of_decl.get(d)) |s| return s;
    const f = d.data.func;
    var params = c.newList(T.SigParam);
    var min: u32 = 0;
    var rest = false;
    var this_ty: ?*Type = null;
    for (f.params, 0..) |pn, i| {
        const p = pn.data.param;
        if (i == 0 and thisParam(d) != null) {
            if (p.type) |n| this_ty = typeFromNode(c, n);
            continue;
        }
        const name = if (p.name.data == .identifier) p.name.data.identifier else c.fmt("__{d}", .{i});
        const optional = p.question or p.init != null or p.dotdotdot or p.type == null and takesFewerArgs(d);
        params.append(c.a, .{ .name = name, .sym = pn.symbol, .optional = optional }) catch oom();
        if (!optional) min = @intCast(params.items.len);
        if (p.dotdotdot) rest = true;
    }
    if (f.kind == .getter or f.kind == .getter_sig) min = 0;
    const s = c.create(Sig, .{
        .decl = d,
        .params = params.items,
        .min_args = min,
        .has_rest = rest,
        .this_ty = this_ty,
        .tparams = tparamsFrom(c, f.type_params.items),
    });
    if (f.kind == .ctor or f.kind == .construct_sig or f.kind == .constructor_type) s.is_ctor = true;
    if (f.kind == .constructor_type and d.mods.abstract) s.abstract = true;
    c.sig_of_decl.put(c.a, d, s) catch oom();
    return s;
}

/// `((a, b) => a)(1)` passes what it passes, and a parameter nobody annotated need not be filled.
fn takesFewerArgs(fnode: *Node) bool {
    const call = binder.callOnTheSpot(fnode) orelse return false;
    return fnode.data.func.params.len > call.data.call.args.len;
}

pub fn paramTypeAt(c: *Checker, s: *Sig, i: usize) *Type {
    const p = &s.params[i];
    if (p.ty) |t| return t;
    const t: *Type = if (s.target) |x| instantiate(c, paramTypeAt(c, x, i), s.mapper) else blk: {
        const d = s.decl orelse break :blk c.t_any;
        if (d.data != .func) break :blk c.t_any;
        const f = d.data.func;
        const offset: usize = if (thisParam(d) != null) 1 else 0;
        const p_node = f.params[i + offset];
        // Callers may omit a defaulted parameter; only the body sees it without `undefined`.
        const declared = typeOfParam(c, p_node);
        break :blk if (p_node.data.param.init != null) addOptional(c, declared) else declared;
    };
    p.ty = t;
    return t;
}

pub fn returnOf(c: *Checker, s: *Sig) *Type {
    if (s.ret) |t| return t;
    if (s.target) |x| {
        if (s.ret_resolving) return c.t_err;
        s.ret_resolving = true;
        defer s.ret_resolving = false;
        const t = instantiate(c, returnOf(c, x), s.mapper);
        s.ret = t;
        return t;
    }
    const d = s.decl orelse return c.t_any;
    if (d.data != .func) return c.t_any;
    const f = d.data.func;
    if (s.ret_resolving) return c.t_err;
    s.ret_resolving = true;
    defer s.ret_resolving = false;
    var t: *Type = undefined;
    if (f.kind == .ctor) {
        const owner = d.parent orelse return c.t_err;
        t = if (owner.symbol) |o| declaredType(c, o) else c.t_err;
    } else if (f.ret) |r| {
        t = typeFromNode(c, r);
    } else if (setterAnnotation(c, d)) |a| {
        t = a;
    } else if (f.body != null) {
        t = expr.returnTypeFromBody(c, d);
    } else {
        t = if (f.kind == .setter or f.kind == .setter_sig) c.t_void else c.t_any;
    }
    s.ret = t;
    return t;
}

pub fn predOf(c: *Checker, s: *Sig) ?*T.Pred {
    if (s.pred_done) return s.pred;
    s.pred_done = true;
    if (s.composite.len > 0) {
        s.pred = compositePred(c, s.composite);
        return s.pred;
    }
    if (s.target) |x| {
        if (predOf(c, x)) |p| {
            const q = c.create(T.Pred, p.*);
            if (p.ty) |t| q.ty = instantiate(c, t, s.mapper);
            s.pred = q;
        }
        return s.pred;
    }
    const d = s.decl orelse return null;
    if (d.data != .func) return null;
    const r = d.data.func.ret orelse {
        s.pred = expr.predicateFromBody(c, s, d);
        return s.pred;
    };
    if (r.data != .type_predicate) return null;
    const x = r.data.type_predicate;
    const name = if (x.param.data == .identifier) x.param.data.identifier else "this";
    var idx: i32 = -1;
    const is_this = x.param.data == .this_type or x.param.data == .this_expr or std.mem.eql(u8, name, "this");
    for (s.params, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
        idx = @intCast(i);
    };
    s.pred = c.create(T.Pred, .{ .asserts = x.asserts, .param_index = idx, .is_this = is_this, .ty = if (x.type) |n| typeFromNode(c, n) else null, .name = name });
    return s.pred;
}

pub fn sigsOfSymbol(c: *Checker, s: *Symbol, want_ctor: bool) []*Sig {
    const cache = if (want_ctor) &c.ctor_list else &c.sig_list;
    if (cache.get(s)) |x| return x;
    var out = c.newList(*Sig);
    for (s.decls, 0..) |d, i| {
        if (d.data != .func) continue;
        const f = d.data.func;
        if (want_ctor != (f.kind == .ctor or f.kind == .construct_sig)) continue;
        if (f.body != null and i > 0) {
            const prev = s.decls[i - 1];
            if (prev.data == .func and prev.parent == d.parent and prev.data.func.kind == f.kind and prev.data.func.body == null) continue;
        }
        out.append(c.a, sigOfDecl(c, d)) catch oom();
    }
    cache.put(c.a, s, out.items) catch oom();
    return out.items;
}

// ---- members ----

pub fn membersOf(c: *Checker, t: *Type) *Members {
    const o = t.data.obj;
    if (o.members) |m| return m;
    if (o.resolving) return c.emptyMembers();
    o.resolving = true;
    defer o.resolving = false;
    const m = switch (o.kind) {
        .iface => resolveIface(c, t, t, o.tparams, t),
        .ref => resolveIface(c, t, o.target.?, o.args.?, o.this_arg orelse t),
        .tuple => resolveTuple(c, t),
        .mapped => resolveMapped(c, t),
        .anon => resolveAnon(c, t),
    };
    o.members = m;
    return m;
}

/// Reading goes through the getter, so a `private set` beside a public `get` stays public.
fn getterOf(s: *Symbol) ?*Node {
    if (s.flags & F.getter == 0) return null;
    for (s.decls) |x| if (x.data == .func and (x.data.func.kind == .getter or x.data.func.kind == .getter_sig)) return x;
    return null;
}

fn addExpandos(c: *Checker, m: *Members, func: *Node) void {
    const holder = binder.expandoHolder(func) orelse return;
    if (holder.exports) |table| {
        var it = table.map.iterator();
        while (it.next()) |e| {
            const s = e.value_ptr.*.resolve();
            if (s.flags & F.property != 0) m.props.put(c.a, e.key_ptr.*, propFromSymbol(c, s, null)) catch oom();
        }
    }
    addLateExpandos(c, m, holder);
}

fn addLateExpandos(c: *Checker, m: *Members, s: *Symbol) void {
    for (s.late_members) |late| {
        const left = late.decls[0];
        if (left.data != .elem_access) continue;
        const key = expr.checkSilent(c, left.data.elem_access.index);
        const name = literalName(c, key.regular orelse key) orelse continue;
        if (m.props.contains(name)) continue;
        const p = propFromSymbol(c, late, null);
        p.name = name;
        m.props.put(c.a, name, p) catch oom();
    }
}

fn propFromSymbol(c: *Checker, s: *Symbol, owner: ?*Type) *Prop {
    const d = s.value_decl orelse (if (s.decls.len > 0) s.decls[0] else null);
    const optional = s.flags & F.optional != 0;
    var readonly = false;
    var private = false;
    var protected = false;
    var abstract = false;
    var is_static = false;
    if (getterOf(s) orelse d) |n| {
        readonly = n.mods.readonly;
        private = n.mods.private;
        protected = n.mods.protected;
        abstract = n.mods.abstract;
        is_static = n.mods.static;
    }
    return mkProp(c, s, d, owner, optional, readonly, private, protected, abstract, is_static);
}

fn mkProp(c: *Checker, s: *Symbol, d: ?*Node, owner: ?*Type, optional: bool, readonly: bool, private: bool, protected: bool, abstract: bool, is_static: bool) *Prop {
    return c.create(Prop, .{
        .name = s.name,
        .sym = s,
        .optional = optional,
        .readonly = readonly or (s.flags & F.getter != 0 and s.flags & F.setter == 0),
        .method = s.flags & F.method != 0,
        .private = private,
        .protected = protected,
        .abstract = abstract,
        .static = is_static,
        .decl = d,
        .owner = owner,
    });
}

fn hasUnnamedMember(s: *Symbol) bool {
    const tbl = s.members orelse return false;
    return tbl.get("__constructor") != null or tbl.get("__call") != null or tbl.get("__new") != null;
}

fn resolveIface(c: *Checker, self: *Type, g: *Type, args: []*Type, this_arg: *Type) *Members {
    const o = g.data.obj;
    const m = c.emptyMembers();
    var from = c.newList(*Type);
    var to = c.newList(*Type);
    for (o.tparams, 0..) |p, i| if (i < args.len) {
        from.append(c.a, p) catch oom();
        to.append(c.a, args[i]) catch oom();
    };
    if (o.this_type) |tt| {
        from.append(c.a, tt) catch oom();
        to.append(c.a, this_arg) catch oom();
    }
    const mapper: ?*Mapper = if (from.items.len > 0) arrayMapper(c, from.items, to.items) else null;
    const s = o.sym.?;
    var calls = c.newList(*Sig);
    var ctors = c.newList(*Sig);
    var indexes = c.newList(T.Index);
    if (s.members) |tbl| {
        var it = tbl.map.iterator();
        while (it.next()) |e| {
            const ms = e.value_ptr.*.resolve();
            const name = e.key_ptr.*;
            if (std.mem.eql(u8, name, "__call")) {
                for (sigsOfSymbol(c, ms, false)) |x| calls.append(c.a, if (mapper) |mp| instSig(c, x, mp) else x) catch oom();
            } else if (std.mem.eql(u8, name, "__new")) {
                for (sigsOfSymbol(c, ms, true)) |x| ctors.append(c.a, if (mapper) |mp| instSig(c, x, mp) else x) catch oom();
            } else if (std.mem.eql(u8, name, "__index")) {
                addIndexes(c, ms, mapper, &indexes, false);
            } else if (std.mem.eql(u8, name, "__constructor")) {
                addParamProps(c, ms, m, mapper, g);
            } else {
                const p = propFromSymbol(c, ms, g);
                p.mapper = mapper;
                m.props.put(c.a, name, p) catch oom();
            }
        }
    }
    // Reading a key can come back to this very type, which then shows what it has so far.
    if (s.late_members.len > 0) self.data.obj.members = m;
    addLateMembers(c, s.late_members, m, mapper, g, &indexes, hasUnnamedMember(s));
    for (basesOf(c, g)) |b0| {
        const b = withThis(c, instantiate(c, b0, mapper), this_arg);
        inheritFrom(c, m, b, &calls, &ctors, &indexes, o.is_class);
    }
    m.calls = calls.items;
    m.ctors = ctors.items;
    m.indexes = indexes.items;
    return m;
}

/// A key the checker can name makes a member. Any other key is an index signature, and since the
/// name is known only when the code runs, it speaks for every sibling too.
fn addLateMembers(c: *Checker, late: []*Symbol, m: *Members, mapper: ?*Mapper, owner: ?*Type, indexes: *std.ArrayList(T.Index), unnamed: bool) void {
    var computed = c.newList(expr.ComputedKey);
    var readonly = true;
    for (late) |ls| {
        const node = binder.nameNode(ls.decls[0]) orelse continue;
        const p = propFromSymbol(c, ls, owner);
        p.mapper = mapper;
        const name = expr.propNameOf(c, node) orelse {
            const key = expr.computedKeyOf(c, node) orelse continue;
            computed.append(c.a, .{ .key = key, .ty = propType(c, p) }) catch oom();
            readonly = readonly and p.readonly;
            continue;
        };
        if (m.props.contains(name)) continue;
        p.name = name;
        m.props.put(c.a, name, p) catch oom();
    }
    if (computed.items.len == 0) return;
    outer: for ([_]*Type{ c.t_string, c.t_symbol, c.t_number }) |key| {
        for (indexes.items) |x| if (x.key == key) continue :outer;
        const used = for (computed.items) |x| {
            if (x.key == key) break true;
        } else false;
        if (!used) continue;
        var parts = c.newList(*Type);
        for (computed.items) |x| {
            if (expr.coveredByKey(c, key, x.key == c.t_number, x.key == c.t_symbol)) parts.append(c.a, x.ty) catch oom();
        }
        for (m.props.values()) |p| {
            if (expr.coveredByKey(c, key, expr.isNumericName(c, p.name), std.mem.startsWith(u8, p.name, "__@"))) parts.append(c.a, propType(c, p)) catch oom();
        }
        // A constructor or a call signature is a sibling with no type of its own.
        if (key == c.t_string and unnamed) parts.append(c.a, c.t_any) catch oom();
        indexes.append(c.a, .{ .key = key, .ty = if (parts.items.len > 0) expr.reduceSubtypes(c, parts.items) else c.t_undefined, .readonly = readonly }) catch oom();
    }
}

fn inheritFrom(c: *Checker, m: *Members, b: *Type, calls: *std.ArrayList(*Sig), ctors: *std.ArrayList(*Sig), indexes: *std.ArrayList(T.Index), is_class: bool) void {
    if (b.data == .inter) {
        // What several members declare is all of them at once, not the first one's.
        var seen: T.PropTable = .empty;
        for (b.data.inter) |x| {
            if (x.data != .obj) continue;
            for (membersOf(c, x).props.values()) |p| {
                const gop = seen.getOrPut(c.a, p.name) catch oom();
                // A never-reduced intersection has no property to combine.
                if (gop.found_existing and !m.props.contains(p.name)) m.props.put(c.a, p.name, getProp(c, b, p.name) orelse continue) catch oom();
                gop.value_ptr.* = p;
            }
        }
        for (b.data.inter) |x| inheritFrom(c, m, x, calls, ctors, indexes, is_class);
        return;
    }
    if (b.data != .obj) return;
    const bm = membersOf(c, b);
    var it = bm.props.iterator();
    while (it.next()) |e| {
        if (m.props.contains(e.key_ptr.*)) continue;
        m.props.put(c.a, e.key_ptr.*, e.value_ptr.*) catch oom();
    }
    for (bm.calls) |x| calls.append(c.a, x) catch oom();
    if (!is_class) for (bm.ctors) |x| ctors.append(c.a, x) catch oom();
    outer: for (bm.indexes) |x| {
        for (indexes.items) |y| if (y.key == x.key) continue :outer;
        indexes.append(c.a, x) catch oom();
    }
}

fn addParamProps(c: *Checker, ctor: *Symbol, m: *Members, mapper: ?*Mapper, owner: *Type) void {
    for (ctor.decls) |d| {
        if (d.data != .func) continue;
        for (d.data.func.params) |pn| {
            if (!(pn.mods.public or pn.mods.private or pn.mods.protected or pn.mods.readonly)) continue;
            const s = pn.symbol orelse continue;
            if (m.props.contains(s.name)) continue;
            const p = mkProp(c, s, pn, owner, pn.data.param.question, pn.mods.readonly, pn.mods.private, pn.mods.protected, false, false);
            p.mapper = mapper;
            m.props.put(c.a, s.name, p) catch oom();
        }
    }
}

fn addIndexes(c: *Checker, s: *Symbol, mapper: ?*Mapper, out: *std.ArrayList(T.Index), static: bool) void {
    for (s.decls) |d| {
        if (d.data != .index_sig or d.mods.static != static) continue;
        const x = d.data.index_sig;
        if (x.params.len == 0) continue;
        const pt = x.params[0].data.param.type orelse continue;
        const key = typeFromNode(c, pt);
        const val = if (x.type) |n| typeFromNode(c, n) else c.t_any;
        const parts: []const *Type = if (key.data == .union_) key.data.union_ else &.{key};
        for (parts) |k| {
            out.append(c.a, .{ .key = instantiate(c, k, mapper), .ty = instantiate(c, val, mapper), .readonly = d.mods.readonly, .decl = d }) catch oom();
        }
    }
}

pub fn withThis(c: *Checker, t: *Type, this_arg: *Type) *Type {
    switch (t.data) {
        .obj => |o| switch (o.kind) {
            .iface => return c.internRef(t, o.tparams, this_arg),
            .ref => return c.internRef(o.target.?, o.args.?, this_arg),
            else => return t,
        },
        .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = withThis(c, y, this_arg);
            return c.getIntersection(out);
        },
        else => return t,
    }
}

fn resolveTuple(c: *Checker, t: *Type) *Members {
    const o = t.data.obj;
    const m = c.emptyMembers();
    var parts = c.newList(*Type);
    var open = false;
    var min: usize = 0;
    for (o.elems, o.eflags, 0..) |e, f, i| {
        parts.append(c.a, if (f == .optional) addOptional(c, e) else e) catch oom();
        if (f == .required) min = i + 1;
        if (f == .rest or f == .variadic) open = true;
        if (!open) {
            const name = c.fmt("{d}", .{i});
            m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = if (f == .optional) addOptional(c, e) else e, .optional = f == .optional, .readonly = o.readonly })) catch oom();
        }
    }
    const elem = if (parts.items.len == 0) c.t_never else c.getUnion(parts.items);
    const base = if (o.readonly) readonlyArrayOf(c, elem) else arrayOf(c, elem);
    if (base.data == .obj) {
        const bm = membersOf(c, base);
        var it = bm.props.iterator();
        while (it.next()) |e| if (!m.props.contains(e.key_ptr.*)) m.props.put(c.a, e.key_ptr.*, e.value_ptr.*) catch oom();
        m.indexes = bm.indexes;
    }
    var len: *Type = c.t_number;
    if (!open) {
        var lens = c.newList(*Type);
        for (min..o.elems.len + 1) |i| lens.append(c.a, c.numLit(@floatFromInt(i))) catch oom();
        len = c.getUnion(lens.items);
    }
    m.props.put(c.a, "length", c.create(Prop, .{ .name = "length", .ty = len, .readonly = o.readonly })) catch oom();
    return m;
}

fn resolveAnon(c: *Checker, t: *Type) *Members {
    const o = t.data.obj;
    if (o.target) |root| {
        const src = membersOf(c, root);
        const m = c.emptyMembers();
        var it = src.props.iterator();
        while (it.next()) |e| m.props.put(c.a, e.key_ptr.*, instProp(c, e.value_ptr.*, o.mapper)) catch oom();
        const calls = c.a.alloc(*Sig, src.calls.len) catch oom();
        for (src.calls, 0..) |s, i| calls[i] = instSig(c, s, o.mapper.?);
        const ctors = c.a.alloc(*Sig, src.ctors.len) catch oom();
        for (src.ctors, 0..) |s, i| ctors[i] = instSig(c, s, o.mapper.?);
        const idx = c.dupe(T.Index, src.indexes);
        for (idx) |*x| {
            x.ty = instantiate(c, x.ty, o.mapper);
            x.key = instantiate(c, x.key, o.mapper);
        }
        m.calls = calls;
        m.ctors = ctors;
        m.indexes = idx;
        return m;
    }
    const m = c.emptyMembers();
    if (o.node) |n| if (n.data == .func and o.sym == null) {
        m.calls = c.dupe(*Sig, &.{sigOfDecl(c, n)});
        addExpandos(c, m, n);
        return m;
    };
    const s = o.sym orelse return m;
    if (s.flags & F.type_literal != 0 and s.flags & (F.function | F.class | F.value_module) == 0) {
        var calls = c.newList(*Sig);
        var ctors = c.newList(*Sig);
        var indexes = c.newList(T.Index);
        // `() => void` and `new () => T` carry their own signature and no members table.
        for (s.decls) |d| if (d.data == .func) {
            const sg = sigOfDecl(c, d);
            if (d.data.func.kind == .constructor_type) ctors.append(c.a, sg) catch oom() else calls.append(c.a, sg) catch oom();
        };
        if (s.members) |tbl| {
            var it = tbl.map.iterator();
            while (it.next()) |e| {
                const ms = e.value_ptr.*.resolve();
                const name = e.key_ptr.*;
                if (std.mem.eql(u8, name, "__call")) {
                    for (sigsOfSymbol(c, ms, false)) |x| calls.append(c.a, x) catch oom();
                } else if (std.mem.eql(u8, name, "__new")) {
                    for (sigsOfSymbol(c, ms, true)) |x| ctors.append(c.a, x) catch oom();
                } else if (std.mem.eql(u8, name, "__index")) {
                    addIndexes(c, ms, null, &indexes, false);
                } else {
                    m.props.put(c.a, name, propFromSymbol(c, ms, null)) catch oom();
                }
            }
        }
        addLateMembers(c, s.late_members, m, null, null, &indexes, hasUnnamedMember(s));
        m.calls = calls.items;
        m.ctors = ctors.items;
        m.indexes = indexes.items;
        return m;
    }
    if (s.flags & (F.function | F.method) != 0) m.calls = sigsOfSymbol(c, s, false);
    if (s.flags & F.class != 0) m.ctors = classCtors(c, s);
    if (s.flags & F.function != 0) {
        for (s.decls) |n| addExpandos(c, m, n);
        addLateExpandos(c, m, s);
    }
    const global_this = s.decls.len == 0 and std.mem.eql(u8, s.name, "globalThis");
    for (exportsOf(c, s)) |e| {
        // `let`, `const` and classes are global bindings, but never properties of the global object.
        if (global_this and e.flags & (F.block_var | F.class | F.enum_any) != 0) continue;
        if (std.mem.eql(u8, e.name, "export=")) continue;
        if (e.flags & F.alias == 0 and e.flags & F.value == 0) continue;
        if (e.flags & F.alias != 0) {
            const tgt = targetOf(c, e) orelse continue;
            if (tgt.flags & F.value == 0) continue;
        }
        const p = propFromSymbol(c, e, null);
        p.static = true;
        if (e.flags & F.variable != 0 and e.decls.len > 0 and e.decls[0].parent != null) {
            const l = e.decls[0].parent.?;
            if (l.data == .var_list and l.data.var_list.kind == .@"const") p.readonly = true;
        }
        if (e.flags & F.enum_member != 0) p.readonly = true;
        m.props.put(c.a, e.name, p) catch oom();
    }
    if (s.flags & F.enum_any != 0) {
        const idx = c.a.alloc(T.Index, 1) catch oom();
        idx[0] = .{ .key = c.t_number, .ty = c.t_string, .readonly = true };
        m.indexes = idx;
    }
    if (s.flags & F.class != 0) {
        const cls = declaredType(c, s);
        const proto_ty = eraseArgs(c, cls);
        m.props.put(c.a, "prototype", c.create(Prop, .{ .name = "prototype", .ty = proto_ty, .readonly = true })) catch oom();
        var indexes = c.newList(T.Index);
        if (s.members) |tbl| if (tbl.get("__index")) |i| addIndexes(c, i.resolve(), null, &indexes, true);
        addLateMembers(c, s.late_statics, m, null, null, &indexes, false);
        if (s.decls.len > 0) {
            for (basesOf(c, cls)) |_| {
                if (classBaseValue(c, s)) |v| if (v.data == .obj or v.data == .inter) {
                    for (propsOf(c, v)) |p| if (!m.props.contains(p.name)) m.props.put(c.a, p.name, p) catch oom();
                };
                break;
            }
            // What extends `any` can have any static on top of the ones it declares.
            if (cls.data == .obj and cls.data.obj.any_base) indexes.append(c.a, .{ .key = c.t_string, .ty = c.t_any }) catch oom();
        }
        m.indexes = indexes.items;
    }
    return m;
}

fn eraseArgs(c: *Checker, t: *Type) *Type {
    if (t.data != .obj or t.data.obj.tparams.len == 0) return t;
    const args = c.a.alloc(*Type, t.data.obj.tparams.len) catch oom();
    @memset(args, c.t_any);
    return c.internRef(t, args, null);
}

fn classBaseValue(c: *Checker, s: *Symbol) ?*Type {
    for (s.decls) |d| {
        if (d.data != .class) continue;
        for (d.data.class.heritage) |h| {
            if (h.data != .heritage_clause or h.data.heritage_clause.tok != .kw_extends) continue;
            for (h.data.heritage_clause.types) |e| {
                if (e.data != .expr_with_type_args) continue;
                return expr.checkExpression(c, e.data.expr_with_type_args.expr);
            }
        }
    }
    return null;
}

fn classCtors(c: *Checker, s: *Symbol) []*Sig {
    const cls = declaredType(c, s);
    if (cls.data != .obj) return &.{};
    const o = cls.data.obj;
    var declared: []*Sig = &.{};
    if (s.members) |tbl| if (tbl.get("__constructor")) |ctor| {
        declared = sigsOfSymbol(c, ctor, true);
    };
    var out = c.newList(*Sig);
    const is_abstract = blk: {
        for (s.decls) |d| if (d.data == .class and d.mods.abstract) break :blk true;
        break :blk false;
    };
    if (declared.len > 0) {
        for (declared) |x| {
            const q = c.create(Sig, x.*);
            q.tparams = o.local_tparams;
            q.ret = if (o.tparams.len > 0) c.internRef(cls, o.tparams, null) else cls;
            q.abstract = is_abstract;
            q.params = c.dupe(T.SigParam, x.params);
            // The clone is a different signature from the one parameters were resolved through.
            q.target = null;
            out.append(c.a, q) catch oom();
        }
        return out.items;
    }
    // No constructor of its own: the base's, returning this class.
    if (classBaseValue(c, s)) |v| {
        const bases = ctorSigs(c, v);
        if (bases.len > 0 and basesOf(c, cls).len > 0) {
            for (bases) |b| {
                const q = c.create(Sig, b.*);
                q.ret = if (o.tparams.len > 0) c.internRef(cls, o.tparams, null) else cls;
                q.tparams = o.local_tparams;
                if (b.tparams.len > 0 and basesOf(c, cls).len > 0) {
                    // Base type arguments are fixed by the extends clause; map them in.
                    const base0 = basesOf(c, cls)[0];
                    if (base0.data == .obj and base0.data.obj.args != null and base0.data.obj.args.?.len == b.tparams.len) {
                        const inst = applySig(c, b, arrayMapper(c, b.tparams, base0.data.obj.args.?));
                        const q2 = c.create(Sig, inst.*);
                        q2.ret = q.ret;
                        q2.tparams = o.local_tparams;
                        q2.abstract = is_abstract;
                        out.append(c.a, q2) catch oom();
                        continue;
                    }
                }
                q.abstract = is_abstract;
                out.append(c.a, q) catch oom();
            }
            return out.items;
        }
    }
    const q = c.create(Sig, .{ .is_ctor = true, .tparams = o.local_tparams, .ret = if (o.tparams.len > 0) c.internRef(cls, o.tparams, null) else cls, .abstract = is_abstract });
    out.append(c.a, q) catch oom();
    return out.items;
}

fn resolveMapped(c: *Checker, t: *Type) *Members {
    const o = t.data.obj;
    const m = c.emptyMembers();
    const n = o.node orelse return m;
    const d = n.data.mapped_type;
    const constraint = instantiate(c, typeFromNode(c, d.constraint), o.mapper);
    const add_opt = d.question_mod == .question or d.question_mod == .plus;
    const add_ro = d.readonly_mod == .kw_readonly or d.readonly_mod == .plus;
    const k = d.constraint;
    var src: ?*Type = null;
    if (k.data == .type_operator and k.data.type_operator.op == .kw_keyof) {
        src = instantiate(c, typeFromNode(c, k.data.type_operator.type), o.mapper);
    }
    if (constraint.vars or (src != null and src.?.vars)) {
        o.open = true;
        if (!(isKeyList(constraint))) return m;
    }
    const modifiers: ?*Type = blk: {
        if (src != null) break :blk null;
        const k0 = typeFromNode(c, k);
        if (k0.data != .param) break :blk null;
        const kc = constraintOf(c, k0) orelse break :blk null;
        if (kc.data != .keyof) break :blk null;
        const from = instantiate(c, kc.data.keyof, o.mapper);
        break :blk getApparent(c, from);
    };
    var indexes = c.newList(T.Index);
    const key_param = mappedParam(c, n);
    const addKey = struct {
        fn f(cc: *Checker, tt: *Type, mm: *Members, idx: *std.ArrayList(T.Index), nn: *Node, kp: *Type, key0: *Type, source: ?*Prop, opt: bool, ro: bool) void {
            const dd = nn.data.mapped_type;
            var keys: []const *Type = &.{key0};
            if (dd.name_type) |nt| {
                const mapper = compose(cc, tt.data.obj.mapper, arrayMapper(cc, cc.dupe(*Type, &.{kp}), cc.dupe(*Type, &.{key0})));
                const nk = instantiate(cc, typeFromNode(cc, nt), mapper);
                keys = if (nk.data == .union_) nk.data.union_ else cc.dupe(*Type, &.{nk});
            }
            for (keys) |key| {
                const name = literalName(cc, key);
                if (name) |nm| {
                    const is_opt = opt or (source != null and source.?.optional and dd.question_mod != .minus);
                    const is_ro = ro or (source != null and source.?.readonly and dd.readonly_mod != .minus);
                    const p = cc.create(Prop, .{ .name = nm, .optional = is_opt, .readonly = is_ro, .mapped_key = key0, .mapped_owner = tt, .mapped_required = dd.question_mod == .minus and source != null and source.?.optional, .decl = if (source) |sp| sp.decl else null });
                    mm.props.put(cc.a, nm, p) catch oom();
                } else if (key.data == .string or key.data == .number or key.data == .symbol or key.data == .tmpl and !key.vars) {
                    const mapper = compose(cc, tt.data.obj.mapper, arrayMapper(cc, cc.dupe(*Type, &.{kp}), cc.dupe(*Type, &.{key})));
                    const val = if (dd.type) |x| instantiate(cc, typeFromNode(cc, x), mapper) else cc.t_any;
                    idx.append(cc.a, .{ .key = key, .ty = if (opt) addOptional(cc, val) else val, .readonly = ro }) catch oom();
                } else if (key.data != .never) {
                    tt.data.obj.open = true;
                }
            }
        }
    }.f;
    if (src) |s0| {
        const s = getApparent(c, s0);
        if (s.data == .unknown) {} else if (s.data == .obj or s.data == .inter or s.data == .union_) {
            for (propsOf(c, s)) |p| {
                if (p.private or p.protected) continue;
                addKey(c, t, m, &indexes, n, key_param, propKey(c, p), p, add_opt, add_ro);
            }
            if (s.data != .union_) for (indexesOf(c, s)) |x| {
                addKey(c, t, m, &indexes, n, key_param, x.key, null, add_opt, add_ro or x.readonly);
            };
        } else o.open = true;
    } else {
        const keys: []const *Type = if (constraint.data == .union_) constraint.data.union_ else &.{constraint};
        for (keys) |key| {
            const name = literalName(c, key);
            const source = if (modifiers != null and name != null) getProp(c, modifiers.?, name.?) else null;
            addKey(c, t, m, &indexes, n, key_param, key, source, add_opt, add_ro);
        }
    }
    m.indexes = indexes.items;
    return m;
}

fn isKeyList(t: *Type) bool {
    return switch (t.data) {
        .str_lit, .num_lit, .string, .number => true,
        .union_ => |u| for (u) |x| {
            if (!isKeyList(x)) break false;
        } else true,
        else => false,
    };
}

fn mappedPropType(c: *Checker, owner: *Type, p: *Prop) *Type {
    const o = owner.data.obj;
    const n = o.node.?;
    const d = n.data.mapped_type;
    const kp = mappedParam(c, n);
    const m = compose(c, o.mapper, arrayMapper(c, c.dupe(*Type, &.{kp}), c.dupe(*Type, &.{p.mapped_key.?})));
    var t = if (d.type) |x| instantiate(c, typeFromNode(c, x), m) else c.t_any;
    if (p.mapped_required) t = relate.removeDefinitelyUndefined(c, t) else if (p.optional) t = addOptional(c, t);
    return t;
}

/// A mapped type whose keys are still generic has no properties yet, but it already says what
/// any key it accepts would hold. This is what gives `{ method: true }` its literal `true` when
/// the parameter is constrained to `{ [K in keyof T]?: true }` and `T` is not inferred yet.
pub fn genericMappedMember(c: *Checker, t: *Type, name: []const u8) ?*Type {
    if (t.data != .obj or t.data.obj.kind != .mapped) return null;
    const o = t.data.obj;
    const n = o.node orelse return null;
    const x = n.data.mapped_type;
    if (x.name_type != null) return null;
    const keys = instantiate(c, typeFromNode(c, x.constraint), o.mapper);
    if (!keys.vars) return null;
    const key = c.strLit(name);
    if (keys.data != .keyof) {
        const k = baseConstraint(c, keys);
        if (k.data != .keyof and !relate.isAssignable(c, key, k)) return null;
    }
    return mappedValueAt(c, t, key);
}

fn mappedValueAt(c: *Checker, t: *Type, key: *Type) *Type {
    const o = t.data.obj;
    const n = o.node.?;
    const x = n.data.mapped_type;
    const m = compose(c, o.mapper, arrayMapper(c, c.dupe(*Type, &.{mappedParam(c, n)}), c.dupe(*Type, &.{key})));
    const v = if (x.type) |y| instantiate(c, typeFromNode(c, y), m) else c.t_any;
    return if (x.question_mod == .question or x.question_mod == .plus) addOptional(c, v) else v;
}

/// What any key of a mapped type holds while its keys are generic.
pub fn genericMappedTemplate(c: *Checker, t: *Type) ?*Type {
    if (t.data != .obj or t.data.obj.kind != .mapped) return null;
    const o = t.data.obj;
    const x = (o.node orelse return null).data.mapped_type;
    if (x.name_type != null) return null;
    const keys = instantiate(c, typeFromNode(c, x.constraint), o.mapper);
    return if (keys.vars) mappedValueAt(c, t, keys) else null;
}

/// What the generic keys of a mapped type come from, known by its constraint alone.
pub fn genericMappedOrigin(c: *Checker, t: *Type) ?*Type {
    if (t.data != .obj or t.data.obj.kind != .mapped) return null;
    const o = t.data.obj;
    const n = o.node orelse return null;
    const keys = instantiate(c, typeFromNode(c, n.data.mapped_type.constraint), o.mapper);
    if (!keys.vars or keys.data != .keyof) return null;
    return genericMappedOrigin(c, keys.data.keyof) orelse getApparent(c, keys.data.keyof);
}

pub fn literalName(c: *Checker, t: *Type) ?[]const u8 {
    return switch (t.data) {
        .str_lit => |v| v,
        .num_lit => |v| numName(c, v),
        .unique => |s| c.fmt("__@{s}", .{s.name}),
        .enum_lit => |e| switch (e.value) {
            .str => |v| v,
            .num => |v| numName(c, v),
            .none => null,
        },
        else => null,
    };
}

pub fn numName(c: *Checker, v: f64) []const u8 {
    return numNameAlloc(c.a, v);
}

/// The one spelling of a numeric property name, shared with the binder so that declarations and
/// lookups agree on it.
pub fn numNameAlloc(a: Allocator, v: f64) []const u8 {
    if (@floor(v) == v and @abs(v) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(v))}) catch oom();
    return std.fmt.allocPrint(a, "{d}", .{v}) catch oom();
}

/// `{ '1': x }` has a string key and `{ 1: x }` a numeric one; the name alone cannot tell.
fn propKey(c: *Checker, p: *Prop) *Type {
    if (p.mapped_key) |k| return k;
    if (p.decl) |n| {
        const name: ?*Node = switch (n.data) {
            .property_decl => |x| x.name,
            .property_sig => |x| x.name,
            .property_assign => |x| x.name,
            .func => |x| x.name,
            else => null,
        };
        if (name) |x| switch (x.data) {
            .string_lit => return c.strLit(p.name),
            .computed_name => |e| {
                const k = expr.checkSilent(c, e.expr);
                if (k.data == .unique) return k;
            },
            else => {},
        };
    }
    return nameToKey(c, p.name);
}

pub fn nameToKey(c: *Checker, name: []const u8) *Type {
    if (std.mem.startsWith(u8, name, "__@")) return wellKnownSymbol(c, name[3..]);
    if (name.len > 0 and (name[0] >= '0' and name[0] <= '9') or (name.len > 1 and name[0] == '-')) {
        const v = std.fmt.parseFloat(f64, name) catch return c.strLit(name);
        if (std.mem.eql(u8, numName(c, v), name)) return c.numLit(v);
    }
    return c.strLit(name);
}

/// `Symbol.iterator` must stay a key of its own, or `keyof Set<string>` would lose it to `symbol`
/// and a mapped copy of a `Set` would no longer be iterable.
fn wellKnownSymbol(c: *Checker, name: []const u8) *Type {
    const ctor = globalType(c, "SymbolConstructor") orelse return c.t_symbol;
    const p = getProp(c, ctor, name) orelse return c.t_symbol;
    const t = propType(c, p);
    return if (t.data == .unique) t else c.t_symbol;
}

// ---- properties and signatures of arbitrary types ----

pub fn propsOf(c: *Checker, t: *Type) []const *Prop {
    switch (t.data) {
        .obj => return membersOf(c, t).props.values(),
        .inter => |x| {
            var seen: T.PropTable = .empty;
            for (x) |y| {
                const ap = getApparent(c, y);
                if (ap.data != .obj and ap.data != .inter) continue;
                for (propsOf(c, ap)) |p| {
                    const gop = seen.getOrPut(c.a, p.name) catch oom();
                    if (!gop.found_existing) gop.value_ptr.* = getProp(c, t, p.name) orelse p;
                }
            }
            return seen.values();
        },
        .union_ => |x| {
            var out = c.newList(*Prop);
            if (x.len == 0) return out.items;
            for (propsOf(c, getApparent(c, x[0]))) |p| {
                if (getProp(c, t, p.name)) |q| out.append(c.a, q) catch oom();
            }
            return out.items;
        },
        else => return &.{},
    }
}

fn objectProp(c: *Checker, t: *Type, name: []const u8) ?*Prop {
    const m = membersOf(c, t);
    if (m.props.get(name)) |p| return p;
    if (tupleProp(c, t, name)) |p| return p;
    if (m.calls.len > 0 or m.ctors.len > 0) {
        const strict_name: ?[]const u8 = if (!c.bind_call_apply) null else if (m.calls.len > 0) "CallableFunction" else if (m.ctors.len > 0) "NewableFunction" else null;
        if (strict_name) |sn| if (globalType(c, sn)) |f| if (f.data == .obj) if (membersOf(c, f).props.get(name)) |p| return p;
        if (globalType(c, "Function")) |f| if (f.data == .obj) if (membersOf(c, f).props.get(name)) |p| return p;
    }
    if (globalType(c, "Object")) |f| if (f.data == .obj) if (membersOf(c, f).props.get(name)) |p| return p;
    return null;
}

/// A tuple's elements are its properties `0`, `1`, ...
fn tupleProp(c: *Checker, t: *Type, name: []const u8) ?*Prop {
    if (!T.isTupleType(t) or name.len == 0 or !std.ascii.isDigit(name[0])) return null;
    const i = std.fmt.parseInt(usize, name, 10) catch return null;
    const o = t.data.obj;
    if (i >= o.elems.len) return null;
    for (o.eflags[0 .. i + 1]) |f| if (f == .rest or f == .variadic) return null;
    const optional = o.eflags[i] == .optional;
    return c.create(Prop, .{ .name = name, .ty = if (optional) addOptional(c, o.elems[i]) else o.elems[i], .optional = optional, .readonly = o.readonly });
}

/// Whether a tuple has no element at `i` and no open tail to hold one.
pub fn endsBefore(t: *Type, i: usize) bool {
    if (!T.isTupleType(t)) return false;
    for (t.data.obj.eflags) |f| if (f == .rest or f == .variadic) return false;
    return i >= t.data.obj.elems.len;
}

fn missingUnionMember(c: *Checker, ap: *Type, name: []const u8) ?*Type {
    if (ap.data != .obj) return null;
    const numeric = if (std.fmt.parseFloat(f64, name)) |_| true else |_| false;
    // A tuple does have a number index, but past its end it holds nothing.
    if (numeric) if (std.fmt.parseInt(usize, name, 10)) |i| {
        if (endsBefore(ap, i)) return c.t_undefined;
    } else |_| {};
    if (numeric) if (indexValue(c, ap, c.t_number)) |v| return v;
    if (indexValue(c, ap, c.t_string)) |v| return v;
    const o = ap.data.obj;
    return if ((o.lit or o.was_lit) and !o.spread) c.t_undefined else null;
}

/// `{ kind: "a" } & { kind: "b" }` holds no value. Asked on use and not when the intersection is
/// built, because the members of an object may still be in the making then.
pub fn isNeverReduced(c: *Checker, t: *Type) bool {
    if (t.data != .inter) return false;
    if (c.never_reduced.get(t)) |v| return v;
    c.never_reduced.put(c.a, t, false) catch oom();
    const v = hasConflictingLiteral(c, t.data.inter);
    if (v) c.never_reduced.put(c.a, t, true) catch oom();
    return v;
}

fn hasConflictingLiteral(c: *Checker, members: []*Type) bool {
    for (members, 0..) |m, i| {
        if (m.data != .obj) continue;
        for (propsOf(c, m)) |p| {
            var shared = false;
            for (members[i + 1 ..]) |o| {
                if (o.data != .obj) continue;
                const q = objectProp(c, o, p.name) orelse continue;
                shared = true;
                if ((p.private or q.private) and p.decl != q.decl) return true;
            }
            if (shared and relate.isDiscriminant(c, members, p.name) and conflicts(c, members, p.name)) return true;
        }
    }
    return false;
}

fn conflicts(c: *Checker, members: []*Type, name: []const u8) bool {
    var types = c.newList(*Type);
    for (members) |m| {
        if (m.data != .obj) continue;
        const p = objectProp(c, m, name) orelse continue;
        const t = propType(c, p);
        if (t.data == .never) return false;
        types.append(c.a, t) catch oom();
    }
    return c.getIntersection(types.items).data == .never;
}

pub fn getProp(c: *Checker, t0: *Type, name: []const u8) ?*Prop {
    const t = getApparent(c, t0);
    switch (t.data) {
        .obj => return objectProp(c, t, name),
        .union_ => |x| {
            var types = c.newList(*Type);
            var first: ?*Prop = null;
            var optional = false;
            var readonly = false;
            var private = false;
            var protected = false;
            for (x) |m| {
                const ap = getApparent(c, m);
                if (ap.data == .never or T.isAny(ap)) continue;
                const p = getProp(c, ap, name) orelse {
                    // Reading stays possible when a member could still hold the property.
                    const partial = missingUnionMember(c, ap, name) orelse return null;
                    types.append(c.a, partial) catch oom();
                    continue;
                };
                if (first == null) first = p;
                optional = optional or p.optional;
                readonly = readonly or p.readonly;
                private = private or p.private;
                protected = protected or p.protected;
                types.append(c.a, propType(c, p)) catch oom();
            }
            const p0 = first orelse return null;
            if (types.items.len == 1) return p0;
            return c.create(Prop, .{ .name = name, .sym = p0.sym, .ty = c.getUnion(types.items), .optional = optional, .readonly = readonly, .private = private, .protected = protected, .decl = p0.decl, .method = p0.method, .owner = p0.owner });
        },
        .inter => |x| {
            var types = c.newList(*Type);
            var first: ?*Prop = null;
            var optional = true;
            var readonly = true;
            for (x) |m| {
                const ap = getApparent(c, m);
                if (ap.data != .obj and ap.data != .union_ and ap.data != .inter) continue;
                const p = if (ap.data == .obj) (membersOf(c, ap).props.get(name) orelse tupleProp(c, ap, name)) else getProp(c, ap, name);
                const q = p orelse continue;
                if (first == null) first = q;
                optional = optional and q.optional;
                readonly = readonly and q.readonly;
                types.append(c.a, propType(c, q)) catch oom();
            }
            const p0 = first orelse {
                for (x) |m| {
                    const ap = getApparent(c, m);
                    if (ap.data == .obj) if (objectProp(c, ap, name)) |p| return p;
                }
                return null;
            };
            if (types.items.len == 1) return p0;
            return c.create(Prop, .{ .name = name, .sym = p0.sym, .ty = c.getIntersection(types.items), .optional = optional, .readonly = readonly, .decl = p0.decl, .method = p0.method, .owner = p0.owner, .private = p0.private, .protected = p0.protected });
        },
        else => return null,
    }
}

fn sigsOf(c: *Checker, t0: *Type, ctor: bool) []*Sig {
    const t = getApparent(c, t0);
    switch (t.data) {
        .obj => {
            const m = membersOf(c, t);
            return if (ctor) m.ctors else m.calls;
        },
        .inter => |x| {
            var out = c.newList(*Sig);
            for (x) |y| for (sigsOf(c, y, ctor)) |s| out.append(c.a, s) catch oom();
            return out.items;
        },
        .union_ => |x| {
            // Only identical overload sets survive a union; anything else needs tsc's signature merge.
            var first: ?[]*Sig = null;
            for (x) |y| {
                const s = sigsOf(c, y, ctor);
                if (s.len == 0) return &.{};
                if (first == null) first = s;
            }
            return unionSigs(c, x, ctor) orelse (if (ctor) null else arrayMemberSigs(c, x)) orelse (first orelse &.{});
        },
        else => return &.{},
    }
}

/// tsc: `(A[] | B[])["member"]` reads as `(A | B)[]["member"]`, because the overloads of two
/// instantiations never merge.
fn arrayMemberSigs(c: *Checker, x: []*Type) ?[]*Sig {
    const array = c.global_array orelse return null;
    const readonly_array = c.global_readonly_array orelse return null;
    var elems = c.newList(*Type);
    var name: ?[]const u8 = null;
    var readonly = false;
    for (x) |t| {
        if (t.data != .obj) return null;
        const s = t.data.obj.sym orelse return null;
        const owner = (s.parent orelse return null).resolve();
        const g = if (owner == array.data.obj.sym.?.resolve())
            array
        else if (owner == readonly_array.data.obj.sym.?.resolve())
            readonly_array
        else
            return null;
        if (name != null and !std.mem.eql(u8, name.?, s.name)) return null;
        name = s.name;
        readonly = readonly or g == readonly_array;
        elems.append(c.a, instantiate(c, g.data.obj.tparams[0], t.data.obj.mapper)) catch oom();
    }
    const e = c.getUnion(elems.items);
    const p = getProp(c, if (readonly) readonlyArrayOf(c, e) else arrayOf(c, e), name orelse return null) orelse return null;
    return sigsOf(c, propType(c, p), false);
}

fn unionSigs(c: *Checker, x: []*Type, ctor: bool) ?[]*Sig {
    var rets = c.newList(*Type);
    var best: ?*Sig = null;
    var tparams: []*Type = &.{};
    const sigs = c.a.alloc(*Sig, x.len) catch oom();
    for (x, sigs) |y, *out| {
        const l = sigsOf(c, y, ctor);
        if (l.len != 1) return null;
        var s = l[0];
        if (s.tparams.len > 0 and tparams.len == 0) {
            tparams = s.tparams;
        } else if (s.tparams.len > 0 and s.tparams.ptr != tparams.ptr) {
            if (!sameTParams(c, s.tparams, tparams)) return null;
            s = applySig(c, s, arrayMapper(c, s.tparams, tparams));
        }
        out.* = s;
        rets.append(c.a, returnOf(c, s)) catch oom();
        if (best == null or s.params.len > best.?.params.len) best = s;
    }
    const b = best orelse return null;
    const params = c.dupe(T.SigParam, b.params);
    for (params, 0..) |*p, i| {
        var parts = c.newList(*Type);
        for (sigs) |s| {
            if (i < s.params.len) parts.append(c.a, paramTypeAt(c, s, i)) catch oom();
        }
        p.ty = c.getIntersection(parts.items);
    }
    var min: u32 = 0;
    for (sigs) |s| min = @max(min, s.min_args);
    const q = c.create(Sig, .{ .tparams = tparams, .params = params, .ret = expr.reduceSubtypes(c, rets.items), .has_rest = b.has_rest, .min_args = min, .is_ctor = ctor, .composite = sigs });
    return c.dupe(*Sig, &.{q});
}

/// Every member has to guard the same thing; one that always answers `false` guards nothing and
/// is let through.
fn compositePred(c: *Checker, sigs: []*Sig) ?*T.Pred {
    var last: ?*T.Pred = null;
    var parts = c.newList(*Type);
    for (sigs) |s| {
        if (predOf(c, s)) |p| {
            if (p.asserts or last != null and (last.?.is_this != p.is_this or last.?.param_index != p.param_index)) return null;
            last = p;
            parts.append(c.a, p.ty orelse return null) catch oom();
        } else {
            const r = returnOf(c, s);
            if (r.data != .bool_lit or r.data.bool_lit) return null;
        }
    }
    const q = c.create(T.Pred, (last orelse return null).*);
    q.ty = c.getUnion(parts.items);
    return q;
}

fn sameTParams(c: *Checker, a: []*Type, b: []*Type) bool {
    if (a.len != b.len) return false;
    const m = arrayMapper(c, a, b);
    for (a, b) |x, y| {
        const p = constraintOf(c, x);
        const q = constraintOf(c, y);
        if ((p == null) != (q == null)) return false;
        if (p != null and !relate.isIdentical(c, instantiate(c, p.?, m), q.?)) return false;
    }
    return true;
}

pub fn callSigs(c: *Checker, t: *Type) []*Sig {
    return sigsOf(c, t, false);
}

pub fn ctorSigs(c: *Checker, t: *Type) []*Sig {
    return sigsOf(c, t, true);
}

pub fn indexesOf(c: *Checker, t0: *Type) []T.Index {
    const t = getApparent(c, t0);
    return switch (t.data) {
        .obj => membersOf(c, t).indexes,
        .inter => |x| blk: {
            var out = c.newList(T.Index);
            for (x) |y| for (indexesOf(c, y)) |i| {
                // The same key twice holds what both members say.
                for (out.items) |*o| {
                    if (o.key != i.key) continue;
                    o.ty = c.getIntersection(&.{ o.ty, i.ty });
                    o.readonly = o.readonly and i.readonly;
                    break;
                } else out.append(c.a, i) catch oom();
            };
            break :blk out.items;
        },
        .union_ => |x| blk: {
            // A union only indexes when every member does.
            if (x.len == 0) break :blk &.{};
            var out = c.newList(T.Index);
            for (indexesOf(c, x[0])) |first| {
                var parts = c.newList(*Type);
                var all = true;
                for (x) |y| {
                    const v = indexValue(c, y, first.key) orelse {
                        all = false;
                        break;
                    };
                    parts.append(c.a, v) catch oom();
                }
                if (all) out.append(c.a, .{ .key = first.key, .ty = c.getUnion(parts.items) }) catch oom();
            }
            break :blk out.items;
        },
        else => &.{},
    };
}

pub fn indexValue(c: *Checker, t: *Type, key: *Type) ?*Type {
    const list = indexesOf(c, t);
    for (list) |i| if (i.key == key) return i.ty;
    if (key.data == .number or key.data == .num_lit) {
        for (list) |i| if (i.key.data == .number) return i.ty;
    }
    if (key.data == .number or key.data == .num_lit or key.data == .string or key.data == .str_lit or key.data == .tmpl or key.data == .strmap) {
        for (list) |i| if (i.key == c.t_string) return i.ty;
    }
    if (key.data == .symbol or key.data == .unique) {
        for (list) |i| if (i.key == c.t_symbol) return i.ty;
    }
    for (list) |i| if (i.key.data == .tmpl and relate.isAssignable(c, key, i.key)) return i.ty;
    return null;
}

pub fn baseConstraint(c: *Checker, t: *Type) *Type {
    return baseConstraintDepth(c, t, 0);
}

fn baseConstraintDepth(c: *Checker, t: *Type, depth: u32) *Type {
    if (depth > 24) return c.t_err;
    switch (t.data) {
        .param => {
            const k = constraintOf(c, t) orelse return c.t_unknown;
            return baseConstraintDepth(c, k, depth + 1);
        },
        .keyof => return c.t_key,
        .tmpl, .strmap => return c.t_string,
        .noinfer => |x| return baseConstraintDepth(c, x, depth + 1),
        .access => |x| {
            if (mappedAccess(c, x.obj, x.index)) |r| return baseConstraintDepth(c, r, depth + 1);
            const o = baseConstraintDepth(c, x.obj, depth + 1);
            const i = baseConstraintDepth(c, x.index, depth + 1);
            if (o.data == .unknown or i.data == .unknown) return c.t_unknown;
            if (o.vars or i.vars) return c.t_unknown;
            const r = getIndexedAccess(c, o, i);
            // `keyof T` may be any key at all, and only an index answers for every one of them.
            return if (i == c.t_key and indexValue(c, o, c.t_string) == null) c.t_unknown else r;
        },
        .cond => |x| {
            if (distributiveConstraint(c, x, depth)) |k| return baseConstraintDepth(c, k, depth + 1);
            const u = defaultCondConstraint(c, x);
            return if (u.vars and u.data != .union_) baseConstraintDepth(c, u, depth + 1) else if (u.vars) c.t_err else u;
        },
        .union_ => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = baseConstraintDepth(c, y, depth + 1);
            return c.getUnion(out);
        },
        .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = baseConstraintDepth(c, y, depth + 1);
            return c.getIntersection(out);
        },
        else => return t,
    }
}

pub fn condDistributive(c: *Checker, x: *T.Cond) ?*Type {
    return distributiveConstraint(c, x, 0);
}

/// What either branch can give. Without this elision one `any` branch would make the conditional
/// assignable to everything.
pub fn defaultCondConstraint(c: *Checker, x: *T.Cond) *Type {
    if (x.default_constraint) |t| return t;
    const then = inferredThen(c, x);
    const els = instantiate(c, condEls(c, x), x.mapper);
    const t = if (T.isAny(then)) els else if (T.isAny(els)) then else c.getUnion(&.{ then, els });
    x.default_constraint = t;
    return t;
}

/// An `infer` left without a candidate reads `unknown` here, which is how `Awaited<T>` stays
/// assignable to `T`: its thenable branch ends up `never`.
fn inferredThen(c: *Checker, x: *T.Cond) *Type {
    if (x.infer_params.len == 0) return instantiate(c, condThen(c, x), x.mapper);
    const check = instantiate(c, x.check, x.mapper);
    const ctx = relate.newInferCtx(c, x.infer_params, 0);
    ctx.conditional = true;
    if (!isGeneric(c, check) and !hasGenericTuple(c, check)) relate.inferTypes(c, ctx, check, instantiate(c, x.extends, x.mapper), 0);
    return instantiate(c, condThen(c, x), compose(c, x.mapper, ctx.mapper));
}

/// `Lead<ConstructorParameters<C>>`: a distributive conditional over something constrained answers
/// for that constraint, which often settles it where the two branches together would not.
fn distributiveConstraint(c: *Checker, x: *T.Cond, depth: u32) ?*Type {
    if (!x.distributive or std.mem.indexOfScalar(*Type, x.outer, x.check) == null) return null;
    const check = if (x.mapper) |m| mapType(c, m, x.check) else x.check;
    const k = baseConstraintDepth(c, check, depth + 1);
    if (k == check or k.data == .unknown or T.isAny(k)) return null;
    var small: [small_list]*Type = undefined;
    const vals = smallList(c, &small, x.outer.len);
    for (x.outer, 0..) |p, i| vals[i] = if (p == x.check) k else if (x.mapper) |m| mapType(c, m, p) else p;
    const key = c.keyOf('D', vals.len + 1);
    key[1] = @truncate(@intFromPtr(x.node) >> 3);
    for (vals, 2..) |v, i| key[i] = v.id;
    const r = c.interned.get(key) orelse blk: {
        const owned = c.a.dupe(u32, key) catch oom();
        // Resolving may ask for this same constraint, and `never` means "there is none".
        c.interned.put(c.a, owned, c.t_never) catch oom();
        const fresh = condInstance(c, x, c.dupe(*Type, vals), true);
        c.interned.put(c.a, owned, fresh) catch oom();
        break :blk fresh;
    };
    return if (r.data == .never) null else r;
}

/// A generic mapped type resolves no keys, but its template already says what `M[K]` holds.
fn mappedAccess(c: *Checker, obj: *Type, idx: *Type) ?*Type {
    if (obj.data != .obj or obj.data.obj.kind != .mapped) return null;
    const o = obj.data.obj;
    const n = o.node orelse return null;
    const x = n.data.mapped_type;
    if (x.name_type != null) return null;
    const tpl = x.type orelse return null;
    const m = compose(c, o.mapper, arrayMapper(c, c.dupe(*Type, &.{mappedParam(c, n)}), c.dupe(*Type, &.{idx})));
    const t = instantiate(c, typeFromNode(c, tpl), m);
    if (x.question_mod == .minus) return relate.removeDefinitelyUndefined(c, t);
    return if (x.question_mod == .question or x.question_mod == .plus) addOptional(c, t) else t;
}

pub fn getApparent(c: *Checker, t: *Type) *Type {
    if (isNeverReduced(c, t)) return c.t_never;
    switch (t.data) {
        .obj => return t,
        .param => |p| {
            if (p.is_this) return withThis(c, baseConstraint(c, t), t);
            const k = baseConstraint(c, t);
            return if (k.data == .unknown or k == t) c.t_empty else getApparent(c, k);
        },
        .access, .cond, .keyof, .tmpl, .strmap, .noinfer => {
            const k = baseConstraint(c, t);
            return if (k == t or k.data == .unknown) c.t_empty else getApparent(c, k);
        },
        .string, .str_lit => return globalType(c, "String") orelse c.t_err,
        .number, .num_lit, .enum_ => return globalType(c, "Number") orelse c.t_err,
        // Older libs have no `BigInt`, or no `Symbol`, and such a value simply has no members.
        .bigint, .big_lit => return globalType(c, "BigInt") orelse c.t_empty,
        .bool_lit => return globalType(c, "Boolean") orelse c.t_err,
        .symbol, .unique => return globalType(c, "Symbol") orelse c.t_empty,
        .enum_lit => |e| return switch (e.value) {
            .str => globalType(c, "String") orelse c.t_err,
            else => globalType(c, "Number") orelse c.t_err,
        },
        .nonprim => return c.t_empty,
        .inter => |x| {
            var changed = false;
            for (x) |y| if (y.data != .obj) {
                changed = true;
            };
            if (!changed) return t;
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = if (y.data == .param or y.data == .access) getApparent(c, y) else y;
            if (std.mem.eql(*Type, out, x)) return t;
            // `T & string` may reduce to a plain `string`, which still needs its wrapper.
            const r = c.getIntersection(out);
            return if (r.data == .inter) r else getApparent(c, r);
        },
        .union_ => |x| {
            const reduced = for (x) |y| {
                if (isNeverReduced(c, y)) break true;
            } else false;
            if (!reduced) return t;
            var kept = c.newList(*Type);
            for (x) |y| if (!isNeverReduced(c, y)) kept.append(c.a, y) catch oom();
            return c.getUnion(kept.items);
        },
        else => return t,
    }
}

pub fn isGeneric(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .param, .access, .cond, .keyof, .strmap, .noinfer => true,
        .tmpl => t.vars,
        .obj => |o| o.kind == .mapped and t.vars,
        .union_, .inter => |x| for (x) |y| {
            if (isGeneric(c, y)) break true;
        } else false,
        else => false,
    };
}

/// Inside a class every member type mentions `this`, which does not make the keys any less known.
pub fn mappedKeysGeneric(c: *Checker, t: *Type) bool {
    const o = t.data.obj;
    const n = o.node orelse return true;
    const x = n.data.mapped_type;
    return x.name_type != null or instantiate(c, typeFromNode(c, x.constraint), o.mapper).vars;
}

// ---- keyof / indexed access ----

pub fn getIndexType(c: *Checker, t: *Type) *Type {
    switch (t.data) {
        .union_ => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = getIndexType(c, y);
            return c.getIntersection(out);
        },
        .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = getIndexType(c, y);
            return c.getUnion(out);
        },
        .any, .err => return c.t_key,
        .unknown, .never => return if (t.data == .never) c.t_key else c.t_never,
        else => {},
    }
    if (t.data == .obj and t.data.obj.kind == .mapped) {
        const d = t.data.obj.node.?.data.mapped_type;
        if (d.name_type == null) return instantiate(c, typeFromNode(c, d.constraint), t.data.obj.mapper);
    }
    if (isGeneric(c, t)) {
        if (c.keyof_cache.get(t)) |x| return x;
        const k = c.mk(.{ .keyof = t });
        k.vars = true;
        c.keyof_cache.put(c.a, t, k) catch oom();
        return k;
    }
    const ap = getApparent(c, t);
    if (ap.data != .obj and ap.data != .inter) return c.t_never;
    var parts = c.newList(*Type);
    for (propsOf(c, ap)) |p| {
        if (p.private or p.protected) continue;
        parts.append(c.a, propKey(c, p)) catch oom();
    }
    for (indexesOf(c, ap)) |i| {
        parts.append(c.a, i.key) catch oom();
        if (i.key == c.t_string) parts.append(c.a, c.t_number) catch oom();
    }
    return c.getUnion(parts.items);
}

pub fn getIndexedAccess(c: *Checker, obj: *Type, idx: *Type) *Type {
    if (T.isAny(obj)) return obj;
    if (obj.data == .never or idx.data == .never) return c.t_never;
    if (isGeneric(c, idx) or isGeneric(c, obj)) {
        if (!(isGeneric(c, idx)) and obj.data == .obj) return concreteAccess(c, obj, idx);
        const key = c.keyOf('x', 2);
        key[1] = obj.id;
        key[2] = idx.id;
        const gop = c.slot(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const t = c.mk(.{ .access = .{ .obj = obj, .index = idx } });
        t.vars = true;
        gop.value_ptr.* = t;
        return t;
    }
    if (idx.data == .union_) {
        const x = idx.data.union_;
        const out = c.a.alloc(*Type, x.len) catch oom();
        for (x, 0..) |y, i| out[i] = getIndexedAccess(c, obj, y);
        return c.getUnion(out);
    }
    return concreteAccess(c, obj, idx);
}

fn concreteAccess(c: *Checker, obj: *Type, idx: *Type) *Type {
    if (obj.data == .union_) {
        const x = obj.data.union_;
        const out = c.a.alloc(*Type, x.len) catch oom();
        for (x, 0..) |y, i| out[i] = concreteAccess(c, y, idx);
        return c.getUnion(out);
    }
    const ap = getApparent(c, obj);
    if (literalName(c, idx)) |name| {
        if (getProp(c, ap, name)) |p| return propType(c, p);
        if (T.isTupleType(ap) and idx.data == .num_lit) return tupleElemAt(c, ap, idx.data.num_lit);
    }
    if (T.isTupleType(ap) and idx.data == .number) return c.getUnion(ap.data.obj.elems);
    if (indexValue(c, ap, idx)) |v| return v;
    return c.t_err;
}

pub fn tupleElemAt(c: *Checker, t: *Type, i: f64) *Type {
    const o = t.data.obj;
    for (o.elems, o.eflags, 0..) |e, f, n| {
        if (f == .rest or f == .variadic) return c.getUnion(o.elems[n..]);
        if (@as(f64, @floatFromInt(n)) == i) return e;
    }
    return c.t_undefined;
}

// ---- conditional types ----

fn condFromNode(c: *Checker, n: *Node) *Type {
    const d = n.data.conditional_type;
    const check = typeFromNode(c, d.check);
    const extends = typeFromNode(c, d.extends);
    var infers = c.newList(*Type);
    if (n.locals) |l| {
        var it = l.map.valueIterator();
        while (it.next()) |s| infers.append(c.a, tparamOf(c, s.*)) catch oom();
    }
    const cond = c.create(T.Cond, .{
        .node = n,
        .check = check,
        .extends = extends,
        .branches = c.create(T.CondBranches, .{}),
        .distributive = check.data == .param,
        .infer_params = infers.items,
        .outer = outerTParams(c, n),
    });
    return condResolve(c, cond, null, false);
}

pub fn condThen(c: *Checker, x: *T.Cond) *Type {
    if (x.branches.then) |t| return t;
    const t = typeFromNode(c, x.node.data.conditional_type.then);
    x.branches.then = t;
    return t;
}

pub fn condEls(c: *Checker, x: *T.Cond) *Type {
    if (x.branches.els) |t| return t;
    const t = typeFromNode(c, x.node.data.conditional_type.els);
    x.branches.els = t;
    return t;
}

fn deferredCond(c: *Checker, root: *T.Cond, mapper: ?*Mapper) *Type {
    var small: [small_list]*Type = undefined;
    const vals = smallList(c, &small, root.outer.len);
    for (root.outer, 0..) |p, i| vals[i] = if (mapper) |m| mapType(c, m, p) else p;
    const key = c.keyOf('c', vals.len + 1);
    key[1] = @truncate(@intFromPtr(root.node) >> 3);
    for (vals, 2..) |v, i| key[i] = v.id;
    const gop = c.slot(key);
    if (gop.found_existing) return gop.value_ptr.*;
    const copy = c.create(T.Cond, root.*);
    copy.mapper = mapper;
    copy.then_inst = null;
    copy.els_inst = null;
    copy.default_constraint = null;
    const t = c.mk(.{ .cond = copy });
    t.vars = true;
    gop.value_ptr.* = t;
    return t;
}

fn condResolve(c: *Checker, root: *T.Cond, mapper: ?*Mapper, for_constraint: bool) *Type {
    if (c.cond_depth > 120) return c.t_err;
    c.cond_depth += 1;
    defer c.cond_depth -= 1;
    const check = instantiate(c, root.check, mapper);
    const extends = instantiate(c, root.extends, mapper);
    if (check == c.t_err or extends == c.t_err) return c.t_err;
    const check_deferred = isGeneric(c, check) or hasGenericTuple(c, check);
    var combined = mapper;
    if (root.infer_params.len > 0) {
        const ctx = relate.newInferCtx(c, root.infer_params, 0);
        ctx.conditional = true;
        if (!check_deferred) relate.inferTypes(c, ctx, check, extends, 0);
        combined = compose(c, mapper, ctx.mapper);
    }
    const inferred_ext = if (root.infer_params.len > 0) instantiate(c, root.extends, combined) else extends;
    if (check_deferred or isGeneric(c, inferred_ext)) return deferredCond(c, root, mapper);
    if (check.data == .any or check == c.t_unresolved) {
        return c.getUnion(&.{ instantiate(c, condThen(c, root), combined), instantiate(c, condEls(c, root), mapper) });
    }
    if (!relate.isAssignable(c, relate.permissive(c, check), relate.permissive(c, inferred_ext))) {
        const els = instantiate(c, condEls(c, root), mapper);
        // `check` is only the upper bound here, so what the extends type admits may still occur.
        if (!for_constraint or inferred_ext.data == .never or !someAssignable(c, relate.permissive(c, inferred_ext), relate.permissive(c, check))) return els;
        return c.getUnion(&.{ instantiate(c, condThen(c, root), combined), els });
    }
    if (relate.isAssignable(c, relate.restrictive(c, check), relate.restrictive(c, inferred_ext))) {
        return instantiate(c, condThen(c, root), combined);
    }
    return deferredCond(c, root, mapper);
}

fn someAssignable(c: *Checker, t: *Type, target: *Type) bool {
    if (t.data != .union_) return relate.isAssignable(c, t, target);
    for (t.data.union_) |x| if (relate.isAssignable(c, x, target)) return true;
    return false;
}

fn hasGenericTuple(c: *Checker, t: *Type) bool {
    if (!T.isTupleType(t)) return false;
    for (t.data.obj.elems, t.data.obj.eflags) |e, f| if (f == .variadic and isGeneric(c, e)) return true;
    return false;
}

fn instCond(c: *Checker, t: *Type, m: *Mapper) *Type {
    const root = t.data.cond;
    const combined = compose(c, root.mapper, m).?;
    // Keyed on what the outer parameters became, and resolved under a flat mapper: composing
    // mappers instead grows them with every nesting level and is exponential on real code.
    var small: [small_list]*Type = undefined;
    const vals = smallList(c, &small, root.outer.len);
    for (root.outer, 0..) |p, i| vals[i] = mapType(c, combined, p);
    const key = c.keyOf('C', vals.len + 1);
    key[1] = @truncate(@intFromPtr(root.node) >> 3);
    for (vals, 2..) |v, i| key[i] = v.id;
    if (c.interned.get(key)) |r| return r;
    const owned = c.a.dupe(u32, key) catch oom();
    const r = condInstance(c, root, c.dupe(*Type, vals), false);
    c.interned.put(c.a, owned, r) catch oom();
    return r;
}

fn condInstance(c: *Checker, root: *T.Cond, vals: []*Type, for_constraint: bool) *Type {
    const flat = arrayMapper(c, root.outer, vals);
    if (!root.distributive) return condResolve(c, root, flat, for_constraint);
    const p = root.check;
    const mapped = mapType(c, flat, p);
    if (mapped == p) return condResolve(c, root, flat, for_constraint);
    if (mapped.data == .never) return c.t_never;
    if (mapped.data != .union_) return condResolve(c, root, flat, for_constraint);
    const x = mapped.data.union_;
    const out = c.a.alloc(*Type, x.len) catch oom();
    for (x, 0..) |y, i| {
        const one = c.dupe(*Type, vals);
        for (root.outer, 0..) |q, k| if (q == p) {
            one[k] = y;
        };
        out[i] = condResolve(c, root, arrayMapper(c, root.outer, one), for_constraint);
    }
    return c.getUnion(out);
}

// ---- template literal types ----

const max_template_text = 1 << 20;
const max_template_spans = 1 << 12;

fn literalText(c: *Checker, t: *Type) ?[]const u8 {
    return switch (t.data) {
        .str_lit => |v| v,
        .num_lit => |v| numName(c, v),
        .big_lit => |v| v,
        .bool_lit => |v| if (v) "true" else "false",
        .null => "null",
        .undefined => "undefined",
        .enum_lit => |e| switch (e.value) {
            .str => |v| v,
            .num => |v| numName(c, v),
            .none => null,
        },
        else => null,
    };
}

pub fn getTemplate(c: *Checker, texts: []const []const u8, types: []const *Type) *Type {
    var size: f64 = 1;
    for (types) |t| {
        if (t.data == .never) return c.t_never;
        if (t.data == .union_) size *= @floatFromInt(t.data.union_.len);
    }
    if (size >= 100_000) {
        reportLimit(c, 2590, "Expression produces a union type that is too complex to represent.");
        return c.t_err;
    }
    for (types, 0..) |t, i| {
        if (t.data == .union_) {
            var out = c.newList(*Type);
            for (t.data.union_) |m| {
                const copy = c.dupe(*Type, types);
                copy[i] = m;
                out.append(c.a, getTemplate(c, texts, copy)) catch oom();
            }
            return c.getUnion(out.items);
        }
    }
    var ntexts = c.newList([]const u8);
    var ntypes = c.newList(*Type);
    var cur = c.newList(u8);
    cur.appendSlice(c.a, texts[0]) catch oom();
    for (types, 0..) |t, i| {
        if (T.isAny(t)) return c.t_string;
        if (literalText(c, t)) |v| {
            cur.appendSlice(c.a, v) catch oom();
        } else if (t.data == .tmpl) {
            const x = t.data.tmpl;
            cur.appendSlice(c.a, x.texts[0]) catch oom();
            for (x.types, 0..) |y, j| {
                ntexts.append(c.a, cur.items) catch oom();
                ntypes.append(c.a, y) catch oom();
                cur = .empty;
                cur.appendSlice(c.a, x.texts[j + 1]) catch oom();
            }
        } else {
            ntexts.append(c.a, cur.items) catch oom();
            ntypes.append(c.a, t) catch oom();
            cur = .empty;
        }
        cur.appendSlice(c.a, texts[i + 1]) catch oom();
        // A recursive alias can double the text on every step, far past anything memory holds.
        if (cur.items.len > max_template_text or ntypes.items.len > max_template_spans) {
            reportLimit(c, 2589, "Type instantiation is excessively deep and possibly infinite.");
            return c.t_err;
        }
    }
    ntexts.append(c.a, cur.items) catch oom();
    if (ntypes.items.len == 0) return c.strLit(ntexts.items[0]);
    if (ntypes.items.len == 1 and ntexts.items[0].len == 0 and ntexts.items[1].len == 0 and ntypes.items[0].data == .string) return c.t_string;
    // Text pieces join the key as interned string literals, which also keeps it fixed width.
    const pieces = c.a.alloc(u32, ntexts.items.len) catch oom();
    for (ntexts.items, 0..) |x, i| pieces[i] = c.strLit(x).id;
    const key = c.keyOf('T', ntypes.items.len + pieces.len);
    for (ntypes.items, 1..) |t, i| key[i] = t.id;
    @memcpy(key[1 + ntypes.items.len ..], pieces);
    const gop = c.slot(key);
    if (gop.found_existing) return gop.value_ptr.*;
    const t = c.mk(.{ .tmpl = c.create(T.Tmpl, .{ .texts = ntexts.items, .types = ntypes.items }) });
    for (ntypes.items) |x| if (x.vars) {
        t.vars = true;
    };
    gop.value_ptr.* = t;
    return t;
}

pub fn getStringMapping(c: *Checker, kind: T.StrMapKind, t: *Type) *Type {
    switch (t.data) {
        .str_lit => |v| {
            const out = c.a.dupe(u8, v) catch oom();
            switch (kind) {
                .upper => _ = std.ascii.upperString(out, v),
                .lower => _ = std.ascii.lowerString(out, v),
                .capitalize => if (out.len > 0) {
                    out[0] = std.ascii.toUpper(out[0]);
                },
                .uncapitalize => if (out.len > 0) {
                    out[0] = std.ascii.toLower(out[0]);
                },
            }
            return c.strLit(out);
        },
        .union_ => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = getStringMapping(c, kind, y);
            return c.getUnion(out);
        },
        .string, .any, .err => return t,
        else => {},
    }
    if (!t.vars) return c.t_string;
    const key = c.keyOf('s', 2);
    key[1] = t.id;
    key[2] = @intFromEnum(kind);
    const gop = c.slot(key);
    if (gop.found_existing) return gop.value_ptr.*;
    const r = c.mk(.{ .strmap = .{ .kind = kind, .ty = t } });
    r.vars = true;
    gop.value_ptr.* = r;
    return r;
}

test "numeric property names normalize like tsc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1", numNameAlloc(a, 1.0));
    try std.testing.expectEqualStrings("16", numNameAlloc(a, 16));
    try std.testing.expectEqualStrings("1.5", numNameAlloc(a, 1.5));
    try std.testing.expectEqualStrings("-2", numNameAlloc(a, -2));
}
