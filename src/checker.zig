//! Statements and declarations, plus the parallel entry point. Each worker owns one `Checker`,
//! which owns all its types; files are partitioned up front so results do not depend on timing.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const project = @import("project.zig");
const pool = @import("pool.zig");
const Bump = @import("bump.zig").Bump;
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
    if (jsDocTyped(c, p)) return;
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

/// JSDoc types are not modeled, so a JavaScript parameter that JSDoc may type stays `any`, silently:
/// a `@param` naming it, or a `@type` or `@overload` on it or on what holds its function.
fn jsDocTyped(c: *Checker, p: *Node) bool {
    const f = d.fileOf(c, p) orelse return false;
    if (!project.isJs(f.path)) return false;
    const name_node = p.data.param.name;
    const name = if (name_node.data == .identifier) name_node.data.identifier else "";
    var n: ?*Node = p;
    while (n) |x| : (n = x.parent) {
        switch (x.data) {
            .block, .source_file, .module_block => return false,
            else => {},
        }
        const doc = jsDocBefore(f.src, x.start) orelse continue;
        if (std.mem.indexOf(u8, doc, "@type") != null or std.mem.indexOf(u8, doc, "@overload") != null) return true;
        if (name.len > 0 and documentsParam(doc, name)) return true;
    }
    return false;
}

fn jsDocBefore(src: []const u8, pos: u32) ?[]const u8 {
    const before = std.mem.trimEnd(u8, src[0..@min(pos, src.len)], " \t\r\n");
    if (!std.mem.endsWith(u8, before, "*/")) return null;
    const open = std.mem.lastIndexOf(u8, before[0 .. before.len - 2], "/*") orelse return null;
    if (!std.mem.startsWith(u8, before[open..], "/**")) return null;
    return before[open..];
}

