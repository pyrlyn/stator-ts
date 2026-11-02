//! The JavaScript emitter: strips types and TS-only syntax from a bound file by editing its
//! source text in place, and rewrites JSX and import extensions as configured.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;

fn oom() noreturn {
    @panic("out of memory");
}

/// The `jsx` compiler option.
pub const Jsx = enum { preserve, react, react_jsx, react_jsxdev };

/// Emit settings, filled from the program's compiler options by `driver.emitOptions`.
pub const Options = struct {
    jsx: Jsx = .preserve,
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    jsx_import_source: []const u8 = "react",
    rewrite_ts_ext: bool = false,
    verbatim_module_syntax: bool = false,
    /// Answers whether an alias resolves to something with no runtime value.
    /// Without it aliases count as values, which is what single-file transpilers do.
    is_type_alias: ?*const fn (ctx: *anyopaque, s: *Symbol) bool = null,
    ctx: *anyopaque = undefined,
    /// Replaces a module specifier outright; used when output must not rely on a resolver.
    map_spec: ?*const fn (ctx: *anyopaque, a: Allocator, f: *ast.File, spec: []const u8) ?[]const u8 = null,
    map_ctx: *anyopaque = undefined,
};

const Edit = struct { start: u32, end: u32, text: []const u8, seq: u32 };

