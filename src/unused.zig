//! tsc's `noUnusedLocals` and `noUnusedParameters`: declarations that nothing reads. Name lookup
//! records what each symbol is read as; once a file is checked, every scope in it is gone over.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Checker = T.Checker;
const oom = T.oom;

fn tracking(c: *const Checker) bool {
    return c.no_unused_locals or c.no_unused_params;
}

/// A declaration whose own name, met inside it, is no use of it: `function f() { f(); }`.
pub fn isSelfReference(n: *Node, last: ?*Node) bool {
    return switch (n.data) {
        .param => |p| last == p.name,
        .func => |f| f.kind == .decl,
        .class => |x| !x.is_expr,
        .interface, .enum_decl, .type_alias, .module_decl => true,
        else => false,
    };
}

/// Records that `from` reads `s`, and hands `s` back.
pub fn noteUse(c: *Checker, from: *Node, s: *Symbol, self: ?*Node, meaning: u32) *Symbol {
    if (!tracking(c)) return s;
    if (self) |x| if (x.symbol()) |own| if (own.resolve() == s.resolve()) return s;
    if (isWriteOnly(from)) return s;
    const gop = c.referenced.getOrPut(c.a, s.resolve()) catch oom();
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* |= meaning;
    return s;
}

fn readAs(c: *const Checker, s: *Symbol) u32 {
    return c.referenced.get(s.resolve()) orelse 0;
}

/// Records that `at` reads the member `p`, which only matters for a private one.
pub fn noteProperty(c: *Checker, at: *Node, p: *const T.Prop) void {
    if (!c.no_unused_locals) return;
    const decl = p.decl orelse return;
    if (!p.private and !isPrivateName(decl)) return;
    const s = (if (p.origin) |o| o.sym else p.sym) orelse decl.symbol() orelse return;
    if (isWriteOnly(at) and s.flags & F.setter == 0) return;
    // A method calling itself through `this` is no use of it.
    if (at.data == .prop_access and at.data.prop_access.expr.data == .this_expr) {
        var cur = at.parent;
        while (cur) |x| : (cur = x.parent) if (x.data == .func) {
            if (x == decl) return;
            break;
        };
    }
    const gop = c.referenced.getOrPut(c.a, s.resolve()) catch oom();
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* |= F.property;
}

fn memberName(n: *Node) ?*Node {
    return switch (n.data) {
        .property_decl => |x| x.name,
        .func => |x| x.name,
        else => null,
    };
}

fn isPrivateName(decl: *Node) bool {
    const name = memberName(decl) orelse return false;
    return name.data == .private_name;
}

fn checkClassMembers(c: *Checker, members: []*Node) void {
    if (!c.no_unused_locals) return;
    for (members) |m| {
        if (m.mods.declare) continue;
        switch (m.data) {
            .property_decl => {},
            .func => |f| switch (f.kind) {
                .method, .getter => {},
                // The getter speaks for the pair.
                .setter => if (m.symbol()) |s| if (s.resolve().flags & F.getter != 0) continue,
                .ctor => {
                    for (f.params) |param| {
                        if (!param.mods.private) continue;
                        const name = param.data.param.name;
                        if (propertyOfParam(m, name)) |s| if (readAs(c, s) != 0) continue;
                        d.report(c, name, 6138, c.fmt("Property '{s}' is declared but its value is never read.", .{ast.memberText(name)}));
                    }
                    continue;
                },
                else => continue,
            },
            else => continue,
        }
        if (!m.mods.private and !isPrivateName(m)) continue;
        if (memberRead(c, m)) continue;
        const name = memberName(m) orelse continue;
        d.report(c, name, 6133, c.fmt("'{s}' is declared but its value is never read.", .{ast.memberText(name)}));
    }
}

/// A parameter property declares a local and a member; reads go through the member.
fn propertyOfParam(ctor: *Node, name: *Node) ?*Symbol {
    const cls = ctor.parent orelse return null;
    const s = cls.symbol() orelse return null;
    const members = s.resolve().members orelse return null;
    return members.get(ast.memberText(name));
}