/// `@param {T} name`, `@param [name]` and the `@arg` and `@argument` spellings.
fn documentsParam(doc: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, doc, i, '@')) |at| {
        i = at + 1;
        var rest = doc[i..];
        const tag_end = std.mem.indexOfAny(u8, rest, " \t\r\n{") orelse rest.len;
        const tag = rest[0..tag_end];
        if (!std.mem.eql(u8, tag, "param") and !std.mem.eql(u8, tag, "arg") and !std.mem.eql(u8, tag, "argument")) continue;
        rest = std.mem.trimStart(u8, rest[tag_end..], " \t\r\n*");
        if (std.mem.startsWith(u8, rest, "{")) {
            var depth: usize = 0;
            var k: usize = 0;
            while (k < rest.len) : (k += 1) {
                if (rest[k] == '{') depth += 1;
                if (rest[k] == '}') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            rest = std.mem.trimStart(u8, rest[@min(k + 1, rest.len)..], " \t\r\n*");
        }
        if (std.mem.startsWith(u8, rest, "[")) rest = rest[1..];
        if (std.mem.startsWith(u8, rest, name)) {
            const after = rest[name.len..];
            if (after.len == 0 or !(std.ascii.isAlphanumeric(after[0]) or after[0] == '_' or after[0] == '$')) return true;
        }
    }
    return false;
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
        if (e.symbol()) |s| {
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
    if (n.symbol()) |s| {
        const declared = d.typeOfSymbol(c, s);
        // Exported and ambient variables are read from elsewhere, so no flow can type them.
        if (c.no_implicit_any and v.type == null and v.init == null and declared.data == .err and isPlainDeclaration(n) and !expr.inJs(c, n) and d.isReadElsewhere(c, n.parent.?, n)) {
            expr.err(c, v.name, 7005, c.fmt("Variable '{s}' implicitly has an 'any' type.", .{s.name}));
        }
        checkRedeclared(c, n, s, v.name);
    }
    const i = v.init orelse return;
    if (v.type == null) if (c.settled_inits.get(i)) |funcs| return expr.deferQuietFuncs(c, i, funcs);
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
    // Exporting a name that is only a type or a namespace is fine; tsc checks it as a value
    // only when it is one or does not resolve.
    if (x.expr.data == .identifier) if (d.resolveName(c, x.expr, x.expr.data.identifier, F.value | F.@"type" | F.namespace | F.alias)) |s| {
        const target = d.targetOf(c, s) orelse s;
        if (target.flags & F.value == 0) return;
    };
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
    if (m.file) |f| if (f.root.locals()) |l| {
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
            if (n.symbol()) |s| _ = d.declaredType(c, s);
            for (x.members) |m| {
                const member = m.data.enum_member;
                if (member.name.data == .computed_name) _ = expr.checkExpression(c, member.name.data.computed_name.expr);
                if (member.init) |i| _ = expr.checkExpression(c, i);
            }
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
    const s = n.symbol() orelse {
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
            const p = d.ownProp(c, this_t, bp.name) orelse continue;
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
    checkIndexConstraints(c, this_t, s, n, false);
    checkIndexConstraints(c, d.typeOfSymbol(c, s), s, n, true);
    checkPropInit(c, n);
}

// ---- index signatures: tsc's checkIndexConstraints ----

/// Declared directly in the type being checked rather than inherited.
fn declaredIn(decl: ?*Node, owner: ?*Symbol, node: *Node) bool {
    const p = (decl orelse return false).parent orelse return false;
    if (p == node) return true;
    const o = owner orelse return false;
    const s = p.symbol() orelse return false;
    return s.resolve() == o.resolve();
}

/// The index signatures whose key a property name falls under.
fn appliesTo(c: *Checker, key: *Type, name: []const u8) bool {
    if (key == c.t_string) return true;
    if (key == c.t_number) return expr.isNumericName(c, name);
    if (key.data == .tmpl or key.data == .strmap) return relate.isAssignable(c, c.strLit(name), key);
    return false;
}

fn appliesToIndex(c: *Checker, key: *Type, other: *Type) bool {
    return relate.isAssignable(c, other, key) or (key == c.t_string and relate.isAssignable(c, other, c.t_number));
}

/// The interface can stand as the error site only when no single base brought both sides along.
fn interfaceSite(c: *Checker, t: *Type, node: *Node, prop: ?[]const u8, key: *Type, other: *Type) ?*Node {
    if (node.data != .interface) return null;
    for (d.basesOf(c, t)) |b| {
        const has_left = if (prop) |name| d.getProp(c, b, name) != null else d.indexValue(c, b, key) != null;
        if (has_left and d.indexValue(c, b, other) != null) return null;
    }
    return node.data.interface.name;
}

fn checkIndexConstraints(c: *Checker, t: *Type, owner: ?*Symbol, node: *Node, is_static: bool) void {
    const infos = d.indexesOf(c, t);
    if (infos.len == 0) return;
    for (d.propsOf(c, t)) |p| {
        if (is_static and std.mem.eql(u8, p.name, "prototype")) continue;
        if (p.name.len > 0 and (p.name[0] == '#' or std.mem.startsWith(u8, p.name, "__@"))) continue;
        const local_prop = declaredIn(p.decl, owner, node);
        const pt = d.propType(c, p);
        for (infos) |info| {
            if (!appliesTo(c, info.key, p.name)) continue;
            const site = if (local_prop) binder.nameNode(p.decl.?) orelse p.decl.? else if (declaredIn(info.decl, owner, node)) info.decl.? else interfaceSite(c, t, node, p.name, info.key, info.key) orelse continue;
            if (relate.isAssignable(c, pt, info.ty)) continue;
            err(c, site, 2411, c.fmt("Property '{s}' of type '{s}' is not assignable to '{s}' index type '{s}'.", .{ p.name, expr.show(c, pt), expr.show(c, info.key), expr.show(c, info.ty) }));
        }
    }
    if (infos.len < 2) return;
    for (infos) |check| {
        const local_check = declaredIn(check.decl, owner, node);
        for (infos) |info| {
            if (info.key == check.key or !appliesToIndex(c, info.key, check.key)) continue;
            const site = if (local_check) check.decl.? else if (declaredIn(info.decl, owner, node)) info.decl.? else interfaceSite(c, t, node, null, check.key, info.key) orelse continue;
            if (relate.isAssignable(c, check.ty, info.ty)) continue;
            err(c, site, 2413, c.fmt("'{s}' index type '{s}' is not assignable to '{s}' index type '{s}'.", .{ expr.show(c, check.key), expr.show(c, check.ty), expr.show(c, info.key), expr.show(c, info.ty) }));
        }
    }
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
    var o: Overriding = .{ .t = t, .this_t = this_t, .static_t = d.typeOfSymbol(c, n.symbol().?), .base_static = c.t_any, .required = required };
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
        const p = d.ownProp(c, t, bp.name) orelse continue;
        if (p.abstract) missing.append(c.a, bp) catch oom();
    }
    if (missing.items.len == 0) return;
    const nm = n.data.class.name orelse n;
    const cname = if (n.symbol()) |s| s.name else "?";
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
    const s = n.symbol() orelse return;
    const t = d.declaredType(c, s);
    if (t.data != .obj) return;
    // tsc checks a merged interface once, at its first declaration.
    const first = for (s.resolve().decls) |x| {
        if (x.data == .interface) break x;
    } else n;
    if (first == n) checkIndexConstraints(c, if (t.data.obj.thisType()) |x| d.withThis(c, t, x) else t, s, n, false);
    for (d.basesOf(c, t)) |b0| {
        const tt = t.data.obj.thisType() orelse t;
        const base = d.withThis(c, b0, tt);
        if (base.data != .obj) continue;
        const this_t = if (t.data.obj.thisType()) |x| d.withThis(c, t, x) else t;
        for (d.propsOf(c, base)) |bp| {
            const p = d.ownProp(c, this_t, bp.name) orelse continue;
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
    checkStrictMode(c, n);
    if (isTypeNode(n)) {
        const t = d.typeFromNode(c, n);
        if (n.data == .type_literal) checkIndexConstraints(c, t, null, n, false);
    }
    if (n.data == .func) {
        // Also covers signature-only declarations, which have no body to check.
        const f = n.data.func;
        if (f.body == null) for (f.params) |p| implicitAny(c, p, n);
    }
    ast.forEachChild(n, c, walkTypes);
}

// ---- strict mode, which TypeScript 7 code is always in: tsc's binder checks ----

const future_reserved = std.StaticStringMap(void).initComptime(.{
    .{"implements"}, .{"interface"}, .{"let"}, .{"package"}, .{"private"}, .{"protected"}, .{"public"}, .{"static"}, .{"yield"},
});

fn checkStrictMode(c: *Checker, n: *Node) void {
    switch (n.data) {
        .identifier => |name| if (future_reserved.has(name) or std.mem.eql(u8, name, "await")) reservedWord(c, n, name),
        .func => |f| if (f.kind == .decl or f.kind == .expr) if (f.name) |x| if (!isAmbient(c, n)) evalOrArguments(c, n, x),
        .param => |x| if (!isAmbient(c, n)) evalOrArguments(c, n, x.name),
        .var_decl => |x| evalOrArguments(c, n, x.name),
        .binding_elem => |x| evalOrArguments(c, n, x.name),
        .binary => |x| if (x.op.isAssignment()) evalOrArguments(c, n, x.left),
        .prefix => |x| if (x.op == .plus2 or x.op == .minus2) evalOrArguments(c, n, x.expr),
        .postfix => |x| evalOrArguments(c, n, x.expr),
        // A missing operand is already a syntax error.
        .delete_expr => |x| if (x.expr.data == .identifier and x.expr.data.identifier.len > 0) {
            err(c, x.expr, 1102, "'delete' cannot be called on an identifier in strict mode.");
        },
        .with_stmt => if (!isAmbient(c, n)) d.reportSpan(c, n, n.start, n.start + 4, 1101, "'with' statements are not allowed in strict mode."),
        .labeled => |x| if (isDeclarationStatement(x.stmt)) err(c, x.label, 1344, "A label is not allowed here."),
        else => {},
    }
}

fn evalOrArguments(c: *Checker, context: *Node, name: *Node) void {
    if (name.data != .identifier) return;
    const text = name.data.identifier;
    if (!std.mem.eql(u8, text, "eval") and !std.mem.eql(u8, text, "arguments")) return;
    if (containingClass(context)) {
        err(c, name, 1210, c.fmt("Code contained in a class is evaluated in JavaScript's strict mode which does not allow this use of '{s}'. For more information, see https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode.", .{text}));
    } else if (inModule(c, name)) {
        err(c, name, 1215, c.fmt("Invalid use of '{s}'. Modules are automatically in strict mode.", .{text}));
    } else {
        err(c, name, 1100, c.fmt("Invalid use of '{s}' in strict mode.", .{text}));
    }
}

/// tsc's `checkContextualIdentifier`, which keeps quiet in a file that does not parse.
fn reservedWord(c: *Checker, n: *Node, name: []const u8) void {
    const f = d.fileOf(c, n) orelse return;
    if (f.diags.len != 0 or f.bad_body or isIdentifierName(n) or isAmbient(c, n)) return;
    if (std.mem.eql(u8, name, "await")) {
        if (f.is_module and inTopLevelContext(n)) err(c, n, 1262, "Identifier expected. 'await' is a reserved word at the top-level of a module.");
        return;
    }
    if (containingClass(n)) {
        err(c, n, 1213, c.fmt("Identifier expected. '{s}' is a reserved word in strict mode. Class definitions are automatically in strict mode.", .{name}));
    } else if (f.is_module) {
        err(c, n, 1214, c.fmt("Identifier expected. '{s}' is a reserved word in strict mode. Modules are automatically in strict mode.", .{name}));
    } else {
        err(c, n, 1212, c.fmt("Identifier expected. '{s}' is a reserved word in strict mode.", .{name}));
    }
}

/// Names that are not bindings or references: property names, and what JSX and exports spell out.
fn isIdentifierName(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .property_decl => |x| x.name == n,
        .property_sig => |x| x.name == n,
        .enum_member => |x| x.name == n,
        .property_assign => |x| x.name == n,
        .prop_access => |x| x.name == n,
        .qualified_name => |x| x.right == n,
        .binding_elem => |x| x.prop_name == n,
        .import_spec => |x| x.prop_name == n,
        .func => |x| x.name == n and switch (x.kind) {
            .method, .method_sig, .getter, .setter, .getter_sig, .setter_sig => true,
            else => false,
        },
        .export_spec, .jsx_attr, .jsx_self_closing, .jsx_opening, .jsx_closing => true,
        else => false,
    };
}

fn isAmbient(c: *Checker, n: *Node) bool {
    if (d.fileOf(c, n)) |f| if (f.is_dts) return true;
    var x: ?*Node = n;
    while (x) |y| : (x = y.parent) if (y.mods.declare) return true;
    return false;
}

fn inModule(c: *Checker, n: *Node) bool {
    const f = d.fileOf(c, n) orelse return false;
    return f.is_module;
}

fn containingClass(n: *Node) bool {
    var x = n.parent;
    while (x) |y| : (x = y.parent) if (y.data == .class) return true;
    return false;
}

/// tsc's `isInTopLevelContext`: no function, class property, static block or namespace between
/// `n` and its file.
fn inTopLevelContext(n0: *Node) bool {
    var n = n0;
    if (n.parent) |p| switch (p.data) {
        .func => |x| if (x.kind == .decl and x.name == n) {
            n = p;
        },
        .class => |x| if (!x.is_expr and x.name == n) {
            n = p;
        },
        else => {},
    };
    var x = n.parent;
    while (x) |y| : (x = y.parent) switch (y.data) {
        .func, .property_decl, .static_block, .module_decl => return false,
        else => {},
    };
    return true;
}

fn isDeclarationStatement(n: *Node) bool {
    return switch (n.data) {
        .func => |x| x.kind == .decl,
        .class => |x| !x.is_expr,
        .var_stmt, .interface, .type_alias, .enum_decl, .module_decl, .import_equals, .namespace_export_decl => true,
        else => false,
    };
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
    forgetBodies(c);
}

/// These answer for nodes inside bodies, and a checked file's bodies are not asked about again:
/// what other files need from them lives on its symbols. Tables grown for one file would otherwise
/// keep growing, and they make up a fifth of what a run allocates.
fn forgetBodies(c: *Checker) void {
    c.name_syms.clearRetainingCapacity();
    c.resolved_calls.clearRetainingCapacity();
    c.call_results.clearRetainingCapacity();
    c.effects.clearRetainingCapacity();
    c.flow_cache.clearRetainingCapacity();
    c.reach_cache.clearRetainingCapacity();
    c.ref_answers.clearRetainingCapacity();
    c.const_keys.clearRetainingCapacity();
    c.constant_refs.clearRetainingCapacity();
    c.logical_left.clearRetainingCapacity();
    c.sensitive_args.clearRetainingCapacity();
    c.elem_index.clearRetainingCapacity();
}

/// More runs hold less at once and rebuild lib types more often. On VS Code 24 holds a quarter less
/// than 16 for 2% more cycles; what each worker holds is the larger part of the peak.
const runs_per_worker = 24;

/// A fresh checker costs about 20 ms of lib types, which is what 100 KB of source takes to check.
const least_run_bytes = 256 * 1024;

const Work = struct {
    prog: *project.Program,
    runs: [][]*ast.File,
    turns: []const u32,
    results: [][]Diag,
    bumps: []Bump,
};

/// What a checker builds for one run is little use to the next, while keeping it all costs more
/// than the AST does, so each run gets a fresh checker and the worker's memory comes back whole.
fn runFiles(w: *Work, worker: usize, turn: usize) void {
    const i = w.turns[turn];
    w.results[i] = &.{};
    if (w.prog.body_failed.load(.monotonic)) return;
    const bump = &w.bumps[worker];
    defer bump.reset();
    const a = bump.allocator();
    const c = Checker.new(a, w.prog);
    d.initGlobals(c);
    var source: usize = 0;
    for (w.runs[i]) |f| {
        c.owned.put(a, f, {}) catch oom();
        source += f.src.len;
    }
    c.reserveFor(source);
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

/// The order to take runs in. A run's memory follows its source, and the largest are neighbours in
/// the heaviest directories, so in path order they are all up at once and that is the peak. Dealing
/// them out by a step near the golden ratio of the count keeps any few of them far apart. Workers
/// start together, so the first of them get the smallest runs, or they would all top out at once.
fn spreadTurns(a: std.mem.Allocator, runs: []const []*ast.File, workers: usize) []u32 {
    const sizes = a.alloc(u64, runs.len) catch oom();
    const by_size = a.alloc(u32, runs.len) catch oom();
    for (runs, sizes, by_size, 0..) |r, *s, *x, i| {
        s.* = 0;
        for (r) |f| s.* += f.src.len;
        x.* = @intCast(i);
    }
    std.mem.sort(u32, by_size, sizes, struct {
        fn more(ctx: []const u64, l: u32, r: u32) bool {
            return if (ctx[l] != ctx[r]) ctx[l] > ctx[r] else l < r;
        }
    }.more);
    const turns = a.alloc(u32, runs.len) catch oom();
    const first = @min(workers, runs.len);
    const rest = runs.len - first;
    @memcpy(turns[0..first], by_size[rest..]);
    if (rest == 0) return turns;
    var step = rest * 618 / 1000 | 1;
    while (std.math.gcd(step, rest) != 1) step += 2;
    for (by_size[0..rest], 0..) |run, k| turns[first + k * step % rest] = run;
    return turns;
}

pub fn checkProgram(a: std.mem.Allocator, p: *project.Program) []Diag {
    var files: std.ArrayList(*ast.File) = .empty;
    const skip_lib = p.cfg.options.skipLibCheck orelse false;
    for (p.files.items) |sf| {
        if (sf.is_lib or sf.read_failed) continue;
        if (sf.file.is_dts and skip_lib) continue;
        if (p.cfg.options.semantics(sf.file) == .none) continue;
        files.append(a, sf.file) catch oom();
    }
    if (files.items.len == 0) return &.{};
    const runs = partition(a, files.items, p.tp.width() * runs_per_worker);
    const results = a.alloc([]Diag, runs.len) catch oom();
    const bumps = a.alloc(Bump, p.tp.width()) catch oom();
    for (bumps) |*x| x.* = .init(std.heap.smp_allocator);
    defer for (bumps) |*x| x.deinit();
    var w = Work{ .prog = p, .runs = runs, .turns = spreadTurns(a, runs, p.tp.width()), .results = results, .bumps = bumps };
    pool.parallelForEach(p.tp, runs.len, &w, runFiles);
    var out: std.ArrayList(Diag) = .empty;
    for (results) |r| out.appendSlice(a, r) catch oom();
    return out.items;
}