const Emitter = struct {
    a: Allocator,
    f: *ast.File,
    opts: Options,
    edits: std.ArrayList(Edit) = .empty,
    used: std.AutoHashMapUnmanaged(*Symbol, void) = .empty,
    imports: std.ArrayList(*Node) = .empty,
    exports: std.ArrayList(*Node) = .empty,
    needs_require: bool = false,
    jsx_used: struct { jsx: bool = false, jsxs: bool = false, jsx_dev: bool = false, fragment: bool = false } = .{},

    fn edit(e: *Emitter, start: u32, end: u32, text: []const u8) void {
        e.edits.append(e.a, .{ .start = start, .end = end, .text = text, .seq = @intCast(e.edits.items.len) }) catch oom();
    }

    fn erase(e: *Emitter, start: u32, end: u32) void {
        if (end > start) e.edit(start, end, "");
    }

    fn eraseNode(e: *Emitter, n: *Node) void {
        e.erase(n.start, n.end);
    }

    fn eraseTypes(e: *Emitter, l: ast.TypeList) void {
        e.erase(l.span.start, l.span.end);
    }

    fn fmt(e: *Emitter, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(e.a, f, args) catch oom();
    }

    fn insertSemi(e: *Emitter, n: *Node) void {
        if (n.end == 0 or e.f.src[n.end - 1] != ';') e.edit(n.end, n.end, ";");
    }

    fn visitAll(e: *Emitter, list: []*Node) void {
        for (list) |n| e.visit(n);
    }

    fn childVisit(e: *Emitter, c: *Node) void {
        e.visit(c);
    }

    fn isTypeKind(k: ast.Kind) bool {
        return switch (k) {
            .kw_type, .this_type, .type_ref, .qualified_name, .type_query, .type_literal, .array_type, .tuple_type, .named_tuple_member, .optional_type, .rest_type, .union_type, .intersection_type, .conditional_type, .infer_type, .paren_type, .type_operator, .indexed_access, .mapped_type, .literal_type, .template_literal_type, .template_type_span, .import_type, .type_predicate, .type_param, .property_sig => true,
            else => false,
        };
    }

    fn valueRef(e: *Emitter, n: *Node) void {
        const name = n.data.identifier;
        const s = binder.lookupLocal(n, name, F.value) orelse return;
        if (s.flags & F.alias != 0) {
            e.used.put(e.a, s, {}) catch oom();
            return;
        }
        if (nsOwner(s)) |owner| {
            if (isInsideDecl(n, owner)) e.edit(n.start, n.start, e.fmt("{s}.", .{owner.name}));
        }
    }

    /// The namespace or enum whose emitted body reaches `s` through a parameter.
    fn nsOwner(s: *Symbol) ?*Symbol {
        const p = s.parent orelse return null;
        if (p.flags & (F.value_module | F.enum_any) == 0 or p.file == null) return null;
        for (p.decls) |d| if (d.data == .module_decl or d.data == .enum_decl) return p;
        return null;
    }

    fn isInsideDecl(n: *Node, owner: *Symbol) bool {
        var c = n.parent;
        while (c) |p| : (c = p.parent) {
            if ((p.data == .module_decl or p.data == .enum_decl) and p.symbol() != null and p.symbol().?.resolve() == owner.resolve()) return true;
        }
        return false;
    }

    fn visit(e: *Emitter, n: *Node) void {
        if (isTypeKind(n.kind())) return;
        switch (n.data) {
            .identifier => e.valueRef(n),
            .prop_access => |x| e.visit(x.expr),
            .property_assign => |x| {
                if (x.name.data == .computed_name) e.visit(x.name);
                e.visit(x.value);
            },
            .shorthand_assign => |x| {
                const name = x.name.data.identifier;
                if (binder.lookupLocal(x.name, name, F.value)) |s| {
                    if (s.flags & F.alias != 0) {
                        e.used.put(e.a, s, {}) catch oom();
                    } else if (nsOwner(s)) |o| {
                        if (isInsideDecl(n, o)) e.edit(x.name.end, x.name.end, e.fmt(": {s}.{s}", .{ o.name, name }));
                    }
                }
                if (x.init) |i| e.visit(i);
            },
            .as_expr => |x| {
                e.visit(x.expr);
                e.erase(x.expr.end, n.end);
            },
            .satisfies_expr => |x| {
                e.visit(x.expr);
                e.erase(x.expr.end, n.end);
            },
            .non_null => |x| {
                e.visit(x.expr);
                e.erase(x.expr.end, n.end);
            },
            .type_assertion => |x| {
                const wrap = switch (binder.stripParens(x.expr).data) {
                    .object_lit, .func, .class => true,
                    else => false,
                };
                e.edit(n.start, x.expr.start, if (wrap) "(" else "");
                e.visit(x.expr);
                if (wrap) e.edit(n.end, n.end, ")");
            },
            .call => |x| {
                e.visit(x.callee);
                e.eraseTypes(x.type_args);
                if (x.callee.data == .import_kw and x.args.len > 0) e.rewriteSpecifier(x.args[0]);
                e.visitAll(x.args);
            },
            .new_expr => |x| {
                e.visit(x.callee);
                e.eraseTypes(x.type_args);
                e.visitAll(x.args);
            },
            .tagged_template => |x| {
                e.visit(x.tag);
                e.eraseTypes(x.type_args);
                e.visit(x.template);
            },
            .expr_with_type_args => |x| {
                e.visit(x.expr);
                e.eraseTypes(x.type_args);
            },
            .string_lit => {},
            .func => e.visitFunc(n),
            .class => e.visitClass(n),
            .interface, .type_alias => e.eraseNode(n),
            .enum_decl => e.visitEnum(n),
            .module_decl => e.visitModule(n),
            .var_stmt => |x| e.visitVarStmt(n, x.list),
            .var_decl => |d| e.visitVarDecl(d),
            .binding_elem => |d| {
                if (d.prop_name) |p| if (p.data == .computed_name) e.visit(p);
                if (d.init) |i| e.visit(i);
                if (d.name.data != .identifier) e.visit(d.name);
            },
            .param => |d| {
                e.visitAll(d.decorators);
                if (d.ann_span.end > d.ann_span.start) e.erase(d.ann_span.start, d.ann_span.end);
                if (d.name.data != .identifier) e.visit(d.name);
                if (d.init) |i| e.visit(i);
            },
            .labeled => |x| e.visit(x.stmt),
            .break_stmt, .continue_stmt, .return_stmt, .throw_stmt, .expr_stmt, .debugger_stmt => {
                e.defaultVisit(n);
                e.insertSemi(n);
            },
            .import_decl => e.imports.append(e.a, n) catch oom(),
            .import_equals => e.visitImportEquals(n),
            .export_decl => e.exports.append(e.a, n) catch oom(),
            .export_assign => |x| e.visitExportAssign(n, x.expr, x.is_equals),
            .namespace_export_decl => e.eraseNode(n),
            .jsx_element, .jsx_self_closing, .jsx_fragment => e.visitJsxRoot(n),
            else => e.defaultVisit(n),
        }
    }

    fn defaultVisit(e: *Emitter, n: *Node) void {
        ast.forEachChild(n, e, childVisit);
    }

    fn visitVarStmt(e: *Emitter, n: *Node, list: *Node) void {
        if (n.mods.declare) return e.eraseNode(n);
        if (n.mods.@"export" and n.parent != null and n.parent.?.data == .module_block) return e.visitNsExportVar(n, list);
        e.visit(list);
        e.insertSemi(n);
    }

    fn visitVarDecl(e: *Emitter, d: *ast.VarDecl) void {
        if (d.ann_span.end > d.ann_span.start) e.erase(d.ann_span.start, d.ann_span.end);
        if (d.name.data != .identifier) e.visit(d.name);
        if (d.init) |i| e.visit(i);
    }

    fn eraseExportKeyword(e: *Emitter, n: *Node) u32 {
        const at = std.mem.indexOfPos(u8, e.f.src, n.start, "export") orelse return n.start;
        var end: u32 = @intCast(at + "export".len);
        while (end < e.f.src.len and (e.f.src[end] == ' ' or e.f.src[end] == '\t')) end += 1;
        e.erase(@intCast(at), end);
        return end;
    }

    fn enclosingNs(n: *Node) ?*Symbol {
        var c = n.parent;
        while (c) |p| : (c = p.parent) {
            if (p.data == .module_decl) return p.symbol();
            if (p.data != .module_block) return null;
        }
        return null;
    }

    fn visitNsExportVar(e: *Emitter, n: *Node, list: *Node) void {
        const ns = enclosingNs(n).?;
        const decls = list.data.var_list.decls;
        var plain = true;
        var any_init = false;
        for (decls) |d| {
            if (d.data.var_decl.name.data != .identifier) plain = false;
            if (d.data.var_decl.init != null) any_init = true;
        }
        if (!plain) {
            // Destructured exports stay local and are copied onto the namespace afterwards.
            _ = e.eraseExportKeyword(n);
            e.visit(list);
            var buf: std.ArrayList(u8) = .empty;
            for (decls) |d| collectNames(e.a, d.data.var_decl.name, ns.name, &buf);
            e.edit(n.end, n.end, buf.items);
            return;
        }
        if (!any_init) return e.eraseNode(n);
        e.erase(n.start, decls[0].start);
        for (decls) |d| {
            const vd = d.data.var_decl;
            if (vd.ann_span.end > vd.ann_span.start) e.erase(vd.ann_span.start, vd.ann_span.end);
            if (vd.init) |i| {
                e.edit(d.start, d.start, e.fmt("{s}.", .{ns.name}));
                e.visit(i);
            } else e.edit(d.start, d.end, "void 0");
        }
        e.insertSemi(n);
    }

    fn visitFunc(e: *Emitter, n: *Node) void {
        const f = n.data.func;
        if (f.body == null and f.kind != .method_sig) return e.eraseNode(n);
        if (n.mods.declare) return e.eraseNode(n);
        const ns = if (n.mods.@"export" and f.kind == .decl) enclosingNs(n) else null;
        if (ns != null) _ = e.eraseExportKeyword(n);
        e.visitAll(f.decorators);
        if (f.name) |x| if (x.data == .computed_name) e.visit(x);
        if (f.question) e.erase(f.q_pos, f.q_pos + 1);
        e.eraseTypes(f.type_params);
        for (f.params, 0..) |p, i| {
            if (p.data.param.name.data == .identifier and std.mem.eql(u8, p.data.param.name.data.identifier, "this")) {
                e.erase(p.start, if (i + 1 < f.params.len) f.params[i + 1].start else p.end);
                continue;
            }
            e.visit(p);
        }
        e.erase(f.ret_span.start, f.ret_span.end);
        if (f.kind == .ctor) e.paramProperties(n, f);
        if (f.body) |b| e.visit(b);
        if (ns) |s| if (f.name) |x| e.edit(n.end, n.end, e.fmt("\n{s}.{s} = {s};", .{ s.name, x.data.identifier, x.data.identifier }));
    }

    fn isSuperCall(s: *Node) bool {
        if (s.data != .expr_stmt) return false;
        const c = s.data.expr_stmt.expr;
        return c.data == .call and c.data.call.callee.data == .super_expr;
    }

    fn paramProperties(e: *Emitter, n: *Node, f: *ast.Func) void {
        var fields: std.ArrayList(u8) = .empty;
        var body: std.ArrayList(u8) = .empty;
        for (f.params) |p| {
            const m = p.mods;
            if (!(m.public or m.private or m.protected or m.readonly or m.override)) continue;
            if (p.data.param.name.data != .identifier) continue;
            const name = p.data.param.name.data.identifier;
            fields.print(e.a, "{s};\n    ", .{name}) catch oom();
            body.print(e.a, "\n        this.{s} = {s};", .{ name, name }) catch oom();
        }
        if (fields.items.len == 0) return;
        e.edit(n.start, n.start, fields.items);
        const b = f.body orelse return;
        var at = b.start + 1;
        for (b.data.block.stmts) |s| if (isSuperCall(s)) {
            at = s.end;
            break;
        };
        e.edit(at, at, body.items);
    }

    fn visitClass(e: *Emitter, n: *Node) void {
        const c = n.data.class;
        if (n.mods.declare) return e.eraseNode(n);
        const ns = if (n.mods.@"export" and !c.is_expr) enclosingNs(n) else null;
        if (ns != null) _ = e.eraseExportKeyword(n);
        e.visitAll(c.decorators);
        e.eraseTypes(c.type_params);
        for (c.heritage) |h| {
            if (h.data.heritage_clause.tok == .kw_implements) {
                e.eraseNode(h);
            } else e.visitAll(h.data.heritage_clause.types);
        }
        for (c.members) |m| e.visitMember(m);
        if (ns) |s| if (c.name) |x| e.edit(n.end, n.end, e.fmt("\n{s}.{s} = {s};", .{ s.name, x.data.identifier, x.data.identifier }));
    }

    fn visitMember(e: *Emitter, m: *Node) void {
        switch (m.data) {
            .property_decl => |d| {
                if (m.mods.declare or m.mods.abstract) return e.eraseNode(m);
                e.visitAll(d.decorators);
                if (d.name.data == .computed_name) e.visit(d.name);
                if (d.ann_span.end > d.ann_span.start) e.erase(d.ann_span.start, d.ann_span.end);
                if (d.init) |i| e.visit(i);
                e.insertSemi(m);
            },
            .index_sig => e.eraseNode(m),
            .func => e.visitFunc(m),
            .static_block => e.defaultVisit(m),
            else => {},
        }
    }

    /// `known` holds the members of the enum being emitted; anything else resolves through the binder.
    fn evalConst(e: *Emitter, n: *Node, known: *std.StringHashMapUnmanaged(f64), depth: u32) ?f64 {
        return switch (n.data) {
            .numeric_lit => |v| parseNumber(v),
            .paren => |x| e.evalConst(x.expr, known, depth),
            .identifier => |v| known.get(v) orelse e.memberValue(n, depth),
            .prop_access => e.memberValue(n, depth),
            .prefix => |x| blk: {
                const v = e.evalConst(x.expr, known, depth) orelse break :blk null;
                break :blk switch (x.op) {
                    .minus => -v,
                    .plus => v,
                    .tilde => @floatFromInt(~toI32(v)),
                    else => null,
                };
            },
            .binary => |x| blk: {
                const l = e.evalConst(x.left, known, depth) orelse break :blk null;
                const r = e.evalConst(x.right, known, depth) orelse break :blk null;
                break :blk switch (x.op) {
                    .plus => l + r,
                    .minus => l - r,
                    .star => l * r,
                    .slash => l / r,
                    .pipe => @floatFromInt(toI32(l) | toI32(r)),
                    .amp => @floatFromInt(toI32(l) & toI32(r)),
                    .caret => @floatFromInt(toI32(l) ^ toI32(r)),
                    .shl => @floatFromInt(toI32(l) << @intCast(@as(u32, @bitCast(toI32(r))) & 31)),
                    .shr => @floatFromInt(toI32(l) >> @intCast(@as(u32, @bitCast(toI32(r))) & 31)),
                    else => null,
                };
            },
            else => null,
        };
    }

    /// The entity a name in an initializer denotes, within this file; aliases lead to other files.
    fn resolveEntity(e: *Emitter, n: *Node) ?*Symbol {
        const s = switch (n.data) {
            .identifier => |v| binder.lookupLocal(n, v, F.value | F.namespace) orelse return null,
            .prop_access => |x| blk: {
                if (x.name.data != .identifier) return null;
                const owner = e.resolveEntity(x.expr) orelse return null;
                const exports = owner.exports orelse return null;
                break :blk exports.get(x.name.data.identifier) orelse return null;
            },
            else => return null,
        };
        const r = s.resolve();
        return if (r.flags & F.alias != 0) null else r;
    }

    /// Value of the enum member `ref` names. Members depend on the ones before them in the same
    /// declaration, so that declaration is evaluated from its top; `depth` bounds reference chains.
    fn memberValue(e: *Emitter, ref: *Node, depth: u32) ?f64 {
        if (depth > 16) return null;
        const s = e.resolveEntity(ref) orelse return null;
        if (s.flags & F.enum_member == 0) return null;
        const m = s.value_decl orelse (if (s.decls.len > 0) s.decls[0] else return null);
        const en = m.parent orelse return null;
        if (en.data != .enum_decl) return null;
        var known: std.StringHashMapUnmanaged(f64) = .empty;
        var next: ?f64 = 0;
        for (en.data.enum_decl.members) |x| {
            const md = x.data.enum_member;
            const v: ?f64 = if (md.init) |i| (if (isStringy(i)) null else e.evalConst(i, &known, depth + 1)) else next;
            if (x == m) return v;
            if (v) |val| {
                known.put(e.a, enumKey(md.name) orelse "", val) catch oom();
                next = val + 1;
            } else next = null;
        }
        return null;
    }

    fn numText(e: *Emitter, v: f64) []const u8 {
        if (std.math.isNan(v)) return "NaN";
        if (std.math.isInf(v)) return if (v > 0) "Infinity" else "-Infinity";
        if (v == @trunc(v) and @abs(v) < 1e15) return e.fmt("{d}", .{@as(i64, @intFromFloat(v))});
        return e.fmt("{d}", .{v});
    }

    /// `var X;` is skipped when another declaration in this file already introduces the name.
    fn varPrefix(e: *Emitter, n: *Node, name: []const u8, exported: bool) []const u8 {
        const s = (n.symbol() orelse return "").resolve();
        for (s.decls) |d| {
            if (!e.inThisFile(d)) continue;
            if (d == n) break;
            if (d.data == .enum_decl or (d.data == .module_decl and binder.Binder.isInstantiatedDecl(d))) return "";
        }
        for (s.decls) |d| if (e.inThisFile(d) and (d.data == .class or d.data == .func)) return "";
        if (exported) return e.fmt("export var {s};\n", .{name});
        return e.fmt("var {s};\n", .{name});
    }

    fn inThisFile(e: *Emitter, d: *Node) bool {
        var c = d;
        while (c.parent) |p| c = p;
        return c == e.f.root;
    }

    fn iifeTail(e: *Emitter, n: *Node, name: []const u8) []const u8 {
        if (n.mods.@"export") if (enclosingNs(n)) |ns| {
            return e.fmt("}})({s} = {s}.{s} || ({s}.{s} = {{}}));", .{ name, ns.name, name, ns.name, name });
        };
        return e.fmt("}})({s} || ({s} = {{}}));", .{ name, name });
    }

    fn visitEnum(e: *Emitter, n: *Node) void {
        const d = n.data.enum_decl;
        if (n.mods.declare) return e.eraseNode(n);
        const name = d.name.data.identifier;
        const ns = enclosingNs(n);
        const exported_top = n.mods.@"export" and ns == null;
        const head = e.fmt("{s}(function ({s}) {{", .{ e.varPrefix(n, name, exported_top), name });
        const body_start = if (d.members.len > 0) d.members[0].start else n.end - 1;
        e.edit(n.start, body_start, head);
        var known: std.StringHashMapUnmanaged(f64) = .empty;
        var next: ?f64 = 0;
        var cur = body_start;
        for (d.members) |m| {
            const md = m.data.enum_member;
            const member = (if (md.name.data == .identifier or md.name.data == .string_lit or md.name.data == .numeric_lit)
                enumKey(md.name)
            else
                null) orelse "";
            const key = jsLiteral(e.a, member);
            if (md.init) |i| {
                if (isStringy(i)) {
                    e.edit(cur, i.start, e.fmt("\n    {s}[{s}] = ", .{ name, key }));
                    e.visit(i);
                    cur = i.end;
                    e.edit(cur, cur, ";");
                    next = null;
                } else if (e.evalConst(i, &known, 0)) |v| {
                    // A constant initializer is folded, as tsc does; the expression text is gone.
                    e.edit(cur, m.end, e.fmt("\n    {s}[{s}[{s}] = {s}] = {s};", .{ name, name, key, e.numText(v), key }));
                    cur = m.end;
                    known.put(e.a, member, v) catch oom();
                    next = v + 1;
                } else {
                    e.edit(cur, i.start, e.fmt("\n    {s}[{s}[{s}] = ", .{ name, name, key }));
                    e.visit(i);
                    cur = i.end;
                    e.edit(cur, cur, e.fmt("] = {s};", .{key}));
                    next = null;
                }
            } else if (next) |v| {
                e.edit(cur, m.end, e.fmt("\n    {s}[{s}[{s}] = {s}] = {s};", .{ name, name, key, e.numText(v), key }));
                cur = m.end;
                known.put(e.a, member, v) catch oom();
                next = v + 1;
            } else {
                // After a member tsc cannot evaluate the next one has no value; tsc emits `void 0`
                // (and an error) rather than restarting at 0.
                e.edit(cur, m.end, e.fmt("\n    {s}[{s}[{s}] = void 0] = {s};", .{ name, name, key, key }));
                cur = m.end;
            }
        }
        e.edit(cur, n.end, e.fmt("\n{s}", .{e.iifeTail(n, name)}));
    }

    fn visitModule(e: *Emitter, n: *Node) void {
        const d = n.data.module_decl;
        if (n.mods.declare or d.is_global or d.name.data == .string_lit or !binder.Binder.isInstantiatedDecl(n)) return e.eraseNode(n);
        const name = d.name.data.identifier;
        const body = d.body orelse return e.eraseNode(n);
        const nested = n.parent != null and n.parent.?.data == .module_decl;
        const exported_top = n.mods.@"export" and enclosingNs(n) == null and !nested;
        const prefix = e.varPrefix(n, name, exported_top);
        const decl = if (nested) e.fmt("let {s};\n", .{name}) else prefix;
        if (body.data == .module_decl) {
            e.edit(n.start, body.start, e.fmt("{s}(function ({s}) {{\n", .{ decl, name }));
            e.visitModule(body);
            e.edit(body.end, n.end, "");
            e.edit(n.end, n.end, e.nestedTail(n, name));
            return;
        }
        e.edit(n.start, body.start + 1, e.fmt("{s}(function ({s}) {{", .{ decl, name }));
        for (body.data.module_block.stmts) |s| e.visit(s);
        e.edit(n.end - 1, n.end, e.nestedTail(n, name));
    }

    fn nestedTail(e: *Emitter, n: *Node, name: []const u8) []const u8 {
        if (n.parent != null and n.parent.?.data == .module_decl) {
            const outer = n.parent.?.symbol().?.name;
            return e.fmt("\n}})({s} = {s}.{s} || ({s}.{s} = {{}}));", .{ name, outer, name, outer, name });
        }
        return e.iifeTail(n, name);
    }

    fn visitImportEquals(e: *Emitter, n: *Node) void {
        const d = n.data.import_equals;
        const name = d.name.data.identifier;
        if (d.type_only) return e.eraseNode(n);
        const sym = n.symbol();
        if (d.ref.data == .external_module_ref) {
            e.needs_require = true;
            const spec = e.f.src[d.ref.data.external_module_ref.expr.start..d.ref.data.external_module_ref.expr.end];
            const kw: []const u8 = if (n.mods.@"export") "export const" else "const";
            e.edit(n.start, n.end, e.fmt("{s} {s} = __require({s});", .{ kw, name, spec }));
            return;
        }
        // `import a = b.c`: an alias of a namespace member, kept only when used as a value.
        const value_used = n.mods.@"export" or e.aliasUsedLater(sym);
        if (!value_used) return e.eraseNode(n);
        e.markRefRoot(d.ref);
        const target = e.entityText(d.ref);
        if (n.mods.@"export") if (enclosingNs(n)) |ns| {
            e.edit(n.start, n.end, e.fmt("{s}.{s} = {s};", .{ ns.name, name, target }));
            return;
        };
        const kw: []const u8 = if (n.mods.@"export") "export var" else "var";
        e.edit(n.start, n.end, e.fmt("{s} {s} = {s};", .{ kw, name, target }));
    }

    fn aliasUsedLater(e: *Emitter, sym: ?*Symbol) bool {
        const s = sym orelse return false;
        var w = UseScan{ .name = s.name, .target = s };
        ast.forEachChild(e.f.root, &w, UseScan.walk);
        return w.found;
    }

    fn markRefRoot(e: *Emitter, n: *Node) void {
        switch (n.data) {
            .identifier => |name| if (binder.lookupLocal(n, name, F.namespace | F.value)) |s| {
                if (s.flags & F.alias != 0) e.used.put(e.a, s, {}) catch oom();
            },
            .qualified_name => |x| e.markRefRoot(x.left),
            .prop_access => |x| e.markRefRoot(x.expr),
            else => {},
        }
    }

    fn entityText(e: *Emitter, n: *Node) []const u8 {
        return e.f.src[n.start..n.end];
    }

    fn visitExportAssign(e: *Emitter, n: *Node, expr: *Node, is_equals: bool) void {
        if (expr.data == .identifier) {
            if (e.resolvesToType(expr, expr.data.identifier)) return e.eraseNode(n);
        }
        if (is_equals) e.edit(n.start, expr.start, "export default ");
        e.visit(expr);
        e.insertSemi(n);
    }

    fn resolvesToType(e: *Emitter, at: *Node, name: []const u8) bool {
        const s = binder.lookupLocal(at, name, F.value | F.type) orelse return false;
        if (s.flags & F.alias != 0) return e.aliasIsType(s);
        return s.flags & F.value == 0;
    }

    fn aliasIsType(e: *Emitter, s: *Symbol) bool {
        return if (e.opts.is_type_alias) |f| f(e.opts.ctx, s) else false;
    }

    /// The specifier and the terminator are only touched once a statement is known to survive:
    /// an insertion at the end of an erased statement would stay behind as a stray `;`.
    fn keepModuleStmt(e: *Emitter, n: *Node, spec: ?*Node, attrs: ?*Node) void {
        if (spec) |s| e.rewriteSpecifier(s);
        if (attrs == null) e.insertSemi(n);
    }

    fn finishImport(e: *Emitter, n: *Node) void {
        const d = n.data.import_decl;
        const clause = d.clause orelse return e.keepModuleStmt(n, d.specifier, d.attrs);
        const c = clause.data.import_clause;
        if (c.type_only) return e.eraseNode(n);
        const verbatim = e.opts.verbatim_module_syntax;
        const keep_default = c.name != null and (verbatim or e.isUsed(clause));
        var parts: std.ArrayList(u8) = .empty;
        var dropped = c.name != null and !keep_default;
        if (keep_default) parts.appendSlice(e.a, c.name.?.data.identifier) catch oom();
        if (c.bindings) |b| switch (b.data) {
            .namespace_import => |x| {
                if (verbatim or e.isUsed(b)) {
                    if (parts.items.len > 0) parts.appendSlice(e.a, ", ") catch oom();
                    parts.print(e.a, "* as {s}", .{x.name.data.identifier}) catch oom();
                } else dropped = true;
            },
            .named_imports => |x| {
                var list: std.ArrayList(u8) = .empty;
                for (x.elems) |spec| {
                    const sd = spec.data.import_spec;
                    if (sd.type_only or !(verbatim or e.isUsed(spec))) {
                        dropped = true;
                        continue;
                    }
                    if (list.items.len > 0) list.appendSlice(e.a, ", ") catch oom();
                    list.appendSlice(e.a, e.specText(spec, sd.prop_name, sd.name)) catch oom();
                }
                const empty_source = x.elems.len == 0;
                if (list.items.len > 0 or verbatim) {
                    if (parts.items.len > 0) parts.appendSlice(e.a, ", ") catch oom();
                    parts.print(e.a, "{{ {s} }}", .{list.items}) catch oom();
                } else if (empty_source) dropped = true;
            },
            else => {},
        };
        if (dropped and parts.items.len == 0) return e.eraseNode(n);
        e.keepModuleStmt(n, d.specifier, d.attrs);
        if (dropped) e.edit(clause.start, clause.end, parts.items);
    }

    fn specText(e: *Emitter, spec: *Node, prop: ?*Node, name: *Node) []const u8 {
        _ = spec;
        const local = e.f.src[name.start..name.end];
        if (prop) |p| return e.fmt("{s} as {s}", .{ e.f.src[p.start..p.end], local });
        return local;
    }

    fn isUsed(e: *Emitter, decl: *Node) bool {
        const s = decl.symbol() orelse return true;
        return e.used.contains(s) and !e.aliasIsType(s);
    }

    fn finishExport(e: *Emitter, n: *Node) void {
        const d = n.data.export_decl;
        if (d.type_only) return e.eraseNode(n);
        const clause = d.clause orelse return e.keepModuleStmt(n, d.specifier, d.attrs);
        if (clause.data != .named_exports) return e.keepModuleStmt(n, d.specifier, d.attrs);
        var list: std.ArrayList(u8) = .empty;
        var dropped = false;
        for (clause.data.named_exports.elems) |spec| {
            const sd = spec.data.export_spec;
            if (sd.type_only or e.exportIsType(spec, d.specifier != null)) {
                dropped = true;
                continue;
            }
            if (list.items.len > 0) list.appendSlice(e.a, ", ") catch oom();
            list.appendSlice(e.a, e.specText(spec, sd.prop_name, sd.name)) catch oom();
        }
        if (dropped and list.items.len == 0 and !e.opts.verbatim_module_syntax) return e.eraseNode(n);
        e.keepModuleStmt(n, d.specifier, d.attrs);
        if (dropped) e.edit(clause.start, clause.end, e.fmt("{{ {s} }}", .{list.items}));
    }

    fn exportIsType(e: *Emitter, spec: *Node, reexport: bool) bool {
        const sd = spec.data.export_spec;
        if (reexport) return if (spec.symbol()) |s| e.aliasIsType(s) else false;
        const local = sd.prop_name orelse sd.name;
        const name = binder.specName(local);
        const s = binder.lookupLocal(spec, name, F.value | F.type) orelse return false;
        if (s.flags & F.alias != 0) {
            if (e.aliasIsType(s)) return true;
            e.used.put(e.a, s, {}) catch oom();
            return false;
        }
        return s.flags & F.value == 0;
    }

    fn rewriteSpecifier(e: *Emitter, s: *Node) void {
        if (s.data != .string_lit) return;
        const v = s.data.string_lit;
        if (e.opts.map_spec) |m| if (m(e.opts.map_ctx, e.a, e.f, v)) |out| {
            e.edit(s.start + 1, s.end - 1, out);
            return;
        };
        if (!e.opts.rewrite_ts_ext) return;
        const out = rewrittenPath(e.a, v, e.opts.jsx) orelse return;
        e.edit(s.start + 1, s.end - 1, out);
    }

    fn visitJsxRoot(e: *Emitter, n: *Node) void {
        if (e.opts.jsx == .preserve) {
            e.markJsxUses(n);
            return;
        }
        var j = JsxOut{ .e = e, .cur = n.start };
        j.element(n);
    }

    fn markRoot(e: *Emitter, n: *Node) void {
        var c = n;
        while (c.data == .prop_access) c = c.data.prop_access.expr;
        if (c.data == .identifier) e.valueRef(c);
    }

    fn markJsxUses(e: *Emitter, n: *Node) void {
        if (binder.lookupLocal(e.f.root, "React", F.value)) |s| e.used.put(e.a, s, {}) catch oom();
        const W = struct {
            fn walk(em: *Emitter, c: *Node) void {
                switch (c.data) {
                    .jsx_expr => |x| if (x.expr) |i| em.visit(i),
                    .jsx_spread_attr => |x| em.visit(x.expr),
                    .identifier => |v| if (v.len > 0 and !(v[0] >= 'a' and v[0] <= 'z') and c.parent != null and c.parent.?.data != .jsx_attr) em.valueRef(c),
                    .prop_access => |x| walk(em, x.expr),
                    .jsx_attr => |x| if (x.value) |i| walk(em, i),
                    .string_lit, .jsx_text => {},
                    else => ast.forEachChild(c, em, walk),
                }
            }
        };
        ast.forEachChild(n, e, W.walk);
    }
};