/// A member's symbol is the class's member, not the one its declaration binds in a scope.
fn memberRead(c: *const Checker, decl: *Node) bool {
    const s = decl.symbol() orelse return true;
    return readAs(c, s) != 0;
}

/// tsc's `accessKind(n) == Write`. tsc's `x++;` and `x += 1;` are writes too, but checking the
/// arithmetic resolves `x` again as a use, so only plain assignment is left write-only.
fn isWriteOnly(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .paren => isWriteOnly(p),
        .binary => |x| x.left == n and x.op == .assign,
        .prop_access => |x| x.name == n and isWriteOnly(p),
        .property_assign => |x| x.value == n and isWriteOnly(p.parent.?),
        .shorthand_assign => |x| x.init != n and isWriteOnly(p.parent.?),
        .array_lit => isWriteOnly(p),
        .for_in => |x| x.init == n,
        .for_of => |x| x.init == n,
        else => false,
    };
}

pub fn checkFile(c: *Checker, f: *ast.File) void {
    if (!tracking(c) or f.is_dts) return;
    markJsxFactories(c, f.root);
    markLinkedNames(c, f);
    walk(c, f.root, f.is_module);
}

/// Classic JSX calls its factory, so a tag reads the name the factory starts with. A tag that
/// is not an intrinsic element reads its own name as well.
fn markJsxFactories(c: *Checker, n: *Node) void {
    switch (n.data) {
        .jsx_opening => |x| markTag(c, x.tag),
        .jsx_self_closing => |x| markTag(c, x.tag),
        else => {},
    }
    switch (n.data) {
        .jsx_element, .jsx_self_closing, .jsx_fragment => {
            const o = c.prog.cfg.options;
            switch (o.jsxMode()) {
                .react_jsx, .react_jsxdev => return,
                else => {},
            }
            markRoot(c, n, if (o.jsxFactory) |x| x else o.reactNamespace orelse "React");
            if (n.data == .jsx_fragment) if (o.jsxFragmentFactory) |x| markRoot(c, n, x);
        },
        else => {},
    }
    ast.forEachChild(n, c, markJsxFactories);
}

fn markTag(c: *Checker, tag: *Node) void {
    var root = tag;
    while (root.data == .prop_access) root = root.data.prop_access.expr;
    if (root.data != .identifier) return;
    const name = root.data.identifier;
    // Lower-case names are intrinsic elements, which are looked up in `JSX.IntrinsicElements`.
    if (root == tag and (name.len == 0 or std.ascii.isLower(name[0]) or std.mem.indexOfScalar(u8, name, '-') != null)) return;
    _ = d.resolveName(c, root, name, F.value);
}

fn markRoot(c: *Checker, at: *Node, entity: []const u8) void {
    const end = std.mem.indexOfScalar(u8, entity, '.') orelse entity.len;
    _ = d.resolveName(c, at, entity[0..end], F.value);
}

/// tsc resolves the names in `{@link x}` as uses. JSDoc in TypeScript is not parsed here, so
/// the comments are read for them; a name a link reaches counts for the file's top level.
fn markLinkedNames(c: *Checker, f: *ast.File) void {
    const src = f.src;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "/**")) |open| {
        const close = std.mem.indexOfPos(u8, src, open + 3, "*/") orelse src.len;
        const doc = src[open..close];
        at = close;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, doc, i, "{@link")) |tag| {
            i = tag + "{@link".len;
            while (i < doc.len and std.ascii.isAlphabetic(doc[i])) i += 1;
            while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t')) i += 1;
            const start = i;
            while (i < doc.len and (std.ascii.isAlphanumeric(doc[i]) or doc[i] == '_' or doc[i] == '$')) i += 1;
            if (i > start) _ = d.resolveName(c, f.root, doc[start..i], F.value | F.type | F.namespace | F.alias);
        }
    }
}

