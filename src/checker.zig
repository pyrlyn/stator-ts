//! Statements and declarations, plus the parallel entry point. Each worker owns one `Checker`,
//! which owns all its types; files are partitioned up front so results do not depend on timing.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const project = @import("project.zig");
const pool = @import("pool.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const expr = @import("expr.zig");
const relate = @import("relate.zig");
const flow = @import("flow.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Checker = T.Checker;
const Type = T.Type;
const oom = T.oom;

pub const Diag = T.Diag;

fn err(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    expr.err(c, n, code, msg);
}

fn checkBlock(c: *Checker, stmts: []*Node) void {
    for (stmts) |s| checkStmt(c, s);
}

fn drainDeferred(c: *Checker) void {
    while (true) {
        while (c.pending_constraints.pop()) |p| d.verifyConstraints(c, p);
        const n = c.deferred.pop() orelse return;
        switch (n.data) {
            .func => checkFuncBody(c, n),
            .class => checkClass(c, n),
            else => {},
        }
    }
}

fn implicitAny(c: *Checker, p: *Node, fnode: ?*Node) void {
    if (!c.no_implicit_any) return;
    const x = p.data.param;
    if (x.type != null or x.init != null) return;
    if (c.param_types.contains(p)) return;
    if (fnode) |f| if (f.data == .func and d.setterGetter(f) != null) return;
    if (x.name.data == .identifier) {
        const name = x.name.data.identifier;
        if (std.mem.eql(u8, name, "this")) return;
        if (x.dotdotdot) {
            err(c, p, 7019, c.fmt("Rest parameter '{s}' implicitly has an 'any[]' type.", .{name}));
        } else {
            err(c, p, 7006, c.fmt("Parameter '{s}' implicitly has an 'any' type.", .{name}));
        }
    } else {
        checkPatternAny(c, x.name);
    }
}

fn checkPatternAny(c: *Checker, pat: *Node) void {
    const elems = switch (pat.data) {
        .object_pattern => |x| x.elems,
        .array_pattern => |x| x.elems,
        else => return,
    };
    for (elems) |e| {
        if (e.data != .binding_elem) continue;
        const x = e.data.binding_elem;
        if (x.init != null) continue;
        if (x.name.data == .identifier) {
            err(c, e, 7031, c.fmt("Binding element '{s}' implicitly has an 'any' type.", .{x.name.data.identifier}));
        } else checkPatternAny(c, x.name);
    }
}

fn checkBindings(c: *Checker, pat: *Node) void {
    const elems = switch (pat.data) {
        .object_pattern => |x| x.elems,
        .array_pattern => |x| x.elems,
        else => return,
    };
    for (elems) |e| {
        if (e.data != .binding_elem) continue;
        const x = e.data.binding_elem;
        if (e.symbol) |s| {
            _ = d.typeOfSymbol(c, s);
            if (x.name.data == .identifier) checkRedeclared(c, e, s, x.name);
        }
        if (x.init) |i| _ = expr.checkExpression(c, i);
        if (x.prop_name) |k| if (k.data == .computed_name) {
            _ = expr.checkExpression(c, k.data.computed_name.expr);
        };
        checkBindings(c, x.name);
    }
}

fn checkParams(c: *Checker, n: *Node) void {
    const f = n.data.func;
    for (f.params) |p| {
        const x = p.data.param;
        for (x.decorators) |dn| _ = expr.checkExpression(c, dn.data.decorator.expr);
        // Signatures without a body are reported by walkTypes, which also reaches the ones in types.
        if (f.body != null) implicitAny(c, p, n);
        if (x.init) |i| {
            const t = expr.checkExpression(c, i);
            if (x.type) |ann| {
                const want = d.typeFromNode(c, ann);
                expr.checkAssignable(c, t, want, i, x.name);
            }
        }
        if (x.name.data != .identifier) {
            // Only the side effects matter: the pattern's type is resolved and cached before its bindings are checked.
            _ = d.typeOfParam(c, p);
            checkBindings(c, x.name);
        }
    }
}

fn checkReturnEnd(c: *Checker, n: *Node) void {
    const f = n.data.func;
    const rn = f.ret orelse return;
    if (f.asterisk) return;
    const b = d.bodyOf(c, n) orelse return;
    const body = b.block;
    if (body.data != .block) return;
    if (rn.data == .type_predicate and rn.data.type_predicate.asserts) return;
    const end = b.end_flow orelse return;
    if (!flow.isReachable(c, end)) return;
    var t = d.typeFromNode(c, rn);
    if (n.mods.async) t = expr.awaitedOf(c, t);
    if (T.isAny(t) or t.data == .void or t.data == .unknown or t.data == .undefined) return;
    if (t.data == .union_) for (t.data.union_) |m| {
        if (m.data == .void or m.data == .any or m.data == .undefined) return;
    };
    if (t.data == .never) {
        err(c, rn, 2534, "A function returning 'never' cannot have a reachable end point.");
        return;
    }
    if (t.vars and t.data != .union_ and t.data != .obj) {
        if (!hasReturnValue(body)) err(c, rn, 2355, "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.");
        return;
    }
    if (hasReturnValue(body)) {
        err(c, rn, 2366, "Function lacks ending return statement and return type does not include 'undefined'.");
    } else {
        err(c, rn, 2355, "A function whose declared type is neither 'undefined', 'void', nor 'any' must return a value.");
    }
}

const RetScan = struct { found: bool = false };

fn scanRet(s: *RetScan, n: *Node) void {
    switch (n.data) {
        .func, .class => return,
        .return_stmt => |x| if (x.expr != null) {
            s.found = true;
        },
        .throw_stmt => {},
        else => {},
    }
    ast.forEachChild(n, s, scanRet);
}

fn hasReturnValue(body: *Node) bool {
    var s = RetScan{};
    ast.forEachChild(body, &s, scanRet);
    return s.found;
}

fn checkFuncBody(c: *Checker, n: *Node) void {
    const f = n.data.func;
    // First, since a parameter's default can name what the block declares.
    const fbody = d.bodyOf(c, n);
    expr.assignContext(c, n);
    checkParams(c, n);
    for (f.decorators) |x| _ = expr.checkExpression(c, x.data.decorator.expr);
    if (f.name) |nm| if (nm.data == .computed_name) {
        _ = expr.checkExpression(c, nm.data.computed_name.expr);
    };
    const body = (fbody orelse return).block;
    if (body.data == .block) {
        checkBlock(c, body.data.block.stmts);
        checkReturnEnd(c, n);
    } else {
        const t = expr.checkExpression(c, body);
        if (f.ret) |r| if (!f.asterisk) {
            var want = d.typeFromNode(c, r);
            if (n.mods.async) {
                want = expr.awaitedOf(c, want);
                expr.checkAssignable(c, expr.awaitedOf(c, t), want, body, body);
            } else if (r.data != .type_predicate) expr.checkAssignable(c, t, want, body, body);
        };
    }
}

fn checkReturn(c: *Checker, n: *Node) void {
    const x = n.data.return_stmt;
    var cur = n.parent;
    var fnode: ?*Node = null;
    while (cur) |y| : (cur = y.parent) {
        if (y.data == .func) {
            fnode = y;
            break;
        }
        if (y.data == .class or y.data == .source_file or y.data == .static_block) break;
    }
    const e = x.expr;
    const v: ?*Type = if (e) |i| expr.checkExpression(c, i) else null;
    const fun = fnode orelse return;
    const f = fun.data.func;
    if (f.kind == .setter or f.kind == .ctor) return;
    if (f.ret) |rn| if (rn.data == .type_predicate) {
        if (v) |t| expr.checkAssignable(c, t, c.t_boolean, e, n);
        return;
    };
    var want = if (f.ret == null) d.setterAnnotation(c, fun) orelse return else if (f.asterisk) expr.generatorContext(c, fun, .ret) orelse return else d.typeFromNode(c, f.ret.?);
    if (T.isAny(want)) return;
    var got = v orelse c.t_undefined;
    if (fun.mods.async) {
        want = expr.awaitedOf(c, want);
        got = expr.awaitedOf(c, got);
    }
    if (want.data == .void and e == null) return;
    if (e == null) {
        if (want.data == .undefined or want.data == .unknown) return;
        if (relate.isAssignable(c, c.t_undefined, want)) return;
        err(c, n, 2322, c.fmt("Type 'undefined' is not assignable to type '{s}'.", .{expr.show(c, want)}));
        return;
    }
    expr.checkAssignable(c, got, want, e, n);
}

fn checkVarDecl(c: *Checker, n: *Node) void {
    const v = n.data.var_decl;
    if (v.type) |ann| _ = d.typeFromNode(c, ann);
    if (v.name.data != .identifier) {
        if (v.init) |i| {
            const t = expr.checkExpression(c, i);
            if (v.type) |ann| expr.checkAssignable(c, t, d.typeFromNode(c, ann), i, v.name);
        }
        checkBindings(c, v.name);
        return;
    }
    if (n.symbol) |s| {
        const declared = d.typeOfSymbol(c, s);
        // Exported and ambient variables are read from elsewhere, so no flow can type them.
        if (c.no_implicit_any and v.type == null and v.init == null and declared.data == .err and isPlainDeclaration(n) and !expr.inJs(c, n) and d.isReadElsewhere(c, n.parent.?, n)) {
            expr.err(c, v.name, 7005, c.fmt("Variable '{s}' implicitly has an 'any' type.", .{s.name}));
        }
        checkRedeclared(c, n, s, v.name);
    }
    const i = v.init orelse return;
    const t = expr.checkExpression(c, i);
    if (v.type) |ann| {
        const want = d.typeFromNode(c, ann);
        if (!T.isAny(want)) expr.checkAssignable(c, t, want, i, v.name);
    }
}

/// `var x` can be written many times, and every declaration after the first must agree with it.
fn checkRedeclared(c: *Checker, n: *Node, s0: *Symbol, name: *Node) void {
    const s = s0.resolve();
    const first = s.value_decl orelse return;
    // Without a type for a missing property, `exactOptionalPropertyTypes` could not be told apart.
    if (first == n or s.flags & F.assignment != 0 or expr.inJs(c, n) or c.exact_optional) return;
    const want = declaredAsAny(c, first, d.typeOfSymbol(c, s));
    const got = declaredAsAny(c, n, d.typeOfDeclaration(c, n));
    if (want.data == .err or got.data == .err or relate.isIdentical(c, want, got)) return;
    err(c, name, 2403, c.fmt("Subsequent variable declarations must have the same type.  Variable '{s}' must be of type '{s}', but here has type '{s}'.", .{ s.name, expr.show(c, want), expr.show(c, got) }));
}

/// The stand-ins for a variable with nothing to go on are `any` to everyone who compares it.
fn declaredAsAny(c: *Checker, n: *Node, t: *Type) *Type {
    if (t == c.t_auto) return c.t_any;
    if (t.data != .err or n.data != .var_decl) return t;
    const v = n.data.var_decl;
    return if (v.type == null and v.init == null) c.t_any else t;
}

const node_core = std.StaticStringMap(void).initComptime(.{
    .{"assert"},
    .{"assert/strict"},
    .{"async_hooks"},
    .{"buffer"},
    .{"child_process"},
    .{"cluster"},
    .{"console"},
    .{"constants"},
    .{"crypto"},
    .{"dgram"},
    .{"diagnostics_channel"},
    .{"dns"},
    .{"dns/promises"},
    .{"domain"},
    .{"events"},
    .{"fs"},
    .{"fs/promises"},
    .{"http"},
    .{"http2"},
    .{"https"},
    .{"inspector"},
    .{"inspector/promises"},
    .{"module"},
    .{"net"},
    .{"os"},
    .{"path"},
    .{"path/posix"},
    .{"path/win32"},
    .{"perf_hooks"},
    .{"process"},
    .{"punycode"},
    .{"querystring"},
    .{"readline"},
    .{"readline/promises"},
    .{"repl"},
    .{"stream"},
    .{"stream/consumers"},
    .{"stream/promises"},
    .{"stream/web"},
    .{"string_decoder"},
    .{"sys"},
    .{"timers"},
    .{"timers/promises"},
    .{"tls"},
    .{"trace_events"},
    .{"tty"},
    .{"url"},
    .{"util"},
    .{"util/types"},
    .{"v8"},
    .{"vm"},
    .{"wasi"},
    .{"worker_threads"},
    .{"zlib"},
});

/// These exist in Node only under their `node:` name.
const node_core_prefixed = std.StaticStringMap(void).initComptime(.{
    .{"node:sea"},
    .{"node:sqlite"},
    .{"node:test"},
    .{"node:test/reporters"},
});

fn isNodeCoreModule(name: []const u8) bool {
    if (node_core_prefixed.has(name)) return true;
    return node_core.has(if (std.mem.startsWith(u8, name, "node:")) name[5..] else name);
}

fn isPlainDeclaration(n: *Node) bool {
    const list = n.parent orelse return false;
    if (list.data != .var_list or list.data.var_list.kind == .@"const") return false;
    const st = list.parent orelse return false;
    return st.data == .var_stmt;
}

pub fn checkModuleRef(c: *Checker, n: *Node, spec: *Node) void {
    if (spec.data != .string_lit) return;
    const f = d.fileOf(c, n) orelse return;
    if (f.is_dts) return;
    const sf = c.prog.sourceOf(f) orelse return;
    const name = spec.data.string_lit;
    if (c.prog.resolveModuleName(sf, name) != null) return;
    if (isSideEffectImport(n)) return;
    // Whichever pass asks first is the only one: a type is read once, and silently or not.
    const silent = c.silent;
    c.silent = 0;
    defer c.silent = silent;
    if (isNodeCoreModule(name)) return expr.reportNodeTypes(c, spec, name);
    err(c, spec, 2307, c.fmt("Cannot find module '{s}' or its corresponding type declarations.", .{name}));
}

const import_context = "An import declaration can only be used at the top level of a namespace or module.";

/// A file that does not parse has bigger problems, and a misplaced token is usually a symptom.
fn grammarErr(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    const f = d.fileOf(c, n) orelse return;
    if (f.diags.len == 0) err(c, n, code, msg);
}

/// Reports `n` when it sits outside a file or a module. What it would have checked stays unchecked.
fn misplaced(c: *Checker, n: *Node, code: u32, msg: []const u8) bool {
    const p = n.parent orelse return false;
    if (p.data == .source_file or p.data == .module_block or p.data == .module_decl) return false;
    grammarErr(c, n, code, msg);
    return true;
}

fn isAmbientModule(n: *Node) bool {
    const x = n.data.module_decl;
    return x.is_global or x.name.data == .string_lit;
}

fn canNameModule(c: *Checker, n: *Node, spec: *Node, is_export: bool) bool {
    const p = n.parent orelse return true;
    if (p.data == .source_file or (p.data == .module_block and isAmbientModule(p.parent.?))) return true;
    if (is_export) {
        err(c, spec, 1194, "Export declarations are not permitted in a namespace.");
    } else {
        err(c, spec, 1147, "Import declarations in a namespace cannot reference a module.");
    }
    return false;
}

fn checkExportAssign(c: *Checker, n: *Node) void {
    const x = n.data.export_assign;
    const context = if (x.is_equals) "An export assignment must be at the top level of a file or module declaration." else "A default export must be at the top level of a file or module declaration.";
    if (misplaced(c, n, if (x.is_equals) 1231 else 1258, context)) return;
    const p = n.parent.?;
    if (p.data == .module_block and !isAmbientModule(p.parent.?)) {
        if (x.is_equals) {
            err(c, n, 1063, "An export assignment cannot be used in a namespace.");
        } else {
            err(c, n, 1319, "A default export can only be used in an ECMAScript-style module.");
        }
        return;
    }
    _ = expr.checkExpression(c, x.expr);
}

/// `export` and `declare` mean something only at the top of a file or a module.
fn checkStatementMods(c: *Checker, n: *Node) void {
    const p = n.parent orelse return;
    if (p.data == .source_file or p.data == .module_block) return;
    var m = n.mods;
    switch (n.data) {
        .func => m.async = false,
        .class => m.abstract = false,
        .enum_decl => m.@"const" = false,
        else => {},
    }
    if (m != ast.Mods{}) grammarErr(c, n, 1184, "Modifiers cannot appear here.");
}

fn isSideEffectImport(n: *Node) bool {
    return n.data == .import_decl and n.data.import_decl.clause == null;
}

fn moduleOf(c: *Checker, n: *Node, spec: *Node) ?*Symbol {
    if (spec.data != .string_lit) return null;
    const f = d.fileOf(c, n) orelse return null;
    const sf = c.prog.sourceOf(f) orelse return null;
    return c.prog.resolveModuleName(sf, spec.data.string_lit);
}

fn checkImport(c: *Checker, n: *Node) void {
    const x = n.data.import_decl;
    if (misplaced(c, n, 1232, import_context) or !canNameModule(c, n, x.specifier, false)) return;
    checkModuleRef(c, n, x.specifier);
    const clause = x.clause orelse return;
    const m = moduleOf(c, n, x.specifier) orelse return;
    const cl = clause.data.import_clause;
    if (cl.name != null) {
        if (m.exports != null and c.prog.exportOf(m, "default") == null and c.prog.exportOf(m, "export=") == null) {
            if (!(c.prog.cfg.options.flag("esModuleInterop") or c.prog.cfg.options.flag("allowSyntheticDefaultImports"))) {
                err(c, cl.name.?, 1192, c.fmt("Module '\"{s}\"' has no default export.", .{moduleName(m)}));
            } else if (m.file) |f| if (!f.is_dts) {
                err(c, cl.name.?, 1192, c.fmt("Module '\"{s}\"' has no default export.", .{moduleName(m)}));
            };
        }
    }
    const b = cl.bindings orelse return;
    if (b.data != .named_imports) return;
    if (c.prog.exportOf(m, "export=") != null) return;
    for (b.data.named_imports.elems) |e| {
        if (e.data != .import_spec) continue;
        const s = e.data.import_spec;
        const nm = s.prop_name orelse s.name;
        const name = if (nm.data == .identifier) nm.data.identifier else if (nm.data == .string_lit) nm.data.string_lit else continue;
        if (c.prog.exportOf(m, name) != null) continue;
        missingExport(c, m, nm, name);
    }
}

fn moduleName(m: *Symbol) []const u8 {
    return if (m.file) |f| f.path else m.name;
}

fn missingExport(c: *Checker, m: *Symbol, at: *Node, name: []const u8) void {
    var names = c.newList([]const u8);
    for (d.exportsOf(c, m)) |e| names.append(c.a, e.name) catch oom();
    if (expr.spellingFor(c, name, names.items)) |s| {
        err(c, at, 2724, c.fmt("'\"{s}\"' has no exported member named '{s}'. Did you mean '{s}'?", .{ moduleName(m), name, s }));
        return;
    }
    if (c.prog.exportOf(m, "default") != null) {
        err(c, at, 2614, c.fmt("Module '\"{s}\"' has no exported member '{s}'. Did you mean to use 'import {s} from \"{s}\"' instead?", .{ moduleName(m), name, name, moduleName(m) }));
        return;
    }
    var local = false;
    if (m.file) |f| if (f.root.locals) |l| {
        local = l.get(name) != null;
    };
    if (local) {
        err(c, at, 2459, c.fmt("Module '\"{s}\"' declares '{s}' locally, but it is not exported.", .{ moduleName(m), name }));
    } else {
        err(c, at, 2305, c.fmt("Module '\"{s}\"' has no exported member '{s}'.", .{ moduleName(m), name }));
    }
}

fn checkExportDecl(c: *Checker, n: *Node) void {
    const x = n.data.export_decl;
    if (misplaced(c, n, 1233, "An export declaration can only be used at the top level of a namespace or module.")) return;
    if (x.specifier) |sp| {
        if (!canNameModule(c, n, sp, true)) return;
        checkModuleRef(c, n, sp);
    } else if (n.parent.?.data != .source_file and !d.isAmbient(c, n)) {
        err(c, n, 1194, "Export declarations are not permitted in a namespace.");
    }
    const clause = x.clause orelse return;
    if (clause.data != .named_exports) return;
    const m: ?*Symbol = if (x.specifier) |sp| moduleOf(c, n, sp) else null;
    for (clause.data.named_exports.elems) |e| {
        if (e.data != .export_spec) continue;
        const s = e.data.export_spec;
        const nm = s.prop_name orelse s.name;
        if (nm.data != .identifier) continue;
        const name = nm.data.identifier;
        if (x.specifier != null) {
            if (m) |mm| if (c.prog.exportOf(mm, name) == null and c.prog.exportOf(mm, "export=") == null) missingExport(c, mm, nm, name);
        } else if (d.resolveName(c, n, name, F.value | F.type | F.namespace | F.alias) == null) {
            if (expr.suggestName(c, nm, name, F.value | F.type | F.namespace)) |sug| {
                err(c, nm, 2552, c.fmt("Cannot find name '{s}'. Did you mean '{s}'?", .{ name, sug }));
            } else {
                err(c, nm, 2304, c.fmt("Cannot find name '{s}'.", .{name}));
            }
        }
    }
}

fn checkStmt(c: *Checker, n: *Node) void {
    c.instantiation_count = 0;
    switch (n.data) {
        .block => |x| checkBlock(c, x.stmts),
        .var_stmt => |x| {
            checkStatementMods(c, n);
            checkStmt(c, x.list);
        },
        .var_list => |x| for (x.decls) |v| checkVarDecl(c, v),
        .expr_stmt => |x| _ = expr.checkExpression(c, x.expr),
        .if_stmt => |x| {
            _ = expr.checkExpression(c, x.cond);
            checkStmt(c, x.then);
            if (x.els) |e| checkStmt(c, e);
        },
        .do_stmt => |x| {
            checkStmt(c, x.body);
            _ = expr.checkExpression(c, x.cond);
        },
        .while_stmt => |x| {
            _ = expr.checkExpression(c, x.cond);
            checkStmt(c, x.body);
        },
        .for_stmt => |x| {
            if (x.init) |i| {
                if (i.data == .var_list) checkStmt(c, i) else _ = expr.checkExpression(c, i);
            }
            if (x.cond) |e| _ = expr.checkExpression(c, e);
            if (x.update) |e| _ = expr.checkExpression(c, e);
            checkStmt(c, x.body);
        },
        .for_in => |x| {
            forInit(c, x.init);
            const t = expr.checkExpression(c, x.expr);
            if (!T.isAny(t) and !t.vars and (t.data == .string or t.data == .number or t.data == .bool_lit)) {
                err(c, x.expr, 2407, c.fmt("The right-hand side of a 'for...in' statement must be of type 'any', an object type or a type parameter, but here has type '{s}'.", .{expr.show(c, t)}));
            }
            checkStmt(c, x.body);
        },
        .for_of => |x| {
            forInit(c, x.init);
            const t = expr.checkExpression(c, x.expr);
            _ = expr.iteratedOf(c, x.expr, expr.nonNullReport(c, t, x.expr), x.is_await);
            checkStmt(c, x.body);
        },
        .return_stmt => checkReturn(c, n),
        .with_stmt => |x| _ = expr.checkExpression(c, x.expr),
        .switch_stmt => |x| {
            const t = expr.checkExpression(c, x.expr);
            for (x.clauses) |cl| {
                switch (cl.data) {
                    .case_clause => |k| {
                        const v = expr.checkExpression(c, k.expr);
                        const a = t.regular orelse t;
                        const b = v.regular orelse v;
                        if (!T.isAny(a) and !T.isAny(b) and !relate.isComparable(c, a, b) and !relate.isComparable(c, b, a)) {
                            err(c, k.expr, 2678, c.fmt("Type '{s}' is not comparable to type '{s}'.", .{ expr.show(c, b), expr.show(c, a) }));
                        }
                        checkBlock(c, k.stmts);
                    },
                    .default_clause => |k| checkBlock(c, k.stmts),
                    else => {},
                }
            }
        },
        .labeled => |x| checkStmt(c, x.stmt),
        .throw_stmt => |x| _ = expr.checkExpression(c, x.expr),
        .try_stmt => |x| {
            checkStmt(c, x.block);
            if (x.catch_clause) |cc| {
                const k = cc.data.catch_clause;
                if (k.decl) |v| if (v.data == .var_decl) if (v.data.var_decl.name.data != .identifier) checkBindings(c, v.data.var_decl.name);
                checkStmt(c, k.block);
            }
            if (x.finally) |f| checkStmt(c, f);
        },
        .func => {
            checkStatementMods(c, n);
            checkFuncBody(c, n);
        },
        .class => {
            checkStatementMods(c, n);
            checkClass(c, n);
        },
        .interface => {
            checkStatementMods(c, n);
            checkInterface(c, n);
        },
        .type_alias => |x| {
            checkStatementMods(c, n);
            _ = d.typeFromNode(c, x.type);
        },
        .enum_decl => |x| {
            checkStatementMods(c, n);
            if (n.symbol) |s| _ = d.declaredType(c, s);
            for (x.members) |m| if (m.data.enum_member.init) |i| {
                _ = expr.checkExpression(c, i);
            };
        },
        .module_decl => |x| {
            if (x.body) |b| checkStmt(c, b);
            if (isAmbientModule(n)) {
                _ = misplaced(c, n, 1234, "An ambient module declaration is only allowed at the top level in a file.");
            } else {
                _ = misplaced(c, n, 1235, "A namespace declaration is only allowed at the top level of a namespace or module.");
            }
        },
        .module_block => |x| checkBlock(c, x.stmts),
        .import_decl => checkImport(c, n),
        .export_decl => checkExportDecl(c, n),
        .export_assign => checkExportAssign(c, n),
        .import_equals => |x| if (!misplaced(c, n, 1232, import_context) and x.ref.data == .external_module_ref) {
            const spec = x.ref.data.external_module_ref.expr;
            if (canNameModule(c, n, spec, false)) checkModuleRef(c, n, spec);
        },
        else => {},
    }
    drainDeferred(c);
}

fn forInit(c: *Checker, i: *Node) void {
    if (i.data == .var_list) checkStmt(c, i) else _ = expr.checkExpression(c, i);
}

fn isOverrideOk(c: *Checker, p: *T.Prop, b: *T.Prop) bool {
    return relate.isAssignable(c, d.propType(c, p), d.propType(c, b));
}

fn checkClass(c: *Checker, n: *Node) void {
    const x = n.data.class;
    for (x.decorators) |dn| _ = expr.checkExpression(c, dn.data.decorator.expr);
    const s = n.symbol orelse {
        checkMembers(c, n, x.members);
        return;
    };
    const t = d.declaredType(c, s);
    if (t.data != .obj) return;
    for (x.heritage) |h| {
        if (h.data != .heritage_clause) continue;
        const hc = h.data.heritage_clause;
        for (hc.types) |e| {
            if (hc.tok == .kw_extends) {
                if (e.data == .expr_with_type_args) _ = expr.checkExpression(c, e.data.expr_with_type_args.expr);
            } else {
                _ = d.typeFromNode(c, e);
            }
        }
    }
    checkMembers(c, n, x.members);
    const this_t = if (t.data.obj.thisType()) |tt| d.withThis(c, t, tt) else t;
    checkOverrides(c, n, t, this_t);
    for (d.basesOf(c, t)) |b0| {
        const base = d.withThis(c, b0, t.data.obj.thisType() orelse t);
        if (base.data != .obj) continue;
        for (d.propsOf(c, base)) |bp| {
            if (bp.private) continue;
            const p = d.membersOf(c, this_t).props.get(bp.name) orelse continue;
            if (p == bp or p.decl == bp.decl) continue;
            if (!isOverrideOk(c, p, bp)) {
                const at = if (p.decl) |dn| nameOfMember(dn) else n;
                err(c, at, 2416, c.fmt("Property '{s}' in type '{s}' is not assignable to the same property in base type '{s}'.", .{ p.name, expr.show(c, t), expr.show(c, b0) }));
            }
        }
        checkAbstract(c, n, t, base);
    }
    for (x.heritage) |h| {
        if (h.data != .heritage_clause or h.data.heritage_clause.tok != .kw_implements) continue;
        for (h.data.heritage_clause.types) |e| {
            const it = d.typeFromNode(c, e);
            if (T.isAny(it) or it.data != .obj) continue;
            if (!relate.isAssignable(c, this_t, d.withThis(c, it, t.data.obj.thisType() orelse t))) {
                err(c, e, 2420, c.fmt("Class '{s}' incorrectly implements interface '{s}'.", .{ s.name, expr.show(c, it) }));
            }
        }
    }
    checkPropInit(c, n);
}

/// What `override` is judged against, and whether a member that overrides has to say so.
const Overriding = struct {
    t: *Type,
    this_t: *Type,
    static_t: *Type,
    base: ?*Type = null,
    base_static: *Type,
    required: bool,
};

fn checkOverrides(c: *Checker, n: *Node, t: *Type, this_t: *Type) void {
    if (expr.inJs(c, n)) return;
    const x = n.data.class;
    const required = (c.prog.cfg.options.noImplicitOverride orelse false) and !d.isAmbient(c, n);
    if (!required and !mentionsOverride(x)) return;
    var o: Overriding = .{ .t = t, .this_t = this_t, .static_t = d.typeOfSymbol(c, n.symbol.?), .base_static = c.t_any, .required = required };
    if (extendsNode(x)) |e| {
        const bases = d.basesOf(c, t);
        if (bases.len > 0) {
            o.base = d.withThis(c, bases[0], t.data.obj.thisType() orelse t);
        } else {
            const b = d.classBase(c, e);
            // A class with an `any` base still has one. A missing base means none, while a base
            // the checker could not work out says nothing either way.
            if (b == c.t_err) return;
            if (b.data == .any) o.base = b;
        }
        o.base_static = expr.checkExpression(c, e.data.expr_with_type_args.expr);
    }
    for (x.members) |m| {
        if (m.mods.declare) continue;
        if (m.data == .func and m.data.func.kind == .ctor) {
            for (m.data.func.params) |p| if (isParamProperty(p)) checkOverride(c, o, p, true);
            continue;
        }
        checkOverride(c, o, m, false);
    }
}

fn mentionsOverride(x: anytype) bool {
    for (x.members) |m| {
        if (m.mods.override) return true;
        if (m.data != .func or m.data.func.kind != .ctor) continue;
        for (m.data.func.params) |p| if (p.mods.override) return true;
    }
    return false;
}

fn extendsNode(x: anytype) ?*Node {
    for (x.heritage) |h| {
        if (h.data != .heritage_clause or h.data.heritage_clause.tok != .kw_extends) continue;
        for (h.data.heritage_clause.types) |e| if (e.data == .expr_with_type_args) return e;
    }
    return null;
}

fn isParamProperty(p: *Node) bool {
    return p.mods.public or p.mods.private or p.mods.protected or p.mods.readonly or p.mods.override;
}

fn checkOverride(c: *Checker, o: Overriding, m: *Node, is_param: bool) void {
    const name_node = binder.nameNode(m) orelse return;
    if (name_node.data == .private_name) return;
    const at = if (is_param) m else name_node;
    const marked = m.mods.override;
    const name = expr.propNameOf(c, name_node) orelse {
        if (marked and name_node.data == .computed_name) err(c, at, 4127, "This member cannot have an 'override' modifier because its name is dynamic.");
        return;
    };
    const base = o.base orelse {
        if (marked) err(c, at, 4112, c.fmt("This member cannot have an 'override' modifier because its containing class '{s}' does not extend another class.", .{expr.show(c, o.t)}));
        return;
    };
    if (!marked and !o.required) return;
    const here = if (m.mods.static) o.static_t else o.this_t;
    const above = if (m.mods.static) o.base_static else base;
    if (d.getProp(c, d.getApparent(c, here), name) == null) return;
    const shown = expr.show(c, base);
    const own = d.getApparent(c, above);
    const found = (if (T.isAny(above)) null else d.getProp(c, own, name)) orelse {
        if (!marked) return;
        if (expr.similarProp(c, name, own)) |s| {
            err(c, at, 4117, c.fmt("This member cannot have an 'override' modifier because it is not declared in the base class '{s}'. Did you mean '{s}'?", .{ shown, s }));
        } else {
            err(c, at, 4113, c.fmt("This member cannot have an 'override' modifier because it is not declared in the base class '{s}'.", .{shown}));
        }
        return;
    };
    if (marked or !o.required or found.decl == null) return;
    if (!found.abstract) {
        if (is_param) {
            err(c, at, 4115, c.fmt("This parameter property must have an 'override' modifier because it overrides a member in base class '{s}'.", .{shown}));
        } else {
            err(c, at, 4114, c.fmt("This member must have an 'override' modifier because it overrides a member in the base class '{s}'.", .{shown}));
        }
    } else if (m.mods.abstract) {
        err(c, at, 4116, c.fmt("This member must have an 'override' modifier because it overrides an abstract method that is declared in the base class '{s}'.", .{shown}));
    }
}

fn nameOfMember(n: *Node) *Node {
    return switch (n.data) {
        .func => |f| f.name orelse n,
        .property_decl => |p| p.name,
        .param => |p| p.name,
        else => n,
    };
}

fn checkAbstract(c: *Checker, n: *Node, t: *Type, base: *Type) void {
    if (n.mods.abstract) return;
    var missing = c.newList(*T.Prop);
    for (d.propsOf(c, base)) |bp| {
        if (!bp.abstract) continue;
        const p = d.membersOf(c, t).props.get(bp.name) orelse continue;
        if (p.abstract) missing.append(c.a, bp) catch oom();
    }
    if (missing.items.len == 0) return;
    const nm = n.data.class.name orelse n;
    const cname = if (n.symbol) |s| s.name else "?";
    const bname = expr.show(c, base);
    if (missing.items.len == 1) {
        err(c, nm, 2515, c.fmt("Non-abstract class '{s}' does not implement inherited abstract member '{s}' from class '{s}'.", .{ cname, missing.items[0].name, bname }));
    } else {
        err(c, nm, 2654, c.fmt("Non-abstract class '{s}' is missing implementations for the following members of '{s}'.", .{ cname, bname }));
    }
}

fn hasDefiniteInit(c: *Checker, cls: *Node, name: []const u8) bool {
    for (cls.data.class.members) |m| {
        if (m.data != .func or m.data.func.kind != .ctor) continue;
        const body = d.bodyOf(c, m) orelse continue;
        var s = InitScan{ .c = c, .name = name };
        ast.forEachChild(body.block, &s, scanInit);
        return s.found;
    }
    return false;
}

const InitScan = struct { c: *Checker, name: []const u8, found: bool = false };

/// Any `this.x = …` counts: tsc proves it by flow, but only a miss would be a wrong error.
fn scanInit(s: *InitScan, n: *Node) void {
    if (n.data == .func and n.data.func.kind != .arrow) return;
    if (n.data == .binary and n.data.binary.op == .assign) scanTarget(s, n.data.binary.left);
    ast.forEachChild(n, s, scanInit);
}

/// `[this.a, this.b] = pair()` and `({ x: this.a } = o)` assign just the same.
fn scanTarget(s: *InitScan, n: *Node) void {
    const l = binder.stripParens(n);
    switch (l.data) {
        .prop_access => |x| if (x.expr.data == .this_expr and std.mem.eql(u8, ast.memberText(x.name), s.name)) {
            s.found = true;
        },
        .array_lit => |x| for (x.elems) |e| scanTarget(s, e),
        .object_lit => |x| for (x.props) |p| switch (p.data) {
            .property_assign => |q| scanTarget(s, q.value),
            .spread_assign => |q| scanTarget(s, q.expr),
            else => {},
        },
        .spread_elem => |x| scanTarget(s, x.expr),
        else => {},
    }
}

fn checkPropInit(c: *Checker, n: *Node) void {
    if (!c.strict_prop_init) return;
    if (n.mods.declare) return;
    if (d.fileOf(c, n)) |f| if (f.is_dts) return;
    for (n.data.class.members) |m| {
        if (m.data != .property_decl) continue;
        const p = m.data.property_decl;
        if (m.mods.static or m.mods.abstract or m.mods.declare) continue;
        if (p.init != null or p.question or p.excl) continue;
        const ann = p.type orelse continue;
        const ty = d.typeFromNode(c, ann);
        if (T.isAny(ty) or ty.data == .unknown) continue;
        if (hasUndefinedType(c, ty)) continue;
        const name = ast.memberText(p.name);
        if (name.len == 0) continue;
        if (hasDefiniteInit(c, n, name)) continue;
        err(c, p.name, 2564, c.fmt("Property '{s}' has no initializer and is not definitely assigned in the constructor.", .{name}));
    }
}

fn hasUndefinedType(c: *Checker, t: *Type) bool {
    return relate.isAssignable(c, c.t_undefined, t);
}

fn checkMembers(c: *Checker, cls: *Node, members: []*Node) void {
    _ = cls;
    for (members) |m| {
        switch (m.data) {
            .func => checkFuncBody(c, m),
            .property_decl => |p| {
                for (p.decorators) |dn| _ = expr.checkExpression(c, dn.data.decorator.expr);
                if (p.name.data == .computed_name) _ = expr.checkExpression(c, p.name.data.computed_name.expr);
                if (p.init) |i| {
                    const t = expr.checkExpression(c, i);
                    if (p.type) |ann| {
                        const want = d.typeFromNode(c, ann);
                        expr.checkAssignable(c, t, if (p.question) d.addOptional(c, want) else want, i, p.name);
                    }
                }
            },
            .static_block => |x| checkStmt(c, x.body),
            else => {},
        }
        drainDeferred(c);
    }
}

fn checkInterface(c: *Checker, n: *Node) void {
    const s = n.symbol orelse return;
    const t = d.declaredType(c, s);
    if (t.data != .obj) return;
    for (d.basesOf(c, t)) |b0| {
        const tt = t.data.obj.thisType() orelse t;
        const base = d.withThis(c, b0, tt);
        if (base.data != .obj) continue;
        const this_t = if (t.data.obj.thisType()) |x| d.withThis(c, t, x) else t;
        for (d.propsOf(c, base)) |bp| {
            const p = d.membersOf(c, this_t).props.get(bp.name) orelse continue;
            if (p == bp or p.decl == bp.decl) continue;
            if (!isOverrideOk(c, p, bp)) {
                err(c, n.data.interface.name, 2430, c.fmt("Interface '{s}' incorrectly extends interface '{s}'.", .{ s.name, expr.show(c, b0) }));
                break;
            }
        }
    }
}

fn isTypeNode(n: *Node) bool {
    return switch (n.data) {
        .type_ref, .type_literal, .array_type, .tuple_type, .union_type, .intersection_type, .conditional_type, .type_operator, .indexed_access, .mapped_type, .template_literal_type, .import_type, .type_query, .paren_type => true,
        .func => |f| f.kind == .function_type or f.kind == .constructor_type,
        else => false,
    };
}

/// Every written type gets resolved once, even in positions no expression reaches, because
/// unknown names and bad arguments in types are reported from there and nowhere else.
fn walkTypes(c: *Checker, n: *Node) void {
    if (n.data == .lazy_body) {
        if (d.bodyOf(c, n.parent.?)) |b| walkTypes(c, b.block);
        return;
    }
    if (isAsConst(n)) return;
    if (isTypeNode(n)) _ = d.typeFromNode(c, n);
    if (n.data == .func) {
        // Also covers signature-only declarations, which have no body to check.
        const f = n.data.func;
        if (f.body == null) for (f.params) |p| implicitAny(c, p, n);
    }
    ast.forEachChild(n, c, walkTypes);
}

fn isAsConst(n: *Node) bool {
    if (n.data != .type_ref) return false;
    const p = n.parent orelse return false;
    const t = switch (p.data) {
        .as_expr => |x| x.type,
        .type_assertion => |x| x.type,
        else => return false,
    };
    return t == n and n.data.type_ref.name.data == .identifier and std.mem.eql(u8, n.data.type_ref.name.data.identifier, "const");
}

fn checkFile(c: *Checker, f: *ast.File) void {
    checkBlock(c, f.root.data.source_file.stmts);
    drainDeferred(c);
    walkTypes(c, f.root);
}

/// More runs hold less at once and rebuild lib types more often: 24 costs 0.2 s of CPU per worker.
const runs_per_worker = 24;

/// A fresh checker costs about 20 ms of lib types, which is what 100 KB of source takes to check.
const least_run_bytes = 256 * 1024;

const Work = struct {
    prog: *project.Program,
    runs: [][]*ast.File,
    results: [][]Diag,
    arenas: []std.heap.ArenaAllocator,
};

/// What a checker builds for one run is little use to the next, while keeping it all costs more
/// than the AST does, so each run gets a fresh checker and the worker's arena comes back whole.
fn runFiles(w: *Work, worker: usize, i: usize) void {
    w.results[i] = &.{};
    if (w.prog.body_failed.load(.monotonic)) return;
    const arena = &w.arenas[worker];
    defer _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    const c = Checker.new(a, w.prog);
    d.initGlobals(c);
    for (w.runs[i]) |f| c.owned.put(a, f, {}) catch oom();
    for (w.runs[i]) |f| checkFile(c, f);
    w.results[i] = keepDiags(c.diags.items);
}

/// Workers run these at once, and the driver's allocator is not theirs to share.
fn keepDiags(diags: []const Diag) []Diag {
    const a = std.heap.smp_allocator;
    const out = a.dupe(Diag, diags) catch oom();
    for (out) |*x| x.msg = a.dupe(u8, x.msg) catch oom();
    return out;
}

/// Files that sit together import the same things, so a run of neighbours keeps its checker's
/// lazily built types useful. Runs outnumber workers so that a free worker can take the next one,
/// whatever core it landed on, and they are fixed for a given job count whichever worker takes
/// them, so a run can be reproduced.
fn partition(a: std.mem.Allocator, files: []*ast.File, most: usize) [][]*ast.File {
    const sorted = a.dupe(*ast.File, files) catch oom();
    std.mem.sort(*ast.File, sorted, {}, struct {
        fn less(_: void, l: *ast.File, r: *ast.File) bool {
            return std.mem.lessThan(u8, l.path, r.path);
        }
    }.less);
    const weights = a.alloc(u64, sorted.len) catch oom();
    for (sorted, weights) |f, *w| w.* = f.src.len + 256;
    const runs = pool.schedule.runsByWeight(a, weights, most, least_run_bytes) catch oom();
    const out = a.alloc([]*ast.File, runs.len) catch oom();
    for (runs, out) |r, *o| o.* = sorted[r.start..r.end];
    return out;
}

pub fn checkProgram(a: std.mem.Allocator, p: *project.Program) []Diag {
    var files: std.ArrayList(*ast.File) = .empty;
    const skip_lib = p.cfg.options.skipLibCheck orelse false;
    for (p.files.items) |sf| {
        if (sf.is_lib or sf.read_failed) continue;
        if (sf.file.is_dts and skip_lib) continue;
        files.append(a, sf.file) catch oom();
    }
    if (files.items.len == 0) return &.{};
    const runs = partition(a, files.items, p.tp.width() * runs_per_worker);
    const results = a.alloc([]Diag, runs.len) catch oom();
    const arenas = a.alloc(std.heap.ArenaAllocator, p.tp.width()) catch oom();
    for (arenas) |*x| x.* = .init(std.heap.smp_allocator);
    defer for (arenas) |*x| x.deinit();
    var w = Work{ .prog = p, .runs = runs, .results = results, .arenas = arenas };
    pool.parallelForEach(p.tp, runs.len, &w, runFiles);
    var out: std.ArrayList(Diag) = .empty;
    for (results) |r| out.appendSlice(a, r) catch oom();
    return out.items;
}