const UseScan = struct {
    name: []const u8,
    target: *Symbol,
    found: bool = false,

    fn walk(w: *UseScan, n: *Node) void {
        if (w.found) return;
        if (n.data == .identifier and std.mem.eql(u8, n.data.identifier, w.name)) {
            const p = n.parent;
            if (p != null and p.?.data != .import_equals and p.?.data != .type_ref) {
                if (binder.lookupLocal(n, w.name, F.value | F.namespace)) |s| {
                    if (s == w.target) w.found = true;
                }
            }
        }
        ast.forEachChild(n, w, walk);
    }
};

/// Rewrites JSX through edits around child expressions, so those stay in place and keep their own edits.
const JsxOut = struct {
    e: *Emitter,
    cur: u32,
    buf: std.ArrayList(u8) = .empty,

    fn text(j: *JsxOut, s: []const u8) void {
        j.buf.appendSlice(j.e.a, s) catch oom();
    }

    fn flush(j: *JsxOut, to: u32) void {
        j.e.edit(j.cur, to, j.buf.items);
        j.buf = .empty;
        j.cur = to;
    }

    fn tagText(j: *JsxOut, tag: *Node) []const u8 {
        const src = j.e.f.src[tag.start..tag.end];
        if (tag.data == .identifier) {
            const v = tag.data.identifier;
            const intrinsic = v.len > 0 and v[0] >= 'a' and v[0] <= 'z' or std.mem.indexOfScalar(u8, v, '-') != null or std.mem.indexOfScalar(u8, v, ':') != null;
            if (intrinsic) return j.e.fmt("\"{s}\"", .{v});
            j.e.valueRef(tag);
            if (binder.lookupLocal(tag, v, F.value)) |s| if (Emitter.nsOwner(s)) |o| if (Emitter.isInsideDecl(tag, o)) return j.e.fmt("{s}.{s}", .{ o.name, v });
        } else if (tag.data == .prop_access) {
            j.e.markRoot(tag);
        }
        return src;
    }

    fn isAuto(j: *JsxOut) bool {
        return j.e.opts.jsx != .react;
    }

    fn element(j: *JsxOut, n: *Node) void {
        var tag: ?*Node = null;
        var attrs: []*Node = &.{};
        var children: []*Node = &.{};
        switch (n.data) {
            .jsx_element => |x| {
                tag = x.open.data.jsx_opening.tag;
                attrs = x.open.data.jsx_opening.attrs;
                children = x.children;
            },
            .jsx_self_closing => |x| {
                tag = x.tag;
                attrs = x.attrs;
            },
            .jsx_fragment => |x| children = x.children,
            else => return,
        }
        const auto = j.isAuto();
        const tag_text = if (tag) |t| j.tagText(t) else if (auto) blk: {
            j.e.jsx_used.fragment = true;
            break :blk "_Fragment";
        } else j.e.opts.jsx_fragment;
        if (!auto) {
            const root = j.e.opts.jsx_factory;
            const dot = std.mem.indexOfScalar(u8, root, '.') orelse root.len;
            if (binder.lookupLocal(n, root[0..dot], F.value)) |s| if (s.flags & F.alias != 0) j.e.used.put(j.e.a, s, {}) catch oom();
        }

        var kids: std.ArrayList(*Node) = .empty;
        for (children) |c| {
            switch (c.data) {
                .jsx_text => if (jsxTrim(j.e.a, c.data.jsx_text).len == 0) continue,
                .jsx_expr => |x| if (x.expr == null) continue,
                else => {},
            }
            kids.append(j.e.a, c) catch oom();
        }
        const many = kids.items.len > 1;
        const dev = j.e.opts.jsx == .react_jsxdev;
        if (dev) {
            j.e.jsx_used.jsx_dev = true;
            j.text("_jsxDEV(");
        } else if (auto) {
            if (many) j.e.jsx_used.jsxs = true else j.e.jsx_used.jsx = true;
            j.text(if (many) "_jsxs(" else "_jsx(");
        } else {
            j.text(j.e.opts.jsx_factory);
            j.text("(");
        }
        j.text(tag_text);
        j.text(", ");
        var key: ?*Node = null;
        const has_props = attrs.len > 0 or (auto and kids.items.len > 0);
        if (!has_props) {
            j.text(if (auto) "{}" else "null");
        } else {
            j.text("{ ");
            for (attrs) |a| j.attr(a, &key);
            if (auto and kids.items.len > 0) {
                j.text("children: ");
                if (many) j.text("[");
                j.writeChildren(kids.items);
                if (many) j.text("]");
            }
            j.text(" }");
        }
        if (dev) {
            j.text(", ");
            if (key) |k| j.attrValue(k) else j.text("void 0");
            // tsc takes the position from the node's full start, so leading whitespace counts.
            var pos = n.start;
            while (pos > 0 and std.ascii.isWhitespace(j.e.f.src[pos - 1])) pos -= 1;
            const lc = j.e.f.lineCol(pos);
            j.text(j.e.fmt(", {s}, {{ fileName: _jsxFileName, lineNumber: {d}, columnNumber: {d} }}, this", .{ if (many) "true" else "false", lc.line, lc.col }));
        } else if (auto) {
            if (key) |k| {
                j.text(", ");
                j.attrValue(k);
            }
        } else if (kids.items.len > 0) {
            j.text(", ");
            j.writeChildren(kids.items);
        }
        j.text(")");
        j.flush(n.end);
    }

    fn writeChildren(j: *JsxOut, kids: []*Node) void {
        for (kids, 0..) |c, i| {
            if (i > 0) j.text(", ");
            switch (c.data) {
                .jsx_text => |v| j.text(jsLiteral(j.e.a, decodeEntities(j.e.a, jsxTrim(j.e.a, v)))),
                .jsx_expr => |x| j.expr(if (x.expr.?.data == .spread_elem) x.expr.?.data.spread_elem.expr else x.expr.?),
                else => j.nested(c),
            }
        }
    }

    fn nested(j: *JsxOut, c: *Node) void {
        j.flush(c.start);
        var inner = JsxOut{ .e = j.e, .cur = c.start };
        inner.element(c);
        j.cur = c.end;
    }

    fn expr(j: *JsxOut, x: *Node) void {
        j.flush(x.start);
        j.e.visit(x);
        j.cur = x.end;
    }

    fn attrValue(j: *JsxOut, v: *Node) void {
        switch (v.data) {
            .string_lit => {
                const raw = j.e.f.src[v.start + 1 .. v.end - 1];
                j.text(jsLiteral(j.e.a, decodeEntities(j.e.a, raw)));
            },
            .jsx_expr => |x| if (x.expr) |i| j.expr(i),
            else => j.nested(v),
        }
    }

    fn attr(j: *JsxOut, a: *Node, key: *?*Node) void {
        switch (a.data) {
            .jsx_spread_attr => |x| {
                j.text("...");
                j.expr(x.expr);
                j.text(", ");
            },
            .jsx_attr => |x| {
                const name = j.e.f.src[x.name.start..x.name.end];
                if (j.isAuto() and std.mem.eql(u8, name, "key") and x.value != null) {
                    key.* = x.value;
                    return;
                }
                if (isPlainIdent(name)) {
                    j.text(name);
                } else j.text(j.e.fmt("\"{s}\"", .{name}));
                j.text(": ");
                if (x.value) |v| j.attrValue(v) else j.text("true");
                j.text(", ");
            },
            else => {},
        }
    }
};