fn walk(c: *Checker, n: *Node, is_module: bool) void {
    // Ambient declarations have no bodies to read anything in.
    if (n.mods.declare) return;
    switch (n.data) {
        .source_file => if (is_module) checkLocals(c, n),
        .func => |f| {
            if (f.body != null) checkLocals(c, n);
            checkTypeParams(c, n, f.type_params);
            if (f.body) |b| if (b.data == .lazy_body) {
                for (f.params) |p| walk(c, p, is_module);
                if (d.bodyOf(c, n)) |body| walk(c, body.block, is_module);
                return;
            };
        },
        .class => |x| {
            checkClassMembers(c, x.members);
            checkTypeParams(c, n, x.type_params);
        },
        .interface => |x| checkTypeParams(c, n, x.type_params),
        .type_alias => |x| checkTypeParams(c, n, x.type_params),
        .infer_type => |x| if (c.no_unused_params and unreadTypeParam(c, x.tparam)) {
            const name = x.tparam.data.type_param.name;
            d.report(c, name, 6196, c.fmt("'{s}' is declared but never used.", .{name.data.identifier}));
        },
        .catch_clause => {},
        else => if (n.locals() != null) checkLocals(c, n),
    }
    const Walk = struct {
        c: *Checker,
        is_module: bool,
        fn visit(w: *const @This(), child: *Node) void {
            walk(w.c, child, w.is_module);
        }
    };
    ast.forEachChild(n, &Walk{ .c = c, .is_module = is_module }, Walk.visit);
}

fn checkLocals(c: *Checker, scope: *Node) void {
    const locals = d.localsOf(c, scope) orelse return;
    var lists = std.AutoArrayHashMapUnmanaged(*Node, void).empty;
    var imports = std.AutoArrayHashMapUnmanaged(*Node, std.ArrayList(*Node)).empty;
    var it = locals.map.keyIterator();
    while (it.next()) |key| {
        const s = key.*.resolve();
        if (s.flags & F.type_param != 0) continue;
        if (readAs(c, s) != 0 or isExported(s)) continue;
        for (s.decls) |decl| {
            if (!declaredIn(decl, scope)) continue;
            switch (decl.data) {
                .var_decl, .param, .binding_elem => {
                    const root = rootDeclaration(decl);
                    if (root.parent) |list| lists.put(c.a, list, {}) catch oom();
                },
                .import_clause, .namespace_import, .import_spec => {
                    if (startsWithUnderscore(nameOf(decl))) continue;
                    const clause = importClauseOf(decl) orelse continue;
                    const gop = imports.getOrPut(c.a, clause) catch oom();
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    gop.value_ptr.append(c.a, decl) catch oom();
                },
                .type_param => {},
                .module_decl => |m| if (m.name.data == .identifier) reportLocal(c, decl),
                // An expression's own name is bound to it, not to the scope around it.
                .func => |x| if (x.kind != .expr) reportLocal(c, decl),
                .class => |x| if (!x.is_expr) reportLocal(c, decl),
                .interface, .type_alias, .enum_decl, .import_equals => reportLocal(c, decl),
                else => {},
            }
        }
    }
    for (lists.keys()) |list| switch (list.data) {
        .var_list => |v| reportVariables(c, list, v.decls),
        .func => |f| reportDeclarations(c, f.params),
        else => {},
    };
    var ii = imports.iterator();
    while (ii.next()) |e| reportImports(c, e.key_ptr.*, e.value_ptr.items);
}

/// A function's table also holds what its parameters declare; each scope speaks for its own.
fn declaredIn(decl: *Node, scope: *Node) bool {
    if (scope.data != .func) return true;
    var cur = decl.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x == scope) return true;
        if (x.data == .func) return false;
    }
    return true;
}

fn isExported(s: *Symbol) bool {
    for (s.decls) |decl| {
        if (decl.mods.@"export") return true;
        // `export const x`: the modifier sits on the statement.
        if (decl.data == .var_decl) if (decl.parent) |list| if (list.parent) |st| if (st.mods.@"export") return true;
    }
    return false;
}

fn rootDeclaration(n: *Node) *Node {
    var cur = n;
    while (cur.data == .binding_elem or cur.data == .object_pattern or cur.data == .array_pattern) cur = cur.parent orelse return cur;
    return cur;
}