fn isPlainIdent(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return false;
    return s.len > 0;
}

/// Same rule as Babel and tsc: lines trim, blank lines vanish, the rest join with one space.
fn jsxTrim(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    const has_nl = std.mem.indexOfScalar(u8, s, '\n') != null;
    var first = true;
    var index: usize = 0;
    const last = std.mem.count(u8, s, "\n");
    while (it.next()) |line| : (index += 1) {
        var t = line;
        if (has_nl) {
            if (index != 0) t = std.mem.trimStart(u8, t, " \t\r");
            if (index != last) t = std.mem.trimEnd(u8, t, " \t\r");
        }
        if (t.len == 0) continue;
        if (!first) out.append(a, ' ') catch oom();
        out.appendSlice(a, t) catch oom();
        first = false;
    }
    return out.items;
}

fn decodeEntities(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    const table = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&nbsp;", "\u{a0}" },
    };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') {
            for (table) |t| if (std.mem.startsWith(u8, s[i..], t[0])) {
                out.appendSlice(a, t[1]) catch oom();
                i += t[0].len;
                continue :outer;
            };
            if (i + 2 < s.len and s[i + 1] == '#') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |end| {
                const body = s[i + 2 .. end];
                const code = if (body.len > 0 and (body[0] == 'x' or body[0] == 'X'))
                    std.fmt.parseInt(u21, body[1..], 16) catch null
                else
                    std.fmt.parseInt(u21, body, 10) catch null;
                if (code) |c| {
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &tmp) catch 0;
                    out.appendSlice(a, tmp[0..n]) catch oom();
                    i = end + 1;
                    continue :outer;
                }
            };
        }
        out.append(a, s[i]) catch oom();
        i += 1;
    }
    return out.items;
}

fn jsLiteral(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => out.appendSlice(a, "\\\"") catch oom(),
        '\\' => out.appendSlice(a, "\\\\") catch oom(),
        '\n' => out.appendSlice(a, "\\n") catch oom(),
        '\r' => out.appendSlice(a, "\\r") catch oom(),
        else => out.append(a, c) catch oom(),
    };
    out.append(a, '"') catch oom();
    return out.items;
}

fn toI32(v: f64) i32 {
    if (std.math.isNan(v) or std.math.isInf(v)) return 0;
    const m = @mod(@trunc(v), 4294967296.0);
    return @bitCast(@as(u32, @intFromFloat(m)));
}

pub fn parseNumber(raw: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    const s = buf[0..n];
    if (s.len > 2 and s[0] == '0') {
        const base: u8 = switch (s[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (base != 0) return if (std.fmt.parseInt(u64, s[2..], base)) |v| @floatFromInt(v) else |_| null;
    }
    return std.fmt.parseFloat(f64, s) catch null;
}

fn enumKey(n: *Node) ?[]const u8 {
    return switch (n.data) {
        .identifier, .string_lit, .numeric_lit => |v| v,
        else => null,
    };
}

fn isStringy(n: *Node) bool {
    return switch (n.data) {
        .string_lit, .no_subst_template, .template_expr => true,
        .paren => |x| isStringy(x.expr),
        .binary => |x| x.op == .plus and (isStringy(x.left) or isStringy(x.right)),
        else => false,
    };
}

fn collectNames(a: Allocator, pat: *Node, ns: []const u8, out: *std.ArrayList(u8)) void {
    switch (pat.data) {
        .identifier => |v| out.print(a, "\n{s}.{s} = {s};", .{ ns, v, v }) catch oom(),
        .object_pattern => |x| for (x.elems) |el| collectNames(a, el.data.binding_elem.name, ns, out),
        .array_pattern => |x| for (x.elems) |el| if (el.data == .binding_elem) collectNames(a, el.data.binding_elem.name, ns, out),
        else => {},
    }
}

/// A relative import path with its `.ts`/`.tsx`/`.mts`/`.cts` extension swapped for the
/// JavaScript one, or null when the path is not relative, is a `.d.ts`, or has no such extension.
pub fn rewrittenPath(a: Allocator, v: []const u8, jsx: Jsx) ?[]const u8 {
    if (!(std.mem.startsWith(u8, v, "./") or std.mem.startsWith(u8, v, "../") or std.mem.startsWith(u8, v, "/"))) return null;
    if (std.mem.endsWith(u8, v, ".d.ts")) return null;
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ ".tsx", if (jsx == .preserve) ".jsx" else ".js" },
        .{ ".mts", ".mjs" },
        .{ ".cts", ".cjs" },
        .{ ".ts", ".js" },
    };
    for (pairs) |p| if (std.mem.endsWith(u8, v, p[0])) {
        return std.mem.concat(a, u8, &.{ v[0 .. v.len - p[0].len], p[1] }) catch oom();
    };
    return null;
}