fn importClauseOf(n: *Node) ?*Node {
    return switch (n.data) {
        .import_clause => n,
        .namespace_import => n.parent,
        else => if (n.parent) |p| p.parent else null,
    };
}

fn nameOf(n: *Node) ?*Node {
    return switch (n.data) {
        .var_decl => |x| x.name,
        .param => |x| x.name,
        .binding_elem => |x| x.name,
        .import_clause => |x| x.name,
        .namespace_import => |x| x.name,
        .import_spec => |x| x.name,
        .import_equals => |x| x.name,
        .func => |x| x.name,
        .class => |x| x.name,
        .interface => |x| x.name,
        .type_alias => |x| x.name,
        .enum_decl => |x| x.name,
        .module_decl => |x| x.name,
        .type_param => |x| x.name,
        else => null,
    };
}

fn startsWithUnderscore(name: ?*Node) bool {
    const n = name orelse return false;
    return n.data == .identifier and n.data.identifier.len > 0 and n.data.identifier[0] == '_';
}

fn isTypeDeclaration(n: *Node) bool {
    return switch (n.data) {
        .type_param, .class, .interface, .type_alias, .enum_decl => true,
        .import_clause => |x| x.type_only,
        .import_spec => if (n.parent) |p| if (p.parent) |clause| clause.data == .import_clause and clause.data.import_clause.type_only else false else false,
        else => false,
    };
}

fn reportLocal(c: *Checker, decl: *Node) void {
    const name = nameOf(decl) orelse decl;
    const text = if (name.data == .identifier) name.data.identifier else return;
    const msg = if (isTypeDeclaration(decl))
        c.fmt("'{s}' is declared but never used.", .{text})
    else
        c.fmt("'{s}' is declared but its value is never read.", .{text});
    report(c, false, name, if (isTypeDeclaration(decl)) 6196 else 6133, msg);
}

fn report(c: *Checker, is_param: bool, n: *Node, code: u32, msg: []const u8) void {
    if (!(if (is_param) c.no_unused_params else c.no_unused_locals)) return;
    d.report(c, n, code, msg);
}

fn isParameter(n: *Node) bool {
    return rootDeclaration(n).data == .param;
}

fn reportVariables(c: *Checker, list: *Node, decls: []*Node) void {
    if (decls.len > 1 and allUnreferenced(c, decls)) {
        report(c, false, list, 6199, "All variables are unused.");
        return;
    }
    reportDeclarations(c, decls);
}

fn reportDeclarations(c: *Checker, decls: []*Node) void {
    for (decls) |decl| {
        const name = nameOf(decl) orelse continue;
        if (decl.data == .param and (d.isParamProp(decl) or isThisName(name))) continue;
        switch (name.data) {
            .object_pattern => |p| reportBindings(c, name, p.elems),
            .array_pattern => |p| reportBindings(c, name, p.elems),
            .identifier => |text| if (unreferenced(c, decl)) {
                report(c, isParameter(decl), name, 6133, c.fmt("'{s}' is declared but its value is never read.", .{text}));
            },
            else => {},
        }
    }
}

fn reportBindings(c: *Checker, pattern: *Node, elems: []*Node) void {
    const bindings = onlyBindings(c, elems);
    if (bindings.len > 1 and allUnreferenced(c, bindings)) {
        report(c, isParameter(pattern), pattern, 6198, "All destructured elements are unused.");
        return;
    }
    reportDeclarations(c, bindings);
}

/// Array patterns can hold holes, which declare nothing.
fn onlyBindings(c: *Checker, elems: []*Node) []*Node {
    var out = std.ArrayList(*Node).empty;
    for (elems) |e| if (e.data == .binding_elem) out.append(c.a, e) catch oom();
    return out.items;
}

fn isThisName(n: *Node) bool {
    return n.data == .identifier and std.mem.eql(u8, n.data.identifier, "this");
}

fn allUnreferenced(c: *Checker, decls: []*Node) bool {
    for (decls) |x| if (!unreferenced(c, x)) return false;
    return true;
}