/// The output file name for a source path: `.ts` becomes `.js`, `.mts` `.mjs`, `.cts` `.cjs`, and
/// `.tsx` `.jsx` when JSX is preserved, else `.js`.
pub fn outputPath(a: Allocator, path: []const u8, jsx: Jsx) []const u8 {
    return rewrittenExt(a, path, jsx);
}

fn rewrittenExt(a: Allocator, path: []const u8, jsx: Jsx) []const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ ".tsx", if (jsx == .preserve) ".jsx" else ".js" },
        .{ ".mts", ".mjs" },
        .{ ".cts", ".cjs" },
        .{ ".ts", ".js" },
    };
    for (pairs) |p| if (std.mem.endsWith(u8, path, p[0])) {
        return std.mem.concat(a, u8, &.{ path[0 .. path.len - p[0].len], p[1] }) catch oom();
    };
    return path;
}

fn firstCodeOffset(src: []const u8) u32 {
    if (!std.mem.startsWith(u8, src, "#!")) return 0;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse return @intCast(src.len);
    return @intCast(nl + 1);
}

fn lessThan(_: void, l: Edit, r: Edit) bool {
    if (l.start != r.start) return l.start < r.start;
    const lz = l.end == l.start;
    const rz = r.end == r.start;
    // An insertion lands before a replacement at the same offset; the wider replacement wins overlaps.
    if (lz != rz) return lz;
    if (l.end != r.end) return l.end > r.end;
    return l.seq < r.seq;
}

/// `file` must be bound. Output is the source with edits applied, so comments and layout survive.
pub fn emit(a: Allocator, file: *ast.File, opts: Options) []const u8 {
    var e = Emitter{ .a = a, .f = file, .opts = opts };
    for (file.root.data.source_file.stmts) |s| e.visit(s);
    for (e.exports.items) |n| e.finishExport(n);
    for (e.imports.items) |n| e.finishImport(n);
    for (file.strip) |s| e.erase(s.start, s.end);

    var header: std.ArrayList(u8) = .empty;
    if (e.needs_require) header.appendSlice(a, "import { createRequire as _createRequire } from \"node:module\";\nconst __require = _createRequire(import.meta.url);\n") catch oom();
    if (e.jsx_used.jsx or e.jsx_used.jsxs or e.jsx_used.jsx_dev or e.jsx_used.fragment) {
        var names: std.ArrayList(u8) = .empty;
        if (e.jsx_used.jsx_dev) names.appendSlice(a, "jsxDEV as _jsxDEV") catch oom();
        if (e.jsx_used.jsx) names.appendSlice(a, "jsx as _jsx") catch oom();
        if (e.jsx_used.jsxs) names.appendSlice(a, if (names.items.len > 0) ", jsxs as _jsxs" else "jsxs as _jsxs") catch oom();
        if (e.jsx_used.fragment) names.appendSlice(a, if (names.items.len > 0) ", Fragment as _Fragment" else "Fragment as _Fragment") catch oom();
        const runtime: []const u8 = if (e.jsx_used.jsx_dev) "jsx-dev-runtime" else "jsx-runtime";
        header.print(a, "import {{ {s} }} from \"{s}/{s}\";\n", .{ names.items, opts.jsx_import_source, runtime }) catch oom();
        if (e.jsx_used.jsx_dev) header.print(a, "const _jsxFileName = {s};\n", .{jsLiteral(a, file.path)}) catch oom();
    }
    if (header.items.len > 0) {
        const at = firstCodeOffset(file.src);
        e.edit(at, at, header.items);
    }

    std.mem.sort(Edit, e.edits.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, file.src.len) catch oom();
    var pos: u32 = 0;
    for (e.edits.items) |ed| {
        if (ed.start < pos) continue;
        out.appendSlice(a, file.src[pos..ed.start]) catch oom();
        out.appendSlice(a, ed.text) catch oom();
        pos = ed.end;
    }
    out.appendSlice(a, file.src[pos..]) catch oom();
    return out.items;
}