fn unreferenced(c: *Checker, decl: *Node) bool {
    const name = nameOf(decl) orelse return true;
    switch (name.data) {
        .object_pattern => |p| return allUnreferenced(c, onlyBindings(c, p.elems)),
        .array_pattern => |p| return allUnreferenced(c, onlyBindings(c, p.elems)),
        else => {},
    }
    if (decl.symbol()) |s| if (readAs(c, s) & F.variable != 0 or isExported(s.resolve())) return false;
    if (decl.data == .binding_elem) if (decl.parent) |p| if (p.data == .object_pattern) {
        // In `{ a, ...b }` reading `b` needs `a` taken out of it.
        const elems = p.data.object_pattern.elems;
        const last = elems[elems.len - 1];
        if (last != decl and last.data == .binding_elem and last.data.binding_elem.dotdotdot) return false;
    };
    if (startsWithUnderscore(name)) {
        if (decl.data == .param) return false;
        if (decl.data == .var_decl) if (decl.parent) |list| if (list.parent) |st| if (st.data == .for_in or st.data == .for_of) return false;
        if (decl.data == .var_decl) if (decl.parent) |list| if (list.data == .var_list and (list.data.var_list.kind == .using or list.data.var_list.kind == .await_using)) return false;
        if (decl.data == .binding_elem and !(decl.parent.?.data == .object_pattern and decl.data.binding_elem.prop_name == null)) return false;
        if (decl.data == .binding_elem and isParameter(decl)) return false;
    }
    return true;
}

fn reportImports(c: *Checker, clause: *Node, unused: []*Node) void {
    if (clause.data != .import_clause) return;
    const x = clause.data.import_clause;
    var count: usize = if (x.name != null) 1 else 0;
    if (x.bindings) |b| count += switch (b.data) {
        .namespace_import => 1,
        .named_imports => |n| n.elems.len,
        else => 0,
    };
    if (count > 1 and count == unused.len) {
        report(c, false, clause.parent orelse clause, 6192, "All imports in import declaration are unused.");
        return;
    }
    for (unused) |decl| reportLocal(c, decl);
}

fn checkTypeParams(c: *Checker, owner: *Node, list: ast.TypeList) void {
    if (list.items.len == 0 or !c.no_unused_params) return;
    // Merged declarations may read a type parameter in another file.
    if (owner.symbol()) |s| for (s.resolve().decls) |x| if (d.fileOf(c, x) != d.fileOf(c, owner)) return;
    var all = list.items.len > 1;
    for (list.items) |tp| if (!unreadTypeParam(c, tp)) {
        all = false;
    };
    if (all) {
        d.reportSpan(c, owner, list.span.start, list.span.end, 6205, "All type parameters are unused.");
        return;
    }
    for (list.items) |tp| if (unreadTypeParam(c, tp)) {
        const name = tp.data.type_param.name;
        report(c, true, tp, 6196, c.fmt("'{s}' is declared but never used.", .{if (name.data == .identifier) name.data.identifier else ""}));
    };
}

fn unreadTypeParam(c: *Checker, tp: *Node) bool {
    if (tp.data != .type_param or startsWithUnderscore(tp.data.type_param.name)) return false;
    const s = tp.symbol() orelse return false;
    if (readAs(c, s) & F.type_param != 0) return false;
    // tsc merges the type parameters of merged declarations: a read in any of them counts.
    const owner = tp.parent orelse return true;
    const merged = owner.symbol() orelse return true;
    const name = tp.data.type_param.name.data.identifier;
    for (merged.resolve().decls) |decl| {
        const list = typeParamsOf(decl) orelse continue;
        for (list.items) |other| {
            if (other == tp or other.data != .type_param) continue;
            if (!std.mem.eql(u8, other.data.type_param.name.data.identifier, name)) continue;
            if (other.symbol()) |o| if (readAs(c, o) & F.type_param != 0) return false;
        }
    }
    return true;
}

fn typeParamsOf(n: *Node) ?ast.TypeList {
    return switch (n.data) {
        .func => |x| x.type_params,
        .class => |x| x.type_params,
        .interface => |x| x.type_params,
        .type_alias => |x| x.type_params,
        else => null,
    };
}