fn testEmit(a: Allocator, src: []const u8) []const u8 {
    const parser = @import("parser.zig");
    const f = parser.parse(a, "t.ts", src);
    binder.bindFile(a, f);
    return emit(a, f, .{});
}

test "erases types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "\nconst x = 1;\nfunction f(a, b) { return a; }\n",
        testEmit(a, "interface I { a: 1 }\nconst x: number = 1 as any;\nfunction f<T>(a: T, b?: string): T { return a!; }\n"),
    );
}

test "drops imports only used as types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "import { b } from './m';\nconst v = b;\n",
        testEmit(a, "import { A, b } from './m';\nconst v: A = b;\n"),
    );
}

test "enum becomes an IIFE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = testEmit(a, "enum E { A, B = 5, C }\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "E[E[\"C\"] = 6] = \"C\";") != null);
    try std.testing.expect(std.mem.startsWith(u8, out, "var E;\n(function (E) {"));
}

test "enum members referenced through another enum are folded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = testEmit(a, "enum Other { A = 5 }\nenum B { X = Other.A, Y }\nnamespace N { export enum I { Z = 3 } }\nenum H { W = N.I.Z | 4, V }\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "B[B[\"X\"] = 5] = \"X\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B[B[\"Y\"] = 6] = \"Y\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "H[H[\"W\"] = 7] = \"W\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "H[H[\"V\"] = 8] = \"V\";") != null);
}

test "a member after one that cannot be evaluated gets no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = testEmit(a, "declare const k: number;\nenum G { X = k, Y }\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "G[G[\"X\"] = k] = \"X\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "G[G[\"Y\"] = void 0] = \"Y\";") != null);
}

test "enum member keys are escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = testEmit(a, "enum E { \"a\\\"b\" = 1, 'c\\\\d' }\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "E[E[\"a\\\"b\"] = 1] = \"a\\\"b\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "E[E[\"c\\\\d\"] = 2] = \"c\\\\d\";") != null);
}

test "an elided import or export leaves no semicolon behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "\n\nconst v = 1;\n\nexport {};\n",
        testEmit(a, "import type { A } from './m'\nimport { I } from './m'\nconst v: A = 1\nexport type { A as AA } from './m'\nexport {}\n"),
    );
}

test "react-jsxdev imports jsxDEV from the dev runtime" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parser.parse(a, "/p/t.tsx", "export const x = <div className=\"a\">hi<span>{1}</span></div>;\n");
    binder.bindFile(a, f);
    const out = emit(a, f, .{ .jsx = .react_jsxdev });
    try std.testing.expect(std.mem.startsWith(u8, out, "import { jsxDEV as _jsxDEV } from \"react/jsx-dev-runtime\";\nconst _jsxFileName = \"/p/t.tsx\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "_jsxDEV(\"span\", { children: 1 }, void 0, false, { fileName: _jsxFileName, lineNumber: 1, columnNumber: 39 }, this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "] }, void 0, true, { fileName: _jsxFileName, lineNumber: 1, columnNumber: 17 }, this);") != null);
}

test "parameter properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = testEmit(a, "class A { constructor(private x: number) {} }\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "this.x = x;") != null);
}
