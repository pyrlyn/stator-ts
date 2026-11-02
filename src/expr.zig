//! Types of expressions: names, member access, operators, literals, contextual typing and calls.
const std = @import("std");
const project = @import("project.zig");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const lexer = @import("lexer.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const spelling = @import("spelling.zig");
const relate = @import("relate.zig");
const flow = @import("flow.zig");
const unused = @import("unused.zig");
const print = @import("print.zig");
const emit = @import("emit.zig");
const checker = @import("checker.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Tok = lexer.Tok;
const Checker = T.Checker;
const Type = T.Type;
const Sig = T.Sig;
const Prop = T.Prop;
const InferCtx = T.InferCtx;
const oom = T.oom;

pub fn show(c: *Checker, t: *Type) []const u8 {
    // Spelling out a type reads what is inside it, and no message can make a declaration circular.
    c.pushResolution(null);
    defer _ = c.popResolution();
    return print.typeToString(c, t);
}

pub fn err(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    if (quiet(c)) return;
    d.report(c, n, code, msg);
}

fn errSpan(c: *Checker, n: *Node, start: u32, end: u32, code: u32, msg: []const u8) void {
    if (quiet(c)) return;
    d.reportSpan(c, n, start, end, code, msg);
}

/// Whether this visit is quiet, in which case what it was about to do is owed to one in the open.
pub fn quiet(c: *Checker) bool {
    if (c.silent == 0) return false;
    c.quiet_debt += 1;
    return true;
}

pub fn checkExpression(c: *Checker, n: *Node) *Type {
    return checkExpr(c, n);
}

/// A declaration's type is read from its initializer before the declaration's own turn comes, and
/// that turn has nothing to add when the first visit was in the open or owes it nothing.
pub fn checkInit(c: *Checker, n: *Node) *Type {
    // Its arguments are not visited, so the declaration's own turn still has them to check.
    if (quickType(c, n)) |t| return t;
    const debt = c.quiet_debt;
    const funcs = c.quiet_funcs.items.len;
    const cycles = c.cycles;
    const t = checkExpr(c, n);
    if (c.flow_active.count() == 0 and (c.silent == 0 or c.quiet_debt == debt) and c.cycles == cycles) {
        c.settled_inits.put(c.a, n, c.dupe(*Node, c.quiet_funcs.items[funcs..])) catch oom();
    }
    return t;
}

/// The lambdas a quiet visit passed over inside `root`, for a visit in the open that will not happen.
/// A lambda inside another one is left to the body around it.
pub fn deferQuietFuncs(c: *Checker, root: *Node, funcs: []const *Node) void {
    for (funcs) |f| {
        var cur = f;
        const inside = while (cur != root) {
            cur = cur.parent orelse break false;
            if (cur != root and (cur.data == .func or cur.data == .class)) break false;
        } else true;
        if (!inside) continue;
        const gop = c.checked_funcs.getOrPut(c.a, f) catch oom();
        if (!gop.found_existing) c.deferred.append(c.a, f) catch oom();
    }
}

/// What an initializer comes to without looking at its arguments, so a declaration they mention
/// has its type already: `const f = run(() => f)` is not a cycle.
fn quickType(c: *Checker, n: *Node) ?*Type {
    const x = binder.skipParens(n);
    return switch (x.data) {
        .await_expr => |y| if (quickType(c, y.expr)) |t| awaitedOf(c, t) else null,
        .as_expr => |y| if (isConstRef(y.type)) null else d.typeFromNode(c, y.type),
        .type_assertion => |y| if (isConstRef(y.type)) null else d.typeFromNode(c, y.type),
        .call => |y| blk: {
            const special = y.callee.data == .import_kw or y.callee.data == .super_expr or namesSymbol(y.callee) or isRequireCall(x, true);
            if (special or y.optional or flow.isOptionalChain(y.callee)) break :blk null;
            const t = nonNull(c, checkSilent(c, y.callee));
            if (t.data != .obj) break :blk null;
            const m = d.shallowMembers(c, t);
            if (m.calls.len != 1 or m.calls[0].tparams.len != 0 or m.ctors.len != 0 or m.indexes.len != 0 or !d.hasNoProps(c, t)) break :blk null;
            break :blk d.returnOf(c, m.calls[0]);
        },
        .new_expr => |y| blk: {
            const t = nonNull(c, checkSilent(c, y.callee));
            if (t.data != .obj or d.callSigs(c, t).len != 0) break :blk null;
            const sigs = d.ctorSigs(c, t);
            if (sigs.len != 1 or sigs[0].tparams.len != 0) break :blk null;
            break :blk d.returnOf(c, sigs[0]);
        },
        else => null,
    };
}

/// tsc's `isRequireCall`, which asks for a string argument only where the module is resolved.
fn isRequireCall(n: *Node, string_arg: bool) bool {
    if (n.data != .call) return false;
    const x = n.data.call;
    if (x.callee.data != .identifier or !std.mem.eql(u8, x.callee.data.identifier, "require")) return false;
    return x.args.len == 1 and (!string_arg or x.args[0].data == .string_lit or x.args[0].data == .no_subst_template);
}

/// Types an expression without reporting: narrowing reads operands the statement walker visits anyway.
pub fn checkSilent(c: *Checker, n: *Node) *Type {
    c.silent += 1;
    defer c.silent -= 1;
    return checkExpr(c, n);
}

// ---- symbols ----

pub fn symbolOf(c: *Checker, n: *Node) ?*Symbol {
    if (c.name_syms.get(n)) |s| return s;
    const s = d.resolveName(c, n, n.data.identifier, F.value | F.alias);
    c.name_syms.put(c.a, n, s) catch oom();
    return s;
}

const hints = std.StaticStringMap(u32).initComptime(.{
    .{ "process", 2580 },                .{ "require", 2580 },       .{ "Buffer", 2580 },                .{ "module", 2580 },
    .{ "$", 2581 },                      .{ "describe", 2582 },      .{ "suite", 2582 },                 .{ "it", 2582 },
    .{ "test", 2582 },                   .{ "document", 2584 },      .{ "console", 2584 },               .{ "Map", 2583 },
    .{ "Set", 2583 },                    .{ "Promise", 2583 },       .{ "Symbol", 2583 },                .{ "WeakMap", 2583 },
    .{ "WeakSet", 2583 },                .{ "Iterator", 2583 },      .{ "AsyncIterator", 2583 },         .{ "SharedArrayBuffer", 2583 },
    .{ "Atomics", 2583 },                .{ "AsyncIterable", 2583 }, .{ "AsyncIterableIterator", 2583 }, .{ "AsyncGenerator", 2583 },
    .{ "AsyncGeneratorFunction", 2583 }, .{ "BigInt", 2583 },        .{ "Reflect", 2583 },               .{ "BigInt64Array", 2583 },
    .{ "BigUint64Array", 2583 },         .{ "beforeEach", 2582 },
});

/// Under `"*"` every installed package is already in, so tsc 7 stops asking for an entry in `types`.
fn sweepsTypes(c: *Checker) bool {
    for (c.prog.cfg.options.types orelse return false) |t| {
        if (std.mem.eql(u8, t, "*")) return true;
    }
    return false;
}

/// A missing Node global and an import of a Node module have one cure, so tsc words them alike.
pub fn reportNodeTypes(c: *Checker, n: *Node, name: []const u8) void {
    if (sweepsTypes(c)) {
        err(c, n, 2580, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node`.", .{name}));
    } else {
        err(c, n, 2591, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for node? Try `npm i --save-dev @types/node` and then add 'node' to the types field in your tsconfig.", .{name}));
    }
}

fn suggestIn(c: *Checker, table: *binder.SymbolTable, name: []const u8, meaning: u32, primitives: bool) ?[]const u8 {
    var list = c.newList([]const u8);
    if (primitives) for ([_][2][]const u8{ .{ "string", "String" }, .{ "number", "Number" }, .{ "boolean", "Boolean" }, .{ "object", "Object" }, .{ "bigint", "BigInt" }, .{ "symbol", "Symbol" } }) |p| {
        if (table.contains(p[1])) list.append(c.a, p[0]) catch oom();
    };
    var it = table.map.keyIterator();
    while (it.next()) |e| {
        const s = e.*;
        const flags = if (s.flags & F.alias != 0) (if (d.targetOf(c, s)) |t| t.flags else 0) else s.flags;
        if (flags & meaning != 0 and !std.mem.startsWith(u8, s.name, "\"")) list.append(c.a, s.name) catch oom();
    }
    return spelling.best(c.a, name, list.items);
}

/// Scopes are tried from the inside out and the first with a close name wins, as in tsc.
pub fn suggestName(c: *Checker, from: *Node, name: []const u8, meaning: u32) ?[]const u8 {
    var cur: ?*Node = from;
    while (cur) |n| : (cur = n.parent) {
        if (d.localsOf(c, n)) |l| if (suggestIn(c, l, name, meaning, false)) |s| return s;
        if (n.data == .module_decl) if (n.symbol()) |sym| if (sym.resolve().exports) |e| {
            if (suggestIn(c, e, name, meaning, false)) |s| return s;
        };
    }
    return suggestIn(c, c.prog.globals, name, meaning, true);
}

fn unresolved(c: *Checker, n: *Node, name: []const u8) *Type {
    for ([_][]const u8{ "any", "string", "number", "boolean", "never", "unknown" }) |primitive| {
        if (std.mem.eql(u8, name, primitive)) {
            err(c, n, 2693, c.fmt("'{s}' only refers to a type, but is being used as a value here.", .{name}));
            return c.t_err;
        }
    }
    if (d.resolveName(c, n, name, F.type) != null) {
        for ([_][]const u8{ "Promise", "Symbol", "Map", "WeakMap", "Set", "WeakSet" }) |since_es2015| {
            if (!std.mem.eql(u8, name, since_es2015)) continue;
            err(c, n, 2585, c.fmt("'{s}' only refers to a type, but is being used as a value here. Do you need to change your target library? Try changing the 'lib' compiler option to es2015 or later.", .{name}));
            return c.t_err;
        }
        err(c, n, 2693, c.fmt("'{s}' only refers to a type, but is being used as a value here.", .{name}));
        return c.t_err;
    }
    if (d.resolveName(c, n, name, F.namespace) != null) {
        err(c, n, 2708, c.fmt("Cannot use namespace '{s}' as a value.", .{name}));
        return c.t_err;
    }
    if (commonJsName(c, n, name)) {
        if (!std.mem.eql(u8, name, "module")) return c.t_any;
        // tsc gives `module` a single member; the module's own shape is not modelled yet.
        const m = c.membersFor(1);
        m.props.put(c.a, "exports", c.create(Prop, .{ .name = "exports", .ty = c.t_any })) catch oom();
        return c.newObj(.{ .kind = .anon, .members = m });
    }
    if (hints.get(name)) |code| {
        const sweep = sweepsTypes(c);
        switch (code) {
            2580 => reportNodeTypes(c, n, name),
            2581 => if (sweep)
                err(c, n, 2581, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for jQuery? Try `npm i --save-dev @types/jquery`.", .{name}))
            else
                err(c, n, 2592, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for jQuery? Try `npm i --save-dev @types/jquery` and then add 'jquery' to the types field in your tsconfig.", .{name})),
            2582 => if (sweep)
                err(c, n, 2582, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for a test runner? Try `npm i --save-dev @types/jest` or `npm i --save-dev @types/mocha`.", .{name}))
            else
                err(c, n, 2593, c.fmt("Cannot find name '{s}'. Do you need to install type definitions for a test runner? Try `npm i --save-dev @types/jest` or `npm i --save-dev @types/mocha` and then add 'jest' or 'mocha' to the types field in your tsconfig.", .{name})),
            2584 => err(c, n, 2584, c.fmt("Cannot find name '{s}'. Do you need to change your target library? Try changing the 'lib' compiler option to include 'dom'.", .{name})),
            else => err(c, n, 2583, c.fmt("Cannot find name '{s}'. Do you need to change your target library? Try changing the 'lib' compiler option to 'es2015' or later.", .{name})),
        }
        return c.t_unresolved;
    }
    if (suggestName(c, n, name, F.value)) |s| {
        err(c, n, 2552, c.fmt("Cannot find name '{s}'. Did you mean '{s}'?", .{ name, s }));
    } else if (n.parent != null and n.parent.?.data == .shorthand_assign) {
        err(c, n, 18004, c.fmt("No value exists in scope for the shorthand property '{s}'. Either declare one or provide an initializer.", .{name}));
    } else {
        err(c, n, 2304, c.fmt("Cannot find name '{s}'.", .{name}));
    }
    return c.t_unresolved;
}

fn containingFunc(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x.data == .func) return x;
        if (x.data == .property_decl or x.data == .static_block) return x;
    }
    return null;
}

fn isAssignTarget(n0: *Node) bool {
    var n = n0;
    while (n.parent) |p| {
        switch (p.data) {
            .paren, .non_null => n = p,
            .binary => |x| return x.left == n and isAssignOp(x.op),
            .prefix => |x| return x.op == .plus2 or x.op == .minus2,
            .postfix => return true,
            .for_in => |x| return x.init == n,
            .for_of => |x| return x.init == n,
            .array_lit, .object_lit, .spread_elem, .spread_assign => {
                if (!isPatternTarget(p)) return false;
                n = p;
            },
            .property_assign => |x| {
                if (x.value != n) return false;
                n = p;
            },
            .shorthand_assign => n = p,
            else => return false,
        }
    }
    return false;
}

pub fn isPatternTarget(n0: *Node) bool {
    var n = n0;
    while (n.parent) |p| {
        switch (p.data) {
            .binary => |x| return x.left == n and x.op == .assign,
            .for_of => |x| return x.init == n,
            .for_in => |x| return x.init == n,
            .array_lit, .object_lit, .spread_elem, .spread_assign, .paren => n = p,
            .property_assign => |x| {
                if (x.value != n) return false;
                n = p;
            },
            else => return false,
        }
    }
    return false;
}

pub fn isAssignOp(op: Tok) bool {
    return @intFromEnum(op) >= @intFromEnum(Tok.assign) and @intFromEnum(op) <= @intFromEnum(Tok.qq_assign);
}

/// Only code in a binding's scope can assign to it, so a local costs its outermost function and
/// not every block in the file, which would each have to be read.
fn markAssignments(c: *Checker, s: *Symbol) void {
    for (s.decls) |x| {
        var scope = x;
        var top: ?*Node = null;
        while (scope.parent) |p| : (scope = p) {
            if (p.data == .func) top = p;
        }
        const from = top orelse scope;
        const gop = c.assigned_scopes.getOrPut(c.a, from) catch oom();
        if (!gop.found_existing) walkAssign(c, from);
    }
}

fn walkAssign(c: *Checker, n: *Node) void {
    if (n.data == .lazy_body) {
        if (d.bodyOf(c, n.parent.?)) |b| walkAssign(c, b.block);
        return;
    }
    if (n.data == .identifier and isAssignTarget(n)) {
        if (symbolOf(c, n)) |s0| {
            const s = s0.resolve();
            const pos = assignmentEnd(n, s);
            const gop = c.assigned_syms.getOrPut(c.a, s) catch oom();
            gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, pos) else pos;
        }
    }
    ast.forEachChild(n, c, walkAssign);
}

/// Where a binding stops changing: the end of the statements around the assignment, since a
/// loop body can run it again. An assignment from a nested function can happen at any time.
fn assignmentEnd(n: *Node, s: *Symbol) u32 {
    const decl = s.value_decl orelse return std.math.maxInt(u32);
    if (containingFunc(n) != containingFunc(decl)) return std.math.maxInt(u32);
    var pos = n.start;
    var cur: ?*Node = n;
    while (cur) |x| : (cur = x.parent) {
        if (x.start <= decl.start) break;
        switch (x.data) {
            .var_stmt, .expr_stmt, .if_stmt, .do_stmt, .while_stmt, .for_stmt, .for_in, .for_of, .with_stmt, .return_stmt, .try_stmt, .class => pos = x.end,
            else => {},
        }
    }
    return pos;
}

fn isPastLastAssignment(c: *Checker, s: *Symbol, n: *Node) bool {
    markAssignments(c, s);
    const last = c.assigned_syms.get(s.resolve()) orelse return true;
    return last < n.start;
}

/// A closure may run after an assignment it cannot see, unless there is no assignment at all.
fn neverInitialized(c: *Checker, s: *Symbol) bool {
    const n = s.value_decl orelse return false;
    if (n.data != .var_decl) return false;
    const v = n.data.var_decl;
    const l = n.parent orelse return false;
    if (v.init != null or v.excl or l.data != .var_list) return false;
    if (l.parent) |p| if (p.data == .for_of or p.data == .for_in) return false;
    if (!isMutableLocal(c, s)) return false;
    markAssignments(c, s);
    return !c.assigned_syms.contains(s.resolve());
}

pub fn isStableBinding(c: *Checker, s: *Symbol) bool {
    if (isConstVar(s)) return true;
    if (!isMutableLocal(c, s)) return false;
    markAssignments(c, s);
    return !c.assigned_syms.contains(s.resolve());
}

fn isMutableLocal(c: *Checker, s: *Symbol) bool {
    if (s.flags & F.param != 0) return true;
    const n = s.value_decl orelse return false;
    var cur = n;
    while (cur.data == .binding_elem or cur.data == .object_pattern or cur.data == .array_pattern) cur = cur.parent orelse return false;
    if (cur.data == .param) return true;
    if (cur.data != .var_decl) return false;
    const l = cur.parent orelse return false;
    if (l.data == .catch_clause) return true;
    if (l.data != .var_list or l.data.var_list.kind != .let) return false;
    const st = l.parent orelse return false;
    if (st.mods.@"export") return false;
    if (st.data == .var_stmt) if (st.parent) |p| if (p.data == .source_file) if (d.fileOf(c, p)) |f| return f.is_module;
    return true;
}

pub fn isConstVar(s: *Symbol) bool {
    const n = s.value_decl orelse return false;
    var cur = n;
    while (cur.data == .binding_elem or cur.data == .object_pattern or cur.data == .array_pattern) cur = cur.parent orelse return false;
    if (cur.data != .var_decl) return false;
    const l = cur.parent orelse return false;
    return l.data == .var_list and l.data.var_list.kind != .@"var" and l.data.var_list.kind != .let;
}

fn withoutParamOptionality(c: *Checker, declared: *Type, p: *Node) *Type {
    if (!c.strict_null or p.data != .param or !hasUndefined(declared)) return declared;
    const init = p.data.param.init orelse return declared;
    const gop = c.param_init_undefined.getOrPut(c.a, p) catch oom();
    if (!gop.found_existing) {
        // The initializer may read the parameter itself, so the slot is filled before checking.
        gop.value_ptr.* = false;
        const has = hasUndefined(checkExpression(c, init));
        c.param_init_undefined.put(c.a, p, has) catch oom();
    }
    return if (c.param_init_undefined.get(p).?) declared else removeUndefined(c, declared);
}

fn isParamSym(s: *Symbol) bool {
    return s.flags & F.param != 0;
}

fn containerOfDecl(s: *Symbol) ?*Node {
    const n = s.value_decl orelse return null;
    return flowScope(n);
}

/// A function called on the spot, even an async one, starts from the code around it.
fn flowScope(n: *Node) ?*Node {
    var fc = containingFunc(n);
    while (fc) |x| {
        if (!binder.calledOnTheSpot(x)) break;
        fc = containingFunc(x);
    }
    return fc;
}

/// Narrowings survive into a closure only for bindings nothing can reassign behind its back.
fn flowContainer(c: *Checker, n: *Node, s: *Symbol) ?*Node {
    var fc = flowScope(n);
    const decl_c = containerOfDecl(s);
    if (fc == decl_c) return fc;
    if (!isConstVar(s) and !(isMutableLocal(c, s) and isPastLastAssignment(c, s, n))) return fc;
    while (fc) |x| {
        if (x == decl_c or x.data != .func) break;
        const k = x.data.func.kind;
        const inline_method = (k == .method or k == .getter or k == .setter) and x.parent != null and isExpressionOwner(x.parent.?);
        if (k != .arrow and k != .expr and !inline_method) break;
        fc = flowScope(x);
    }
    return fc;
}

fn isExpressionOwner(n: *Node) bool {
    return n.data == .object_lit or (n.data == .class and n.data.class.is_expr);
}

fn declaredBefore(c: *Checker, s: *Symbol, n: *Node) bool {
    const decl = s.value_decl orelse return true;
    const f1 = d.fileOf(c, decl);
    const f2 = d.fileOf(c, n);
    if (f1 != f2) return true;
    if (decl.start < n.start) {
        if (decl.data == .var_decl and n.start < decl.end) {
            // `let x = x` reads itself before it exists, but a closure in the initializer does not.
            return containingFunc(n) != containingFunc(decl);
        }
        return true;
    }
    if (f1) |f| if (f.is_dts) return true;
    // Used from a function, it may run after the declaration.
    var cur = n.parent;
    const scope = decl.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x == scope) break;
        switch (x.data) {
            .func, .property_decl, .static_block => {
                if (x.data == .property_decl and x.mods.static) continue;
                if (x.data == .static_block) continue;
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn checkUseBeforeDecl(c: *Checker, n: *Node, s: *Symbol) void {
    if (s.flags & (F.block_var | F.class | F.regular_enum) == 0) return;
    if (declaredBefore(c, s, n)) return;
    if (s.flags & F.class != 0) {
        err(c, n, 2449, c.fmt("Class '{s}' used before its declaration.", .{s.name}));
    } else if (s.flags & F.regular_enum != 0) {
        err(c, n, 2450, c.fmt("Enum '{s}' used before its declaration.", .{s.name}));
    } else {
        err(c, n, 2448, c.fmt("Block-scoped variable '{s}' used before its declaration.", .{s.name}));
    }
}

/// A namespace body has a flow of its own, so nothing assigned around it can be seen from inside.
fn moduleBlockOf(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) if (x.data == .module_block) return x;
    return null;
}

fn hasUndefined(t: *Type) bool {
    return switch (t.data) {
        .undefined => true,
        .union_ => |u| for (u) |m| {
            if (m.data == .undefined) break true;
        } else false,
        else => false,
    };
}

pub fn spellingFor(c: *Checker, name: []const u8, candidates: []const []const u8) ?[]const u8 {
    return spelling.best(c.a, name, candidates);
}

pub fn nonNullReport(c: *Checker, t: *Type, n: *Node) *Type {
    return checkNonNull(c, t, n);
}

pub fn removeUndefined(c: *Checker, t: *Type) *Type {
    return relate.removeDefinitelyUndefined(c, t);
}

/// A reference means the same on every visit, and a call around it visits it on every pass, each
/// time with a walk over the flow graph. What a visit owes or met half done cannot stand for the rest.
fn checkRef(c: *Checker, n: *Node) *Type {
    if (c.ref_answers.get(n)) |t| return t;
    const debt = c.quiet_debt;
    const funcs = c.quiet_funcs.items.len;
    const cycles = c.cycles;
    const t = if (n.data == .identifier) checkIdentifier(c, n) else checkPropAccess(c, n);
    if (c.quiet_debt == debt and c.quiet_funcs.items.len == funcs and c.cycles == cycles and
        c.flow_active.count() == 0) c.ref_answers.put(c.a, n, t) catch oom();
    return t;
}

fn checkIdentifier(c: *Checker, n: *Node) *Type {
    const name = n.data.identifier;
    if (name.len == 0) return c.t_err;
    const s0 = symbolOf(c, n) orelse {
        if (std.mem.eql(u8, name, "undefined")) return c.t_undefined;
        if (std.mem.eql(u8, name, "arguments") and containingFunc(n) != null) return d.globalType(c, "IArguments") orelse c.t_err;
        if (std.mem.eql(u8, name, "globalThis")) return c.t_err;
        return unresolved(c, n, name);
    };
    const s = d.targetOf(c, s0) orelse return d.importedProperty(c, s0) orelse c.t_unresolved;
    if (s.flags & F.value == 0) {
        if (s.flags & (F.type | F.namespace) != 0) {
            if (s.flags & F.namespace_module != 0 and s.flags & F.type == 0) {
                err(c, n, 2708, c.fmt("Cannot use namespace '{s}' as a value.", .{name}));
            } else {
                err(c, n, 2693, c.fmt("'{s}' only refers to a type, but is being used as a value here.", .{name}));
            }
        }
        return c.t_err;
    }
    if (s0.flags & F.alias != 0 and aliasIsTypeOnly(s0)) {
        err(c, n, 1361, c.fmt("'{s}' cannot be used as a value because it was imported using 'import type'.", .{name}));
    }
    checkUseBeforeDecl(c, n, s);
    const bound = narrowedBinding(c, s, n, d.typeOfSymbol(c, s));
    if (s.flags & F.variable == 0) return bound;
    if (isAssignTarget(n) and !isCompound(n)) return bound;
    const declared = narrowableRef(c, n, bound);
    const fc = flowContainer(c, n, s);
    const outer = flowScope(n) != containerOfDecl(s);
    const dn = s.value_decl;
    const auto = declared == c.t_auto;
    var assume = (outer and !neverInitialized(c, s)) or isParamSym(s) or dn == null or (!auto and (T.isAny(declared) or declared.data == .void or declared.data == .unknown)) or (n.parent != null and n.parent.?.data == .non_null);
    if (auto) {
        // `x!` asserts on what was assigned, so what it starts from is still nothing.
        const asserted = n.parent != null and n.parent.?.data == .non_null;
        const initial = if (assume and !asserted) declared else c.t_undefined;
        const t = flow.flowType(c, n, declared, initial, fc);
        if (asserted) return if (t == c.t_auto) c.t_any else nonNull(c, t);
        return autoTyped(c, n, s, t);
    }
    if (!assume) {
        if (dn.?.data == .var_decl) {
            const v = dn.?.data.var_decl;
            const l = dn.?.parent.?;
            // An initializer settles it only for a name that cannot be reached around it.
            const hoisted = l.data == .var_list and l.data.var_list.kind == .@"var";
            assume = (v.init != null and !hoisted and declaredBefore(c, s, n)) or v.excl or dn.?.mods.declare or l.data == .catch_clause or (l.data == .var_list and l.parent != null and (l.parent.?.data == .for_of or l.parent.?.data == .for_in or (l.parent.?.data == .var_stmt and l.parent.?.mods.declare)));
            if (hoisted and !c.strict_null) assume = true;
            if (!assume and moduleBlockOf(n) != moduleBlockOf(dn.?)) assume = true;
            if (d.fileOf(c, dn.?)) |f| if (f.is_dts or f != d.fileOf(c, n)) {
                assume = true;
            };
        } else assume = true;
    }
    const initial = if (!assume) (if (c.strict_null) d.addOptional(c, declared) else declared) else if (isParamSym(s) and dn != null) withoutParamOptionality(c, declared, dn.?) else declared;
    const result = flow.flowType(c, n, declared, initial, fc);
    if (!assume and c.strict_null and !hasUndefined(declared) and hasUndefined(result) and !isSameVarDeclNull(declared)) {
        err(c, n, 2454, c.fmt("Variable '{s}' is used before being assigned.", .{name}));
        return declared;
    }
    return result;
}

/// The flow reached the variable's declaration without finding an assignment, as a closure does.
fn autoTyped(c: *Checker, n: *Node, s: *Symbol, t: *Type) *Type {
    if (t != c.t_auto) return t;
    if (n.flow() != null and c.flow_depth <= 120) {
        if (s.value_decl) |dn| err(c, dn.data.var_decl.name, 7034, c.fmt("Variable '{s}' implicitly has type 'any' in some locations where its type cannot be determined.", .{s.name}));
        err(c, n, 7005, c.fmt("Variable '{s}' implicitly has an 'any' type.", .{s.name}));
    }
    return c.t_any;
}

/// A `T extends X | undefined` read where only its constraint matters narrows as that constraint:
/// `if (t) t.x` has to get past the `undefined`.
fn narrowableRef(c: *Checker, n: *Node, t: *Type) *Type {
    if (!hasUnionConstraint(c, t)) return t;
    // The answer depends on the context of this very visit.
    c.quiet_debt += 1;
    if (!isConstraintPosition(c, n, t) and !(inferFor(c, n) == null and hasPlainContext(c, n))) return t;
    return constraintOrSelf(c, t);
}

fn hasUnionConstraint(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_, .inter => |x| for (x) |m| {
            if (hasUnionConstraint(c, m)) break true;
        } else false,
        .param, .access, .cond => blk: {
            const k = d.baseConstraint(c, t);
            break :blk k.data == .union_ or k.data == .null or k.data == .undefined;
        },
        else => false,
    };
}

fn hasNonNullableConstraint(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_, .inter => |x| for (x) |m| {
            if (hasNonNullableConstraint(c, m)) break true;
        } else false,
        .param, .access, .cond => !maybeNullable(d.baseConstraint(c, t)),
        else => false,
    };
}

fn maybeNullable(t: *Type) bool {
    return switch (t.data) {
        .null, .undefined => true,
        .union_, .inter => |x| for (x) |m| {
            if (maybeNullable(m)) break true;
        } else false,
        else => false,
    };
}

/// In `o[k]` with both generic the answer has to stay `T[K]`, unless `o` could be nullish.
fn isConstraintPosition(c: *Checker, n: *Node, t: *Type) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .prop_access => true,
        .call => |x| x.callee == n,
        .new_expr => |x| x.callee == n,
        .elem_access => |x| x.expr == n and !(hasNonNullableConstraint(c, t) and d.isGeneric(c, checkExpr(c, x.index))),
        else => false,
    };
}

fn hasPlainContext(c: *Checker, n: *Node) bool {
    if (n.data != .identifier and n.data != .prop_access and n.data != .elem_access) return false;
    const t = contextualType(c, n) orelse return false;
    return !d.isGeneric(c, t);
}

fn constraintOrSelf(c: *Checker, t: *Type) *Type {
    switch (t.data) {
        .union_ => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |m, i| out[i] = constraintOrSelf(c, m);
            return c.getUnion(out);
        },
        .param, .access, .cond, .inter => {
            const k = d.baseConstraint(c, t);
            return if (k.data == .unknown) t else k;
        },
        else => return t,
    }
}

/// `const { kind, payload } = action`: a check of `kind` also tells about `payload`. The pattern
/// stands in for the union it came from and narrows as a reference, then `payload` is read again
/// from what is left.
fn narrowedBinding(c: *Checker, s: *Symbol, n: *Node, t: *Type) *Type {
    const el = s.value_decl orelse return t;
    if (el.data != .binding_elem) return t;
    const e = el.data.binding_elem;
    if (e.init != null or e.dotdotdot) return t;
    const pat = el.parent orelse return t;
    const siblings = switch (pat.data) {
        .object_pattern => |x| x.elems,
        .array_pattern => |x| x.elems,
        else => return t,
    };
    if (siblings.len < 2) return t;
    var root = pat.parent orelse return t;
    while (root.data == .binding_elem or root.data == .object_pattern or root.data == .array_pattern) root = root.parent orelse return t;
    if (root.data == .var_decl) {
        if (!isConstVar(s)) return t;
    } else if (root.data != .param or !isStableBinding(c, s)) return t;
    const at = n.flow() orelse return t;
    const gop = c.binding_busy.getOrPut(c.a, pat) catch oom();
    if (gop.found_existing) return t;
    defer _ = c.binding_busy.remove(pat);
    const whole = d.bindingParentType(c, el);
    const parent_t = if (whole.data == .param) d.baseConstraint(c, whole) else whole;
    if (parent_t.data != .union_) return t;
    const narrowed = flow.flowAt(c, pat, at, parent_t);
    if (narrowed.data == .never) return c.t_never;
    return d.bindingElemFrom(c, el, narrowed);
}

fn isSameVarDeclNull(t: *Type) bool {
    return t.data == .unknown or t.data == .never;
}

/// `x.y += 1` reads before it writes, so its target narrows like any other read.
fn isWriteOnly(n: *Node) bool {
    return isAssignTarget(n) and !isCompound(n);
}

pub fn isCompound(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        // `x ??= y` either leaves `x` alone or writes `y` over it, and never mixes the two.
        .binary => |x| x.op != .assign and x.op != .amp2_assign and x.op != .pipe2_assign and x.op != .qq_assign,
        .prefix, .postfix => true,
        else => false,
    };
}

fn aliasIsTypeOnly(s: *Symbol) bool {
    for (s.decls) |x| switch (x.data) {
        .import_spec => |y| {
            if (y.type_only) return true;
            if (x.parent) |p| if (p.parent) |q| if (q.parent) |r| if (r.data == .import_clause and r.data.import_clause.type_only) return true;
            if (x.parent) |p| if (p.parent) |q| if (q.data == .import_clause and q.data.import_clause.type_only) return true;
        },
        .import_clause => |y| return y.type_only,
        .namespace_import => if (x.parent) |p| if (p.data == .import_clause and p.data.import_clause.type_only) return true,
        else => {},
    };
    return false;
}

/// Builds `this.<name>` as read at the end of `ctor`, for a question no source node asks.
pub fn thisAccess(c: *Checker, name: *Node, ctor: *Node) ?*Node {
    const end = (d.bodyOf(c, ctor) orelse return null).end_flow orelse return null;
    return thisAccessAt(c, name, ctor, end);
}

pub fn thisAccessAt(c: *Checker, name: *Node, owner: *Node, end: *binder.FlowNode) *Node {
    const this = c.a.create(Node) catch oom();
    const ref = c.a.create(Node) catch oom();
    this.* = .{ .start = owner.start, .end = owner.start, .parent = ref, .data = .this_expr };
    ref.* = Node.atFlow(end, owner.start, owner.start, owner, .{ .prop_access = .{ .expr = this, .name = name, .optional = false } });
    return ref;
}

pub fn flowTypeOfQuery(c: *Checker, n: *Node, s: *Symbol) *Type {
    const target = d.targetOf(c, s) orelse return c.t_err;
    const t = d.typeOfSymbol(c, target);
    if (target.flags & F.variable == 0) return t;
    if (n.flow() == null) return t;
    return flow.flowType(c, n, t, t, flowContainer(c, n, s));
}

/// `typeof a.b` is what `a.b` would read as at that point.
pub fn memberQuery(c: *Checker, n: *Node, left: *Type) *Type {
    const x = n.data.qualified_name;
    const base = checkNonNull(c, left, x.left);
    if (T.isAny(base)) return base;
    return propAccessType(c, n, base, x.right, ast.memberText(x.right));
}

// ---- this / super ----

fn thisOfClass(c: *Checker, cls: *Node, is_static: bool) *Type {
    const s = cls.symbol() orelse return c.t_err;
    if (is_static) return d.typeOfSymbol(c, s);
    const t = d.declaredType(c, s);
    if (t.data == .obj) if (t.data.obj.thisType()) |x| return x;
    return c.t_err;
}

pub fn checkThisAt(c: *Checker, n: *Node) *Type {
    return thisTypeAt(c, n) orelse c.t_err;
}

/// Null where tsc's `tryGetThisTypeAt` finds nothing: `this` is then an implicit `any`.
fn thisTypeAt(c: *Checker, n: *Node) ?*Type {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        switch (x.data) {
            .func => |f| switch (f.kind) {
                .arrow => continue,
                .decl, .expr => {
                    if (d.thisParam(x)) |p| if (p.data.param.type) |ann| return d.typeFromNode(c, ann);
                    if (x.parent) |p| if (p.data == .property_assign or p.data == .object_lit) return objectThis(c, x);
                    if (contextualThis(c, x)) |t| return t;
                    if (d.thisParam(x) != null or checker.jsDocHas(c, x, &.{ "@this", "@type" })) return c.t_err;
                    return assignedThis(c, x);
                },
                .method, .getter, .setter, .ctor => {
                    if (d.thisParam(x)) |p| if (p.data.param.type) |ann| return d.typeFromNode(c, ann);
                    const owner = x.parent orelse return c.t_err;
                    if (owner.data == .class) return thisOfClass(c, owner, x.mods.static);
                    return objectThis(c, x);
                },
                else => return c.t_err,
            },
            .property_decl => {
                const owner = x.parent orelse return c.t_err;
                return thisOfClass(c, owner, x.mods.static);
            },
            .static_block => {
                const owner = x.parent orelse return c.t_err;
                return thisOfClass(c, owner, true);
            },
            // A member does not own its own name: `this` there belongs to what surrounds the literal.
            .computed_name => return thisTypeAt(c, x.parent orelse break),
            .module_decl, .enum_decl => return null,
            .class => {},
            .interface, .type_literal => return d.typeFromNode(c, n),
            else => {},
        }
    }
    return c.t_err;
}

/// `obj.m = function () { this }` sees `obj`, except `exports.m = ...` in a CommonJS file.
fn assignedThis(c: *Checker, fnode: *Node) ?*Type {
    if (!c.no_implicit_this and !inJs(c, fnode)) return null;
    var at = fnode;
    while (at.parent) |p| : (at = p) if (p.data != .paren) break;
    const p = at.parent orelse return null;
    if (p.data != .binary or !isAssignOp(p.data.binary.op) or p.data.binary.right != at) return null;
    const target = p.data.binary.left;
    const obj = switch (target.data) {
        .prop_access => |x| x.expr,
        .elem_access => |x| x.expr,
        else => return null,
    };
    if (obj.data == .identifier and inJs(c, fnode) and commonJsName(c, obj, obj.data.identifier)) return null;
    return widenFresh(c, checkExpr(c, obj));
}

/// tsc's `checkThisExpression` diagnostics: where `this` may not appear, and where it is an implicit `any`.
fn checkThisPlace(c: *Checker, n: *Node) void {
    var captured = false;
    var in_computed = false;
    var cur = n.parent;
    var container: ?*Node = null;
    while (cur) |x| : (cur = x.parent) {
        switch (x.data) {
            .func => |f| {
                if (f.kind == .arrow) {
                    captured = true;
                    continue;
                }
                container = x;
                break;
            },
            .property_decl, .static_block, .module_decl, .enum_decl, .index_sig => {
                container = x;
                break;
            },
            .computed_name => {
                // A class member's name is evaluated outside the class body.
                const member = x.parent orelse continue;
                if (member.parent) |cls| if (cls.data == .class) {
                    in_computed = true;
                    cur = cls;
                    continue;
                };
                // An object literal member's name belongs to what surrounds the literal.
                cur = member;
                continue;
            },
            .decorator => {
                // Decorators run outside the class or member they decorate.
                const owner = x.parent orelse continue;
                cur = if (owner.data == .param) owner.parent orelse owner else owner;
                continue;
            },
            else => {},
        }
    }
    if (in_computed) {
        err(c, n, 2465, "'this' cannot be referenced in a computed property name.");
    } else if (container) |k| switch (k.data) {
        .module_decl => err(c, n, 2331, "'this' cannot be referenced in a module or namespace body."),
        .enum_decl => err(c, n, 2332, "'this' cannot be referenced in current location."),
        else => {},
    };
    if (!c.no_implicit_this) return;
    if (container == null) {
        const f = d.fileOf(c, n) orelse return;
        if (captured and !f.is_module) err(c, n, 7041, "The containing arrow function captures the global value of 'this'.");
        return;
    }
    if (thisTypeAt(c, n) == null) err(c, n, 2683, "'this' implicitly has type 'any' because it does not have a type annotation.");
}

fn contextualThis(c: *Checker, fnode: *Node) ?*Type {
    const sig = contextualSig(c, fnode) orelse return null;
    return sig.this_ty;
}

/// An object-literal method sees the literal, or the `ThisType` its context promises.
fn objectThis(c: *Checker, fnode: *Node) *Type {
    if (contextualThis(c, fnode)) |t| return t;
    if (!c.no_implicit_this and !inJs(c, fnode)) return c.t_any;
    var cur: ?*Node = fnode;
    while (cur) |x| : (cur = x.parent) {
        if (x.data == .object_lit) {
            if (contextualType(c, x)) |t| {
                if (!T.isAny(t)) return c.t_err;
            }
            return checkSilent(c, x);
        }
    }
    return c.t_err;
}

fn superBase(c: *Checker, n: *Node) ?struct { base: *Type, is_static: bool } {
    var cur = n.parent;
    var is_static = false;
    while (cur) |x| : (cur = x.parent) {
        if (x.data == .func and x.data.func.kind != .arrow) is_static = x.mods.static;
        if (x.data == .property_decl) is_static = x.mods.static;
        if (x.data == .static_block) is_static = true;
        if (x.data == .class) {
            const s = x.symbol() orelse return null;
            const t = d.declaredType(c, s);
            if (t.data != .obj) return null;
            const bases = d.basesOf(c, t);
            if (bases.len == 0) return null;
            // A base method that returns `this` answers to the class calling it.
            const own = t.data.obj.thisType() orelse return .{ .base = bases[0], .is_static = is_static };
            return .{ .base = if (is_static) bases[0] else d.withThis(c, bases[0], own), .is_static = is_static };
        }
    }
    return null;
}

// ---- contextual types ----

fn ctxEntry(c: *Checker, n: *Node) ?Checker.CtxEntry {
    var i = c.ctx_stack.items.len;
    while (i > 0) {
        i -= 1;
        if (c.ctx_stack.items[i].node == n) return c.ctx_stack.items[i];
    }
    return null;
}

fn inferFor(c: *Checker, n: *Node) ?*InferCtx {
    if (c.ctx_stack.items.len == 0) return null;
    var cur: ?*Node = n;
    while (cur) |x| : (cur = x.parent) {
        if (ctxEntry(c, x)) |e| return e.ctx;
    }
    return null;
}

fn enclosingFunc(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x.data == .func) return x;
        if (x.data == .class) return null;
    }
    return null;
}

fn contextualReturn(c: *Checker, fnode: *Node) ?*Type {
    const f = fnode.data.func;
    if (f.ret) |r| {
        const t = d.typeFromNode(c, r);
        return if (fnode.mods.async) asyncReturnContext(c, t) else t;
    }
    if (f.asterisk) return null;
    if (d.setterAnnotation(c, fnode)) |t| return t;
    const sig = contextualSig(c, fnode) orelse {
        const t = iifeContext(c, fnode) orelse return null;
        return if (fnode.mods.async) asyncReturnContext(c, t) else t;
    };
    const t = d.returnOf(c, sig);
    return if (fnode.mods.async) asyncReturnContext(c, awaitableMembers(c, t)) else t;
}

/// tsc's `getContextualReturnType`: `(() => …)()` returns whatever its call is expected to give.
fn iifeContext(c: *Checker, fnode: *Node) ?*Type {
    return contextualType(c, binder.callOnTheSpot(fnode) orelse return null);
}

fn hasThen(c: *Checker, t: *Type) bool {
    const then = d.getProp(c, d.getApparent(c, t), "then") orelse return false;
    return d.callSigs(c, d.propType(c, then)).len > 0;
}

/// An async body's lone literal is judged against the promised type, and `Promise<'a'> | number`
/// has none: the union as a whole offers no `then`.
fn literalReturnContext(c: *Checker, fnode: *Node) ?*Type {
    const ctx = contextualReturn(c, fnode) orelse return null;
    if (!fnode.mods.async or fnode.data.func.ret != null) return ctx;
    const t = d.returnOf(c, contextualSig(c, fnode) orelse return ctx);
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    for (members) |m| if (!hasThen(c, m)) return null;
    return ctx;
}

/// An async function can only ever produce the promise in `Promise<T> | string`.
fn awaitableMembers(c: *Checker, t: *Type) *Type {
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var kept = c.newList(*Type);
    for (members) |m| switch (m.data) {
        .any, .err, .unknown, .void, .param, .access, .cond, .noinfer => kept.append(c.a, m) catch oom(),
        .obj, .inter => if (hasThen(c, m)) kept.append(c.a, m) catch oom(),
        else => {},
    };
    return c.getUnion(kept.items);
}

/// The three things a generator's return type speaks for, in the order `Generator` takes them.
pub const Channel = enum(u2) { yield, ret, next };

/// tsc reads these straight from the arguments of the global iterator types. Any other iterable
/// leaves the channel unknown, and the body is typed on its own.
fn iteratorArg(c: *Checker, t: *Type, ch: Channel, is_async: bool) ?*Type {
    if (t.data == .union_) {
        var parts = c.newList(*Type);
        for (t.data.union_) |m| if (iteratorArg(c, m, ch, is_async)) |x| parts.append(c.a, x) catch oom();
        return if (parts.items.len == 0) null else c.getUnion(parts.items);
    }
    if (t.data != .obj) return null;
    const target = t.data.obj.target orelse return null;
    const names: []const []const u8 = if (is_async)
        &.{ "AsyncGenerator", "AsyncIterable", "AsyncIterableIterator", "AsyncIteratorObject", "AsyncIterator" }
    else
        &.{ "Generator", "Iterable", "IterableIterator", "IteratorObject", "Iterator" };
    for (names) |name| if (d.globalType(c, name) == target) {
        const args = t.data.obj.args orelse return null;
        return if (@intFromEnum(ch) < args.len) args[@intFromEnum(ch)] else null;
    };
    return null;
}

pub fn generatorContext(c: *Checker, fnode: *Node, ch: Channel) ?*Type {
    const f = fnode.data.func;
    const t = if (f.ret) |r| d.typeFromNode(c, r) else if (contextualSig(c, fnode)) |sig| d.returnOf(c, sig) else iifeContext(c, fnode) orelse return null;
    return iteratorArg(c, t, ch, fnode.mods.async);
}

/// An async body may return the value or a promise of it, so a generic call there has to infer
/// from `PromiseLike<void>` as well as from `void`.
fn asyncReturnContext(c: *Checker, t: *Type) *Type {
    const w = awaitedOf(c, t);
    return c.getUnion(&.{ w, d.generic(c, "PromiseLike", &.{w}) });
}

fn typeOfMember(c: *Checker, t: *Type, name: []const u8) ?*Type {
    if (t.data == .union_) {
        var parts = c.newList(*Type);
        for (t.data.union_) |m| if (typeOfMember(c, m, name)) |x| parts.append(c.a, x) catch oom();
        if (parts.items.len == 0) return null;
        return c.getContextUnion(parts.items);
    }
    if (t.data == .param or t.data == .access or t.data == .noinfer) {
        const k = d.baseConstraint(c, t);
        if (k.data == .unknown or k == t) return null;
        return typeOfMember(c, k, name);
    }
    if (t.data != .obj and t.data != .inter) return null;
    if (d.genericMappedMember(c, t, name)) |x| return x;
    if (d.getProp(c, t, name)) |p| {
        return if (p.optional) removeUndefined(c, d.propType(c, p)) else d.propType(c, p);
    }
    if (T.isTupleType(t)) return null;
    const isnum = if (std.fmt.parseFloat(f64, name)) |_| true else |_| false;
    if (isnum) if (d.indexValue(c, t, c.t_number)) |v| return v;
    return d.indexValue(c, t, c.t_string);
}

/// A name known only when the code runs can be spoken for by an index signature alone.
fn computedMemberContext(c: *Checker, t: *Type, name: *Node) ?*Type {
    return typeAtKey(c, t, computedKeyOf(c, name) orelse return null);
}

fn typeAtKey(c: *Checker, t: *Type, key: *Type) ?*Type {
    if (t.data == .union_) {
        var parts = c.newList(*Type);
        for (t.data.union_) |m| if (typeAtKey(c, m, key)) |x| parts.append(c.a, x) catch oom();
        if (parts.items.len == 0) return null;
        return c.getContextUnion(parts.items);
    }
    if (t.data != .obj and t.data != .inter) return null;
    return d.indexValue(c, t, key);
}

fn elemOfCtx(c: *Checker, n: *Node, t: *Type, i: usize) ?*Type {
    if (t.data == .union_) {
        var parts = c.newList(*Type);
        for (t.data.union_) |m| if (elemOfCtx(c, n, m, i)) |x| parts.append(c.a, x) catch oom();
        if (parts.items.len == 0) return null;
        return c.getContextUnion(parts.items);
    }
    if (T.isTupleType(t)) {
        const o = t.data.obj;
        if (i < o.tuple.elems.len and o.tuple.eflags[i] != .rest and o.tuple.eflags[i] != .variadic) return o.tuple.elems[i];
        for (o.tuple.eflags, 0..) |f, k| switch (f) {
            .rest => return o.tuple.elems[k],
            .variadic => return d.getIndexedAccess(c, o.tuple.elems[k], c.t_number),
            else => {},
        };
        return null;
    }
    if (c.isArrayType(t)) return t.data.obj.args.?[0];
    if (t.data == .param or t.data == .access or t.data == .cond) {
        const k = d.baseConstraint(c, t);
        return if (k.data == .unknown or k == t) null else elemOfCtx(c, n, k, i);
    }
    if (t.data == .any or t.data == .string) return t;
    if (t.data == .inter) return typeOfMember(c, t, c.fmt("{d}", .{i}));
    if (t.data != .obj) return null;
    if (d.indexValue(c, t, c.t_number)) |x| return x;
    return if (d.getProp(c, t, "__@iterator") != null) iteratedOf(c, n, t, false) else null;
}

pub fn contextualType(c: *Checker, n: *Node) ?*Type {
    const t = withReturnMapper(c, n, rawContext(c, n) orelse return null);
    return if (c.context_for_signature) soFarInferred(c, n, t) else t;
}

/// A lambda's context reads through what arguments to its left already inferred, which plain
/// expressions must not: their context still has to be free to go another way.
fn soFarInferred(c: *Checker, n: *Node, t: *Type) *Type {
    if (!t.vars) return t;
    const ctx = inferFor(c, n) orelse return t;
    for (ctx.infos) |i| {
        if (i.candidates.items.len > 0 or i.contra.items.len > 0 or d.defaultOf(c, i.param) != null) break;
    } else return t;
    return instantiateTop(c, t, relate.nonFixing(c, ctx));
}

fn instantiateTop(c: *Checker, t: *Type, m: *T.Mapper) *Type {
    switch (t.data) {
        .param, .access, .cond, .keyof, .tmpl, .strmap, .noinfer => return d.instantiate(c, t, m),
        .union_, .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = instantiateTop(c, y, m);
            return if (t.data == .union_) c.getUnion(out) else c.getIntersection(out);
        },
        else => return t,
    }
}

/// What the enclosing call's own contextual return type says about its type parameters. Without
/// it the `[k, v]` in `new Map(xs.map((x) => [k, v]))` never learns that it is a tuple.
fn withReturnMapper(c: *Checker, n: *Node, t: *Type) *Type {
    if (!t.vars or c.ctx_stack.items.len == 0) return t;
    const ctx = inferFor(c, n) orelse return t;
    return viaReturnMapper(c, t, ctx.return_mapper orelse return t);
}

/// `f(): boolean { return xs.reduce((a, x) => a || x.ok, false); }`: `boolean` asks for no literal
/// in particular, so the seed `false` must widen and leave room for what the lambda returns.
fn viaReturnMapper(c: *Checker, t: *Type, m: *T.Mapper) *Type {
    const r = instantiateInstantiable(c, t, m);
    if (r == t or r.data != .union_) return r;
    const members = r.data.union_;
    if (std.mem.indexOfScalar(*Type, members, c.t_true) == null or std.mem.indexOfScalar(*Type, members, c.t_false) == null) return r;
    var rest = c.newList(*Type);
    for (members) |x| if (x != c.t_true and x != c.t_false) rest.append(c.a, x) catch oom();
    return c.getUnion(rest.items);
}

fn instantiateInstantiable(c: *Checker, t: *Type, m: *T.Mapper) *Type {
    return switch (t.data) {
        .param, .access, .cond, .keyof, .tmpl, .strmap, .noinfer => d.instantiate(c, t, m),
        .union_ => |x| blk: {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |e, i| out[i] = instantiateInstantiable(c, e, m);
            break :blk c.getUnion(out);
        },
        else => t,
    };
}

fn rawContext(c: *Checker, n: *Node) ?*Type {
    if (ctxEntry(c, n)) |e| return e.ty;
    const p = n.parent orelse return null;
    switch (p.data) {
        .var_decl => |x| {
            if (x.init != n) return null;
            if (x.type) |t| return d.typeFromNode(c, t);
            return patternContext(c, x.name);
        },
        .property_decl => |x| {
            if (x.init != n) return null;
            if (x.type) |t| return d.typeFromNode(c, t);
            return null;
        },
        .param => |x| {
            if (x.init != n) return null;
            if (x.type) |t| return d.typeFromNode(c, t);
            if (p.parent) |fnode| if (fnode.data == .func) {
                assignContext(c, fnode);
                if (c.param_types.get(p)) |t| return t;
            };
            return patternContext(c, x.name);
        },
        .binding_elem => |x| {
            if (x.init != n) return null;
            return bindingDefaultContext(c, p) orelse patternContext(c, x.name);
        },
        .func => |f| {
            if (f.body != n) return null;
            return contextualReturn(c, p);
        },
        .return_stmt => {
            const fnode = enclosingFunc(p) orelse return null;
            if (!fnode.data.func.asterisk) return contextualReturn(c, fnode);
            const t = generatorContext(c, fnode, .ret) orelse return null;
            return if (fnode.mods.async) asyncReturnContext(c, t) else t;
        },
        .yield_expr => |x| {
            const fnode = enclosingFunc(p) orelse return null;
            if (!x.star) return generatorContext(c, fnode, .yield);
            const yielded = generatorContext(c, fnode, .yield) orelse return null;
            const ret = contextualType(c, p) orelse c.t_silent_never;
            const parts = [_]*Type{ yielded, ret, generatorContext(c, fnode, .next) orelse c.t_unknown };
            const g = d.generic(c, "Generator", &parts);
            return if (fnode.mods.async) c.getUnion(&.{ g, d.generic(c, "AsyncGenerator", &parts) }) else g;
        },
        .await_expr => {
            const t = contextualType(c, p) orelse return null;
            const w = awaitedOf(c, t);
            return c.getUnion(&.{ w, d.generic(c, "PromiseLike", &.{w}) });
        },
        .paren, .non_null => return contextualType(c, p),
        .as_expr => |x| {
            if (isConstRef(x.type)) return contextualType(c, p);
            return d.typeFromNode(c, x.type);
        },
        .satisfies_expr => |x| return d.typeFromNode(c, x.type),
        .type_assertion => |x| {
            if (isConstRef(x.type)) return contextualType(c, p);
            return d.typeFromNode(c, x.type);
        },
        .conditional => |x| {
            if (x.cond == n) return null;
            return contextualType(c, p);
        },
        .binary => |x| {
            switch (x.op) {
                .assign, .amp2_assign, .pipe2_assign, .qq_assign => {
                    if (x.right != n) return null;
                    // An expando is typed by this very value, unless its function's variable has a type.
                    if (x.left.symbol()) |s| if (!hasAnnotatedOwner(s)) return null;
                    return assignmentContext(c, x.left);
                },
                .pipe2, .qq => {
                    if (contextualType(c, p)) |t| return t;
                    if (x.right == n) return c.logical_left.get(p) orelse checkSilent(c, x.left);
                    return null;
                },
                .amp2, .comma => {
                    if (x.right != n) return null;
                    return contextualType(c, p);
                },
                else => return null,
            }
        },
        .property_assign => |x| {
            if (x.value != n) return null;
            const obj = p.parent orelse return null;
            const t = objectContext(c, obj) orelse return null;
            const name = propNameOf(c, x.name) orelse return computedMemberContext(c, t, x.name);
            return typeOfMember(c, t, name);
        },
        .shorthand_assign => |x| {
            const obj = p.parent orelse return null;
            const t = objectContext(c, obj) orelse return null;
            return typeOfMember(c, t, x.name.data.identifier);
        },
        .spread_assign => {
            const obj = p.parent orelse return null;
            return contextualType(c, obj);
        },
        .object_lit => {
            // Methods and accessors sit directly in the literal.
            if (n.data != .func) return null;
            const t = objectContext(c, p) orelse return null;
            const f = n.data.func;
            const nm = f.name orelse return null;
            const name = propNameOf(c, nm) orelse return computedMemberContext(c, t, nm);
            return typeOfMember(c, t, name);
        },
        .array_lit => |x| {
            const t = contextualType(c, p) orelse return null;
            // Scanning for the position is quadratic over a literal; big ones were indexed by checkArrayLit.
            const i: usize = if (c.elem_index.get(n)) |k| k else for (x.elems, 0..) |e, k| {
                if (e == n) break k;
            } else 0;
            return elemOfCtx(c, n, t, i);
        },
        .call => |x| return argContext(c, p, n, x.args),
        .new_expr => |x| return argContext(c, p, n, x.args),
        .jsx_attr => return jsxAttrContext(c, p) orelse c.t_err,
        .jsx_expr => {
            const a = p.parent orelse return c.t_err;
            if (a.data == .jsx_attr) return jsxAttrContext(c, a) orelse c.t_err;
            if (a.data == .jsx_element) return jsxChildContext(c, p, a) orelse c.t_err;
            return c.t_err;
        },
        .jsx_spread_attr => return c.t_err,
        else => return null,
    }
}

/// `this.title = $(".a")` with `title?: Div`: the annotation is the context, not the `undefined`
/// that only says the property may be absent.
fn assignmentContext(c: *Checker, left: *Node) ?*Type {
    if (left.data == .prop_access) {
        const x = left.data.prop_access;
        if (d.getProp(c, checkSilent(c, x.expr), ast.memberText(x.name))) |p| {
            if (isImpliedByUse(p)) return null;
            if (p.optional) return removeUndefined(c, d.propType(c, p));
        }
    }
    return checkSilent(c, left);
}

/// A property with neither type nor initializer gets its type from assignments like this one, so
/// asking for it here would go in a circle.
fn isImpliedByUse(p: *Prop) bool {
    var q = p;
    while (q.origin) |o| q = o;
    const s = q.sym orelse return false;
    const n = s.value_decl orelse return false;
    if (n.data != .property_decl) return false;
    const x = n.data.property_decl;
    return x.type == null and x.init == null;
}

/// `const [a, b] = c ? f() : ["", null]`: a pattern asks for a tuple, wherever the literal sits.
/// `{ f = (a) => a }: { f?: F }`: a default is read against what the pattern takes apart.
fn bindingDefaultContext(c: *Checker, el: *Node) ?*Type {
    const pat = el.parent orelse return null;
    const owner = pat.parent orelse return null;
    const parent = switch (owner.data) {
        .var_decl => |x| if (x.type) |t| d.typeFromNode(c, t) else if (x.init) |i| checkSilent(c, i) else null,
        .param => |x| if (x.type) |t| d.typeFromNode(c, t) else c.param_types.get(owner),
        .binding_elem => bindingDefaultContext(c, owner),
        else => null,
    } orelse return null;
    const e = el.data.binding_elem;
    if (pat.data == .array_pattern) {
        if (e.name.data != .identifier) return null;
        const i = std.mem.indexOfScalar(*Node, pat.data.array_pattern.elems, el) orelse return null;
        return elemOfCtx(c, el, parent, i);
    }
    const key = e.prop_name orelse e.name;
    return typeOfMember(c, parent, propNameOf(c, key) orelse return null);
}

fn patternContext(c: *Checker, pat: *Node) ?*Type {
    if (pat.data != .array_pattern or c.skip_patterns > 0) return null;
    const elems = pat.data.array_pattern.elems;
    var min: usize = 0;
    for (elems, 0..) |e, i| {
        if (e.data == .binding_elem and !e.data.binding_elem.dotdotdot and e.data.binding_elem.init == null) min = i + 1;
    }
    const types = c.a.alloc(*Type, elems.len) catch oom();
    const flags = c.a.alloc(T.ElemFlag, elems.len) catch oom();
    for (elems, types, flags, 0..) |e, *t, *f, i| {
        const rest = e.data == .binding_elem and e.data.binding_elem.dotdotdot;
        const nested = if (e.data == .binding_elem) patternContext(c, e.data.binding_elem.name) else null;
        t.* = if (rest) d.arrayOf(c, c.t_any) else nested orelse c.t_any;
        f.* = if (rest) .rest else if (i >= min) .optional else .required;
    }
    return c.makeTuple(types, flags, false, &.{});
}

/// `fire({ method: "read", params: { channel: ROOT } })`: the params must be those of `read`, or
/// `ROOT` widens against the strings of the other members and no member takes the result.
fn objectContext(c: *Checker, obj: *Node) ?*Type {
    const t = contextualType(c, obj) orelse return null;
    if (t.data != .union_ or obj.data != .object_lit) return t;
    const gop = c.discriminated.getOrPut(c.a, .{ obj, t }) catch oom();
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = t;
    const out = discriminate(c, obj, t);
    c.discriminated.put(c.a, .{ obj, t }, out) catch oom();
    return out;
}

const Keep = enum { no, yes, maybe };

fn discriminate(c: *Checker, obj: *Node, t: *Type) *Type {
    const types = t.data.union_;
    const keep = c.a.alloc(Keep, types.len) catch oom();
    for (types, keep) |m, *k| k.* = if (m.data == .obj or m.data == .inter or m.data == .param or m.data == .access) .yes else .no;
    const props = obj.data.object_lit.props;
    for (props) |p| switch (p.data) {
        .property_assign => |x| {
            const name = propNameOf(c, x.name) orelse continue;
            if (!possiblyDiscriminant(x.value) or !relate.isDiscriminant(c, types, name)) continue;
            keepMatching(c, types, keep, name, contextFree(c, x.value));
        },
        .shorthand_assign => |x| {
            const name = x.name.data.identifier;
            if (relate.isDiscriminant(c, types, name)) keepMatching(c, types, keep, name, contextFree(c, x.name));
        },
        else => {},
    };
    // A property the literal leaves out reads as `undefined`, and that discriminates too.
    for (d.propsOf(c, types[0])) |x| {
        if (literalDeclares(c, props, x.name) or !partlyOptional(c, types, x.name)) continue;
        if (relate.isDiscriminant(c, types, x.name)) keepMatching(c, types, keep, x.name, c.t_undefined);
    }
    if (std.mem.indexOfScalar(Keep, keep, .no) == null) return t;
    var rest = c.newList(*Type);
    for (types, keep) |m, k| if (k == .yes) rest.append(c.a, m) catch oom();
    return if (rest.items.len == 0) t else c.getUnion(rest.items);
}

fn keepMatching(c: *Checker, types: []*Type, keep: []Keep, name: []const u8, value: *Type) void {
    var matched = false;
    for (types, keep) |m, *k| {
        if (k.* == .no) continue;
        const target = memberOrIndex(c, m, name) orelse continue;
        const hit = if (value.data == .union_) for (value.data.union_) |v| {
            if (relate.isAssignable(c, v, target)) break true;
        } else false else relate.isAssignable(c, value, target);
        if (hit) matched = true else k.* = .maybe;
    }
    for (keep) |*k| if (k.* == .maybe) {
        k.* = if (matched) .no else .yes;
    };
}

fn memberOrIndex(c: *Checker, t: *Type, name: []const u8) ?*Type {
    if (t.data != .obj and t.data != .inter) return null;
    if (d.getProp(c, t, name)) |p| return d.propType(c, p);
    return d.indexValue(c, t, c.t_string);
}

fn literalDeclares(c: *Checker, props: []*Node, name: []const u8) bool {
    for (props) |p| {
        const declared = switch (p.data) {
            .property_assign => |x| propNameOf(c, x.name),
            .shorthand_assign => |x| x.name.data.identifier,
            .func => |f| if (f.name) |nm| propNameOf(c, nm) else null,
            else => null,
        } orelse continue;
        if (std.mem.eql(u8, declared, name)) return true;
    }
    return false;
}

/// Present in every member, optional in at least one.
fn partlyOptional(c: *Checker, types: []*Type, name: []const u8) bool {
    var optional = false;
    for (types) |m| {
        const p = d.getProp(c, m, name) orelse return false;
        if (p.optional) optional = true;
    }
    return optional;
}

fn possiblyDiscriminant(n: *Node) bool {
    return switch (n.data) {
        .string_lit, .numeric_lit, .bigint_lit, .no_subst_template, .template_expr, .true_lit, .false_lit, .null_lit, .identifier => true,
        .prop_access => |x| possiblyDiscriminant(x.expr),
        .paren => |x| possiblyDiscriminant(x.expr),
        else => false,
    };
}

fn contextFree(c: *Checker, n: *Node) *Type {
    c.ctx_stack.append(c.a, .{ .node = n, .ty = c.t_any, .ctx = null }) catch oom();
    defer _ = c.ctx_stack.pop();
    return checkSilent(c, n);
}

fn argContext(c: *Checker, call: *Node, n: *Node, args: []*Node) ?*Type {
    const i = for (args, 0..) |a, k| {
        if (a == n) break k;
    } else return null;
    const sig = resolvedSig(c, call) orelse return if (isUntypedCall(c, call)) null else c.t_err;
    return relate.typeAt(c, sig, i);
}

fn isUntypedCall(c: *Checker, call: *Node) bool {
    const callee = switch (call.data) {
        .call => |x| x.callee,
        .new_expr => |x| x.callee,
        else => return false,
    };
    if (callee.data == .import_kw or callee.data == .super_expr) return false;
    const t = nonNull(c, checkSilent(c, callee));
    if (T.isAny(t) or t.data == .never) return saysNothing(c, t);
    const sigs = if (call.data == .call) d.callSigs(c, t) else d.ctorSigs(c, t);
    return sigs.len == 0 and !t.vars and !isOpen(c, t);
}

/// The plain `t_err` can hide a type the checker could not work out, whose signatures would have
/// given a lambda its context, so that one must not count against the lambda.
fn saysNothing(c: *Checker, t: *Type) bool {
    return t.data != .err or t == c.t_unresolved;
}

fn isConstRef(n: *Node) bool {
    return n.data == .type_ref and n.data.type_ref.name.data == .identifier and std.mem.eql(u8, n.data.type_ref.name.data.identifier, "const");
}

fn instantiateCtx(c: *Checker, n: *Node, t: *Type) *Type {
    if (!t.vars) return t;
    const ctx = inferFor(c, n) orelse return t;
    return d.instantiate(c, t, relate.noDefault(c, ctx));
}

/// What the call around this one has learned so far reaches the lambdas of this one:
/// `layer(Foo, gen(function* () { ... }))` types the body from what `Foo` said.
fn outerInferred(c: *Checker, n: *Node, t: *Type) *Type {
    if (!t.vars) return t;
    const ctx = inferFor(c, n) orelse return t;
    return d.instantiate(c, t, relate.inferredPart(c, ctx) orelse return t);
}

fn isConstContext(c: *Checker, n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .as_expr => |x| isConstRef(x.type),
        .type_assertion => |x| isConstRef(x.type),
        .paren, .array_lit, .spread_elem, .object_lit, .spread_assign => isConstContext(c, p) or constParamCtx(c, n),
        .property_assign, .shorthand_assign => isConstContext(c, p),
        else => constParamCtx(c, n),
    };
}

fn constParamCtx(c: *Checker, n: *Node) bool {
    const t = contextualType(c, n) orelse return false;
    return t.data == .param and t.data.param.is_const;
}

fn literalCtx(c: *Checker, cand: *Type, t: *Type) bool {
    if (cand.data == .union_) {
        for (cand.data.union_) |m| if (literalCtx(c, m, t)) return true;
        return false;
    }
    switch (t.data) {
        .union_, .inter => |x| {
            for (x) |m| if (literalCtx(c, cand, m)) return true;
            return false;
        },
        .param, .access, .cond => {
            const k = d.baseConstraint(c, t);
            if (k == t or k.data == .unknown) return false;
            return literalCtxCons(cand, k) or literalCtx(c, cand, k);
        },
        else => return (cand.data == .unique and t.data == .unique) or literalCtxCons(cand, t),
    }
}

const LitKind = enum { none, str, num, big, bool };

fn litKind(t: *Type) LitKind {
    return switch (t.data) {
        .str_lit, .tmpl, .strmap, .keyof => .str,
        .num_lit => .num,
        .big_lit => .big,
        .bool_lit => .bool,
        .enum_lit => |e| if (e.value == .str) .str else .num,
        else => .none,
    };
}

fn literalCtxCons(cand: *Type, t: *Type) bool {
    if (t.data == .enum_) return cand.data == .num_lit or cand.data == .enum_lit;
    const k = litKind(cand);
    return k != .none and k == litKind(t);
}

fn primConstraint(c: *Checker, cand: *Type, t: *Type) bool {
    if (t.data == .param or t.data == .access) {
        const k = d.baseConstraint(c, t);
        return switch (cand.data) {
            .str_lit => containsKind(k, .string) or containsKind(k, .keyof),
            .num_lit => containsKind(k, .number),
            .big_lit => containsKind(k, .bigint),
            .bool_lit => containsBool(c, k),
            .enum_lit => |e| containsKind(k, if (e.value == .str) .string else .number),
            else => false,
        };
    }
    if (t.data == .union_) {
        for (t.data.union_) |m| if (primConstraint(c, cand, m)) return true;
    }
    return false;
}

fn containsBool(c: *Checker, k: *Type) bool {
    if (k == c.t_boolean) return true;
    if (k.data == .union_) for (k.data.union_) |m| if (containsBool(c, m)) return true;
    return false;
}

fn containsKind(k: *Type, tag: std.meta.Tag(T.Data)) bool {
    if (std.meta.activeTag(k.data) == tag) return true;
    if (k.data == .union_) for (k.data.union_) |m| if (containsKind(m, tag)) return true;
    return false;
}

/// The type of an expression stored in a mutable place: `{ a: 1 }.a` is `number` unless context says `1`.
fn mutableLocation(c: *Checker, n: *Node, t: *Type) *Type {
    if (t.data == .union_) {
        var keep = false;
        for (t.data.union_) |m| if (m.regular != null) {
            keep = true;
        };
        if (!keep and t != c.t_boolean) return t;
    }
    if (isConstContext(c, n)) return regularize(c, t);
    const inner = binder.stripParens(n);
    if (inner.data == .as_expr or inner.data == .type_assertion) return t;
    if (contextualType(c, n)) |ctx| if (keepsLiteral(c, t, ctx)) return t;
    return widenUnique(c, widenFresh(c, t));
}

fn keepsLiteral(c: *Checker, t: *Type, ctx: *Type) bool {
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    for (members) |m| {
        if (literalCtx(c, m.regular orelse m, ctx) or primConstraint(c, m.regular orelse m, ctx)) return true;
    }
    return false;
}

fn thisArgument(c: *Checker, receiver: *Node, optional: bool) *Type {
    const t = checkExpr(c, receiver);
    return if (optional) nonNull(c, t) else t;
}

fn widenUnique(c: *Checker, t: *Type) *Type {
    return if (t.data == .unique) c.t_symbol else t;
}

pub fn widenFresh(c: *Checker, t: *Type) *Type {
    return switch (t.data) {
        .str_lit => if (t.regular != null) c.t_string else t,
        .num_lit => if (t.regular != null) c.t_number else t,
        .big_lit => if (t.regular != null) c.t_bigint else t,
        .bool_lit => if (t.regular != null) c.t_boolean else t,
        .enum_lit => |e| if (t.regular != null) (if (e.parent.flags & F.enum_any != 0) d.declaredType(c, e.parent) else t) else t,
        .union_ => |u| blk: {
            const out = c.a.alloc(*Type, u.len) catch oom();
            for (u, 0..) |m, i| out[i] = widenFresh(c, m);
            break :blk c.getUnion(out);
        },
        else => t,
    };
}

/// The literal `t` with `prop` applied to each property type.
fn rebuildLiteral(c: *Checker, t: *Type, comptime prop: fn (*Checker, *Type) *Type) *Type {
    const src = d.membersOf(c, t);
    const props = src.props.values();
    // Most literals hold nothing `prop` changes, and those keep their table.
    var changed: ?*T.Members = null;
    for (props, 0..) |p, i| {
        if (isAccessor(p)) {
            if (changed) |m| m.props.put(c.a, p.name, p) catch oom();
            continue;
        }
        const before = d.propType(c, p);
        const after = prop(c, before);
        if (changed == null and after == before) continue;
        const m = changed orelse first: {
            const x = c.membersFor(props.len);
            for (props[0..i]) |same| x.props.put(c.a, same.name, same) catch oom();
            changed = x;
            break :first x;
        };
        const q = c.create(Prop, p.*);
        q.ty = after;
        m.props.put(c.a, p.name, q) catch oom();
    }
    return settledLiteral(c, t, changed orelse src);
}

/// An accessor widened what it returns by itself, and its body may well read the declaration that
/// is being widened right now.
fn isAccessor(p: *Prop) bool {
    const n = p.decl orelse return false;
    return n.data == .func and (n.data.func.kind == .getter or n.data.func.kind == .setter);
}

fn settledLiteral(c: *Checker, t: *Type, m: *T.Members) *Type {
    var copy = t.data.obj.*;
    copy.lit = false;
    copy.was_lit = true;
    const src = d.membersOf(c, t);
    m.calls = src.calls;
    m.ctors = src.ctors;
    m.indexes = src.indexes;
    copy.members = m;
    const r = c.newObj(copy);
    r.vars = t.vars;
    return r;
}

/// Drops freshness only. Widening is separate because an argument or a target
/// keeps the shape of `c ? {} : { a: 1 }`, which only a declaration normalizes.
pub fn regularize(c: *Checker, t: *Type) *Type {
    if (t.data == .obj and t.data.obj.lit) {
        if (c.regular_objs.get(t)) |r| return r;
        const r = rebuildLiteral(c, t, regularize);
        c.regular_objs.put(c.a, t, r) catch oom();
        return r;
    }
    if (t.data == .union_) {
        var change = false;
        for (t.data.union_) |m| if (m.regular != null or (m.data == .obj and m.data.obj.lit)) {
            change = true;
        };
        if (!change) return t;
        const out = c.a.alloc(*Type, t.data.union_.len) catch oom();
        for (t.data.union_, 0..) |m, i| out[i] = regularize(c, m);
        return c.getUnion(out);
    }
    return t.regular orelse t;
}

pub fn regularWiden(c: *Checker, t: *Type) *Type {
    return regularize(c, widenObjectLiterals(c, t));
}

/// What is destructured is read unwidened: in `x ?? {}` the `{}` is still a closed literal that
/// simply lacks what `x` has, and it must not swallow `x`.
pub fn patternParent(c: *Checker, t: *Type) *Type {
    if (t.data == .union_) for (t.data.union_) |m| {
        if (m.data == .obj and m.data.obj.lit and relate.isEmptyObject(c, m)) return regularize(c, t);
    };
    return regularWiden(c, t);
}

fn widenedLiteral(c: *Checker, t: *Type) *Type {
    if (c.widened_objs.get(t)) |r| return r;
    const r = rebuildLiteral(c, t, regularWiden);
    c.widened_objs.put(c.a, t, r) catch oom();
    return r;
}

/// The literals one literal sits next to, a property deeper at each level: `c ? { a: 1 } : { b: 2 }`
/// widens so each branch names every property, which is what lets `x.a` be read on the union
/// afterwards, and the same goes for `[{ o: {} }, { o: { a: 1 } }]` one level down.
const Widening = struct {
    parent: ?*Widening = null,
    prop: []const u8 = "",
    kin: ?[]*Type = null,
    known: ?[]const []const u8 = null,

    fn siblings(w: *Widening, c: *Checker) []*Type {
        if (w.kin) |k| return k;
        var out = c.newList(*Type);
        for (w.parent.?.siblings(c)) |t| {
            if (t.data != .obj or !t.data.obj.lit) continue;
            const p = d.ownProp(c, t, w.prop) orelse continue;
            const v = d.propType(c, p);
            if (v.data == .union_) out.appendSlice(c.a, v.data.union_) catch oom() else out.append(c.a, v) catch oom();
        }
        w.kin = out.items;
        return out.items;
    }

    fn names(w: *Widening, c: *Checker) []const []const u8 {
        if (w.known) |k| return k;
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (w.siblings(c)) |t| {
            if (t.data != .obj or !t.data.obj.lit or t.data.obj.spread) continue;
            for (d.membersOf(c, t).props.keys()) |k| seen.put(c.a, k, {}) catch oom();
        }
        w.known = seen.keys();
        return seen.keys();
    }
};

fn widenLiteralAmong(c: *Checker, t: *Type, w: *Widening) *Type {
    const m = c.emptyMembers();
    const props = d.membersOf(c, t).props;
    for (props.values()) |p| {
        if (isAccessor(p)) {
            m.props.put(c.a, p.name, p) catch oom();
            continue;
        }
        const q = c.create(Prop, p.*);
        var inner = Widening{ .parent = w, .prop = p.name };
        q.ty = regularize(c, widenAmong(c, d.propType(c, p), &inner));
        m.props.put(c.a, p.name, q) catch oom();
    }
    for (w.names(c)) |k| if (!props.contains(k)) {
        m.props.put(c.a, k, c.create(Prop, .{ .name = k, .ty = c.t_undefined, .optional = true, .missing = c.exact_optional })) catch oom();
    };
    return settledLiteral(c, t, m);
}

fn widenAmong(c: *Checker, t: *Type, among: ?*Widening) *Type {
    if (c.isArrayType(t)) {
        const e = t.data.obj.args.?[0];
        const r = widenObjectLiterals(c, e);
        return if (r == e) t else c.internRef(t.data.obj.target.?, &.{r}, null);
    }
    if (t.data == .obj) {
        if (!t.data.obj.lit) return t;
        return if (among) |w| widenLiteralAmong(c, t, w) else widenedLiteral(c, t);
    }
    if (t.data != .union_) return t;
    if (among == null) if (c.widened_objs.get(t)) |r| return r;
    var top = Widening{ .kin = t.data.union_ };
    const w = among orelse &top;
    const out = c.a.alloc(*Type, t.data.union_.len) catch oom();
    var change = false;
    var literal = false;
    var empty = false;
    for (t.data.union_, 0..) |m, i| {
        out[i] = if (isNullish(m)) m else widenAmong(c, m, w);
        change = change or out[i] != m;
        literal = literal or (m.data == .obj and m.data.obj.lit);
        empty = empty or relate.isEmptyObject(c, out[i]);
    }
    // Widened, an empty literal stops being closed and holds everything else in the union.
    const r = if (literal and empty) reduceSubtypes(c, out) else if (change) c.getUnion(out) else t;
    if (among == null) c.widened_objs.put(c.a, t, r) catch oom();
    return r;
}

/// The part of widening that concerns object literals, which applies even where primitives keep
/// their literal type.
pub fn widenObjectLiterals(c: *Checker, t: *Type) *Type {
    return widenAmong(c, t, null);
}

pub fn widenInit(c: *Checker, init: *Node, t: *Type, is_const: bool) *Type {
    _ = init;
    if (is_const) return widenObjectLiterals(c, t);
    const w = widenUnique(c, regularize(c, widenFresh(c, widenObjectLiterals(c, t))));
    if (!c.strict_null and (w.data == .null or w.data == .undefined)) return c.t_any;
    return w;
}

// ---- functions ----

fn isUntypedParam(p: *Node) bool {
    const x = p.data.param;
    return x.type == null and !(x.name.data == .identifier and std.mem.eql(u8, x.name.data.identifier, "this"));
}

/// `isSensitive` for a call argument: a literal is walked once, not once per candidate and pass.
fn sensitiveArg(c: *Checker, n: *Node) bool {
    switch (n.data) {
        .object_lit, .array_lit => {},
        else => return isSensitive(n),
    }
    const gop = c.sensitive_args.getOrPut(c.a, n) catch oom();
    if (!gop.found_existing) gop.value_ptr.* = isSensitive(n);
    return gop.value_ptr.*;
}

pub fn isSensitive(n0: *Node) bool {
    const n = n0;
    switch (n.data) {
        .func => |f| {
            if (f.kind != .arrow and f.kind != .expr and f.kind != .method) return false;
            for (f.params) |p| if (isUntypedParam(p)) return true;
            if (f.kind == .arrow and f.type_params.items.len == 0 and f.ret == null) {
                if (f.body) |b| if (!ast.isBlockBody(b)) return isSensitive(b);
            }
            return false;
        },
        .object_lit => |x| {
            for (x.props) |p| {
                switch (p.data) {
                    .property_assign => |y| if (isSensitive(y.value)) return true,
                    .func => if (isSensitive(p)) return true,
                    else => {},
                }
            }
            return false;
        },
        .array_lit => |x| {
            for (x.elems) |e| if (isSensitive(e)) return true;
            return false;
        },
        .conditional => |x| return isSensitive(x.then) or isSensitive(x.els),
        .binary => |x| return (x.op == .pipe2 or x.op == .qq) and (isSensitive(x.left) or isSensitive(x.right)),
        .paren => |x| return isSensitive(x.expr),
        .spread_elem => |x| return isSensitive(x.expr),
        else => return false,
    }
}

fn sigFromType(c: *Checker, t0: *Type, fnode: *Node) ?*Sig {
    const t = t0;
    if (t.data == .union_) {
        var sigs = c.newList(*Sig);
        for (t.data.union_) |m| {
            if (m.data == .null or m.data == .undefined) continue;
            const s = sigFromType(c, m, fnode) orelse continue;
            if (sigs.items.len > 0 and !sameShape(c, sigs.items[0], s)) return null;
            sigs.append(c.a, s) catch oom();
        }
        if (sigs.items.len == 0) return null;
        if (sigs.items.len == 1) return sigs.items[0];
        return d.unionOfReturns(c, sigs.items);
    }
    if (t.data == .param or t.data == .access or t.data == .cond) {
        const k = d.baseConstraint(c, t);
        if (k == t or k.data == .unknown) return null;
        return sigFromType(c, k, fnode);
    }
    if (t.data != .obj and t.data != .inter) return null;
    var found: ?*Sig = null;
    for (d.callSigs(c, t)) |s| {
        if (isAritySmaller(s, fnode)) continue;
        if (found) |x| {
            found = (if (c.no_implicit_any) combinedSig(c, x, s) else null) orelse return null;
        } else found = s;
    }
    return found;
}

fn isAritySmaller(s: *Sig, fnode: *Node) bool {
    if (s.has_rest) return false;
    const params = fnode.data.func.params;
    var required: usize = 0;
    for (params) |p| {
        if (p.data.param.init != null or p.data.param.question or p.data.param.dotdotdot) break;
        required += 1;
    }
    if (d.thisParam(fnode) != null) required -|= 1;
    return s.params.len < required;
}

/// Overloads give a lambda the union of what each one would pass at that position. Generic ones
/// must be generic alike, and then the first one's type parameters speak for both.
fn combinedSig(c: *Checker, a: *Sig, b: *Sig) ?*Sig {
    if (!sameTypeParams(c, a, b)) return null;
    const mapper = if (a.tparams.len > 0) d.arrayMapper(c, b.tparams, a.tparams) else null;
    const fixed_a = if (a.has_rest) a.params.len - 1 else a.params.len;
    const fixed_b = if (b.has_rest) b.params.len - 1 else b.params.len;
    const n = @max(fixed_a, fixed_b);
    const has_rest = a.has_rest or b.has_rest;
    const params = c.a.alloc(T.SigParam, n + @intFromBool(has_rest)) catch oom();
    for (params, 0..) |*p, i| {
        const x = relate.typeAt(c, a, i) orelse c.t_unknown;
        const y = relate.typeAt(c, b, i) orelse c.t_unknown;
        const u = c.getUnion(&.{ x, d.instantiate(c, y, mapper) });
        const from: T.SigParam = if (i < a.params.len) a.params[i] else if (i < b.params.len) b.params[i] else .{ .name = "args" };
        p.* = .{ .name = from.name, .sym = from.sym, .optional = from.optional, .ty = if (i < n) u else d.arrayOf(c, u) };
    }
    return c.create(Sig, .{
        .tparams = a.tparams,
        .params = params,
        .has_rest = has_rest,
        .min_args = @min(a.min_args, b.min_args),
        .ret = c.getIntersection(&.{ d.returnOf(c, a), d.instantiate(c, d.returnOf(c, b), mapper) }),
    });
}

fn sameTypeParams(c: *Checker, a: *Sig, b: *Sig) bool {
    if (a.tparams.len != b.tparams.len) return false;
    if (a.tparams.len == 0) return true;
    const mapper = d.arrayMapper(c, b.tparams, a.tparams);
    for (a.tparams, b.tparams) |x, y| {
        const left = d.constraintOf(c, x) orelse c.t_unknown;
        const right = d.constraintOf(c, y) orelse c.t_unknown;
        if (!relate.isIdentical(c, left, d.instantiate(c, right, mapper))) return false;
    }
    return true;
}

fn sameShape(c: *Checker, a: *Sig, b: *Sig) bool {
    if (a.params.len != b.params.len or a.has_rest != b.has_rest) return false;
    for (0..a.params.len) |i| {
        if (!relate.isIdentical(c, d.paramTypeAt(c, a, i), d.paramTypeAt(c, b, i))) return false;
    }
    return true;
}

pub fn contextualSig(c: *Checker, fnode: *Node) ?*Sig {
    // An accessor is no method: its property may be what the context got from this very literal.
    if (fnode.data.func.kind == .getter or fnode.data.func.kind == .setter) return null;
    const t = signatureContext(c, fnode) orelse return null;
    return sigFromType(c, t, fnode);
}

fn signatureContext(c: *Checker, fnode: *Node) ?*Type {
    const save = c.context_for_signature;
    defer c.context_for_signature = save;
    c.context_for_signature = true;
    return contextualType(c, fnode);
}

/// A lambda's parameters take their types once, from the first context that reaches them.
pub fn assignContext(c: *Checker, fnode: *Node) void {
    if (c.context_assigned.contains(fnode)) return;
    const f = fnode.data.func;
    if (f.kind != .arrow and f.kind != .expr and f.kind != .method) return;
    if (binder.callOnTheSpot(fnode)) |call| return assignFromCall(c, fnode, call);
    const ct = signatureContext(c, fnode) orelse return;
    const ctx = inferFor(c, fnode);
    if (ct.data == .err and ct != c.t_unresolved) {
        // A failed call hands out `any` context only for the final, reporting visit.
        if (!quiet(c)) {
            c.context_assigned.put(c.a, fnode, {}) catch oom();
            for (f.params) |p| if (p.data.param.type == null) c.param_types.put(c.a, p, c.t_err) catch oom();
        }
        return;
    }
    // The context can hold this very lambda, through a `T` inferred from the literal around it.
    if (c.context_assigning.contains(fnode)) return;
    c.context_assigning.put(c.a, fnode, {}) catch oom();
    const found = sigFromType(c, ct, fnode);
    _ = c.context_assigning.remove(fnode);
    const sig = found orelse return;
    c.context_assigned.put(c.a, fnode, {}) catch oom();
    // The lambda stands in for the context and is compared to it as a generic function.
    if (f.type_params.items.len == 0 and isSensitive(fnode)) d.sigOfDecl(c, fnode).tparams = sig.tparams;
    const mapper = if (ctx) |x| x.mapper else null;
    const offset: usize = if (d.thisParam(fnode) != null) 1 else 0;
    for (f.params[offset..], 0..) |p, i| {
        const x = p.data.param;
        if (x.type != null) continue;
        var t: *Type = undefined;
        if (x.dotdotdot) {
            t = restFrom(c, sig, i);
        } else {
            // Past the signature's last parameter tsc assigns no contextual type at all: the
            // parameter is an implicit `any`, reported only under noImplicitAny.
            t = relate.typeAt(c, sig, i) orelse (if (sig.has_rest) c.t_err else continue);
            if (x.question or x.init != null) t = d.addOptional(c, t);
        }
        c.param_types.put(c.a, p, d.instantiate(c, t, mapper)) catch oom();
    }
}

/// `(o => o.has(k))(new Set())` has its arguments right there: what they pass is what it takes,
/// and a parameter left without one is `undefined`.
fn assignFromCall(c: *Checker, fnode: *Node, call: *Node) void {
    c.context_assigned.put(c.a, fnode, {}) catch oom();
    const args = call.data.call.args;
    const spread = for (args) |a| {
        if (a.data == .spread_elem) break true;
    } else false;
    const offset: usize = if (d.thisParam(fnode) != null) 1 else 0;
    for (fnode.data.func.params[offset..], 0..) |p, i| {
        const x = p.data.param;
        if (x.type != null) continue;
        var t: *Type = undefined;
        if (spread) {
            t = c.t_err;
        } else if (x.dotdotdot) {
            const rest = args[@min(i, args.len)..];
            const elems = c.a.alloc(*Type, rest.len) catch oom();
            for (rest, elems) |a, *e| e.* = widenInit(c, a, checkSilent(c, a), false);
            const flags = c.a.alloc(T.ElemFlag, rest.len) catch oom();
            @memset(flags, .required);
            t = c.makeTuple(elems, flags, false, &.{});
        } else if (i < args.len) {
            t = widenInit(c, args[i], checkSilent(c, args[i]), false);
        } else if (x.init != null) {
            continue;
        } else {
            t = c.t_undefined;
        }
        c.param_types.put(c.a, p, if (x.question) d.addOptional(c, t) else t) catch oom();
    }
}

/// `(...args) => ...`: everything the signature takes from position `i` on, still one by one.
fn restFrom(c: *Checker, sig: *Sig, i: usize) *Type {
    const fixed = if (sig.has_rest) sig.params.len - 1 else sig.params.len;
    const rest = relate.restType(c, sig);
    if (i == fixed) if (rest) |r| return r;
    var elems = c.newList(*Type);
    var flags = c.newList(T.ElemFlag);
    var k = i;
    while (k < fixed) : (k += 1) {
        elems.append(c.a, relate.typeAt(c, sig, k) orelse break) catch oom();
        flags.append(c.a, if (k < sig.min_args) .required else .optional) catch oom();
    }
    if (rest) |r| {
        const skip = if (i > fixed) i - fixed else 0;
        if (T.isTupleType(r)) {
            const o = r.data.obj;
            for (o.tuple.elems, o.tuple.eflags, 0..) |e, f, n| {
                if (n < skip and f != .rest and f != .variadic) continue;
                elems.append(c.a, e) catch oom();
                flags.append(c.a, f) catch oom();
            }
        } else if (c.isArrayType(r)) {
            if (elems.items.len == 0) return r;
            elems.append(c.a, r.data.obj.args.?[0]) catch oom();
            flags.append(c.a, .rest) catch oom();
        } else {
            elems.append(c.a, r) catch oom();
            flags.append(c.a, .variadic) catch oom();
        }
    }
    return c.makeTuple(elems.items, flags.items, false, &.{});
}

fn checkFunctionExpr(c: *Checker, n: *Node) *Type {
    if (c.skip_sensitive and isSensitive(n)) {
        c.quiet_debt += 1;
        return c.t_pending_fn;
    }
    assignContext(c, n);
    if (c.silent == 0) {
        const gop = c.checked_funcs.getOrPut(c.a, n) catch oom();
        if (!gop.found_existing) c.deferred.append(c.a, n) catch oom();
    } else c.quiet_funcs.append(c.a, n) catch oom();
    // An object literal's method has a symbol, but only the node carries its signature.
    const t = if (n.symbol() != null and n.data.func.kind != .method) d.typeOfSymbol(c, n.symbol().?) else lambdaType(c, n);
    // The return type must come from the body while the call's context is still on the stack;
    // read lazily from `inferTypes` it would lose it.
    if (n.data.func.ret == null and n.data.func.body != null and inContext(c, n)) {
        const save = c.skip_sensitive;
        defer c.skip_sensitive = save;
        c.skip_sensitive = false;
        const sigs = d.callSigs(c, t);
        // Coming back to a function whose return is being read is no new read: the literal around
        // a method gets checked again for its `this`.
        if (sigs.len == 1 and sigs[0].ret == null and !sigs[0].ret_resolving) {
            // Only a context with a return of its own compares this one, so only then can a
            // declaration that is waiting for it be at fault.
            const compared = comparesReturn(c, n);
            if (!compared) c.pushResolution(null);
            _ = d.returnOf(c, sigs[0]);
            if (!compared) _ = c.popResolution();
        }
    }
    return t;
}

fn comparesReturn(c: *Checker, n: *Node) bool {
    const sig = contextualSig(c, n) orelse return false;
    const r = d.returnOf(c, sig);
    return r.data != .void and !T.isAny(r);
}

fn hasAnnotatedOwner(s: *Symbol) bool {
    const n = (s.parent orelse return false).value_decl orelse return false;
    return n.data == .var_decl and n.data.var_decl.type != null;
}

fn inContext(c: *Checker, n: *Node) bool {
    var cur: ?*Node = n;
    while (cur) |x| : (cur = x.parent) {
        if (ctxEntry(c, x) != null) return true;
    }
    return false;
}

fn lambdaType(c: *Checker, n: *Node) *Type {
    if (c.node_types.get(n)) |t| return t;
    const t = c.newObj(.{ .kind = .anon, .node = n });
    t.vars = d.outerTParams(c, n).len > 0;
    c.node_types.put(c.a, n, t) catch oom();
    return t;
}

const Returns = struct { c: *Checker, list: std.ArrayList(*Node) = .empty, yields: std.ArrayList(*Node) = .empty };

fn collectReturns(r: *Returns, n: *Node) void {
    switch (n.data) {
        .func, .class, .interface, .type_alias, .module_decl => return,
        .return_stmt => r.list.append(r.c.a, n) catch oom(),
        .yield_expr => r.yields.append(r.c.a, n) catch oom(),
        else => {},
    }
    ast.forEachChild(n, r, collectReturns);
}

/// TS 5.5: a one-return boolean function can stand for `x is T` without saying so.
pub fn predicateFromBody(c: *Checker, s: *Sig, fnode: *Node) ?*T.Pred {
    const f = fnode.data.func;
    if (s.params.len == 0 or fnode.mods.async or f.asterisk) return null;
    if (f.kind == .getter or f.kind == .setter or f.kind == .ctor) return null;
    if (f.body == null) return null;
    const offset: usize = if (d.thisParam(fnode) != null) 1 else 0;
    // A lambda typed from context has no parameter types yet; it is asked again once it does.
    for (f.params[offset..]) |p| {
        if (p.data.param.type == null and p.data.param.init == null and !c.param_types.contains(p)) {
            s.pred_done = false;
            return null;
        }
    }
    const body = d.bodyOf(c, fnode).?;
    var single: ?*Node = null;
    if (body.block.data != .block) {
        single = body.block;
    } else {
        var r = Returns{ .c = c };
        ast.forEachChild(body.block, &r, collectReturns);
        if (r.list.items.len != 1) return null;
        single = r.list.items[0].data.return_stmt.expr orelse return null;
        if (body.end_flow) |e| if (flow.isReachable(c, e)) return null;
    }
    const e = binder.stripParens(single.?);
    if (checkSilent(c, e) != c.t_boolean) return null;
    for (s.params, 0..) |sp, i| {
        const pn = f.params[i + offset];
        const x = pn.data.param;
        if (x.dotdotdot or x.name.data != .identifier) continue;
        const sym = pn.symbol() orelse continue;
        if (!isStableBinding(c, sym)) continue;
        const init = d.typeOfParam(c, pn);
        if (init == c.t_boolean) continue;
        if (flow.refinedParam(c, x.name, e, fnode, init)) |ty| {
            return c.create(T.Pred, .{ .asserts = false, .param_index = @intCast(i), .is_this = false, .ty = ty, .name = sp.name });
        }
    }
    return null;
}

/// The initializer of a `const` declared without a type, which flow may read through.
pub fn aliasedCondition(c: *Checker, n: *Node) ?*Node {
    return constInit(symbolOf(c, n) orelse return null);
}

pub fn constInit(s: *Symbol) ?*Node {
    if (!isConstVar(s)) return null;
    const v = s.value_decl orelse return null;
    if (v.data != .var_decl or v.data.var_decl.type != null) return null;
    return v.data.var_decl.init;
}

pub fn returnTypeFromBody(c: *Checker, fnode: *Node) *Type {
    const f = fnode.data.func;
    const body = d.bodyOf(c, fnode) orelse return c.t_any;
    c.silent += 1;
    defer c.silent -= 1;
    // A body has one answer, whichever pass over which call happens to ask first.
    const skip = c.skip_sensitive;
    defer c.skip_sensitive = skip;
    c.skip_sensitive = false;
    const is_async = fnode.mods.async;
    var parts = c.newList(*Type);
    var r = Returns{ .c = c };
    if (body.block.data != .block) {
        parts.append(c.a, checkExpr(c, body.block)) catch oom();
    } else {
        ast.forEachChild(body.block, &r, collectReturns);
        var implicit = if (body.end_flow) |e| flow.isReachable(c, e) else false;
        var self_call = false;
        for (r.list.items) |x| {
            if (x.data.return_stmt.expr) |e| {
                if (!flow.isReachable(c, x.flow())) continue;
                if (isCallToSelf(c, fnode, e)) {
                    self_call = true;
                    continue;
                }
                parts.append(c.a, checkExpr(c, e)) catch oom();
            } else {
                if (flow.isReachable(c, x.flow())) implicit = true;
            }
        }
        if (parts.items.len == 0 and !implicit and !f.asterisk and (self_call or mayReturnNever(fnode))) {
            return if (is_async) promiseOf(c, c.t_never) else c.t_never;
        }
        if (implicit and parts.items.len > 0) parts.append(c.a, c.t_undefined) catch oom();
        if (parts.items.len == 0) {
            if (f.asterisk) {
                parts.append(c.a, c.t_void) catch oom();
            } else {
                const none = valuelessReturn(c, fnode);
                return if (is_async) promiseOf(c, none) else none;
            }
        }
    }
    if (is_async) for (parts.items) |*x| {
        x.* = awaitedOf(c, x.*);
    };
    const t = widenFor(c, fnode, body.block, reduceSubtypes(c, parts.items), if (f.asterisk) generatorContext(c, fnode, .ret) else literalReturnContext(c, fnode));
    if (f.asterisk) {
        var ys = c.newList(*Type);
        for (r.yields.items) |y| {
            const x = y.data.yield_expr;
            if (x.star) {
                ys.append(c.a, if (x.expr) |e| iteratedOf(c, e, checkExpr(c, e), is_async) else c.t_any) catch oom();
            } else if (x.expr) |e| ys.append(c.a, checkExpr(c, e)) catch oom() else ys.append(c.a, c.t_undefined) catch oom();
        }
        const y = if (ys.items.len == 0) c.t_never else widenFor(c, fnode, body.block, c.getUnion(ys.items), generatorContext(c, fnode, .yield));
        return d.generic(c, if (is_async) "AsyncGenerator" else "Generator", &.{ y, t, generatorContext(c, fnode, .next) orelse c.t_err });
    }
    return if (is_async) promiseOf(c, t) else t;
}

/// `return f()` inside `f` says nothing about what `f` returns.
fn isCallToSelf(c: *Checker, fnode: *Node, e: *Node) bool {
    var x = binder.stripParens(e);
    if (fnode.mods.async and x.data == .await_expr) x = binder.stripParens(x.data.await_expr.expr);
    if (x.data != .call or x.data.call.callee.data != .identifier) return false;
    const callee = x.data.call.callee;
    const t = checkSilent(c, callee);
    if (t.data != .obj) return false;
    const own = fnode.symbol();
    if (t.data.obj.node != fnode and (own == null or t.data.obj.sym != own)) return false;
    const kind = fnode.data.func.kind;
    if (kind != .expr and kind != .arrow) return true;
    // Only a name that cannot be pointed elsewhere is sure to still be this function.
    const s = symbolOf(c, callee) orelse return false;
    const decl = s.value_decl orelse return false;
    return isStableBinding(c, s) or (decl.data == .func and decl.data.func.kind == .expr);
}

/// A declaration or a class method has a name to be called by, so a body that only throws is
/// taken for an unfinished `void` and not for a promise never to return.
fn mayReturnNever(fnode: *Node) bool {
    return switch (fnode.data.func.kind) {
        .expr, .arrow => true,
        .method => fnode.parent != null and fnode.parent.?.data == .object_lit,
        else => false,
    };
}

/// A lone literal widens unless the context asks for it; several name a set on purpose.
fn widenFor(c: *Checker, fnode: *Node, body: *Node, t: *Type, ctx: ?*Type) *Type {
    if (!relate.isUnitType(t.regular orelse t)) return regularize(c, widenObjectLiterals(c, t));
    const want = if (ctx) |x| withReturnMapper(c, fnode, x) else null;
    if (want == null or !literalCtx(c, t.regular orelse t, want.?)) return widenInit(c, body, t, false);
    return regularize(c, t);
}

/// Since TypeScript 6 a body without a value satisfies any context that admits `undefined`.
fn valuelessReturn(c: *Checker, fnode: *Node) *Type {
    const t = contextualReturn(c, fnode) orelse return c.t_void;
    const admits = switch (t.data) {
        .undefined => true,
        .union_ => |x| std.mem.indexOfScalar(*Type, x, c.t_undefined) != null,
        else => false,
    };
    return if (admits) c.t_undefined else c.t_void;
}

pub fn reduceSubtypes(c: *Checker, parts: []const *Type) *Type {
    var seen = c.newList(*Type);
    var big: ?T.IdMap(*Type, void) = if (parts.len > 64) .empty else null;
    for (parts) |p| {
        // Members compete one by one, whichever branch brought them.
        const members: []const *Type = if (p.data == .union_ and p.data.union_.len <= 16) p.data.union_ else &.{p};
        for (members) |m| {
            // A huge literal would make this scan quadratic; the set takes over for those.
            const dup = if (big) |*set| (set.getOrPut(c.a, m) catch oom()).found_existing else std.mem.indexOfScalar(*Type, seen.items, m) != null;
            if (!dup) seen.append(c.a, m) catch oom();
        }
    }
    if (seen.items.len < 2) return c.getUnion(seen.items);
    // `[]` carries no element type of its own, so it never survives next to a real array.
    const empty = d.arrayOf(c, c.t_err);
    if (std.mem.indexOfScalar(*Type, seen.items, empty)) |at| {
        const other = for (seen.items) |p| {
            if (p != empty and (c.isArrayType(p) or T.isTupleType(p))) break true;
        } else false;
        if (other) _ = seen.orderedRemove(at);
    }
    if (seen.items.len < 2) return c.getUnion(seen.items);
    const objs = for (seen.items) |p| {
        if (p.data == .obj) break true;
    } else false;
    if (!objs or seen.items.len > 16) return c.getUnion(seen.items);
    var out = c.newList(*Type);
    outer: for (seen.items, 0..) |p, i| {
        for (seen.items, 0..) |q, j| {
            if (i == j or p.data != .obj or q.data != .obj) continue;
            if (absorbedBy(c, p, q) and !(j > i and absorbedBy(c, q, p))) continue :outer;
        }
        out.append(c.a, p) catch oom();
    }
    return c.getUnion(out.items);
}

/// A fresh literal keeps the properties a wider sibling does not name, and a literal describes one
/// value, so nothing with more properties than it wrote is a subtype of it.
fn absorbedBy(c: *Checker, p: *Type, q: *Type) bool {
    if (writesMore(c, p, q)) return false;
    if (q.data.obj.lit) {
        for (d.propsOf(c, p)) |x| {
            if (d.getProp(c, q, x.name) == null and d.propType(c, x).data != .undefined) return false;
        }
        if (d.indexesOf(c, p).len > d.indexesOf(c, q).len) return false;
    }
    // Two classes only ever stand for each other by derivation, however alike they look.
    const pt = p.data.obj.target orelse p;
    const qt = q.data.obj.target orelse q;
    if (pt.data.obj.is_class and qt.data.obj.is_class and !flow.hasBase(c, p, qt)) return false;
    const rp = regularize(c, p);
    const rq = regularize(c, q);
    if (relate.variantSubtype(c, rp, rq)) |r| return r;
    return if (p.data.obj.lit) relate.isSubtype(c, rp, rq) else relate.isStrictSubtype(c, rp, rq);
}

/// Freshness counts at any depth: `{ a: { b, c } }` is no subtype of `{ a: { b } }` while fresh.
fn writesMore(c: *Checker, p: *Type, q: *Type) bool {
    if (q.data.obj.lit and relate.isEmptyObject(c, q) and !relate.isEmptyObject(c, p)) return true;
    if (!p.data.obj.lit) return false;
    if (relate.excessProp(c, p, q) != null) return true;
    for (d.propsOf(c, p)) |x| {
        const inner = d.propType(c, x);
        if (inner.data != .obj) continue;
        const other = d.propType(c, d.getProp(c, q, x.name) orelse continue);
        if (other.data == .obj and writesMore(c, inner, other)) return true;
    }
    return false;
}

pub fn promiseOf(c: *Checker, t: *Type) *Type {
    return d.generic(c, "Promise", &.{t});
}

pub fn awaitedOf(c: *Checker, t0: *Type) *Type {
    return awaited(c, t0, 0);
}

fn awaited(c: *Checker, t: *Type, depth: u32) *Type {
    if (depth > 16) return c.t_err;
    switch (t.data) {
        .any, .err, .unknown, .never => return t,
        .union_ => |u| {
            const out = c.a.alloc(*Type, u.len) catch oom();
            for (u, 0..) |m, i| out[i] = awaited(c, m, depth + 1);
            return c.getUnion(out);
        },
        .obj, .inter => {},
        .param, .access, .cond => {
            const k = d.baseConstraint(c, t);
            if (k == t or k.data == .unknown) return t;
            if (d.getProp(c, k, "then") == null) return t;
            return c.t_err;
        },
        else => return t,
    }
    const then = d.getProp(c, t, "then") orelse return t;
    const pt = d.propType(c, then);
    if (T.isAny(pt)) return pt;
    const sigs = d.callSigs(c, pt);
    if (sigs.len == 0) return t;
    var parts = c.newList(*Type);
    for (sigs) |s| {
        const cb = relate.typeAt(c, s, 0) orelse continue;
        const inner = relate.removeDefinitelyUndefined(c, cb);
        const members: []const *Type = if (inner.data == .union_) inner.data.union_ else &.{inner};
        for (members) |m| {
            if (m.data == .null) continue;
            for (d.callSigs(c, m)) |x| {
                if (relate.typeAt(c, x, 0)) |v| parts.append(c.a, v) catch oom();
            }
        }
    }
    if (parts.items.len == 0) return c.t_err;
    return awaited(c, c.getUnion(parts.items), depth + 1);
}

pub fn iteratedOf(c: *Checker, n: *Node, t: *Type, is_await: bool) *Type {
    switch (t.data) {
        .any, .err => return t,
        .string, .str_lit => if (!is_await) return c.t_string,
        .never => return c.t_never,
        .union_ => |u| {
            const out = c.a.alloc(*Type, u.len) catch oom();
            for (u, 0..) |m, i| out[i] = iteratedOf(c, n, m, is_await);
            return c.getUnion(out);
        },
        else => {},
    }
    if (c.isArrayType(t)) return if (is_await) awaitedOf(c, t.data.obj.args.?[0]) else t.data.obj.args.?[0];
    if (T.isTupleType(t)) {
        const o = t.data.obj;
        if (o.tuple.elems.len == 0) return c.t_never;
        return if (is_await) awaitedOf(c, c.getUnion(o.tuple.elems)) else c.getUnion(o.tuple.elems);
    }
    const keys: []const []const u8 = if (is_await) &.{ "__@asyncIterator", "__@iterator" } else &.{"__@iterator"};
    for (keys) |key| {
        const p = d.getProp(c, t, key) orelse continue;
        const sigs = d.callSigs(c, d.propType(c, p));
        if (sigs.len == 0) continue;
        const it = d.returnOf(c, sigs[0]);
        if (T.isAny(it)) return it;
        const next = d.getProp(c, it, "next") orelse return c.t_err;
        const ns = d.callSigs(c, d.propType(c, next));
        if (ns.len == 0) return c.t_err;
        var r = d.returnOf(c, ns[0]);
        if (is_await) r = awaitedOf(c, r);
        // IteratorResult is a union; the yielded side is the one with `done?: false`.
        const members: []const *Type = if (r.data == .union_) r.data.union_ else &.{r};
        var parts = c.newList(*Type);
        for (members) |m| {
            const dp = d.getProp(c, m, "done");
            if (dp) |x| {
                const dt = d.propType(c, x);
                if ((dt.regular orelse dt) == c.t_true) continue;
            }
            const v = d.getProp(c, m, "value") orelse continue;
            parts.append(c.a, d.propType(c, v)) catch oom();
        }
        if (parts.items.len == 0) return c.t_err;
        const v = c.getUnion(parts.items);
        // `for await` over a sync iterable waits for each value it yields.
        return if (is_await and std.mem.eql(u8, key, "__@iterator")) awaitedOf(c, v) else v;
    }
    if (t.data == .param or t.data == .access or t.data == .cond or t.data == .inter) {
        const k = d.baseConstraint(c, t);
        if (k.vars or k == t or k.data == .unknown) return c.t_err;
        return iteratedOf(c, n, k, is_await);
    }
    if (t.data == .obj and (t.data.obj.any_base or t.data.obj.open)) return c.t_err;
    err(c, n, 2488, c.fmt("Type '{s}' must have a '[Symbol.iterator]()' method that returns an iterator.", .{show(c, t)}));
    return c.t_err;
}

pub fn propNameOf(c: *Checker, n: *Node) ?[]const u8 {
    return switch (n.data) {
        .identifier, .string_lit, .no_subst_template => |v| v,
        .numeric_lit => |v| d.numName(c, (emit.parseNumber(v) orelse 0)),
        .computed_name => |x| blk: {
            const e = binder.stripParens(x.expr);
            if (e.data == .prop_access and e.data.prop_access.expr.data == .identifier and std.mem.eql(u8, e.data.prop_access.expr.data.identifier, "Symbol")) {
                break :blk c.fmt("__@{s}", .{e.data.prop_access.name.data.identifier});
            }
            if (e.data == .string_lit) break :blk e.data.string_lit;
            if (e.data == .numeric_lit) break :blk d.numName(c, (emit.parseNumber(e.data.numeric_lit) orelse 0));
            const t = checkSilent(c, e);
            break :blk d.literalName(c, t.regular orelse t);
        },
        else => null,
    };
}

// ---- destructuring ----

pub fn destructuredType(c: *Checker, parent: *Type, pat: *Node, el: *Node) *Type {
    const e = el.data.binding_elem;
    if (T.isAny(parent)) return parent;
    if (pat.data == .object_pattern) {
        if (e.dotdotdot) {
            var skip = c.newList([]const u8);
            for (pat.data.object_pattern.elems) |o| {
                if (o == el or o.data != .binding_elem) continue;
                const key = o.data.binding_elem.prop_name orelse o.data.binding_elem.name;
                skip.append(c.a, propNameOf(c, key) orelse return c.t_err) catch oom();
            }
            return restOf(c, parent, skip.items);
        }
        const key = e.prop_name orelse e.name;
        const name = propNameOf(c, key) orelse return c.t_err;
        const base = nonNull(c, parent);
        if (T.isAny(base)) return base;
        if (base.data == .unknown or base.vars and base.data != .obj) {
            const ap = d.getApparent(c, base);
            if (d.getProp(c, ap, name)) |p| {
                unused.noteProperty(c, el, p);
                return d.propType(c, p);
            }
            return c.t_err;
        }
        if (d.getProp(c, base, name)) |p| {
            unused.noteProperty(c, el, p);
            return d.propType(c, p);
        }
        if (d.indexValue(c, base, d.nameToKey(c, name))) |v| return v;
        if (base.data == .obj and (base.data.obj.open or base.data.obj.any_base)) return c.t_err;
        err(c, key, 2339, c.fmt("Property '{s}' does not exist on type '{s}'.", .{ name, show(c, base) }));
        return c.t_err;
    }
    const elems = pat.data.array_pattern.elems;
    const i = for (elems, 0..) |x, k| {
        if (x == el) break k;
    } else 0;
    const base = nonNull(c, parent);
    if (base.data == .union_) {
        const all = for (base.data.union_) |m| {
            if (!T.isTupleType(m) and !c.isArrayType(m)) break false;
        } else true;
        if (all) {
            const reached = for (base.data.union_) |m| {
                if (T.isTupleType(m) and i < m.data.obj.tuple.elems.len) break true;
            } else false;
            const out = c.a.alloc(*Type, base.data.union_.len) catch oom();
            for (base.data.union_, 0..) |m, k| {
                out[k] = if (reached and !e.dotdotdot and d.endsBefore(m, i)) c.t_undefined else destructuredType(c, m, pat, el);
            }
            return c.getUnion(out);
        }
    }
    if (T.isTupleType(base)) {
        const o = base.data.obj;
        if (e.dotdotdot) {
            if (i >= o.tuple.elems.len) return c.makeTuple(&.{}, &.{}, false, &.{});
            return c.makeTuple(o.tuple.elems[i..], o.tuple.eflags[i..], false, &.{});
        }
        if (i < o.tuple.elems.len) {
            return if (o.tuple.eflags[i] == .optional) d.addOptional(c, o.tuple.elems[i]) else o.tuple.elems[i];
        }
        for (o.tuple.eflags, 0..) |f, k| if (f == .rest) return o.tuple.elems[k];
        // A default covers what the tuple does not have.
        if (e.init != null) return c.t_undefined;
        if (el.parent != null) err(c, el, 2493, c.fmt("Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{ show(c, base), o.tuple.elems.len, i }));
        return c.t_err;
    }
    const v = iteratedOf(c, el, base, false);
    return if (e.dotdotdot) d.arrayOf(c, v) else v;
}

fn restOf(c: *Checker, t: *Type, skip: []const []const u8) *Type {
    if (t.data == .union_) {
        var out = c.newList(*Type);
        for (t.data.union_) |m| if (m.data != .null and m.data != .undefined) out.append(c.a, restOf(c, m, skip)) catch oom();
        return if (out.items.len > 0) c.getUnion(out.items) else restOf(c, t.data.union_[0], skip);
    }
    if (t.vars and t.data != .obj) return c.t_err;
    const ap = d.getApparent(c, t);
    const m = c.emptyMembers();
    outer: for (d.propsOf(c, ap)) |p| {
        for (skip) |s| if (std.mem.eql(u8, s, p.name)) continue :outer;
        if (p.private or p.protected or p.method) continue;
        const q = c.create(Prop, p.*);
        q.ty = d.propType(c, p);
        // tsc's `getSpreadSymbol(prop, false)`: the rest is a fresh object the code owns.
        q.readonly = false;
        m.props.put(c.a, p.name, q) catch oom();
    }
    m.indexes = c.dupe(T.Index, d.indexesOf(c, ap));
    return c.newObj(.{ .kind = .anon, .members = m });
}

fn isDestructuringTarget(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .binary => |x| x.op == .assign and x.left == n,
        .array_lit, .spread_elem => isDestructuringTarget(p),
        .property_assign => |x| x.value == n and if (p.parent) |o| isDestructuringTarget(o) else false,
        else => false,
    };
}

fn destructuredElement(c: *Checker, n: *Node, t: *Type, i: usize) *Type {
    if (T.isAny(t)) return t;
    if (t.data == .union_) {
        const out = c.a.alloc(*Type, t.data.union_.len) catch oom();
        for (t.data.union_, out) |m, *o| o.* = destructuredElement(c, n, m, i);
        return c.getUnion(out);
    }
    if (T.isTupleType(t)) return d.tupleElemAt(c, t, @floatFromInt(i));
    c.silent += 1;
    defer c.silent -= 1;
    const v = iteratedOf(c, n, t, false);
    return if (c.no_unchecked_index) d.addOptional(c, v) else v;
}

fn destructuredMember(c: *Checker, t: *Type, name: []const u8) ?*Type {
    if (T.isAny(t)) return t;
    if (d.getProp(c, t, name)) |p| return d.propType(c, p);
    return d.indexValue(c, t, c.t_string);
}

pub fn assignedType(c: *Checker, n: *Node) ?*Type {
    switch (n.data) {
        .var_decl => |v| {
            if (v.init) |i| return checkSilent(c, i);
            const l = n.parent orelse return null;
            if (l.data == .var_list) if (l.parent) |p| {
                if (p.data == .for_of) return c.t_err;
                if (p.data == .for_in) return c.t_string;
            };
            return null;
        },
        .binding_elem => return if (n.symbol()) |s| d.typeOfSymbol(c, s) else null,
        else => {},
    }
    var cur = n;
    while (cur.parent) |p| {
        switch (p.data) {
            .paren, .non_null => cur = p,
            .binary => |x| {
                if (x.left != cur) return null;
                return checkSilent(c, x.right);
            },
            .prefix, .postfix => return c.t_number,
            .array_lit => |x| {
                const i = std.mem.indexOfScalar(*Node, x.elems, cur) orelse return null;
                return destructuredElement(c, p, assignedType(c, p) orelse return null, i);
            },
            .property_assign => |x| {
                if (x.value != cur) return null;
                const src = assignedType(c, p.parent orelse return null) orelse return null;
                return destructuredMember(c, src, propNameOf(c, x.name) orelse return null);
            },
            .shorthand_assign => |x| {
                const src = assignedType(c, p.parent orelse return null) orelse return null;
                return destructuredMember(c, src, x.name.data.identifier);
            },
            else => return null,
        }
    }
    return null;
}

// ---- null handling ----

fn exprName(c: *Checker, n: *Node) ?[]const u8 {
    return switch (n.data) {
        .identifier => |v| v,
        // tsc parses `this` in `typeof this.x` as a name; elsewhere it is no entity name.
        .this_expr => if (inTypeQuery(n)) "this" else null,
        .paren => |x| exprName(c, x.expr),
        .prop_access => |x| blk: {
            const l = exprName(c, x.expr) orelse break :blk null;
            break :blk c.fmt("{s}.{s}", .{ l, ast.memberText(x.name) });
        },
        .non_null => |x| exprName(c, x.expr),
        else => null,
    };
}

fn inTypeQuery(n: *Node) bool {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) switch (x.data) {
        .type_query => return true,
        .prop_access, .qualified_name => {},
        else => return false,
    };
    return false;
}

fn nullFlags(t: *Type) struct { n: bool, u: bool } {
    var hn = false;
    var hu = false;
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    for (members) |m| {
        if (m.data == .null) hn = true;
        if (m.data == .undefined) hu = true;
    }
    return .{ .n = hn, .u = hu };
}

pub fn nonNull(c: *Checker, t: *Type) *Type {
    if (!c.strict_null) return t;
    if (isNullish(t)) return c.t_never;
    if (t.data == .unknown) return c.t_empty;
    if (t.data != .union_) return definite(c, t);
    var parts = c.newList(*Type);
    for (t.data.union_) |m| if (!isNullish(m)) parts.append(c.a, definite(c, m)) catch oom();
    return c.getUnion(parts.items);
}

/// `T & null` can only ever hold the null.
pub fn isNullish(t: *Type) bool {
    return switch (t.data) {
        .null, .undefined, .void => true,
        .inter => |x| for (x) |m| {
            if (m.data == .null or m.data == .undefined or m.data == .void) break true;
        } else false,
        else => false,
    };
}

/// The value is known to be there, yet a `T` that admits `undefined` has to stay `T` to the reader.
pub fn definite(c: *Checker, t: *Type) *Type {
    if (t.data != .param and t.data != .access) return t;
    const k = d.baseConstraint(c, t);
    if (k.data != .unknown and !maybeNullable(k)) return t;
    return c.intersect(&.{ t, c.t_empty }, false);
}

fn isNullKeyword(n: *Node) bool {
    return n.data == .null_lit or (n.data == .identifier and std.mem.eql(u8, n.data.identifier, "undefined"));
}

/// Reports a value that may be null or undefined where one is required, then drops those parts.
fn checkNonNull(c: *Checker, t: *Type, n: *Node) *Type {
    if (!c.strict_null) return t;
    const f = nullFlags(t);
    if (t.data == .unknown) {
        if (exprName(c, n)) |name| {
            err(c, n, 18046, c.fmt("'{s}' is of type 'unknown'.", .{name}));
        } else err(c, n, 2571, "Object is of type 'unknown'.");
        return c.t_err;
    }
    if (!f.n and !f.u) return t;
    if (isNullKeyword(binder.stripParens(n))) {
        err(c, n, 18050, c.fmt("The value '{s}' cannot be used here.", .{if (f.n) "null" else "undefined"}));
        return c.t_err;
    }
    if (exprName(c, n)) |name| {
        if (f.n and f.u) {
            err(c, n, 18049, c.fmt("'{s}' is possibly 'null' or 'undefined'.", .{name}));
        } else if (f.n) {
            err(c, n, 18047, c.fmt("'{s}' is possibly 'null'.", .{name}));
        } else {
            err(c, n, 18048, c.fmt("'{s}' is possibly 'undefined'.", .{name}));
        }
    } else if (f.n and f.u) {
        err(c, n, 2533, "Object is possibly 'null' or 'undefined'.");
    } else if (f.n) {
        err(c, n, 2531, "Object is possibly 'null'.");
    } else {
        err(c, n, 2532, "Object is possibly 'undefined'.");
    }
    const r = nonNull(c, t);
    return if (r.data == .never) c.t_err else r;
}

// ---- member access ----

fn enclosingClass(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) if (x.data == .class) return x;
    return null;
}

fn checkVisibility(c: *Checker, n: *Node, left: *Type, p: *Prop, name_node: *Node) void {
    if (!p.private and !p.protected) return;
    const name = p.name;
    const owner_decl = if (p.decl) |x| ownerClass(x) else null;
    if (p.private) {
        var cur = enclosingClass(n);
        while (cur) |x| : (cur = enclosingClass(x)) if (x == owner_decl) return;
        const cls = if (owner_decl) |x| (if (x.symbol()) |s| s.name else "?") else "?";
        err(c, name_node, 2341, c.fmt("Property '{s}' is private and only accessible within class '{s}'.", .{ name, cls }));
        return;
    }
    var cur = enclosingClass(n);
    while (cur) |x| : (cur = enclosingClass(x)) {
        if (x == owner_decl) return;
        if (derivesFrom(c, x, owner_decl)) return;
    }
    if (!p.static and thisDerivesFrom(c, n, owner_decl)) return;
    const cls = if (owner_decl) |x| (if (x.symbol()) |s| s.name else "?") else "?";
    _ = left;
    err(c, name_node, 2445, c.fmt("Property '{s}' is protected and only accessible within class '{s}' and its subclasses.", .{ name, cls }));
}

/// A function written outside the class may still declare, or be promised, a `this` of it.
fn thisDerivesFrom(c: *Checker, n: *Node, owner: ?*Node) bool {
    const sym = (owner orelse return false).symbol() orelse return false;
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x.data != .func or x.data.func.kind == .arrow) continue;
        const this_ty = if (d.thisParam(x)) |p| d.typeFromNode(c, p.data.param.type orelse return false) else contextualThis(c, x) orelse return false;
        const k = if (this_ty.data == .param) d.baseConstraint(c, this_ty) else this_ty;
        return flow.hasBase(c, k, d.declaredType(c, sym));
    }
    return false;
}

fn ownerClass(x: *Node) ?*Node {
    var cur: ?*Node = x;
    while (cur) |y| : (cur = y.parent) if (y.data == .class) return y;
    return null;
}

fn derivesFrom(c: *Checker, cls: *Node, base: ?*Node) bool {
    const b = base orelse return false;
    const s = cls.symbol() orelse return false;
    const t = d.declaredType(c, s);
    if (t.data != .obj) return false;
    return baseHas(c, t, b, 0);
}

fn baseHas(c: *Checker, t: *Type, b: *Node, depth: u32) bool {
    if (depth > 32) return true;
    const g = if (t.data == .obj and t.data.obj.kind == .ref) t.data.obj.target.? else t;
    if (g.data != .obj or g.data.obj.kind != .iface) return false;
    if (g.data.obj.any_base) return true;
    for (d.basesOf(c, g)) |x| {
        const h = if (x.data == .obj and x.data.obj.kind == .ref) x.data.obj.target.? else x;
        if (h.data == .obj) if (h.data.obj.sym) |s| for (s.decls) |y| if (y == b) return true;
        if (baseHas(c, x, b, depth + 1)) return true;
    }
    return false;
}

/// An instance read of a member that exists only on the class itself.
fn hasStaticProp(c: *Checker, t: *Type, name: []const u8) bool {
    const h = if (t.data == .obj and t.data.obj.kind == .ref) t.data.obj.target.? else t;
    if (h.data != .obj) return false;
    const s = h.data.obj.sym orelse return false;
    if (s.flags & F.class == 0) return false;
    const p = d.getProp(c, d.typeOfSymbol(c, s), name) orelse return false;
    const decl = (p.sym orelse return false).value_decl orelse return false;
    return decl.mods.static;
}

fn missingProp(c: *Checker, n: *Node, name_node: *Node, name: []const u8, t: *Type) void {
    if (name.len > 0 and name[0] == '#') {
        err(c, name_node, 18013, c.fmt("Property '{s}' is not accessible outside class because it has a private identifier.", .{name}));
        return;
    }
    _ = n;
    const ap = d.getApparent(c, t);
    if (hasStaticProp(c, t, name)) {
        const shown = show(c, t);
        err(c, name_node, 2576, c.fmt("Property '{s}' does not exist on type '{s}'. Did you mean to access the static member '{s}.{s}' instead?", .{ name, shown, shown, name }));
        return;
    }
    // An empty name is the parser's stand-in for one that is missing, and it has said so already.
    if (name.len == 0) return;
    if (similarProp(c, name, ap)) |s| {
        err(c, name_node, 2551, c.fmt("Property '{s}' does not exist on type '{s}'. Did you mean '{s}'?", .{ name, show(c, t), s }));
    } else {
        err(c, name_node, 2339, c.fmt("Property '{s}' does not exist on type '{s}'.", .{ name, show(c, t) }));
    }
}

/// JavaScript adds members to functions and classes in ways that are not modeled.
fn declaredInJs(c: *Checker, s: *Symbol) bool {
    return s.decls.len > 0 and inJs(c, s.decls[0]);
}

pub fn inJs(c: *Checker, n: *Node) bool {
    const f = d.fileOf(c, n) orelse return false;
    return project.isJs(f.path);
}

/// tsc's binder declares `module` and `exports` in a JavaScript file it saw export through
/// CommonJS, and its name resolver takes `require` in `require(x)` as the module loader.
fn commonJsName(c: *Checker, n: *Node, name: []const u8) bool {
    if (!inJs(c, n)) return false;
    if (std.mem.eql(u8, name, "require")) {
        const p = n.parent orelse return false;
        return isRequireCall(p, false) and p.data.call.callee == n;
    }
    if (!std.mem.eql(u8, name, "module") and !std.mem.eql(u8, name, "exports")) return false;
    const f = d.fileOf(c, n) orelse return false;
    // An ES module never becomes CommonJS.
    if (f.is_module) return false;
    if (c.commonjs_files.get(f.root)) |known| return known;
    const found = hasCommonJsIndicator(c, f.root);
    c.commonjs_files.put(c.a, f.root, found) catch oom();
    return found;
}

fn isIdent(n: *Node, name: []const u8) bool {
    return n.data == .identifier and std.mem.eql(u8, n.data.identifier, name);
}

fn isModuleExports(n: *Node) bool {
    return n.data == .prop_access and isIdent(n.data.prop_access.expr, "module") and isIdent(n.data.prop_access.name, "exports");
}

fn isExportsRef(n: *Node) bool {
    return isIdent(n, "exports") or isModuleExports(n);
}

/// What sets tsc's `CommonJSModuleIndicator`: `require(x)`, `module.exports = …`,
/// `exports.x = …`, `module.exports.x = …` and `Object.defineProperty(exports, …)`.
fn hasCommonJsIndicator(c: *Checker, n: *Node) bool {
    switch (n.data) {
        .lazy_body => {
            const b = d.bodyOf(c, n.parent.?) orelse return false;
            return hasCommonJsIndicator(c, b.block);
        },
        .call => |x| {
            if (isRequireCall(n, false)) return true;
            if (x.args.len > 0 and isExportsRef(x.args[0]) and x.callee.data == .prop_access and
                isIdent(x.callee.data.prop_access.expr, "Object") and isIdent(x.callee.data.prop_access.name, "defineProperty")) return true;
        },
        .binary => |x| if (x.op == .assign) {
            if (isModuleExports(x.left)) return true;
            const target = switch (x.left.data) {
                .prop_access => |p| p.expr,
                .elem_access => |p| p.expr,
                else => null,
            };
            if (target) |t| if (isExportsRef(t)) return true;
        },
        else => {},
    }
    const Search = struct {
        c: *Checker,
        found: bool = false,
        fn visit(s: *@This(), child: *Node) void {
            if (!s.found) s.found = hasCommonJsIndicator(s.c, child);
        }
    };
    var search: Search = .{ .c = c };
    ast.forEachChild(n, &search, Search.visit);
    return search.found;
}

/// `import * as f from 'cjs'` under interop: the module comes back as `default`.
fn isInteropNamespace(c: *Checker, n: *Node) bool {
    if (n.data != .identifier) return false;
    const o = c.prog.cfg.options;
    if (!o.flag("esModuleInterop") and !o.flag("allowSyntheticDefaultImports")) return false;
    const s = symbolOf(c, n) orelse return false;
    for (s.decls) |x| if (x.data == .namespace_import) return true;
    return false;
}

fn isOpen(c: *Checker, t: *Type) bool {
    switch (t.data) {
        .obj => |o| {
            if (o.open or o.any_base) return true;
            if (o.sym) |s| if (s.flags & (F.function | F.class) != 0 and o.kind == .anon and declaredInJs(c, s)) return true;
            if (o.kind == .mapped and t.vars) return true;
            if (o.kind == .iface or o.kind == .ref) {
                const g = o.target orelse t;
                if (g.data == .obj) {
                    _ = d.basesOf(c, g);
                    if (g.data.obj.any_base) return true;
                }
                for (d.basesOf(c, g)) |b| if (isOpen(c, b)) return true;
            }
            return false;
        },
        .inter, .union_ => |x| {
            if (t.data == .inter) {
                // An intersection can remove the nullable part of an indexed-access constraint.
                const apparent = d.getApparent(c, t);
                if (apparent != t) return isOpen(c, apparent);
            }
            for (x) |m| if (isOpen(c, m)) return true;
            return false;
        },
        .param, .access, .cond => {
            const k = d.baseConstraint(c, t);
            // Nullable generic constraints still lack the flow facts of their indexed access.
            return k != t and k.data != .unknown and ((k.vars and maybeNullable(k)) or isOpen(c, k));
        },
        else => return false,
    }
}

fn checkPropAccess(c: *Checker, n: *Node) *Type {
    const x = n.data.prop_access;
    const name = ast.memberText(x.name);
    if (x.expr.data == .super_expr) return checkSuperProp(c, n, name);
    var left = checkExpr(c, x.expr);
    const chain = !x.optional and flow.isOptionalChain(x.expr);
    var short_circuits = false;
    if (x.optional or chain) {
        const nn = nonNull(c, left);
        short_circuits = nn != left;
        left = nn;
    } else left = checkNonNull(c, left, x.expr);
    if (T.isAny(left)) return left;
    if (isCallee(n)) left = widenObjectLiterals(c, left);
    const result = propAccessType(c, n, left, x.name, name);
    return if (short_circuits) d.addOptional(c, result) else result;
}

fn isCallee(n: *Node) bool {
    var at = n;
    while (at.parent) |p| : (at = p) {
        if (p.data == .paren) continue;
        return p.data == .call and p.data.call.callee == at;
    }
    return false;
}

fn propAccessType(c: *Checker, n: *Node, left: *Type, name_node: *Node, name: []const u8) *Type {
    if (left.data == .never) {
        err(c, name_node, 2339, c.fmt("Property '{s}' does not exist on type 'never'.", .{name}));
        return c.t_err;
    }
    const p = d.getProp(c, left, name) orelse {
        if (d.indexValue(c, left, d.nameToKey(c, name))) |v| {
            const r = if (c.no_unchecked_index) d.addOptional(c, v) else v;
            if (isWriteOnly(n) or n.flow() == null) return r;
            return flow.flowType(c, n, r, r, containingFunc(n));
        }
        if (isOpen(c, left)) return c.t_err;
        const ap = d.getApparent(c, left);
        if (T.isAny(ap)) return ap;
        if (n.data == .prop_access and std.mem.eql(u8, name, "default") and isInteropNamespace(c, n.data.prop_access.expr)) return left;
        missingProp(c, n, name_node, name, left);
        return c.t_err;
    };
    checkVisibility(c, n, left, p, name_node);
    unused.noteProperty(c, n, p);
    checkUsedBeforeInit(c, n, p, name_node);
    if (isWriteOnly(n)) return d.propWriteType(c, p);
    const declared = d.propType(c, p);
    if (n.flow() == null or T.isAny(declared)) return declared;
    if (p.method and declared.data != .union_) return declared;
    const narrowable = narrowableRef(c, n, declared);
    if (c.strict_null and addedHere(c, n, p)) {
        const r = flow.flowType(c, n, narrowable, d.addOptional(c, narrowable), containingFunc(n));
        if (!canBeUndefined(narrowable) and canBeUndefined(r)) {
            err(c, name_node, 2565, c.fmt("Property '{s}' is used before being assigned.", .{name}));
            return narrowable;
        }
        return r;
    }
    return flow.flowType(c, n, narrowable, narrowable, containingFunc(n));
}

/// Field initializers and static blocks run in document order, before the fields below them exist.
fn checkUsedBeforeInit(c: *Checker, n: *Node, p: *Prop, name_node: *Node) void {
    const decl = (if (p.sym) |s| s.value_decl else null) orelse p.decl orelse return;
    if (d.fileOf(c, n)) |f| if (f.is_dts) return;
    if (!inFieldInitializer(n)) return;
    if (decl.data == .property_decl and decl.data.property_decl.question and !decl.mods.accessor) return;
    if (n.data == .prop_access and isAccess(n.data.prop_access.expr)) return;
    if (decl.data == .func and decl.data.func.kind == .method and decl.mods.static) return;
    if (memberDeclaredBefore(c, decl, n, name_node)) return;
    // Without define semantics the base class's field is already there when the derived initializer runs.
    if (!useDefineForClassFields(c) and declaredInBaseClass(c, decl, p.name)) return;
    err(c, name_node, 2729, c.fmt("Property '{s}' is used before its initialization.", .{ast.memberText(name_node)}));
}

fn isAccess(n: *Node) bool {
    return n.data == .prop_access or n.data == .elem_access;
}

fn inFieldInitializer(n: *Node) bool {
    var prev = n;
    var cur = n.parent;
    while (cur) |x| : ({
        prev = x;
        cur = x.parent;
    }) switch (x.data) {
        .property_decl, .static_block => return true,
        .type_query, .jsx_closing => return false,
        // A function body runs later, but its computed name is evaluated in place.
        .func => |f| if (f.kind == .arrow or prev == f.body) return false,
        else => {},
    };
    return false;
}

fn useDefineForClassFields(c: *Checker) bool {
    const o = c.prog.cfg.options;
    return o.useDefineForClassFields orelse (d.targetYear(o.target orelse "esnext") >= 2022);
}

/// Fields are emitted as class fields, so a parameter property is assigned after them.
fn emitStandardClassFields(c: *Checker) bool {
    return useDefineForClassFields(c) and d.targetYear(c.prog.cfg.options.target orelse "esnext") >= 2022;
}

fn declaredInBaseClass(c: *Checker, decl: *Node, name: []const u8) bool {
    const cls = enclosingClass(decl) orelse return false;
    const s = cls.symbol() orelse return false;
    const bases = d.basesOf(c, d.declaredType(c, s));
    if (bases.len == 0) return false;
    const bp = d.getProp(c, bases[0], name) orelse return false;
    return (bp.sym orelse return false).value_decl != null;
}

fn isParamProperty(n: *Node) bool {
    return n.data == .param and d.isParamProp(n);
}

/// tsc's `isBlockScopedNameDeclaredBeforeUse` for a class member read through `access`.
fn memberDeclaredBefore(c: *Checker, decl: *Node, access: *Node, usage: *Node) bool {
    if (d.fileOf(c, decl) != d.fileOf(c, usage)) return true;
    const container = blockScopeContainer(decl);
    const uninitialized_this = decl.data == .property_decl and access.data == .prop_access and
        access.data.prop_access.expr.data == .this_expr and decl.data.property_decl.init == null and !decl.data.property_decl.excl;
    if (decl.start <= usage.start and !uninitialized_this) {
        if (decl.data == .property_decl) return !referencedWithin(decl, usage, false);
        if (isParamProperty(decl)) return !(emitStandardClassFields(c) and enclosingClass(decl) == enclosingClass(usage) and usedDeferred(c, usage, decl, container));
        return true;
    }
    if (usedDeferred(c, usage, decl, container)) {
        if (emitStandardClassFields(c) and (decl.data == .property_decl or isParamProperty(decl))) return !referencedWithin(decl, usage, true);
        return true;
    }
    return false;
}

fn blockScopeContainer(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) switch (x.data) {
        .switch_stmt, .catch_clause, .module_decl, .for_stmt, .for_in, .for_of, .func, .property_decl, .static_block => return x,
        .block => if (x.parent == null or (x.parent.?.data != .func and x.parent.?.data != .static_block)) return x,
        else => if (x.parent == null) return x,
    };
    return null;
}

/// tsc's `isUsedInFunctionOrInstanceProperty`: the read happens only after the declaration has run.
fn usedDeferred(c: *Checker, usage: *Node, decl: *Node, container: ?*Node) bool {
    var cur: ?*Node = usage;
    while (cur) |x| : (cur = x.parent) {
        if (x == container) return false;
        switch (x.data) {
            .func => if (!isCallee(x)) return true,
            .static_block => if (decl.start < usage.start) return true,
            else => {},
        }
        const p = x.parent orelse continue;
        if (p.data != .property_decl or p.data.property_decl.init != x) continue;
        if (p.mods.static) {
            if (decl.data == .func and decl.data.func.kind == .method) return true;
            if (decl.data == .property_decl and enclosingClass(usage) == decl.parent and initializedInStaticBlocks(c, decl, x.start)) return true;
        } else {
            const instance_field = decl.data == .property_decl and !decl.mods.static;
            if (!instance_field or enclosingClass(usage) != enclosingClass(decl)) return true;
        }
    }
    return false;
}

/// tsc's `isPropertyInitializedInStaticBlocks`: blocks run in document order, so only those above `until` count.
fn initializedInStaticBlocks(c: *Checker, decl: *Node, until: u32) bool {
    const name = decl.data.property_decl.name;
    if (name.data != .identifier and name.data != .private_name) return false;
    const cls = decl.parent orelse return false;
    const t = d.typeOfSymbol(c, decl.symbol() orelse return false);
    for (cls.data.class.members) |m| {
        if (m.data != .static_block or m.start > until) continue;
        // A block that never completes leaves nothing unassigned behind it.
        const end = m.data.static_block.end_flow orelse return true;
        const r = flow.flowType(c, thisAccessAt(c, name, m, end), t, d.addOptional(c, t), m);
        if (!canBeUndefined(r)) return true;
    }
    return false;
}

/// tsc's `isPropertyImmediatelyReferencedWithinDeclaration`.
fn referencedWithin(decl: *Node, usage: *Node, stop_at_any_field: bool) bool {
    if (usage.end > decl.end) return false;
    var prev = usage;
    var cur: ?*Node = usage;
    while (cur) |x| : ({
        prev = x;
        cur = x.parent;
    }) {
        if (x == decl) break;
        switch (x.data) {
            .func => |f| switch (f.kind) {
                .arrow => return false,
                .method, .getter, .setter => if (prev == f.body) return false,
                else => {},
            },
            .property_decl => return stop_at_any_field and
                ((decl.data == .property_decl and x.parent == decl.parent) or
                    (isParamProperty(decl) and decl.parent != null and x.parent == decl.parent.?.parent)),
            else => {},
        }
    }
    return true;
}

/// `f.x` next to the `f.x = 1` that declares it: the property exists only past that statement.
fn addedHere(c: *Checker, n: *Node, p: *T.Prop) bool {
    const decl = (p.sym orelse return false).value_decl orelse return false;
    // tsc's strictPropertyInitialization rule for `this.x` looks only at declared fields.
    if (c.strict_prop_init and n.data == .prop_access and n.data.prop_access.expr.data == .this_expr) return false;
    return decl.data == .prop_access and flowScope(n) == flowScope(decl);
}

fn canBeUndefined(t: *Type) bool {
    if (t.data != .union_) return t.data == .undefined;
    for (t.data.union_) |m| if (m.data == .undefined) return true;
    return false;
}

/// tsc's `checkThisBeforeSuper`, for `this` or `super` directly in a derived class's constructor:
/// an arrow function may run later, so one in between ends the check.
fn checkBeforeSuper(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    const ctor = blk: {
        var cur = n.parent;
        while (cur) |x| : (cur = x.parent) switch (x.data) {
            .func => |f| break :blk if (f.kind == .ctor) x else return,
            .property_decl, .class, .computed_name, .static_block, .decorator => return,
            else => {},
        };
        return;
    };
    const cls = ctor.parent orelse return;
    if (cls.data != .class) return;
    const base = d.extendsClause(cls) orelse return;
    if (binder.stripParens(base.data.expr_with_type_args.expr).data == .null_lit) return;
    const f = n.flow() orelse return;
    if (!flow.isPostSuper(c, f)) err(c, n, code, msg);
}

/// In static code `super` is the base class's constructor, elsewhere an instance of it.
fn superType(c: *Checker, n: *Node) *Type {
    const info = superBase(c, n) orelse return c.t_err;
    if (!info.is_static) return info.base;
    const s = if (info.base.data == .obj) info.base.data.obj.sym else null;
    return d.typeOfSymbol(c, s orelse return c.t_err);
}

fn checkSuperProp(c: *Checker, n: *Node, name: []const u8) *Type {
    const x = n.data.prop_access;
    checkBeforeSuper(c, x.expr, 17011, "'super' must be called before accessing a property of 'super' in the constructor of a derived class.");
    const base = superType(c, n);
    if (base == c.t_err) return base;
    if (T.isAny(base)) return base;
    const p = d.getProp(c, base, name) orelse {
        if (isOpen(c, base)) return c.t_err;
        err(c, x.name, 2339, c.fmt("Property '{s}' does not exist on type '{s}'.", .{ name, show(c, base) }));
        return c.t_err;
    };
    return d.propType(c, p);
}

fn isValidIndex(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .string, .number, .symbol, .str_lit, .num_lit, .unique, .enum_lit, .enum_, .any, .err, .tmpl, .strmap, .keyof, .never => true,
        .param, .access, .cond => blk: {
            const k = d.baseConstraint(c, t);
            break :blk k == t or k.data == .unknown or isValidIndex(c, k);
        },
        .union_, .inter => |x| for (x) |m| {
            if (!isValidIndex(c, m)) break false;
        } else true,
        else => false,
    };
}

fn checkElemAccess(c: *Checker, n: *Node) *Type {
    const x = n.data.elem_access;
    var left = checkExpr(c, x.expr);
    const idx0 = checkExpr(c, x.index);
    const idx = idx0.regular orelse idx0;
    const chain = !x.optional and flow.isOptionalChain(x.expr);
    var short_circuits = false;
    if (x.optional or chain) {
        const nn = nonNull(c, left);
        short_circuits = nn != left;
        left = nn;
    } else left = checkNonNull(c, left, x.expr);
    if (T.isAny(left)) {
        // Unlike `x.y`, `x[0]` on `any` still reads what `if (isArray(x[0]))` found out.
        if (left.data != .any or n.flow() == null or isWriteOnly(n)) return left;
        return flow.flowType(c, n, left, left, containingFunc(n));
    }
    if (isConstEnumObject(left) and x.index.data != .string_lit and x.index.data != .no_subst_template) {
        err(c, x.index, 2476, "A const enum member can only be accessed using a string literal.");
        return c.t_err;
    }
    const result = elemType(c, n, left, if (isNumericKey(c, x.index)) c.t_number else idx, x.index);
    return if (short_circuits) d.addOptional(c, result) else result;
}

fn isConstEnumObject(t: *Type) bool {
    if (t.data != .obj or t.data.obj.kind != .anon) return false;
    const s = t.data.obj.sym orelse return false;
    return s.flags & F.const_enum != 0;
}

/// `for (const i in list) other[i]`: keys of a numeric index are strings only in name.
fn isLiteralObject(t: *Type) bool {
    return t.data == .obj and t.data.obj.kind == .anon and t.data.obj.lit;
}

fn isNumericKey(c: *Checker, index: *Node) bool {
    const e = binder.stripParens(index);
    if (e.data != .identifier) return false;
    const s = (symbolOf(c, e) orelse return false).resolve();
    if (s.flags & F.variable == 0) return false;
    var child = index;
    var cur = index.parent;
    while (cur) |x| : ({
        child = x;
        cur = x.parent;
    }) {
        if (x.data != .for_in or x.data.for_in.body != child or forInSymbol(c, x) != s) continue;
        const keys = d.indexesOf(c, d.getApparent(c, checkSilent(c, x.data.for_in.expr)));
        if (keys.len == 1 and keys[0].key.data == .number) return true;
    }
    return false;
}

fn forInSymbol(c: *Checker, loop: *Node) ?*Symbol {
    const init = loop.data.for_in.init;
    if (init.data == .identifier) return if (symbolOf(c, init)) |s| s.resolve() else null;
    if (init.data != .var_list or init.data.var_list.decls.len == 0) return null;
    return init.data.var_list.decls[0].symbol();
}

fn elemType(c: *Checker, n: *Node, left: *Type, idx: *Type, index_node: *Node) *Type {
    if (T.isAny(idx)) return c.t_err;
    if (left.data == .never or idx.data == .never) return c.t_never;
    const known_keys = left.data == .obj and left.data.obj.kind == .mapped and !d.mappedKeysGeneric(c, left);
    if (d.isGeneric(c, idx) or (!known_keys and d.isGeneric(c, left) and !(d.literalName(c, idx) != null and left.data == .param))) {
        if (isValidIndex(c, idx) or d.isGeneric(c, idx)) return d.getIndexedAccess(c, left, idx);
    }
    if (idx.data == .union_) {
        const u = idx.data.union_;
        const out = c.a.alloc(*Type, u.len) catch oom();
        for (u, 0..) |m, i| out[i] = elemType(c, n, left, m, index_node);
        return c.getUnion(out);
    }
    const assign = isWriteOnly(n);
    if (d.literalName(c, idx)) |name| {
        if (d.getProp(c, left, name)) |p| {
            if (assign) return d.propWriteType(c, p);
            const declared = d.propType(c, p);
            if (n.flow() == null or declared.data == .err) return declared;
            const narrowable = narrowableRef(c, n, declared);
            return flow.flowType(c, n, narrowable, narrowable, containingFunc(n));
        }
    }
    const ap = d.getApparent(c, left);
    if (T.isTupleType(ap) and idx.data == .num_lit) {
        const o = ap.data.obj;
        const i = idx.data.num_lit;
        const open = for (o.tuple.eflags) |f| {
            if (f == .rest or f == .variadic) break true;
        } else false;
        if (!open and i >= @as(f64, @floatFromInt(o.tuple.elems.len)) and i >= 0) {
            // The literal may exceed i64, so it is printed as the float it is.
            err(c, index_node, 2493, c.fmt("Tuple type '{s}' of length '{d}' has no element at index '{d}'.", .{ show(c, ap), o.tuple.elems.len, i }));
            return c.t_undefined;
        }
        // Past the fixed elements only the open tail can be there, not the whole tuple.
        if (open and i >= 0) {
            const v = d.tupleElemAt(c, ap, i);
            return if (c.no_unchecked_index and !assign) d.addOptional(c, v) else v;
        }
    }
    const index_key = if (idx.data == .enum_lit) (if (idx.data.enum_lit.value == .str) c.t_string else c.t_number) else idx;
    if (d.indexValue(c, ap, idx) orelse d.indexValue(c, ap, index_key)) |v| {
        const r = if (c.no_unchecked_index and !assign) d.addOptional(c, v) else v;
        if (assign or n.flow() == null or (d.literalName(c, idx) == null and index_node.data != .identifier)) return r;
        return flow.flowType(c, n, r, r, containingFunc(n));
    }
    if (idx.data == .enum_ or idx.data == .enum_lit) if (d.indexValue(c, ap, c.t_number)) |v| return v;
    if (idx.data == .symbol or idx.data == .unique) if (d.indexValue(c, ap, c.t_string)) |v| {
        err(c, index_node, 2538, c.fmt("Type '{s}' cannot be used as an index type.", .{show(c, idx)}));
        return v;
    };
    if (T.isTupleType(ap) and idx.data == .number) return c.getUnion(ap.data.obj.tuple.elems);
    if (isOpen(c, left)) return c.t_err;
    if (!isValidIndex(c, idx)) {
        err(c, index_node, 2538, c.fmt("Type '{s}' cannot be used as an index type.", .{show(c, idx)}));
        return c.t_err;
    }
    if (d.literalName(c, idx)) |name| {
        if (idx.data == .str_lit or idx.data == .num_lit) {
            if (c.no_implicit_any) {
                if (isLiteralObject(ap)) {
                    err(c, n, 2339, c.fmt("Property '{s}' does not exist on type '{s}'.", .{ name, show(c, left) }));
                    return c.t_undefined;
                }
                reportImplicitIndex(c, n, index_node, idx, left, ap);
            }
            return c.t_err;
        }
    }
    // An object literal is known in full: any key gives one of its values or nothing.
    if (isLiteralObject(ap) and (idx.data == .string or idx.data == .number)) {
        var values = c.newList(*Type);
        for (d.propsOf(c, ap)) |p| values.append(c.a, d.propType(c, p)) catch oom();
        values.append(c.a, c.t_undefined) catch oom();
        return c.getUnion(values.items);
    }
    if (c.no_implicit_any) reportImplicitIndex(c, n, index_node, idx, left, ap);
    return c.t_err;
}

fn reportImplicitIndex(c: *Checker, n: *Node, index_node: *Node, idx: *Type, left: *Type, ap: *Type) void {
    const name = d.literalName(c, idx);
    const file = d.fileOf(c, n);
    if (name != null and file != null and hasStaticProp(c, left, name.?)) {
        const shown = show(c, left);
        const arg = file.?.src[index_node.start..index_node.end];
        err(c, n, 2576, c.fmt("Property '{s}' does not exist on type '{s}'. Did you mean to access the static member '{s}[{s}]' instead?", .{ name.?, shown, shown, arg }));
    } else if (d.indexValue(c, ap, c.t_number) != null) {
        err(c, index_node, 7015, "Element implicitly has an 'any' type because index expression is not of type 'number'.");
    } else if (if (name) |nm| similarProp(c, nm, ap) else null) |close| {
        err(c, index_node, 2551, c.fmt("Property '{s}' does not exist on type '{s}'. Did you mean '{s}'?", .{ name.?, show(c, left), close }));
    } else {
        err(c, n, 7053, c.fmt("Element implicitly has an 'any' type because expression of type '{s}' can't be used to index type '{s}'.", .{ show(c, idx), show(c, left) }));
    }
}

// ---- literals ----

fn checkArrayLit(c: *Checker, n: *Node) *Type {
    const items = n.data.array_lit.elems;
    if (items.len > 32 and !c.elem_index.contains(items[0])) for (items, 0..) |e, k| c.elem_index.put(c.a, e, @intCast(k)) catch oom();
    const is_const = isConstContext(c, n);
    const ctx = contextualType(c, n);
    const tuple_ctx = is_const or isDestructuringTarget(n) or (ctx != null and tupleLike(c, ctx.?));
    var elems = c.newList(*Type);
    var flags = c.newList(T.ElemFlag);
    for (items) |e| {
        switch (e.data) {
            .spread_elem => |x| {
                const t = checkExpr(c, x.expr);
                if (T.isTupleType(t)) {
                    const o = t.data.obj;
                    for (o.tuple.elems, o.tuple.eflags) |y, f| {
                        elems.append(c.a, y) catch oom();
                        flags.append(c.a, f) catch oom();
                    }
                } else if (t.vars and t.data == .param or tuple_ctx and isTupleUnion(c, t)) {
                    elems.append(c.a, t) catch oom();
                    flags.append(c.a, .variadic) catch oom();
                } else {
                    elems.append(c.a, iteratedOf(c, x.expr, t, false)) catch oom();
                    flags.append(c.a, .rest) catch oom();
                }
            },
            .omitted_expr => {
                elems.append(c.a, c.t_undefined) catch oom();
                flags.append(c.a, .required) catch oom();
            },
            else => {
                elems.append(c.a, mutableLocation(c, e, checkExpr(c, e))) catch oom();
                flags.append(c.a, .required) catch oom();
            },
        }
    }
    if (tuple_ctx) return writtenArray(c, c.makeTuple(elems.items, flags.items, is_const and !(ctx != null and mutableArrayCtx(c, ctx.?)), &.{}));
    if (elems.items.len == 0) return writtenArray(c, d.arrayOf(c, c.t_err));
    var parts = c.newList(*Type);
    for (elems.items, flags.items) |e, f| {
        if (f == .variadic) {
            parts.append(c.a, c.t_err) catch oom();
        } else parts.append(c.a, e) catch oom();
    }
    return writtenArray(c, d.arrayOf(c, reduceSubtypes(c, parts.items)));
}

fn writtenArray(c: *Checker, t: *Type) *Type {
    if (c.array_sink) |m| m.put(c.a, t, {}) catch oom();
    return t;
}

fn isTupleUnion(c: *Checker, t: *Type) bool {
    if (t.data != .union_) return false;
    for (t.data.union_) |m| if (!T.isTupleType(m) and !c.isArrayType(m)) return false;
    return true;
}

/// `[...] as const satisfies string[]`: the assertion must not produce a value its own
/// context would then reject.
fn mutableArrayCtx(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_ => |x| for (x) |m| {
            if (mutableArrayCtx(c, m)) break true;
        } else false,
        .any, .err, .null, .undefined => false,
        else => (T.isTupleType(t) and !t.data.obj.readonly) or relate.isAssignable(c, t, d.arrayOf(c, c.t_any)),
    };
}

fn tupleLike(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_, .inter => |x| for (x) |m| {
            if (tupleLike(c, m)) break true;
        } else false,
        .obj => T.isTupleType(t),
        .param => blk: {
            const k = d.baseConstraint(c, t);
            break :blk k != t and tupleLike(c, k);
        },
        else => false,
    };
}

/// `{ get: () => items, make: (item) => ... }`: what one lambda of a literal returned counts by
/// the time the next one asks for its parameters.
fn inferFromSite(c: *Checker, n: *Node, t: *Type) void {
    if (c.skip_sensitive or c.ctx_stack.items.len == 0 or !sensitiveArg(c, n)) return;
    const ctx = inferFor(c, n) orelse return;
    relate.inferTypes(c, ctx, t, rawContext(c, n) orelse return, 0);
}

fn checkObjectLit(c: *Checker, n: *Node) *Type {
    const items = n.data.object_lit.props;
    const is_const = isConstContext(c, n);
    var m = c.membersFor(items.len);
    var open = false;
    var vars = false;
    var has_spread = false;
    var pending = false;
    var spreads_any = false;
    // What has been spread from a type parameter, and the objects around it.
    var parts: std.ArrayList(*Type) = .empty;
    // What was written since the last spread, which is what a computed key can stand for.
    var run_start: usize = 0;
    var computed: std.ArrayList(ComputedKey) = .empty;
    var split: ?SplitSpread = null;
    for (items, 0..) |p, i| {
        switch (p.data) {
            .property_assign => |x| {
                const raw = checkExpr(c, x.value);
                inferFromSite(c, x.value, raw);
                const v = mutableLocation(c, x.value, raw);
                if (x.name.data == .computed_name) {
                    const key = binder.stripParens(x.name.data.computed_name.expr);
                    _ = checkExpr(c, key);
                }
                const name = propNameOf(c, x.name) orelse {
                    if (computedKeyOf(c, x.name)) |key| {
                        computed.append(c.a, .{ .key = key, .ty = v }) catch oom();
                    } else open = true;
                    continue;
                };
                if (v.vars) vars = true;
                if (isPending(c, v)) pending = true;
                m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = v, .readonly = is_const, .decl = p })) catch oom();
            },
            .shorthand_assign => |x| {
                // `{ "a" }` and `{ 1 }` parse as shorthand so the parser can report them.
                if (x.name.data != .identifier) continue;
                const v = mutableLocation(c, x.name, checkIdentifier(c, x.name));
                const name = x.name.data.identifier;
                if (v.vars) vars = true;
                m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = v, .readonly = is_const, .decl = p })) catch oom();
            },
            .spread_assign => |x| {
                const s = checkExpr(c, x.expr);
                if (!T.isAny(s) and !isSpreadable(c, s)) err(c, p, 2698, "Spread types may only be created from object types.");
                if (T.isAny(s) or !isSpreadable(c, s)) {
                    spreads_any = true;
                    continue;
                }
                closeRun(c, m, items[run_start..i], computed.items, is_const, has_spread);
                run_start = i + 1;
                computed.clearRetainingCapacity();
                if (split != null) {
                    open = true;
                    continue;
                }
                if (s.data == .param or s.data == .access or s.data == .cond) {
                    if (m.props.count() > 0) parts.append(c.a, literalObject(c, n, m, open, vars, pending, has_spread)) catch oom();
                    parts.append(c.a, s) catch oom();
                    m = c.emptyMembers();
                    continue;
                }
                if (s.vars and s.data != .obj) {
                    open = true;
                    continue;
                }
                const first = !has_spread and m.props.count() == 0 and m.indexes.len == 0;
                const shape = if (s.data == .union_) loneShape(c, s) else s;
                if (shape.data == .union_ and parts.items.len == 0) {
                    split = .{ .members = shape.data.union_, .before = m, .first = first };
                    m = c.emptyMembers();
                    has_spread = true;
                    continue;
                }
                m = spreadInto(c, m, shape, s.data == .union_, is_const, &open);
                spreadIndexes(c, m, shape, first);
                has_spread = true;
                if (s.vars) vars = true;
            },
            .func => |f| {
                const nm = f.name orelse continue;
                const is_accessor = f.kind == .getter or f.kind == .setter;
                // An accessor's body, and with it a computed name, is checked once the literal is done.
                if (is_accessor) {
                    if (d.outerTParams(c, p).len > 0) vars = true;
                    assignContext(c, p);
                    if (!quiet(c)) {
                        const gop = c.checked_funcs.getOrPut(c.a, p) catch oom();
                        if (!gop.found_existing) c.deferred.append(c.a, p) catch oom();
                    }
                }
                const name = propNameOf(c, nm) orelse {
                    const key = if (is_accessor) null else computedKeyOf(c, nm);
                    if (key) |k| {
                        computed.append(c.a, .{ .key = k, .ty = checkFunctionExpr(c, p) }) catch oom();
                    } else open = true;
                    continue;
                };
                if (is_accessor) {
                    if (p.symbol()) |s| m.props.put(c.a, name, c.create(Prop, .{ .name = name, .sym = s, .readonly = f.kind == .getter and s.flags & F.setter == 0, .decl = p })) catch oom();
                    continue;
                }
                const v = checkFunctionExpr(c, p);
                inferFromSite(c, p, v);
                if (v.vars) vars = true;
                if (isPending(c, v)) pending = true;
                m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = v, .method = true, .decl = p })) catch oom();
            },
            else => {},
        }
    }
    if (spreads_any) return c.t_any;
    closeRun(c, m, items[run_start..], computed.items, is_const, has_spread);
    if (split) |x| {
        const out = c.a.alloc(*Type, x.members.len) catch oom();
        for (x.members, out) |u, *r| {
            const copy = c.emptyMembers();
            copy.indexes = x.before.indexes;
            copy.props = x.before.props.clone(c.a) catch oom();
            const merged = spreadInto(c, copy, u, false, is_const, &open);
            spreadIndexes(c, merged, u, x.first);
            var it = m.props.iterator();
            while (it.next()) |e| merged.props.put(c.a, e.key_ptr.*, e.value_ptr.*) catch oom();
            r.* = literalObject(c, n, merged, open, vars, pending, true);
        }
        return c.getUnion(out);
    }
    const t = literalObject(c, n, m, open, vars, pending, has_spread);
    if (parts.items.len == 0) return t;
    if (m.props.count() > 0) parts.append(c.a, t) catch oom();
    return c.getIntersection(parts.items);
}

/// `{ ...(c ? a : b), x }` is one object per member, and what surrounds the spread is in each of them.
const SplitSpread = struct { members: []const *Type, before: *T.Members, first: bool };

fn literalObject(c: *Checker, n: *Node, m: *T.Members, open: bool, vars: bool, pending: bool, has_spread: bool) *Type {
    const t = c.newObj(.{ .kind = .anon, .sym = n.symbol(), .node = null, .members = m, .lit = true, .literal = n, .non_inferrable = pending, .open = open, .spread = has_spread });
    t.vars = vars;
    return t;
}

fn isPending(c: *Checker, t: *Type) bool {
    return t == c.t_pending_fn or (t.data == .obj and t.data.obj.non_inferrable);
}

fn spreadIndexes(c: *Checker, m: *T.Members, s: *Type, first: bool) void {
    const from = d.indexesOf(c, nonNull(c, s));
    if (first) {
        // The copy is a new object, so it is writable whatever the source said.
        m.indexes = c.dupe(T.Index, from);
        for (m.indexes) |*x| x.readonly = false;
        return;
    }
    m.indexes = sharedIndexes(c, m.indexes, from);
}

/// `{ ...rec }` keeps its index signature, `{ ...rec, a }` does not: an index has to hold on both sides.
fn sharedIndexes(c: *Checker, left: []T.Index, right: []T.Index) []T.Index {
    var kept = c.newList(T.Index);
    for (left) |x| for (right) |y| if (x.key == y.key) {
        kept.append(c.a, .{ .key = x.key, .ty = c.getUnion(&.{ x.ty, y.ty }), .decl = x.decl }) catch oom();
    };
    return kept.items;
}

pub const ComputedKey = struct { key: *Type, ty: *Type };

/// tsc files a computed key whose name is not known under number, symbol or string, in that order.
pub fn computedKeyOf(c: *Checker, name: *Node) ?*Type {
    if (name.data != .computed_name) return null;
    const t = checkSilent(c, binder.stripParens(name.data.computed_name.expr));
    if (t.data == .err or !relate.isAssignable(c, t, c.t_key)) return null;
    if (relate.isAssignable(c, t, c.t_number)) return c.t_number;
    if (relate.isAssignable(c, t, c.t_symbol)) return c.t_symbol;
    return c.t_string;
}

fn closeRun(c: *Checker, m: *T.Members, run: []*Node, computed: []const ComputedKey, readonly: bool, after_spread: bool) void {
    if (run.len == 0) return;
    const own: []T.Index = if (computed.len > 0) literalIndexes(c, m, run, computed, readonly) else &.{};
    m.indexes = if (after_spread) sharedIndexes(c, m.indexes, own) else own;
}

/// A computed key could be any of the names written beside it, so its index covers them all.
fn literalIndexes(c: *Checker, m: *T.Members, run: []*Node, computed: []const ComputedKey, readonly: bool) []T.Index {
    var out = c.newList(T.Index);
    for ([_]*Type{ c.t_string, c.t_number, c.t_symbol }) |key| {
        const used = for (computed) |x| {
            if (x.key == key) break true;
        } else false;
        if (!used) continue;
        var parts = c.newList(*Type);
        for (computed) |x| {
            if (coveredByKey(c, key, x.key == c.t_number, x.key == c.t_symbol)) parts.append(c.a, x.ty) catch oom();
        }
        for (run) |p| {
            const name = literalMemberName(c, p) orelse continue;
            const prop = m.props.get(name) orelse continue;
            if (coveredByKey(c, key, isNumericName(c, name), std.mem.startsWith(u8, name, "__@"))) parts.append(c.a, d.propType(c, prop)) catch oom();
        }
        out.append(c.a, .{ .key = key, .ty = if (parts.items.len > 0) reduceSubtypes(c, parts.items) else c.t_undefined, .readonly = readonly }) catch oom();
    }
    return out.items;
}

pub fn isNumericName(c: *Checker, name: []const u8) bool {
    const v = emit.parseNumber(name) orelse return false;
    return std.mem.eql(u8, d.numName(c, v), name);
}

pub fn coveredByKey(c: *Checker, key: *Type, numeric: bool, symbol: bool) bool {
    if (key == c.t_string) return !symbol;
    return if (key == c.t_number) numeric else symbol;
}

fn literalMemberName(c: *Checker, p: *Node) ?[]const u8 {
    return switch (p.data) {
        .property_assign => |x| propNameOf(c, x.name),
        .shorthand_assign => |x| if (x.name.data == .identifier) x.name.data.identifier else null,
        .func => |f| if (f.name) |nm| propNameOf(c, nm) else null,
        else => null,
    };
}

/// `...(flag && { a })` is `a` or nothing at all, which reads as an optional `a`.
fn loneShape(c: *Checker, s: *Type) *Type {
    var shape: ?*Type = null;
    for (s.data.union_) |m| {
        if (spreadsNothing(c, m)) continue;
        if (shape != null) return s;
        shape = m;
    }
    return shape orelse c.t_empty;
}

/// `x && { a: 1 }` spreads fine: a falsy value adds nothing, so only what is left has to be an object.
fn isSpreadable(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .any, .err, .nonprim, .obj => true,
        .union_ => |u| blk: {
            var left = false;
            for (u) |m| {
                if (definitelyFalsy(c, m) == m) continue;
                if (!isSpreadable(c, m)) break :blk false;
                left = true;
            }
            break :blk left;
        },
        .inter => |u| for (u) |m| {
            if (!isSpreadable(c, m)) break false;
        } else true,
        .param => if (d.constraintOf(c, t) == null) true else isSpreadable(c, d.baseConstraint(c, t)),
        .access, .cond => blk: {
            const k = d.baseConstraint(c, t);
            break :blk k == t or k.data == .unknown or isSpreadable(c, k);
        },
        else => false,
    };
}

fn spreadsNothing(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .null, .undefined, .string, .number, .bigint, .bool_lit, .str_lit, .num_lit, .big_lit, .tmpl, .strmap, .enum_, .enum_lit, .nonprim, .keyof => true,
        else => relate.isEmptyObject(c, t),
    };
}

fn spreadInto(c: *Checker, m: *T.Members, s: *Type, partial: bool, is_const: bool, open: *bool) *T.Members {
    if (s.data == .union_) {
        // Each constituent could spread differently; tsc makes a union of objects.
        open.* = true;
        return m;
    }
    if (s.data == .null or s.data == .undefined or s.data == .never) return m;
    if (s.data != .obj and s.data != .inter) {
        if (s.vars) open.* = true;
        return m;
    }
    if (isOpen(c, s)) open.* = true;
    for (d.propsOf(c, s)) |p| {
        if (p.private or p.protected) continue;
        if (p.method and s.data == .obj and s.data.obj.is_class) continue;
        const q = c.create(Prop, p.*);
        var v = d.propType(c, p);
        if (partial) {
            v = d.addOptional(c, v);
            q.optional = true;
        }
        if (q.optional) if (m.props.get(p.name)) |old| {
            v = c.getUnion(&.{ d.propType(c, old), removeUndefined(c, v) });
            q.optional = old.optional;
        };
        q.ty = v;
        q.readonly = is_const;
        q.origin = null;
        m.props.put(c.a, p.name, q) catch oom();
    }
    return m;
}

// ---- operators ----

fn isNumberLike(c: *Checker, t: *Type) bool {
    return T.isAny(t) or relate.isAssignable(c, t, c.t_number) and t.data != .never;
}

fn isBigLike(c: *Checker, t: *Type) bool {
    return !T.isAny(t) and relate.isAssignable(c, t, c.t_bigint) and t.data != .never;
}

fn isStringLike(c: *Checker, t: *Type) bool {
    return relate.isAssignable(c, t, c.t_string) and t.data != .never;
}

fn isArithOperand(c: *Checker, t: *Type) bool {
    if (T.isAny(t) or isNumberLike(c, t) or isBigLike(c, t)) return true;
    return t.vars and isNumberLike(c, d.baseConstraint(c, t));
}

fn arithOperand(c: *Checker, t0: *Type, n: *Node, code: u32) void {
    const t = checkNonNull(c, t0, n);
    if (isArithOperand(c, t)) return;
    err(c, n, code, if (code == 2362) "The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type." else "The right-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.");
}

fn opText(op: Tok) []const u8 {
    return switch (op) {
        .plus, .plus_assign => "+",
        .lt => "<",
        .gt => ">",
        .lte => "<=",
        .gte => ">=",
        .eq2 => "==",
        .eq3 => "===",
        .neq => "!=",
        .neq3 => "!==",
        else => "?",
    };
}

fn equalityOverlap(c: *Checker, l: *Type, r: *Type) bool {
    // tsc compares `null` and `undefined` against anything, `strictNullChecks` or not.
    if (l.data == .null or l.data == .undefined or r.data == .null or r.data == .undefined) return true;
    return relate.isComparable(c, l, r) or relate.isComparable(c, r, l);
}

pub fn baseOfLiteral(c: *Checker, t: *Type) *Type {
    return switch (t.data) {
        .str_lit => c.t_string,
        .num_lit => c.t_number,
        .big_lit => c.t_bigint,
        .bool_lit => c.t_boolean,
        .enum_lit => |e| if (e.value == .str) c.t_string else c.t_number,
        .union_ => |u| blk: {
            const out = c.a.alloc(*Type, u.len) catch oom();
            for (u, 0..) |m, i| out[i] = baseOfLiteral(c, m);
            break :blk c.getUnion(out);
        },
        else => t,
    };
}

/// What `a` can be when `a && b` stops at it. Unlike narrowing, this splits `string` into `""`,
/// since a value of that type has to be exactly that to get here.
fn definitelyFalsy(c: *Checker, t: *Type) *Type {
    return switch (t.data) {
        .union_ => |u| blk: {
            const out = c.a.alloc(*Type, u.len) catch oom();
            for (u, 0..) |m, i| out[i] = definitelyFalsy(c, m);
            break :blk c.getUnion(out);
        },
        .string => c.strLit(""),
        .number => c.numLit(0),
        .bigint => c.bigLit("0"),
        .void, .undefined, .null, .any, .unknown, .err => t,
        .bool_lit => |v| if (v) c.t_never else t,
        .str_lit => |v| if (v.len == 0) t else c.t_never,
        .num_lit => |v| if (v == 0) t else c.t_never,
        .big_lit => |v| if (std.mem.eql(u8, v, "0")) t else c.t_never,
        .enum_lit => |e| switch (e.value) {
            .num => |v| if (v == 0) t else c.t_never,
            .str => |v| if (v.len == 0) t else c.t_never,
            else => c.t_never,
        },
        else => c.t_never,
    };
}

fn checkBinary(c: *Checker, n: *Node) *Type {
    const x = n.data.binary;
    const op = x.op;
    if (op == .assign) return checkAssign(c, n);
    if (isAssignOp(op)) return checkCompound(c, n);
    if (op == .comma) {
        _ = checkExpr(c, x.left);
        if (!(c.prog.cfg.options.allowUnreachableCode orelse false) and isSideEffectFree(x.left) and !isIndirectCall(n) and !inJsxParentError(c, x.left)) {
            err(c, x.left, 2695, "Left side of comma operator is unused and has no side effects.");
        }
        return checkExpr(c, x.right);
    }
    const l0 = checkExpr(c, x.left);
    // Checking the left operand again for each right one's context is exponential on `a || b || c`.
    if (op == .pipe2 or op == .qq) c.logical_left.put(c.a, n, l0) catch oom();
    const r0 = checkExpr(c, x.right);
    if (op == .amp2 or op == .pipe2) checkTruthiness(c, l0, x.left);
    if (op == .qq) checkNullishLeft(c, x.left);
    return binaryResult(c, n, op, x.left, x.right, l0, r0);
}

/// tsc's `checkTruthinessExpression`: a condition is checked, then tested for truthiness.
pub fn checkCondition(c: *Checker, n: *Node) *Type {
    const t = checkExpression(c, n);
    checkTruthiness(c, t, n);
    return t;
}

/// tsc's `checkTruthinessOfType`: `void` cannot be tested, and some expressions can be told
/// truthy or falsy from their syntax alone.
fn checkTruthiness(c: *Checker, t: *Type, n: *Node) void {
    if (t.data == .void) return err(c, n, 1345, "An expression of type 'void' cannot be tested for truthiness.");
    switch (truthySemantics(c, n)) {
        .always => errSpan(c, n, spanStart(c, n), n.end, 2872, "This kind of expression is always truthy."),
        .never => errSpan(c, n, spanStart(c, n), n.end, 2873, "This kind of expression is always falsy."),
        else => {},
    }
}

/// Where tsc's `getErrorSpanForNode` starts: at the name of a named function or class
/// expression, and at the keyword of `x satisfies T`.
fn spanStart(c: *Checker, n: *Node) u32 {
    return switch (n.data) {
        .func => |f| if (f.name) |name| name.start else n.start,
        .class => |k| if (k.name) |name| name.start else n.start,
        .satisfies_expr => |x| blk: {
            const f = d.fileOf(c, n) orelse break :blk n.start;
            break :blk skipTrivia(f.src, x.expr.end);
        },
        else => n.start,
    };
}

pub fn skipTrivia(src: []const u8, from: u32) u32 {
    var i: usize = from;
    while (i < src.len) {
        if (std.ascii.isWhitespace(src[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, src[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        } else if (std.mem.startsWith(u8, src[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |e| e + 2 else src.len;
        } else break;
    }
    return @intCast(i);
}

/// tsc's `skipOuterExpressions` with `OuterExpressionKinds.All`.
fn skipOuter(n0: *Node) *Node {
    var n = binder.stripParens(n0);
    while (n.data == .expr_with_type_args) n = binder.stripParens(n.data.expr_with_type_args.expr);
    return n;
}

/// tsc's `PredicateSemantics`: whether a predicate holds always, never, or either way.
const Semantics = enum(u2) {
    none = 0,
    always = 1,
    never = 2,
    sometimes = 3,

    fn either(a: Semantics, b: Semantics) Semantics {
        return @enumFromInt(@intFromEnum(a) | @intFromEnum(b));
    }
};

fn isUndefinedName(c: *Checker, n: *Node) bool {
    return n.data == .identifier and std.mem.eql(u8, n.data.identifier, "undefined") and symbolOf(c, n) == null;
}

/// tsc's `getSyntacticTruthySemantics`.
fn truthySemantics(c: *Checker, n0: *Node) Semantics {
    const n = skipOuter(n0);
    return switch (n.data) {
        // `while (0)` and `while (1)` are idioms, not mistakes.
        .numeric_lit => |v| if (emit.parseNumber(v)) |x| if (x == 0 or x == 1) .sometimes else .always else .always,
        .array_lit, .bigint_lit, .object_lit, .regex_lit, .jsx_element, .jsx_self_closing => .always,
        .func => |f| if (f.kind == .expr or f.kind == .arrow) .always else .sometimes,
        .class => |k| if (k.is_expr) .always else .sometimes,
        .void_expr, .null_lit => .never,
        .string_lit, .no_subst_template => |v| if (v.len > 0) .always else .never,
        .conditional => |x| truthySemantics(c, x.then).either(truthySemantics(c, x.els)),
        .identifier => if (isUndefinedName(c, n)) .never else .sometimes,
        else => .sometimes,
    };
}

/// tsc's `checkNullishCoalesceOperandLeft`.
fn checkNullishLeft(c: *Checker, left: *Node) void {
    const target = skipOuter(left);
    switch (nullishSemantics(c, target)) {
        .always => err(c, target, 2871, "This expression is always nullish."),
        .never => err(c, target, 2869, "Right operand of ?? is unreachable because the left operand is never nullish."),
        else => {},
    }
}

/// tsc's `getSyntacticNullishnessSemantics`.
fn nullishSemantics(c: *Checker, n0: *Node) Semantics {
    const n = skipOuter(n0);
    return switch (n.data) {
        .await_expr, .call, .tagged_template, .elem_access, .meta_property, .new_expr, .prop_access, .yield_expr, .this_expr => .sometimes,
        .binary => |x| switch (x.op) {
            .pipe2, .pipe2_assign, .amp2, .amp2_assign => .sometimes,
            // The right operand is the value.
            .comma, .assign => nullishSemantics(c, x.right),
            .qq, .qq_assign => blk: {
                const l = nullishSemantics(c, x.left);
                var out: Semantics = if (@intFromEnum(l) & @intFromEnum(Semantics.never) != 0) .never else .none;
                if (@intFromEnum(l) & @intFromEnum(Semantics.always) != 0) out = out.either(nullishSemantics(c, x.right));
                break :blk out;
            },
            else => .never,
        },
        .conditional => |x| nullishSemantics(c, x.then).either(nullishSemantics(c, x.els)),
        .null_lit => .always,
        .identifier => if (isUndefinedName(c, n)) .always else .sometimes,
        else => .never,
    };
}

fn isSideEffectFree(n0: *Node) bool {
    const n = binder.stripParens(n0);
    return switch (n.data) {
        .identifier, .string_lit, .regex_lit, .tagged_template, .template_expr, .no_subst_template, .numeric_lit, .bigint_lit, .true_lit, .false_lit, .null_lit, .array_lit, .object_lit, .typeof_expr, .non_null, .jsx_self_closing, .jsx_element => true,
        .func => |f| f.kind == .expr or f.kind == .arrow,
        .class => |k| k.is_expr,
        .conditional => |x| isSideEffectFree(x.then) and isSideEffectFree(x.els),
        .binary => |x| !x.op.isAssignment() and isSideEffectFree(x.left) and isSideEffectFree(x.right),
        .prefix => |x| x.op == .bang or x.op == .plus or x.op == .minus or x.op == .tilde,
        else => false,
    };
}

/// `(0, x.f)(…)` and `(0, eval)(…)` call without passing `this`, which is the point of the `0`.
fn isIndirectCall(n: *Node) bool {
    const x = n.data.binary;
    const p = n.parent orelse return false;
    if (p.data != .paren or x.left.data != .numeric_lit or !std.mem.eql(u8, x.left.data.numeric_lit, "0")) return false;
    const pp = p.parent orelse return false;
    const called = (pp.data == .call and pp.data.call.callee == p) or pp.data == .tagged_template;
    const right_ok = x.right.data == .prop_access or x.right.data == .elem_access or isIdent(x.right, "eval");
    return called and right_ok;
}

/// The parser already said that adjacent JSX elements need one parent there.
fn inJsxParentError(c: *Checker, n: *Node) bool {
    const f = d.fileOf(c, n) orelse return false;
    for (f.diags) |x| if (x.code == 2657 and x.start <= n.start and n.start < x.start + x.len) return true;
    return false;
}

/// A generic `x` that may be undefined says so only through its constraint, so in `x || y` the
/// constraint stands in for it.
fn withoutUndefined(c: *Checker, t: *Type) *Type {
    if (!hasUndefinedConstraint(c, t)) return t;
    return relate.removeDefinitelyUndefined(c, constraintOrSelf(c, t));
}

fn hasUndefinedConstraint(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_ => |x| for (x) |m| {
            if (hasUndefinedConstraint(c, m)) break true;
        } else false,
        .param, .access, .cond => mayBeUndefined(d.baseConstraint(c, t)),
        else => false,
    };
}

/// tsc's `checkDeleteExpression`, past checking the operand itself.
fn checkDeleteOperand(c: *Checker, e: *Node) void {
    const left, const name = switch (e.data) {
        .prop_access => |x| blk: {
            if (x.name.data == .private_name) err(c, e, 18011, "The operand of a 'delete' operator cannot be a private identifier.");
            break :blk .{ checkSilent(c, x.expr), ast.memberText(x.name) };
        },
        .elem_access => |x| blk: {
            const idx = checkSilent(c, x.index);
            break :blk .{ checkSilent(c, x.expr), d.literalName(c, idx.regular orelse idx) orelse return };
        },
        else => return err(c, e, 2703, "The operand of a 'delete' operator must be a property reference."),
    };
    if (T.isAny(left)) return;
    const p = d.getProp(c, left, name) orelse return;
    if (p.readonly) return err(c, e, 2704, "The operand of a 'delete' operator cannot be a read-only property.");
    if (!c.strict_null) return;
    const t = d.propType(c, p);
    if (T.isAny(t) or t.data == .unknown or t.data == .never) return;
    const optional = if (c.exact_optional) p.optional else p.optional or holdsUndefined(c, t);
    if (!optional) err(c, e, 2790, "The operand of a 'delete' operator must be optional.");
}

/// tsc's `TypeFactsIsUndefined`: a generic type answers through its constraint, and tsc
/// counts neither `void` nor a missing constraint.
fn holdsUndefined(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .undefined => true,
        .union_ => |x| for (x) |m| {
            if (holdsUndefined(c, m)) break true;
        } else false,
        .param, .access, .cond => blk: {
            const k = d.baseConstraint(c, t);
            break :blk k != t and holdsUndefined(c, k);
        },
        else => false,
    };
}

fn mayBeUndefined(t: *Type) bool {
    return switch (t.data) {
        .undefined => true,
        .union_ => |x| for (x) |m| {
            if (mayBeUndefined(m)) break true;
        } else false,
        else => false,
    };
}

fn binaryResult(c: *Checker, n: *Node, op: Tok, ln: *Node, rn: *Node, l0: *Type, r0: *Type) *Type {
    switch (op) {
        .amp2 => {
            if (flow.byTruthiness(c, l0, true).data == .never) return l0;
            return c.getUnion(&.{ definitelyFalsy(c, l0), r0 });
        },
        .pipe2 => {
            // The right side never runs, so it says nothing about the result.
            if (flow.byTruthiness(c, l0, false).data == .never) return l0;
            const lt = withoutUndefined(c, flow.byTruthiness(c, l0, true));
            return reduceSubtypes(c, &.{ lt, r0 });
        },
        .qq => {
            if (l0.data == .undefined or l0.data == .null) return r0;
            const kept = nonNull(c, l0);
            if (kept == l0) return l0;
            return reduceSubtypes(c, &.{ kept, r0 });
        },
        .plus => {
            if (l0.data == .never or r0.data == .never) return c.t_never;
            // A string on either side makes `+` total, so null and undefined are fine there.
            const stringy = isStringLike(c, l0) or isStringLike(c, r0);
            const l = if (stringy) l0 else checkNonNullPlus(c, l0, ln);
            const r = if (stringy) r0 else checkNonNullPlus(c, r0, rn);
            const any_side = T.isAny(l) or T.isAny(r);
            if (!any_side and isNumberLike(c, l) and isNumberLike(c, r)) return c.t_number;
            if (isBigLike(c, l) and isBigLike(c, r)) return c.t_bigint;
            if ((!T.isAny(l) and isStringLike(c, l)) or (!T.isAny(r) and isStringLike(c, r))) return c.t_string;
            if (any_side) return if (l.data == .err or r.data == .err) c.t_err else c.t_any;
            if (l.vars or r.vars) {
                const lb = d.baseConstraint(c, l);
                const rb = d.baseConstraint(c, r);
                if (isStringLike(c, lb) or isStringLike(c, rb)) return c.t_string;
                if (isNumberLike(c, lb) and isNumberLike(c, rb)) return c.t_number;
            }
            err(c, n, 2365, c.fmt("Operator '+' cannot be applied to types '{s}' and '{s}'.", .{ show(c, widenFresh(c, l)), show(c, widenFresh(c, r)) }));
            return c.t_err;
        },
        .minus, .star, .star2, .slash, .percent, .shl, .shr, .ushr, .amp, .pipe, .caret => {
            if (l0.data == .never or r0.data == .never) return c.t_never;
            arithOperand(c, l0, ln, 2362);
            arithOperand(c, r0, rn, 2363);
            const l = nonNull(c, l0);
            const r = nonNull(c, r0);
            if (isBigLike(c, l) and isBigLike(c, r)) return c.t_bigint;
            if (isBigLike(c, l) != isBigLike(c, r) and !T.isAny(l) and !T.isAny(r)) {
                err(c, n, 2365, c.fmt("Operator cannot be applied to types '{s}' and '{s}'.", .{ show(c, l), show(c, r) }));
            }
            return c.t_number;
        },
        .lt, .gt, .lte, .gte => {
            const l = checkNonNull(c, l0, ln);
            const r = checkNonNull(c, r0, rn);
            if (T.isAny(l) or T.isAny(r)) return c.t_boolean;
            const lw = baseOfLiteral(c, l.regular orelse l);
            const rw = baseOfLiteral(c, r.regular orelse r);
            const ok = (isNumberLike(c, lw) or isBigLike(c, lw)) and (isNumberLike(c, rw) or isBigLike(c, rw)) or relate.isComparable(c, lw, rw) or relate.isComparable(c, rw, lw) or lw.vars or rw.vars;
            if (!ok) err(c, n, 2365, c.fmt("Operator '{s}' cannot be applied to types '{s}' and '{s}'.", .{ opText(op), show(c, lw), show(c, rw) }));
            return c.t_boolean;
        },
        .eq2, .eq3, .neq, .neq3 => {
            const l = l0.regular orelse l0;
            const r = r0.regular orelse r0;
            if (!equalityOverlap(c, regularize(c, l), regularize(c, r)) and !T.isAny(l) and !T.isAny(r)) {
                err(c, n, 2367, c.fmt("This comparison appears to be unintentional because the types '{s}' and '{s}' have no overlap.", .{ show(c, l), show(c, r) }));
            }
            return c.t_boolean;
        },
        .kw_instanceof => {
            const l = l0;
            if (!T.isAny(l) and !l.vars and isPrimitiveValue(c, l)) {
                err(c, ln, 2358, "The left-hand side of an 'instanceof' expression must be of type 'any', an object type or a type parameter.");
            }
            if (!T.isAny(r0) and !isFunctionLike(c, r0) and !r0.vars) {
                err(c, rn, 2359, "The right-hand side of an 'instanceof' expression must be either of type 'any', a class, function, or other type assignable to the 'Function' interface type, or an object type with a 'Symbol.hasInstance' method.");
            }
            return c.t_boolean;
        },
        .kw_in => {
            // A private name is looked up on the right instead.
            if (ln.data != .private_name) {
                const l = checkNonNull(c, l0, ln);
                if (!T.isAny(l)) checkAssignable(c, l, c.getUnion(&.{ c.t_string, c.t_number, c.t_symbol }), null, ln);
            }
            const r = checkNonNull(c, r0, rn);
            if (!T.isAny(r)) checkAssignable(c, r, c.t_nonprim, null, rn);
            return c.t_boolean;
        },
        else => return c.t_err,
    }
}

fn checkNonNullPlus(c: *Checker, t: *Type, n: *Node) *Type {
    return checkNonNull(c, t, n);
}

pub fn isPrimitiveValue(c: *Checker, t: *Type) bool {
    _ = c;
    return switch (t.data) {
        .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .null, .undefined, .enum_, .enum_lit, .unique, .void => true,
        .union_ => |u| for (u) |m| {
            if (!isPrimitiveValue(undefined, m)) break false;
        } else true,
        else => false,
    };
}

fn isFunctionLike(c: *Checker, t: *Type) bool {
    if (d.callSigs(c, t).len > 0 or d.ctorSigs(c, t).len > 0) return true;
    if (d.getProp(c, t, "__@hasInstance") != null) return true;
    if (d.globalType(c, "Function")) |f| return relate.isAssignable(c, t, f);
    return false;
}

fn isReadonlyTarget(c: *Checker, n0: *Node) bool {
    // `(x.y as T) = v` is how code opts out, so an assertion ends the search.
    var n = n0;
    while (true) n = switch (n.data) {
        .paren => |x| x.expr,
        .non_null => |x| x.expr,
        else => break,
    };
    switch (n.data) {
        .identifier => |name| {
            const s = symbolOf(c, n) orelse return false;
            const target = d.targetOf(c, s) orelse return false;
            if (isConstVar(target) and target.flags & F.variable != 0) {
                err(c, n, 2588, c.fmt("Cannot assign to '{s}' because it is a constant.", .{name}));
                return true;
            }
            if (target.flags & (F.function | F.class | F.enum_any | F.value_module) != 0 and target.flags & F.variable == 0) {
                if (target.flags & F.function != 0) {
                    err(c, n, 2630, c.fmt("Cannot assign to '{s}' because it is a function.", .{name}));
                } else if (target.flags & F.class != 0) {
                    err(c, n, 2629, c.fmt("Cannot assign to '{s}' because it is a class.", .{name}));
                } else if (target.flags & F.enum_any != 0) {
                    err(c, n, 2628, c.fmt("Cannot assign to '{s}' because it is an enum.", .{name}));
                } else {
                    err(c, n, 2631, c.fmt("Cannot assign to '{s}' because it is a namespace.", .{name}));
                }
                return true;
            }
            if (s.flags & F.alias != 0) {
                err(c, n, 2632, c.fmt("Cannot assign to '{s}' because it is an import.", .{name}));
                return true;
            }
            return false;
        },
        .prop_access => |x| {
            const left = checkSilent(c, x.expr);
            if (T.isAny(left)) return false;
            const name = ast.memberText(x.name);
            const p = d.getProp(c, left, name) orelse return false;
            if (propReadonly(c, p, n)) {
                err(c, x.name, 2540, c.fmt("Cannot assign to '{s}' because it is a read-only property.", .{name}));
                return true;
            }
            return false;
        },
        .elem_access => |x| {
            const left = checkSilent(c, x.expr);
            const idx = checkSilent(c, x.index);
            if (T.isAny(left)) return false;
            if (d.literalName(c, idx.regular orelse idx)) |name| {
                if (d.getProp(c, left, name)) |p| {
                    if (!propReadonly(c, p, n)) return false;
                    err(c, n, 2540, c.fmt("Cannot assign to '{s}' because it is a read-only property.", .{name}));
                    return true;
                }
            }
            for (d.indexesOf(c, left)) |i| {
                if (i.readonly and (i.key == idx or relate.isAssignable(c, idx, i.key))) {
                    err(c, n, 2542, c.fmt("Index signature in type '{s}' only permits reading.", .{show(c, left)}));
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn propReadonly(c: *Checker, p: *Prop, n: *Node) bool {
    if (!p.readonly) return false;
    // Constructors initialize their own readonly fields.
    const decl = p.decl orelse return true;
    const owner = ownerClass(decl) orelse return true;
    if (decl.data != .property_decl and decl.data != .param) return true;
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) {
        if (x.data == .func) {
            if (x.data.func.kind == .ctor and x.parent == owner) return false;
            if (x.data.func.kind != .arrow) return true;
        }
        if (x.data == .property_decl and x.parent == owner) return false;
        if (x.data == .static_block and x.parent == owner) return false;
    }
    _ = c;
    return true;
}

fn checkAssign(c: *Checker, n: *Node) *Type {
    const x = n.data.binary;
    const left = binder.stripParens(x.left);
    if (left.data == .array_lit or left.data == .object_lit) {
        return checkDestructuringAssign(c, x.left, x.right);
    }
    const target = checkExpr(c, x.left);
    const value = checkExpr(c, x.right);
    if (!isReadonlyTarget(c, x.left) and !T.isAny(target)) checkAssignable(c, value, target, x.right, x.left);
    return value;
}

fn checkDestructuringAssign(c: *Checker, left: *Node, right: *Node) *Type {
    const source = checkExpr(c, right);
    destructureInto(c, binder.stripParens(left), source);
    return source;
}

/// tsc's `checkDestructuringAssignment`: every target in the pattern takes the part of `source`
/// it is written from.
pub fn destructureInto(c: *Checker, target0: *Node, source0: *Type) void {
    var target = target0;
    var source = source0;
    if (target.data == .shorthand_assign) {
        const x = target.data.shorthand_assign;
        if (x.init) |i| {
            // A default that cannot be undefined fills in for a missing value.
            if (c.strict_null and !hasUndefined(checkExpr(c, i))) source = removeUndefined(c, source);
            const declared = checkExpr(c, x.name);
            if (!T.isAny(declared)) checkAssignable(c, checkExpr(c, i), declared, i, x.name);
        }
        target = x.name;
    }
    if (target.data == .binary and target.data.binary.op == .assign) {
        _ = checkExpr(c, target);
        target = target.data.binary.left;
        if (c.strict_null) source = removeUndefined(c, source);
    }
    switch (target.data) {
        .object_lit => |x| for (x.props) |p| switch (p.data) {
            .property_assign => |a| destructureInto(c, a.value, destructuredProp(c, source, a.name)),
            .shorthand_assign => |a| destructureInto(c, p, destructuredProp(c, source, a.name)),
            .spread_assign => |a| {
                var skip = c.newList([]const u8);
                for (x.props) |o| {
                    const key = switch (o.data) {
                        .property_assign => |q| q.name,
                        .shorthand_assign => |q| q.name,
                        else => continue,
                    };
                    skip.append(c.a, propNameOf(c, key) orelse return) catch oom();
                }
                destructureInto(c, a.expr, if (T.isAny(source)) source else restOf(c, source, skip.items));
            },
            else => {},
        },
        .array_lit => |x| for (x.elems, 0..) |e, i| switch (e.data) {
            .omitted_expr => {},
            .spread_elem => |s| {
                const rest = if (T.isAny(source)) source else if (T.isTupleType(source)) restOfTuple(c, source, i) else d.arrayOf(c, destructuredElement(c, target, source, i));
                destructureInto(c, s.expr, rest);
            },
            else => destructureInto(c, e, destructuredElement(c, target, source, i)),
        },
        else => {
            const declared = checkExpr(c, target);
            if (!T.isAny(source) and !T.isAny(declared) and !isReadonlyTarget(c, target)) checkAssignable(c, source, declared, target, target);
        },
    }
}

fn destructuredProp(c: *Checker, source: *Type, name: *Node) *Type {
    const key = propNameOf(c, name) orelse return c.t_err;
    return destructuredMember(c, nonNull(c, source), key) orelse c.t_err;
}

fn restOfTuple(c: *Checker, t: *Type, i: usize) *Type {
    const o = t.data.obj;
    if (i >= o.tuple.elems.len) return c.makeTuple(&.{}, &.{}, false, &.{});
    return c.makeTuple(o.tuple.elems[i..], o.tuple.eflags[i..], false, &.{});
}

fn checkCompound(c: *Checker, n: *Node) *Type {
    const x = n.data.binary;
    // The written target takes more than its narrowed literal: `supported &&= next()`.
    const l = baseOfLiteral(c, checkExpr(c, x.left));
    const r = checkExpr(c, x.right);
    _ = isReadonlyTarget(c, x.left);
    const op: Tok = switch (x.op) {
        .plus_assign => .plus,
        .minus_assign => .minus,
        .star_assign => .star,
        .star2_assign => .star2,
        .slash_assign => .slash,
        .percent_assign => .percent,
        .shl_assign => .shl,
        .shr_assign => .shr,
        .ushr_assign => .ushr,
        .amp_assign => .amp,
        .pipe_assign => .pipe,
        .caret_assign => .caret,
        .amp2_assign => .amp2,
        .pipe2_assign => .pipe2,
        .qq_assign => .qq,
        else => return c.t_err,
    };
    const result = binaryResult(c, n, op, x.left, x.right, l, r);
    const arith = switch (op) {
        .minus, .star, .star2, .slash, .percent, .shl, .shr, .ushr, .amp, .pipe, .caret => true,
        else => false,
    };
    // tsc checks the assignment only when both operands were fit for arithmetic.
    const fit = !arith or (isArithOperand(c, nonNull(c, l)) and isArithOperand(c, nonNull(c, r)));
    if (!fit) return result;
    if (!T.isAny(l) and !T.isAny(result) and op != .amp2 and op != .pipe2 and op != .qq) {
        checkAssignable(c, result, l, x.left, x.left);
    } else if (op == .pipe2 or op == .qq or op == .amp2) {
        if (!T.isAny(l)) checkAssignable(c, r, l, x.right, x.left);
    }
    return result;
}

fn checkPrefix(c: *Checker, n: *Node) *Type {
    const x = n.data.prefix;
    const t = checkExpr(c, x.expr);
    switch (x.op) {
        .bang => {
            checkTruthiness(c, t, x.expr);
            // tsc answers `false` for an operand that is always truthy and `true` for one that
            // is always falsy; `never` has neither fact and stays `boolean`.
            if (t.data == .never or T.isAny(t)) return c.t_boolean;
            // Fresh, like a written `true`: `let x = !0` must still widen to `boolean`.
            if (flow.byTruthiness(c, t, false).data == .never) return c.freshOf(c.t_false);
            if (flow.byTruthiness(c, t, true).data == .never) return c.freshOf(c.t_true);
            return c.t_boolean;
        },
        .plus2, .minus2 => {
            _ = isReadonlyTarget(c, x.expr);
            incOperand(c, t, x.expr);
            return if (isBigLike(c, t)) c.t_bigint else c.t_number;
        },
        .plus, .minus, .tilde => {
            if (t.data == .num_lit and x.op == .minus) return c.freshOf(c.numLit(-t.data.num_lit));
            if (t.data == .num_lit and x.op == .plus) return t;
            if (t.data == .big_lit and x.op == .minus) return c.freshOf(c.bigLit(c.fmt("-{s}", .{t.data.big_lit})));
            const v = checkNonNull(c, t, x.expr);
            if (isBigLike(c, v)) {
                if (x.op == .plus) err(c, x.expr, 2736, c.fmt("Operator '+' cannot be applied to type '{s}'.", .{show(c, v)}));
                return c.t_bigint;
            }
            if (v.data == .symbol or v.data == .unique) {
                err(c, x.expr, 2469, c.fmt("The '{s}' operator cannot be applied to type 'symbol'.", .{if (x.op == .plus) "+" else if (x.op == .minus) "-" else "~"}));
            }
            return c.t_number;
        },
        else => return c.t_err,
    }
}

fn incOperand(c: *Checker, t0: *Type, n: *Node) void {
    const t = checkNonNull(c, t0, n);
    if (T.isAny(t) or isNumberLike(c, t) or isBigLike(c, t)) return;
    if (t.vars and isNumberLike(c, d.baseConstraint(c, t))) return;
    err(c, n, 2356, "An arithmetic operand must be of type 'any', 'number', 'bigint' or an enum type.");
}

// ---- assignability with error detail ----

/// Reports `value` not fitting `target`, at the innermost place the literal shape allows.
pub fn checkAssignable(c: *Checker, s: *Type, t: *Type, value: ?*Node, at: *Node) void {
    if (relate.isAssignable(c, s, t)) return;
    if (quiet(c)) return;
    if (value) |v| if (elaborate(c, v, s, t)) return;
    reportNotAssignable(c, s, t, at, value);
}

fn elaborate(c: *Checker, n0: *Node, s: *Type, t: *Type) bool {
    const n = switch (n0.data) {
        .paren => |x| x.expr,
        else => n0,
    };
    if (n != n0) return elaborate(c, n, s, t);
    switch (n.data) {
        .object_lit => |x| {
            var any = false;
            for (x.props) |p| {
                const data: struct { name: *Node, value: ?*Node } = switch (p.data) {
                    .property_assign => |y| .{ .name = y.name, .value = y.value },
                    .shorthand_assign => |y| .{ .name = y.name, .value = null },
                    .func => |y| .{ .name = y.name orelse continue, .value = null },
                    else => continue,
                };
                const name = propNameOf(c, data.name) orelse continue;
                const sp = d.getProp(c, s, name) orelse continue;
                const tt = targetProp(c, t, name) orelse continue;
                const st = d.propType(c, sp);
                if (relate.isAssignable(c, st, tt)) continue;
                any = true;
                if (data.value) |v| if (elaborate(c, v, st, tt)) continue;
                reportNotAssignable(c, st, tt, data.name, null);
            }
            return any;
        },
        .array_lit => |x| {
            if (!holdsArrays(c, t)) return false;
            c.ctx_stack.append(c.a, .{ .node = n, .ty = t, .ctx = null }) catch oom();
            defer _ = c.ctx_stack.pop();
            var any = false;
            for (x.elems, 0..) |e, i| {
                if (e.data == .spread_elem or e.data == .omitted_expr) continue;
                const tt = elemOfCtx(c, n, t, i) orelse continue;
                // `string[]` would blame every element for what only some of them are.
                const st = if (c.isArrayType(s) and e.data != .func) checkSilent(c, e) else elemAt(c, s, i) orelse continue;
                if (relate.isAssignable(c, st, tt)) continue;
                any = true;
                if (elaborate(c, e, st, tt)) continue;
                reportNotAssignable(c, st, tt, e, null);
            }
            return any;
        },
        .func => |f| {
            // A lambda's single returned expression is where the blame belongs.
            if (f.kind != .arrow or f.ret != null) return false;
            const body = f.body orelse return false;
            if (ast.isBlockBody(body)) return false;
            const ss = d.callSigs(c, s);
            const ts = d.callSigs(c, t);
            if (ss.len != 1 or ts.len != 1) return false;
            const tr = d.returnOf(c, ts[0]);
            const sr = d.returnOf(c, ss[0]);
            if (tr.data == .void or T.isAny(tr) or relate.isAssignable(c, sr, tr)) return false;
            if (!paramsFit(c, ss[0], ts[0])) return false;
            if (elaborate(c, body, sr, tr)) return true;
            reportNotAssignable(c, sr, tr, body, null);
            return true;
        },
        else => return false,
    }
}

pub fn holdsArrays(c: *Checker, t: *Type) bool {
    if (t.data == .union_) return for (t.data.union_) |m| {
        if (holdsArrays(c, m)) break true;
    } else false;
    return c.isArrayType(t) or T.isTupleType(t);
}

fn paramsFit(c: *Checker, s: *Sig, t: *Sig) bool {
    for (0..s.params.len) |i| {
        const x = relate.typeAt(c, s, i) orelse return true;
        const y = relate.typeAt(c, t, i) orelse return true;
        if (!relate.isAssignable(c, y, x) and !relate.isAssignable(c, x, y)) return false;
    }
    return true;
}

fn elemAt(c: *Checker, s: *Type, i: usize) ?*Type {
    if (T.isTupleType(s)) return if (i < s.data.obj.tuple.elems.len) s.data.obj.tuple.elems[i] else null;
    if (c.isArrayType(s)) return s.data.obj.args.?[0];
    return null;
}

fn targetProp(c: *Checker, t: *Type, name: []const u8) ?*Type {
    if (t.data == .union_) {
        var parts = c.newList(*Type);
        for (t.data.union_) |m| if (m.data == .obj or m.data == .inter) if (targetProp(c, m, name)) |x| parts.append(c.a, x) catch oom();
        return if (parts.items.len == 0) null else c.getUnion(parts.items);
    }
    if (d.getProp(c, t, name)) |p| return d.propType(c, p);
    return d.indexValue(c, t, c.t_string);
}

fn joinNames(c: *Checker, names: []const []const u8) []const u8 {
    var out = c.newList(u8);
    for (names, 0..) |x, i| {
        if (i > 0) out.appendSlice(c.a, ", ") catch oom();
        out.appendSlice(c.a, x) catch oom();
    }
    return out.items;
}

fn reportNotAssignable(c: *Checker, s: *Type, t0: *Type, n: *Node, value: ?*Node) void {
    const t = reportedTarget(c, s, t0);
    if (relate.excessProp(c, s, t)) |p| {
        const at = if (p.decl) |x| propNameNode(x) else n;
        if (relate.isJsxAttributes(s)) {
            err(c, at, 2322, c.fmt("Type '{s}' is not assignable to type '{s}'.", .{ show(c, s), show(c, t) }));
            return;
        }
        err(c, at, 2353, c.fmt("Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{ p.name, show(c, t) }));
        return;
    }
    _ = value;
    if (reportWeak(c, s, t, n)) return;
    if ((s.data == .obj or s.data == .inter) and (t.data == .obj or t.data == .inter)) {
        if (s.data == .obj and c.isArrayType(s) and s.data.obj.target == c.global_readonly_array and c.isMutableArray(t)) {
            err(c, n, 4104, c.fmt("The type '{s}' is 'readonly' and cannot be assigned to the mutable type '{s}'.", .{ show(c, s), show(c, t) }));
            return;
        }
        if (T.isTupleType(s) and s.data.obj.readonly and c.isMutableArray(t)) {
            err(c, n, 4104, c.fmt("The type '{s}' is 'readonly' and cannot be assigned to the mutable type '{s}'.", .{ show(c, s), show(c, t) }));
            return;
        }
        if (reportMissing(c, s, t, n)) return;
    }
    err(c, n, 2322, c.fmt("Type '{s}' is not assignable to type '{s}'.", .{ showSource(c, s, t), show(c, t) }));
}

/// tsc: "reporting the `null` and `undefined` in the type is hardly useful".
fn reportedTarget(c: *Checker, s: *Type, t: *Type) *Type {
    if (!isSettled(c, s) or t.data != .union_ or t.alias != null or t.data.union_.len > 3) return t;
    var rest: ?*Type = null;
    for (t.data.union_) |m| {
        if (isNullish(m)) continue;
        if (rest != null) return t;
        rest = m;
    }
    return if (rest != null and t.data.union_.len > 1) rest.? else t;
}

/// Neither a value that may yet be anything nor one that is itself empty.
fn isSettled(c: *Checker, s: *Type) bool {
    return switch (s.data) {
        .union_ => s == c.t_boolean or s.enum_sym != null,
        .obj, .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_, .enum_lit, .tmpl, .strmap => true,
        else => false,
    };
}

/// tsc looks for a common property before comparing anything, so this message has no head.
fn reportWeak(c: *Checker, s: *Type, t: *Type, n: *Node) bool {
    if (!relate.isWeak(c, t)) return false;
    const a = d.getApparent(c, s);
    if ((a.data != .obj and a.data != .inter) or relate.hasCommonProp(c, a, t)) return false;
    err(c, n, 2559, c.fmt("Type '{s}' has no properties in common with type '{s}'.", .{ show(c, s), show(c, t) }));
    return true;
}

/// tsc 7 puts the missing properties on top of every head message but a class heritage check's.
pub fn reportMissing(c: *Checker, s: *Type, t: *Type, n: *Node) bool {
    if ((s.data != .obj and s.data != .inter) or t.data != .obj) return false;
    // Tuples compare by length first, so that is what goes wrong, not a missing `1`.
    if (T.isTupleType(t) and (T.isTupleType(s) or c.isArrayType(s))) return false;
    // tsc swaps such a class for its base before comparing, and only then finds the property
    // missing, so the general message stays on top.
    if (addsNothing(c, s) or addsNothing(c, t)) return false;
    const missing = relate.missingProps(c, s, t);
    if (missing.len == 0) return false;
    if (missing.len == 1) {
        err(c, n, 2741, c.fmt("Property '{s}' is missing in type '{s}' but required in type '{s}'.", .{ missing[0], show(c, s), show(c, t) }));
    } else if (missing.len <= 4) {
        err(c, n, 2739, c.fmt("Type '{s}' is missing the following properties from type '{s}': {s}", .{ show(c, s), show(c, t), joinNames(c, missing) }));
    } else {
        err(c, n, 2740, c.fmt("Type '{s}' is missing the following properties from type '{s}': {s}, and {d} more.", .{ show(c, s), show(c, t), joinNames(c, missing[0..4]), missing.len - 4 }));
    }
    return true;
}

/// tsc's getSingleBaseForNonAugmentingSubtype, as far as messages show it: `Derived<T>` still
/// reports under its own name.
fn addsNothing(c: *Checker, t: *Type) bool {
    if (t.data != .obj or t.data.obj.target != null) return false;
    const g = t;
    if (g.data != .obj or g.data.obj.kind == .anon) return false;
    const s = g.data.obj.sym orelse return false;
    if (s.flags & (F.class | F.interface) == 0 or d.basesOf(c, g).len != 1) return false;
    return s.members == null or s.members.?.map.count() == 0;
}

/// tsc names the literal only when the target is itself literal; otherwise `string` reads better.
fn showSource(c: *Checker, s: *Type, t: *Type) []const u8 {
    if (t != c.t_boolean and isLiteralish(t)) return show(c, s);
    return show(c, regularize(c, relate.literalBase(c, s.regular orelse s)));
}

fn isLiteralish(t: *Type) bool {
    return switch (t.data) {
        .str_lit, .num_lit, .big_lit, .bool_lit, .enum_lit, .tmpl, .strmap, .null, .undefined => true,
        .union_ => |u| for (u) |m| {
            if (isLiteralish(m)) break true;
        } else false,
        else => false,
    };
}

fn propNameNode(p: *Node) *Node {
    return switch (p.data) {
        .property_assign => |x| x.name,
        .shorthand_assign => |x| x.name,
        .func => |f| f.name orelse p,
        else => p,
    };
}

// ---- calls ----

const Arg = struct {
    node: ?*Node,
    ty: ?*Type = null,
    spread: bool = false,
    /// How the last quiet visit went: reached at all, whether it owes anything, and which lambdas
    /// it passed over, as a range of `quiet_funcs`.
    visited: bool = false,
    owes: bool = false,
    funcs: [2]u32 = .{ 0, 0 },
};

fn effectiveArgs(c: *Checker, nodes: []*Node) []Arg {
    var out = std.ArrayList(Arg).initCapacity(c.a, nodes.len) catch oom();
    for (nodes) |a| {
        if (a.data == .spread_elem) {
            const t = checkExpr(c, a.data.spread_elem.expr);
            if (T.isTupleType(t)) {
                const o = t.data.obj;
                for (o.tuple.elems, o.tuple.eflags) |e, f| out.append(c.a, switch (f) {
                    .required => .{ .node = a, .ty = e },
                    .optional => .{ .node = a, .ty = d.addOptional(c, e) },
                    .rest => .{ .node = a, .ty = d.arrayOf(c, e), .spread = true },
                    .variadic => .{ .node = a, .ty = e, .spread = true },
                }) catch oom();
                continue;
            }
            out.append(c.a, .{ .node = a, .ty = t, .spread = true }) catch oom();
        } else out.append(c.a, .{ .node = a }) catch oom();
    }
    return out.items;
}

fn argType(c: *Checker, a: Arg, param: ?*Type, ctx: ?*InferCtx) *Type {
    if (a.ty) |t| {
        return if (a.spread) iteratedOf(c, a.node.?, t, false) else t;
    }
    const n = a.node.?;
    c.ctx_stack.append(c.a, .{ .node = n, .ty = param, .ctx = ctx }) catch oom();
    defer _ = c.ctx_stack.pop();
    const t = checkExpr(c, n);
    // `const b: Box<"a" | "b"> = box("a")`: a literal the return type asks for must survive,
    // or widening the candidate would turn it into `string`.
    if (ctx) |x| if (x.return_mapper) |m| if (param) |p| {
        const fresh = t.regular != null or (t.data == .union_ and hasFreshMember(t));
        if (fresh and t.data != .obj and literalCtx(c, t.regular orelse t, viaReturnMapper(c, p, m))) return regularize(c, t);
    };
    return t;
}

fn hasFreshMember(t: *Type) bool {
    for (t.data.union_) |m| if (m.regular != null) return true;
    return false;
}

fn arityOk(c: *Checker, s: *Sig, args: []Arg) bool {
    const a = relate.arityOf(c, s);
    var spread_at: ?usize = null;
    for (args, 0..) |x, i| if (x.spread) {
        spread_at = i;
        break;
    };
    // tsc: a non-tuple spread fits only once every required parameter before it is covered,
    // and only into a rest parameter or a parameter slot that exists.
    if (spread_at) |i| {
        return i >= a.min and (a.max == null or i < a.max.?);
    }
    if (args.len < a.min) return false;
    if (a.max) |m| if (args.len > m) return false;
    return true;
}

fn hasGenericRest(c: *Checker, s: *Sig) bool {
    const r = relate.restType(c, s) orelse return false;
    return r.vars;
}

fn inferSig(c: *Checker, n: *Node, s: *Sig, args: []Arg, sensitive_ok: bool) *Sig {
    const ctx = relate.newInferCtx(c, s.tparams, 0);
    const ret = d.returnOf(c, s);
    // A predicate takes the place of the return type here: `strictEqual(x, "a")` keeps `"a"`.
    ctx.ret = if (d.predOf(c, s)) |p| p.ty orelse c.t_void else ret;
    if (contextualType(c, n)) |ct0| {
        if (ct0.data != .err and ret.vars) {
            // A pattern shapes literals but knows nothing of the values: `[a] = await Promise.all(...)`.
            if (!fromPattern(c, n, ct0)) relate.inferTypes(c, ctx, instantiateCtx(c, n, ct0), ret, T.Priority.return_type);
            // A separate pass: these serve as context only and must never become candidates.
            const rc = relate.newInferCtx(c, s.tparams, 0);
            relate.inferTypes(c, rc, outerInferred(c, n, ct0), ret, T.Priority.return_type);
            ctx.return_mapper = relate.inferredPart(c, rc);
        }
    }
    if (s.this_ty) |tt| if (tt.vars and n.data == .call) {
        var callee = n.data.call.callee;
        while (callee.data == .paren) callee = callee.data.paren.expr;
        switch (callee.data) {
            // `a?.f()` runs only with a real `a`, so `this` never carries the null side.
            .prop_access => |x| relate.inferTypes(c, ctx, thisArgument(c, x.expr, x.optional), tt, 0),
            .elem_access => |x| relate.inferTypes(c, ctx, thisArgument(c, x.expr, x.optional), tt, 0),
            else => {},
        }
    };
    const fixed = if (s.has_rest) s.params.len - 1 else s.params.len;
    const rest = relate.restType(c, s);
    const generic_rest = rest != null and !c.isArrayType(rest.?) and !T.isTupleType(rest.?) and rest.?.vars;
    const save = c.skip_sensitive;
    defer c.skip_sensitive = save;
    c.skip_sensitive = !sensitive_ok;
    // Lambdas fix what their parameters mention, so everything else has to vote first,
    // wherever it sits: `reduce((r, x) => r, 0)`.
    const end = if (generic_rest) @min(fixed, args.len) else args.len;
    inferArgs(c, ctx, s, args[0..end], false);
    const trailing: []Arg = if (generic_rest and args.len >= fixed) args[fixed..] else &.{};
    const has_rest_args = generic_rest and args.len >= fixed;
    // Plain trailing arguments vote before the lambdas, which may take their types as parameters.
    const plain = for (trailing) |a| {
        if (a.ty == null and sensitiveArg(c, a.node.?)) break false;
    } else true;
    if (has_rest_args and plain) inferRest(c, ctx, rest.?, trailing);
    if (sensitive_ok) inferArgs(c, ctx, s, args[0..end], true);
    if (has_rest_args and !plain) inferRest(c, ctx, rest.?, trailing);
    const vals = c.a.alloc(*Type, s.tparams.len) catch oom();
    for (vals, 0..) |*v, i| v.* = relate.getInferred(c, ctx, i);
    return d.applySig(c, s, d.arrayMapper(c, s.tparams, vals));
}

fn fromPattern(c: *Checker, n: *Node, t: *Type) bool {
    c.skip_patterns += 1;
    defer c.skip_patterns -= 1;
    return contextualType(c, n) != t;
}

fn inferRest(c: *Checker, ctx: *InferCtx, rest: *Type, args: []Arg) void {
    var elems = c.newList(*Type);
    var flags = c.newList(T.ElemFlag);
    for (args, 0..) |a, i| {
        const want = d.getIndexedAccess(c, rest, c.numLit(@floatFromInt(i)));
        const at = argType(c, a, want, ctx);
        // `T extends string[]` asks for a tuple of the literals as written.
        elems.append(c.a, if (a.spread) at else if (keepsLiteral(c, at, want)) regularize(c, at) else regularize(c, widenFresh(c, at))) catch oom();
        flags.append(c.a, if (a.spread) .rest else .required) catch oom();
    }
    relate.inferTypes(c, ctx, c.makeTuple(elems.items, flags.items, false, &.{}), rest, 0);
}

fn inferArgs(c: *Checker, ctx: *InferCtx, s: *Sig, args: []Arg, sensitive: bool) void {
    const sink = c.array_sink;
    defer c.array_sink = sink;
    for (args, 0..) |a, i| {
        const is_sensitive = a.ty == null and sensitiveArg(c, a.node.?);
        // The plain members of a literal vote with everything else; only its lambdas wait.
        const partial = is_sensitive and !sensitive and (a.node.?.data == .object_lit or a.node.?.data == .array_lit);
        if (is_sensitive != sensitive and !partial) continue;
        const pt = relate.typeAt(c, s, i) orelse break;
        const save = c.skip_sensitive;
        defer c.skip_sensitive = save;
        if (partial) c.skip_sensitive = true;
        // A literal whose lambdas still wait is only a draft of the one that follows.
        c.array_sink = if (partial) null else &ctx.array_lits;
        relate.inferTypes(c, ctx, argType(c, a, pt, ctx), pt, 0);
    }
}

const Failure = struct { arg: usize, s: *Type, t: *Type };

fn firstBadArg(c: *Checker, s: *Sig, args: []Arg, sensitive_ok: bool, strict: bool) ?Failure {
    const save = c.skip_sensitive;
    defer c.skip_sensitive = save;
    c.skip_sensitive = !sensitive_ok;
    for (args) |*a| a.visited = false;
    for (args, 0..) |*a, i| {
        const pt = relate.typeAt(c, s, i) orelse break;
        const debt = c.quiet_debt;
        const funcs: u32 = @intCast(c.quiet_funcs.items.len);
        const at = argType(c, a.*, pt, null);
        a.visited = true;
        a.owes = c.quiet_debt != debt;
        a.funcs = .{ funcs, @intCast(c.quiet_funcs.items.len) };
        const ok = if (strict) relate.isSubtype(c, at, pt) else relate.isAssignable(c, at, pt);
        if (!ok) return .{ .arg = i, .s = at, .t = pt };
    }
    return null;
}

fn explicitTypeArgs(c: *Checker, s: *Sig, nodes: []*Node) ?*Sig {
    if (nodes.len > s.tparams.len) return null;
    var min = s.tparams.len;
    while (min > 0 and d.defaultOf(c, s.tparams[min - 1]) != null) min -= 1;
    if (nodes.len < min) return null;
    const vals = c.a.alloc(*Type, s.tparams.len) catch oom();
    for (nodes, 0..) |x, i| vals[i] = d.typeFromNode(c, x);
    for (nodes.len..s.tparams.len) |i| {
        vals[i] = d.instantiate(c, d.defaultOf(c, s.tparams[i]).?, d.arrayMapper(c, s.tparams[0..i], vals[0..i]));
    }
    for (s.tparams, 0..) |p, i| if (d.constraintOf(c, p)) |k0| {
        const k = d.instantiate(c, k0, d.arrayMapper(c, s.tparams, vals));
        if (!k.vars and !vals[i].vars and !relate.isAssignable(c, vals[i], k)) {
            if (i < nodes.len) err(c, nodes[i], 2344, c.fmt("Type '{s}' does not satisfy the constraint '{s}'.", .{ show(c, vals[i]), show(c, k) }));
            return null;
        }
    };
    return d.applySig(c, s, d.arrayMapper(c, s.tparams, vals));
}

fn appliedSigs(c: *Checker, sigs: []*Sig, nodes: []*Node) []*Sig {
    var out = c.newList(*Sig);
    for (sigs) |s| if (s.tparams.len > 0) if (explicitTypeArgs(c, s, nodes)) |x| out.append(c.a, x) catch oom();
    return out.items;
}

/// `Foo<string>` used as a value: keeps the members, narrows the signatures to the applied ones.
pub fn instantiationExpr(c: *Checker, t: *Type, nodes: []*Node) *Type {
    switch (t.data) {
        .union_, .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = instantiationExpr(c, y, nodes);
            return if (t.data == .union_) c.getUnion(out) else c.getIntersection(out);
        },
        .obj => {
            const m = d.membersOf(c, t);
            const calls = appliedSigs(c, m.calls, nodes);
            const ctors = appliedSigs(c, m.ctors, nodes);
            if (calls.len == 0 and ctors.len == 0) return t;
            const out = c.emptyMembers();
            out.props = m.props;
            out.indexes = m.indexes;
            out.calls = calls;
            out.ctors = ctors;
            const r = c.newObj(.{ .kind = .anon, .members = out });
            for (nodes) |a| if (d.typeFromNode(c, a).vars) {
                r.vars = true;
            };
            return r;
        },
        else => return t,
    }
}

fn calleeSpan(n: *Node) *Node {
    const callee = switch (n.data) {
        .call => |x| x.callee,
        .new_expr => |x| x.callee,
        else => return n,
    };
    return if (callee.data == .prop_access) callee.data.prop_access.name else callee;
}

/// `new Promise(resolve => resolve())`, the `T` nothing said to be `void`.
fn isPromiseResolve(c: *Checker, n: *Node) bool {
    if (n.data != .call or n.data.call.callee.data != .identifier) return false;
    const decl = (symbolOf(c, n.data.call.callee) orelse return false).value_decl orelse return false;
    if (decl.data != .param) return false;
    const func = decl.parent orelse return false;
    if (func.data != .func or (func.data.func.kind != .arrow and func.data.func.kind != .expr)) return false;
    const call = func.parent orelse return false;
    if (call.data != .new_expr or call.data.new_expr.callee.data != .identifier) return false;
    return symbolOf(c, call.data.new_expr.callee) == d.globalSym(c, "Promise");
}

fn reportArity(c: *Checker, n: *Node, sigs: []*Sig, args: []Arg, node_args: []*Node) void {
    var min: u32 = std.math.maxInt(u32);
    var max: u32 = 0;
    var unbounded = false;
    for (sigs) |s| {
        const a = relate.arityOf(c, s);
        min = @min(min, a.min);
        if (a.max) |m| max = @max(max, m) else unbounded = true;
    }
    const got: u32 = @intCast(args.len);
    for (args) |a| if (a.spread) {
        err(c, a.node.?, 2556, "A spread argument must either have a tuple type or be passed to a rest parameter.");
        return;
    };
    if (got < min or (got <= max and sigs.len > 1)) {
        const at = calleeSpan(n);
        if (got >= min) {
            // Between overloads: nothing takes exactly this many.
            var below: u32 = 0;
            var above: u32 = std.math.maxInt(u32);
            for (sigs) |s| {
                const a = relate.arityOf(c, s);
                const hi = a.max orelse a.min;
                if (hi < got) below = @max(below, hi);
                if (a.min > got) above = @min(above, a.min);
            }
            err(c, at, 2575, c.fmt("No overload expects {d} arguments, but overloads do exist that expect either {d} or {d} arguments.", .{ got, below, above }));
            return;
        }
        if (unbounded or max > min) {
            if (unbounded) {
                err(c, at, 2555, c.fmt("Expected at least {d} arguments, but got {d}.", .{ min, got }));
            } else {
                err(c, at, 2554, c.fmt("Expected {d}-{d} arguments, but got {d}.", .{ min, max, got }));
            }
        } else if (min == 1 and got == 0 and isPromiseResolve(c, n)) {
            err(c, at, 2794, "Expected 1 arguments, but got 0. Did you forget to include 'void' in your type argument to 'Promise'?");
        } else {
            err(c, at, 2554, c.fmt("Expected {d} arguments, but got {d}.", .{ min, got }));
        }
        return;
    }
    const first = node_args[@min(max, @as(u32, @intCast(node_args.len - 1)))];
    const last = node_args[node_args.len - 1];
    const msg = if (min == max) c.fmt("Expected {d} arguments, but got {d}.", .{ min, got }) else c.fmt("Expected {d}-{d} arguments, but got {d}.", .{ min, max, got });
    errSpan(c, first, first.start, last.end, 2554, msg);
}

/// A later declaration's overloads are tried first, and signatures with literal parameters
/// before everything else. This is what lets libs and augmentations refine a merged interface.
fn reorderCandidates(c: *Checker, sigs: []*Sig) []*Sig {
    if (sigs.len < 2) return sigs;
    var out = std.ArrayList(*Sig).initCapacity(c.a, sigs.len) catch oom();
    var last_parent: ?*Node = null;
    var last_symbol: ?*Symbol = null;
    var cutoff: usize = 0;
    var index: usize = 0;
    var specialized: usize = 0;
    for (sigs) |s| {
        const sym = if (s.decl) |x| (if (x.symbol()) |y| y.resolve() else null) else null;
        const parent = if (s.decl) |x| x.parent else null;
        if (last_symbol == null or sym == last_symbol) {
            if (last_parent != null and parent == last_parent) {
                index += 1;
            } else {
                last_parent = parent;
                index = cutoff;
            }
        } else {
            cutoff = out.items.len;
            index = cutoff;
        }
        last_symbol = sym;
        var at = index;
        if (hasLiteralParam(s)) {
            at = specialized;
            specialized += 1;
            cutoff += 1;
        }
        out.insertAssumeCapacity(at, s);
    }
    return out.items;
}

fn hasLiteralParam(s: *Sig) bool {
    const n = s.decl orelse return false;
    if (n.data != .func) return false;
    for (n.data.func.params) |p| if (p.data.param.type) |t| if (t.data == .literal_type) return true;
    return false;
}

fn resolveCall(c: *Checker, n: *Node, sigs: []*Sig, node_args: []*Node, type_args: []*Node, is_decor: bool) ?*Sig {
    _ = is_decor;
    const quiet_funcs = c.quiet_funcs.items.len;
    const args = effectiveArgs(c, node_args);
    var cands = std.ArrayList(*Sig).initCapacity(c.a, sigs.len) catch oom();
    for (reorderCandidates(c, sigs)) |s| {
        if (arityOk(c, s, args)) cands.append(c.a, s) catch oom();
    }
    if (cands.items.len == 0) {
        reportArity(c, n, sigs, args, node_args);
        checkArgsLoose(c, args);
        return null;
    }
    const any_sensitive = for (args) |a| {
        if (a.node != null and a.ty == null and sensitiveArg(c, a.node.?)) break true;
    } else false;
    const passes: []const bool = if (any_sensitive) &.{ false, true } else &.{true};
    // Most calls fit their first candidate and never touch these.
    var failed: std.ArrayList(Failure) = .empty;
    var failed_sigs: std.ArrayList(*Sig) = .empty;
    c.silent += 1;
    var chosen: ?*Sig = null;
    var wrong_count: ?*Sig = null;
    // Overloads first have to fit as subtypes, so an `any` argument does not stop at the first
    // signature that would take anything.
    const relations: []const bool = if (cands.items.len > 1) &.{ true, false } else &.{false};
    outer: for (relations) |strict| {
        failed.clearRetainingCapacity();
        failed_sigs.clearRetainingCapacity();
        for (cands.items) |s| {
            var inst = s;
            if (type_args.len > 0) {
                if (s.tparams.len == 0) continue;
                inst = explicitTypeArgs(c, s, type_args) orelse continue;
            }
            const generic = inst.tparams.len > 0;
            for (passes) |sens| {
                const cur = if (generic) inferSig(c, n, inst, args, sens) else inst;
                // A generic rest parameter tells how many arguments it takes only now.
                if (generic and hasGenericRest(c, inst) and !arityOk(c, cur, args)) {
                    wrong_count = cur;
                    break;
                }
                if (firstBadArg(c, cur, args, sens, strict)) |f| {
                    failed.append(c.a, f) catch oom();
                    failed_sigs.append(c.a, cur) catch oom();
                    break;
                }
                if (sens) {
                    chosen = cur;
                    break :outer;
                }
            }
        }
    }
    c.silent -= 1;
    defer if (c.silent == 0) c.quiet_funcs.shrinkRetainingCapacity(quiet_funcs);
    if (chosen) |sig| {
        settleArgs(c, args, sig);
        return sig;
    }
    if (failed.items.len == 0) if (wrong_count) |s| {
        var one = [_]*Sig{s};
        reportArity(c, n, &one, args, node_args);
        checkArgsLoose(c, args);
        return null;
    };
    if (type_args.len > 0) {
        const fit: ?*Sig = for (cands.items) |s| {
            if (s.tparams.len > 0) {
                var min = s.tparams.len;
                while (min > 0 and d.defaultOf(c, s.tparams[min - 1]) != null) min -= 1;
                if (type_args.len >= min and type_args.len <= s.tparams.len) break s;
            }
        } else null;
        if (fit == null) {
            const count = sigs[0].tparams.len;
            err(c, type_args[0], 2558, c.fmt("Expected {d} type arguments, but got {d}.", .{ count, type_args.len }));
            checkArgsLoose(c, args);
            return null;
        }
        // No candidate got as far as its arguments: the type arguments fell at a constraint
        // inside the silent pass, so the constraint error has to be raised in the open here.
        if (failed.items.len == 0 and explicitTypeArgs(c, fit.?, type_args) == null) {
            checkArgsLoose(c, args);
            return null;
        }
    }
    if (failed.items.len == 0) {
        checkArgsLoose(c, args);
        return null;
    }
    if (cands.items.len == 1) {
        const f = failed.items[0];
        reportArg(c, failed_sigs.items[0], args, f);
        checkArgsIn(c, args, failed_sigs.items[0]);
        return failed_sigs.items[0];
    }
    const same = for (failed.items) |f| {
        if (f.arg != failed.items[0].arg) break false;
    } else true;
    const at = if (same) args[failed.items[0].arg].node orelse n else calleeSpan(n);
    err(c, at, 2769, "No overload matches this call.");
    checkArgsIn(c, args, failed_sigs.items[0]);
    return null;
}

fn reportArg(c: *Checker, sig: *Sig, args: []Arg, f: Failure) void {
    _ = sig;
    if (quiet(c)) return;
    const a = args[f.arg];
    const at = a.node orelse return;
    if (a.ty == null and elaborate(c, at, f.s, f.t)) return;
    const target = reportedTarget(c, f.s, f.t);
    if (relate.excessProp(c, f.s, target)) |p| {
        err(c, if (p.decl) |x| propNameNode(x) else at, 2353, c.fmt("Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{ p.name, show(c, target) }));
        return;
    }
    if (reportWeak(c, f.s, target, at) or reportMissing(c, f.s, target, at)) return;
    err(c, at, 2345, c.fmt("Argument of type '{s}' is not assignable to parameter of type '{s}'.", .{ showSource(c, f.s, target), show(c, target) }));
}

/// After a failed call the arguments still get checked, with whatever context is left.
/// One more pass in the open, so errors inside the arguments surface. A failed call still has
/// the signature it failed against, and its lambdas read their parameters from that.
fn checkArgsIn(c: *Checker, args: []Arg, sig: *Sig) void {
    for (args, 0..) |a, i| {
        if (a.ty != null) continue;
        _ = argType(c, a, relate.typeAt(c, sig, i), null);
    }
}

/// The pass that chose `sig` has just visited the arguments in this very context, so a visit in
/// the open has only the errors and lambdas of that one to catch up on, and a quiet one nothing.
fn settleArgs(c: *Checker, args: []Arg, sig: *Sig) void {
    for (args, 0..) |a, i| {
        if (a.ty != null) continue;
        const root = a.node orelse continue;
        if (a.visited and (c.silent > 0 or !a.owes)) {
            if (c.silent == 0) deferQuietFuncs(c, root, c.quiet_funcs.items[a.funcs[0]..a.funcs[1]]);
            continue;
        }
        _ = argType(c, a, relate.typeAt(c, sig, i), null);
    }
}

fn checkArgsLoose(c: *Checker, args: []Arg) void {
    for (args) |a| {
        if (a.ty != null) continue;
        const n = a.node orelse continue;
        c.ctx_stack.append(c.a, .{ .node = n, .ty = c.t_err, .ctx = null }) catch oom();
        _ = checkExpr(c, n);
        _ = c.ctx_stack.pop();
    }
}

fn typeList(x: ast.TypeList) []*Node {
    return x.items;
}

fn calleeSigs(c: *Checker, t: *Type) ?[]*Sig {
    const s = d.callSigs(c, t);
    return if (s.len > 0) s else null;
}

fn namesSymbol(callee: *Node) bool {
    return switch (callee.data) {
        .identifier => |name| std.mem.eql(u8, name, "Symbol"),
        .prop_access => |y| std.mem.eql(u8, ast.memberText(y.name), "for") and y.expr.data == .identifier and std.mem.eql(u8, y.expr.data.identifier, "Symbol"),
        else => false,
    };
}

/// The declaration whose name `Symbol()` gives a type of its own: `const K = Symbol()`.
fn symbolCallOwner(c: *Checker, n: *Node) ?*Symbol {
    if (!namesSymbol(n.data.call.callee)) return null;
    var cur = n;
    while (cur.parent) |p| : (cur = p) {
        if (p.data != .paren) break;
    }
    const owner = cur.parent orelse return null;
    switch (owner.data) {
        .var_decl => |v| {
            if (v.init != cur or v.name.data != .identifier) return null;
            const s = owner.symbol() orelse return null;
            return if (isConstVar(s)) s else null;
        },
        .property_decl => |v| {
            if (v.init != cur or !owner.mods.static or !owner.mods.readonly) return null;
            return owner.symbol();
        },
        else => {
            _ = c;
            return null;
        },
    }
}

fn checkCall(c: *Checker, n: *Node) *Type {
    if (firstAnswer(c, n)) |t| return t;
    const debt = c.quiet_debt;
    const funcs = c.quiet_funcs.items.len;
    const cycles = c.cycles;
    var sig: ?*Sig = null;
    var t = checkCallResult(c, n, &sig);
    if (t.data == .symbol) if (symbolCallOwner(c, n)) |s| {
        t = d.uniqueSymbol(c, s);
    };
    const settled = c.cycles == cycles and (c.silent == 0 or (c.flow_active.count() == 0 and c.quiet_debt == debt and
        c.quiet_funcs.items.len == funcs and (isFixed(sig) or contextualType(c, n) == null)));
    if (settled) if (sig) |s| c.resolved_calls.put(c.a, n, s) catch oom();
    return keepAnswer(c, n, t, sig, settled);
}

/// A call inside an argument would be resolved again on every pass of the call around it, and
/// those passes multiply with depth. Like tsc, a later quiet visit takes the first answer; the
/// visit in the open still resolves, for the errors a quiet one could not report, unless the
/// answer is settled: reached in the open, or owing nothing in a context that cannot change.
fn firstAnswer(c: *Checker, n: *Node) ?*Type {
    const answer = c.call_results.get(n) orelse return null;
    if (answer.settled) return answer.ty;
    if (!quiet(c)) return null;
    return answer.ty;
}

/// A loop still being settled feeds on temporary types, so what it computes must not stick.
/// The first answer stands even when the visit in the open knows a better context: the call
/// around it has already been decided on that answer.
fn keepAnswer(c: *Checker, n: *Node, t: *Type, sig: ?*Sig, settled: bool) *Type {
    if (c.flow_active.count() != 0) return t;
    const gop = c.call_results.getOrPut(c.a, n) catch oom();
    if (!gop.found_existing) gop.value_ptr.* = .{ .ty = t, .sig = sig, .settled = settled };
    if (settled) gop.value_ptr.settled = true;
    return gop.value_ptr.ty;
}

/// What a call to `sig` gives does not depend on the context around it.
fn isFixed(sig: ?*Sig) bool {
    const s = sig orelse return false;
    return s.tparams.len == 0 and s.target == null;
}

fn checkCallResult(c: *Checker, n: *Node, resolved: *?*Sig) *Type {
    const x = n.data.call;
    if (x.callee.data == .import_kw) {
        for (x.args) |a| _ = checkExpr(c, a);
        return importCall(c, n);
    }
    if (x.callee.data == .super_expr) return checkSuperCall(c, n);
    var callee = checkExpr(c, x.callee);
    var chain = x.optional or flow.isOptionalChain(x.callee);
    if (chain) {
        const nn = nonNull(c, callee);
        chain = nn != callee;
        callee = nn;
    } else callee = checkNonNull(c, callee, x.callee);
    if (T.isAny(callee) or callee.data == .never) {
        if (saysNothing(c, callee)) untypedArgs(c, x.args) else looseArgs(c, x.args);
        return if (callee.data == .never) c.t_never else callee;
    }
    const sigs = calleeSigs(c, callee) orelse {
        if (isOpen(c, callee) or callee.vars) looseArgs(c, x.args) else untypedArgs(c, x.args);
        if (isOpen(c, callee)) return c.t_err;
        if (callee.vars and callee.data != .obj) {
            const k = d.baseConstraint(c, callee);
            if (k.vars or k == callee) return c.t_err;
        }
        if (d.ctorSigs(c, callee).len > 0) {
            err(c, x.callee, 2348, c.fmt("Value of type '{s}' is not callable. Did you mean to include 'new'?", .{show(c, callee)}));
            return c.t_err;
        }
        if (d.globalType(c, "Function")) |f| if (callee.data == .obj and relate.isAssignable(c, callee, f) and d.callSigs(c, callee).len == 0 and hasFunctionMembers(c, callee)) return c.t_any;
        err(c, x.callee, 2349, c.fmt("This expression is not callable.\n  Type '{s}' has no call signatures.", .{show(c, callee)}));
        return c.t_err;
    };
    const resolving = c.resolving_calls.getOrPut(c.a, n) catch oom();
    const was = resolving.found_existing;
    defer if (!was) {
        _ = c.resolving_calls.remove(n);
    };
    const sig = resolveCall(c, n, sigs, x.args, typeList(x.type_args), false) orelse return c.t_err;
    resolved.* = sig;
    var r = d.returnOf(c, sig);
    if (chain) r = d.addOptional(c, r);
    return r;
}

fn hasFunctionMembers(c: *Checker, t: *Type) bool {
    return d.getProp(c, t, "apply") != null and d.getProp(c, t, "call") != null;
}

fn importCall(c: *Checker, n: *Node) *Type {
    const x = n.data.call;
    if (x.args.len == 0) return c.t_err;
    const a = binder.stripParens(x.args[0]);
    if (a.data != .string_lit) return promiseOf(c, c.t_any);
    const f = d.fileOf(c, n) orelse return c.t_err;
    const sf = c.prog.sourceOf(f) orelse return c.t_err;
    const m = c.prog.resolveModuleName(sf, a.data.string_lit) orelse {
        checker.checkModuleRef(c, n, a);
        return promiseOf(c, c.t_any);
    };
    const whole = if (c.prog.exportOf(m, "export=")) |e| d.targetOf(c, e) orelse m else m;
    return promiseOf(c, syntheticDefault(c, d.typeOfSymbol(c, whole), m));
}

/// Interop hands a CommonJS module to `import()` as an object whose `default` is the module.
fn syntheticDefault(c: *Checker, t: *Type, m: *Symbol) *Type {
    const o = c.prog.cfg.options;
    if (!o.flag("esModuleInterop") and !o.flag("allowSyntheticDefaultImports")) return t;
    if (T.isAny(t) or t.data != .obj) return t;
    const has_export_equals = c.prog.exportOf(m, "export=") != null;
    const declared_only = if (m.file) |f| f.is_dts else true;
    if (!has_export_equals and !declared_only) return t;
    if (c.prog.exportOf(m, "default") != null or c.prog.exportOf(m, "__esModule") != null) return t;
    const out = c.emptyMembers();
    for (d.propsOf(c, t)) |p| out.props.put(c.a, p.name, p) catch oom();
    out.props.put(c.a, "default", c.create(T.Prop, .{ .name = "default", .sym = m, .ty = t })) catch oom();
    return c.newObj(.{ .kind = .anon, .members = out });
}

fn looseArgs(c: *Checker, nodes: []*Node) void {
    checkArgsLoose(c, argsFor(c, nodes));
}

/// What has no signatures says nothing about its arguments, so their lambdas are implicit `any`.
fn untypedArgs(c: *Checker, nodes: []*Node) void {
    for (nodes) |n| {
        c.ctx_stack.append(c.a, .{ .node = n, .ty = c.t_any, .ctx = null }) catch oom();
        _ = checkExpr(c, n);
        _ = c.ctx_stack.pop();
    }
}

fn argsFor(c: *Checker, nodes: []*Node) []Arg {
    const out = c.a.alloc(Arg, nodes.len) catch oom();
    for (nodes, 0..) |a, i| out[i] = .{ .node = a };
    return out;
}

pub fn similarProp(c: *Checker, name: []const u8, t: *Type) ?[]const u8 {
    var names = c.newList([]const u8);
    if (t.data == .obj or t.data == .inter or t.data == .union_) {
        for (d.propsOf(c, t)) |p| {
            if (p.private) continue;
            names.append(c.a, p.name) catch oom();
        }
    }
    return spelling.best(c.a, name, names.items);
}

fn checkSuperCall(c: *Checker, n: *Node) *Type {
    const x = n.data.call;
    const cls = enclosingClass(n) orelse {
        looseArgs(c, x.args);
        return c.t_err;
    };
    for (classHeritage(cls)) |e| {
        if (e.data != .expr_with_type_args) continue;
        const b = checkExpr(c, e.data.expr_with_type_args.expr);
        if (T.isAny(b)) break;
        const sigs = d.ctorSigs(c, b);
        if (sigs.len == 0) break;
        _ = resolveCall(c, n, instantiateBase(c, sigs, e), x.args, &.{}, false);
        return c.t_void;
    }
    looseArgs(c, x.args);
    return c.t_void;
}

fn instantiateBase(c: *Checker, sigs: []*Sig, e: *Node) []*Sig {
    const targs = e.data.expr_with_type_args.type_args.items;
    var out = c.newList(*Sig);
    for (sigs) |s| {
        if (s.tparams.len > 0 and targs.len <= s.tparams.len and targs.len >= d.minArgs(c, s.tparams)) {
            const vals = c.a.alloc(*Type, s.tparams.len) catch oom();
            d.fillArgs(c, vals, s.tparams, targs);
            out.append(c.a, d.applySig(c, s, d.arrayMapper(c, s.tparams, vals))) catch oom();
        } else out.append(c.a, s) catch oom();
    }
    return out.items;
}

fn classHeritage(cls: *Node) []*Node {
    for (cls.data.class.heritage) |h| {
        if (h.data == .heritage_clause and h.data.heritage_clause.tok == .kw_extends) return h.data.heritage_clause.types;
    }
    return &.{};
}

fn checkNew(c: *Checker, n: *Node) *Type {
    if (firstAnswer(c, n)) |t| return t;
    return keepAnswer(c, n, checkNewResult(c, n), null, c.silent == 0);
}

fn checkNewResult(c: *Checker, n: *Node) *Type {
    const x = n.data.new_expr;
    const callee = checkNonNull(c, checkExpr(c, x.callee), x.callee);
    if (T.isAny(callee)) {
        if (saysNothing(c, callee)) untypedArgs(c, x.args) else looseArgs(c, x.args);
        return callee;
    }
    const sigs = d.ctorSigs(c, callee);
    if (sigs.len == 0) {
        if (isOpen(c, callee) or callee.vars) looseArgs(c, x.args) else untypedArgs(c, x.args);
        if (isOpen(c, callee)) return c.t_err;
        if (d.callSigs(c, callee).len > 0) {
            const calls = d.callSigs(c, callee);
            if (d.returnOf(c, calls[0]).data == .void) {
                if (c.no_implicit_any) err(c, n, 7009, "'new' expression, whose target lacks a construct signature, implicitly has an 'any' type.");
                return c.t_any;
            }
        }
        if (callee.vars and callee.data != .obj) return c.t_err;
        err(c, x.callee, 2351, c.fmt("This expression is not constructable.\n  Type '{s}' has no construct signatures.", .{show(c, callee)}));
        return c.t_err;
    }
    if (sigs[0].abstract) {
        err(c, n, 2511, "Cannot create an instance of an abstract class.");
    }
    checkCtorAccess(c, n, sigs[0]);
    const sig = resolveCall(c, n, sigs, x.args, typeList(x.type_args), false) orelse return c.t_err;
    if (c.silent == 0) c.resolved_calls.put(c.a, n, sig) catch oom();
    return d.returnOf(c, sig);
}

fn checkCtorAccess(c: *Checker, n: *Node, s: *Sig) void {
    const decl = s.decl orelse return;
    if (!decl.mods.private and !decl.mods.protected) return;
    const owner = decl.parent orelse return;
    var cur = enclosingClass(n);
    while (cur) |x| : (cur = enclosingClass(x)) if (x == owner) return;
    const name = if (owner.symbol()) |o| o.name else "?";
    if (decl.mods.private) {
        err(c, n, 2673, c.fmt("Constructor of class '{s}' is private and only accessible within the class declaration.", .{name}));
    } else {
        err(c, n, 2674, c.fmt("Constructor of class '{s}' is protected and only accessible within the class declaration.", .{name}));
    }
}

fn checkTagged(c: *Checker, n: *Node) *Type {
    const x = n.data.tagged_template;
    const t = checkExpr(c, x.tag);
    if (x.template.data == .template_expr) for (x.template.data.template_expr.spans) |sp| {
        _ = checkExpr(c, sp.data.template_span.expr);
    };
    if (T.isAny(t)) return t;
    const sigs = d.callSigs(c, t);
    if (sigs.len == 0) return c.t_err;
    // The string array comes first; only a fixed return type can be trusted without resolving it.
    if (sigs.len == 1 and sigs[0].tparams.len == 0) return d.returnOf(c, sigs[0]);
    return c.t_err;
}

/// A signature that can narrow or end flow: tsc limits these to explicitly annotated callees.
pub fn effectsSig(c: *Checker, n: *Node) ?*Sig {
    const gop = c.effects.getOrPut(c.a, n) catch oom();
    if (gop.found_existing) {
        if (gop.value_ptr.* != &effects_pending) return gop.value_ptr.*;
        _ = c.metCycle();
        return null;
    }
    gop.value_ptr.* = &effects_pending;
    const s = findEffects(c, n);
    c.effects.put(c.a, n, s) catch oom();
    return s;
}

/// Marks a lookup still running, for the reference inside it that asks again.
var effects_pending: Sig = undefined;

fn findEffects(c: *Checker, n: *Node) ?*Sig {
    if (n.data != .call) return null;
    const x = n.data.call;
    const t = explicitType(c, binder.stripParens(x.callee), 0) orelse return null;
    const sigs = d.callSigs(c, t);
    if (sigs.len > 1 or sigs.len == 1 and sigs[0].tparams.len > 0) {
        // Only the overload the call picks counts, instantiated, and finding it is a full call
        // resolution, so do that only when some overload could affect control flow at all.
        for (sigs) |s| {
            if (hasFlowEffect(c, s)) break;
        } else return null;
        const r = resolvedSig(c, n) orelse return null;
        return if (hasFlowEffect(c, r)) r else null;
    }
    if (sigs.len != 1) return null;
    const s = sigs[0];
    if (s.decl) |dn| if (dn.data == .func and dn.data.func.ret == null) return null;
    return s;
}

fn hasFlowEffect(c: *Checker, s: *Sig) bool {
    const dn = s.decl orelse return false;
    if (dn.data != .func or dn.data.func.ret == null) return false;
    return d.predOf(c, s) != null or d.returnOf(c, s).data == .never;
}

fn explicitType(c: *Checker, n: *Node, depth: u32) ?*Type {
    if (depth > 8) return null;
    switch (n.data) {
        .identifier => {
            const s0 = symbolOf(c, n) orelse return null;
            const s = d.targetOf(c, s0) orelse return null;
            if (s.flags & (F.function | F.method | F.class | F.value_module) != 0) return d.typeOfSymbol(c, s);
            const dn = s.value_decl orelse return null;
            switch (dn.data) {
                .var_decl => |v| {
                    if (v.type) |t| return d.typeFromNode(c, t);
                    return null;
                },
                .param => |v| {
                    if (v.type) |t| return d.typeFromNode(c, t);
                    return null;
                },
                else => return null,
            }
        },
        .this_expr => return checkThisAt(c, n),
        .prop_access => |x| {
            const l = explicitType(c, binder.stripParens(x.expr), depth + 1) orelse return null;
            const p = d.getProp(c, l, ast.memberText(x.name)) orelse return null;
            // `export { ok }` in a namespace: the member is the alias, the declaration is behind it.
            const s = if (p.sym) |y| if (y.flags & F.alias != 0) d.targetOf(c, y) orelse return null else y else null;
            const dn = (if (s) |y| y.value_decl else null) orelse p.decl orelse return null;
            switch (dn.data) {
                .func => {},
                .property_decl => |v| if (v.type == null) return null,
                .property_sig => |v| if (v.type == null) return null,
                .var_decl => |v| if (v.type == null) return null,
                else => return null,
            }
            return d.propType(c, p);
        },
        else => return null,
    }
}

pub fn resolvedSig(c: *Checker, n: *Node) ?*Sig {
    if (c.resolved_calls.get(n)) |s| return s;
    if (c.resolving_calls.contains(n)) {
        _ = c.metCycle();
        return null;
    }
    c.resolving_calls.put(c.a, n, {}) catch oom();
    defer _ = c.resolving_calls.remove(n);
    if (n.data == .call) {
        const x = n.data.call;
        if (x.callee.data == .import_kw or x.callee.data == .super_expr) return null;
        c.silent += 1;
        defer c.silent -= 1;
        // Nothing around a statement gives it a context, so the visit its own turn would make is
        // this one, and doing it now saves that turn the resolution.
        if (n.parent != null and n.parent.?.data == .expr_stmt) {
            _ = checkCall(c, n);
            if (c.call_results.get(n)) |a| if (a.sig != null) return a.sig;
        }
        var callee = checkExpr(c, x.callee);
        if (x.optional or flow.isOptionalChain(x.callee)) callee = nonNull(c, callee);
        if (T.isAny(callee)) return null;
        const sigs = calleeSigs(c, callee) orelse return null;
        if (sigs.len == 1 and sigs[0].tparams.len == 0) {
            c.resolved_calls.put(c.a, n, sigs[0]) catch oom();
            return sigs[0];
        }
        const sig = resolveCall(c, n, sigs, x.args, typeList(x.type_args), false) orelse return null;
        c.resolved_calls.put(c.a, n, sig) catch oom();
        return sig;
    }
    if (n.data == .new_expr) {
        const x = n.data.new_expr;
        c.silent += 1;
        defer c.silent -= 1;
        const callee = checkExpr(c, x.callee);
        if (T.isAny(callee)) return null;
        const sigs = d.ctorSigs(c, callee);
        if (sigs.len == 0) return null;
        const sig = resolveCall(c, n, sigs, x.args, typeList(x.type_args), false) orelse return null;
        c.resolved_calls.put(c.a, n, sig) catch oom();
        return sig;
    }
    return null;
}

pub fn isExhaustive(c: *Checker, sw: *Node) bool {
    const x = sw.data.switch_stmt;
    const e = binder.stripParens(x.expr);
    if (e.data == .typeof_expr) return typeofExhausted(c, x.clauses, e.data.typeof_expr.expr);
    const t = checkSilent(c, x.expr);
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    if (members.len == 0 or t.data == .never) return true;
    var values = c.newList(*Type);
    for (x.clauses) |cl| {
        if (cl.data != .case_clause) continue;
        const v = checkSilent(c, cl.data.case_clause.expr);
        values.append(c.a, v.regular orelse v) catch oom();
    }
    for (members) |m| {
        const reg = m.regular orelse m;
        if (!relate.isUnitType(reg)) return false;
        const hit = for (values.items) |v| {
            if (v == reg) break true;
        } else false;
        if (!hit) return false;
    }
    return true;
}

fn typeofExhausted(c: *Checker, clauses: []*Node, operand: *Node) bool {
    const words = [_][]const u8{ "string", "number", "bigint", "boolean", "symbol", "undefined", "object", "function" };
    var seen: [words.len]bool = @splat(false);
    for (clauses) |cl| {
        if (cl.data != .case_clause) continue;
        const v = binder.stripParens(cl.data.case_clause.expr);
        const word = switch (v.data) {
            .string_lit, .no_subst_template => |w| w,
            else => return false,
        };
        for (words, 0..) |w, i| if (std.mem.eql(u8, w, word)) {
            seen[i] = true;
        };
    }
    const t = d.baseConstraint(c, checkSilent(c, operand));
    if (t.data == .unknown or T.isAny(t)) return std.mem.allEqual(bool, &seen, true);
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    for (members) |m| {
        // An empty object has no `typeof` to name, so a case for every one still lets it through.
        const kind = flow.typeofKind(c, m) orelse return false;
        for (words, seen) |w, hit| {
            if (hit and std.mem.eql(u8, w, kind)) break;
        } else return false;
    }
    return true;
}

// ---- dispatcher ----

/// `` obj[`${k}Count`] ``: the key keeps its literal shape so it can find the property.
fn isElementKey(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .paren => isElementKey(p),
        .elem_access => |x| x.index == n,
        else => false,
    };
}

/// The string a constant expression evaluates to. Non-integer numbers stay out because their
/// printed form would have to match JavaScript's exactly.
fn constantText(c: *Checker, n0: *Node, depth: u32) ?[]const u8 {
    if (depth > 16) return null;
    const n = binder.stripParens(n0);
    switch (n.data) {
        .string_lit => |v| return v,
        .no_subst_template => |v| return v,
        .numeric_lit => {
            const v = checkExpr(c, n);
            if (v.data != .num_lit) return null;
            return integerText(c, v.data.num_lit);
        },
        .template_expr => |x| {
            var out = c.newList(u8);
            out.appendSlice(c.a, x.head) catch oom();
            for (x.spans) |sp| {
                const v = constantText(c, sp.data.template_span.expr, depth + 1) orelse return null;
                out.appendSlice(c.a, v) catch oom();
                out.appendSlice(c.a, sp.data.template_span.text) catch oom();
            }
            return out.items;
        },
        .binary => |x| {
            if (x.op != .plus) return null;
            const l = constantText(c, x.left, depth + 1) orelse return null;
            const r = constantText(c, x.right, depth + 1) orelse return null;
            return c.fmt("{s}{s}", .{ l, r });
        },
        .prop_access => return enumText(c, checkSilent(c, n)),
        .identifier => {
            const s0 = symbolOf(c, n) orelse return null;
            const s = d.targetOf(c, s0) orelse return null;
            if (s.flags & F.enum_member != 0) return enumText(c, d.typeOfSymbol(c, s));
            if (!isConstVar(s)) return null;
            const dn = s.value_decl orelse return null;
            if (dn.data != .var_decl or dn.data.var_decl.type != null) return null;
            return constantText(c, dn.data.var_decl.init orelse return null, depth + 1);
        },
        else => return null,
    }
}

fn enumText(c: *Checker, t: *Type) ?[]const u8 {
    const m = t.regular orelse t;
    if (m.data != .enum_lit) return null;
    return switch (m.data.enum_lit.value) {
        .str => |v| v,
        .num => |v| integerText(c, v),
        .none => null,
    };
}

fn integerText(c: *Checker, v: f64) ?[]const u8 {
    if (v != @trunc(v) or @abs(v) >= 1e15) return null;
    return c.fmt("{d}", .{@as(i64, @intFromFloat(v))});
}

fn checkTemplate(c: *Checker, n: *Node) *Type {
    const x = n.data.template_expr;
    var texts = c.newList([]const u8);
    var types = c.newList(*Type);
    texts.append(c.a, x.head) catch oom();
    for (x.spans) |sp| {
        const v = checkExpr(c, sp.data.template_span.expr);
        if (v.data == .symbol or v.data == .unique) err(c, sp.data.template_span.expr, 2731, "Implicit conversion of a 'symbol' to a 'string' will fail at runtime. Consider wrapping this expression in 'String(...)'.");
        types.append(c.a, v) catch oom();
        texts.append(c.a, sp.data.template_span.text) catch oom();
    }
    const tagged = n.parent != null and n.parent.?.data == .tagged_template;
    if (!tagged) if (constantText(c, n, 0)) |text| return c.freshOf(c.strLit(text));
    if (isConstContext(c, n) or isElementKey(n)) return d.getTemplate(c, texts.items, types.items);
    if (contextualType(c, n)) |ctx| {
        const t = c.strLit("");
        if (literalCtx(c, t, ctx) or primConstraint(c, t, ctx)) return d.getTemplate(c, texts.items, types.items);
    }
    return c.t_string;
}

fn checkAsExpr(c: *Checker, n: *Node, e: *Node, tn: *Node) *Type {
    if (isConstRef(tn)) return regularize(c, checkExpr(c, e));
    const s = checkExpr(c, e);
    const t = d.typeFromNode(c, tn);
    if (T.isAny(s) or T.isAny(t)) return t;
    const sr = regularize(c, widenFresh(c, s));
    if (!relate.isComparable(c, t, sr) and !relate.isComparable(c, sr, t) and !relate.isComparable(c, sr, widenAll(c, t))) {
        err(c, n, 2352, c.fmt("Conversion of type '{s}' to type '{s}' may be a mistake because neither type sufficiently overlaps with the other. If this was intentional, convert the expression to 'unknown' first.", .{ show(c, sr), show(c, t) }));
    }
    return t;
}

fn widenAll(c: *Checker, t: *Type) *Type {
    return baseOfLiteral(c, t);
}

fn checkYield(c: *Checker, n: *Node) *Type {
    const x = n.data.yield_expr;
    const t = if (x.expr) |e| checkExpr(c, e) else c.t_undefined;
    const fnode = containingFunc(n) orelse return c.t_err;
    if (fnode.data != .func or !fnode.data.func.asterisk) return c.t_err;
    const is_async = fnode.mods.async;
    const e = x.expr orelse n;
    // Without an annotation the signature is built from the yields, so they fit by definition.
    if (fnode.data.func.ret != null) if (generatorContext(c, fnode, .yield)) |want| {
        const got = if (x.star) iteratedOf(c, e, t, is_async) else t;
        checkAssignable(c, if (is_async) awaitedOf(c, got) else got, want, x.expr, e);
    };
    if (x.star) return iteratorArg(c, t, .ret, is_async) orelse c.t_err;
    return generatorContext(c, fnode, .next) orelse c.t_err;
}

fn checkJsx(c: *Checker, n: *Node) void {
    switch (n.data) {
        .jsx_expr => |x| if (x.expr) |e| {
            _ = checkExpr(c, e);
            return;
        },
        .jsx_spread_attr => |x| {
            _ = checkExpr(c, x.expr);
            return;
        },
        .identifier, .prop_access, .this_expr => return,
        .jsx_opening => |x| {
            checkIntrinsicTag(c, n, x.tag);
            if (checkJsxAttributes(c, n, x.tag, x.attrs)) return;
        },
        .jsx_self_closing => |x| {
            checkIntrinsicTag(c, n, x.tag);
            if (checkJsxAttributes(c, n, x.tag, x.attrs)) return;
        },
        .jsx_closing => |x| checkIntrinsicTag(c, n, x.tag),
        else => {},
    }
    ast.forEachChild(n, c, checkJsx);
}

/// tsc's `getIntrinsicTagSymbol`: a lower-case tag is looked up in `JSX.IntrinsicElements`, and
/// without that interface the element is `any`.
fn checkIntrinsicTag(c: *Checker, n: *Node, tag: *Node) void {
    if (!c.no_implicit_any or tag.data != .identifier) return;
    const name = tag.data.identifier;
    if (name.len == 0 or !(std.ascii.isLower(name[0]) or std.mem.indexOfAny(u8, name, "-:") != null)) return;
    const ns = jsxNamespace(c, n) orelse return;
    if (ns) |x| if (x.exports) |e| if (e.get("IntrinsicElements")) |ie| if (ie.resolve().flags & F.type != 0) return;
    err(c, n, 7026, "JSX element implicitly has type 'any' because no interface 'JSX.IntrinsicElements' exists.");
}

fn isIntrinsicTag(tag: *Node) bool {
    if (tag.data != .identifier) return false;
    const name = tag.data.identifier;
    return name.len > 0 and (std.ascii.isLower(name[0]) or std.mem.indexOfAny(u8, name, "-:") != null);
}

/// tsc's `getIntrinsicAttributesTypeFromJsxOpeningLikeElement`: `JSX.IntrinsicElements[tag]`, or
/// its string index. Null when there is nothing to check against.
fn intrinsicProps(c: *Checker, el: *Node, tag: *Node, report: bool) ?*Type {
    if (!isIntrinsicTag(tag)) return null;
    const ns = (jsxNamespace(c, el) orelse return null) orelse return null;
    const ie = (ns.exports orelse return null).get("IntrinsicElements") orelse return null;
    if (ie.resolve().flags & F.type == 0) return null;
    const t = d.declaredType(c, ie.resolve());
    if (T.isAny(t)) return null;
    const name = tag.data.identifier;
    if (d.getProp(c, t, name)) |p| return d.propType(c, p);
    if (d.indexValue(c, t, c.t_string)) |v| return v;
    if (report) err(c, el, 2339, c.fmt("Property '{s}' does not exist on type 'JSX.IntrinsicElements'.", .{name}));
    return null;
}

fn jsxTag(el: *Node) ?*Node {
    return switch (el.data) {
        .jsx_opening => |x| x.tag,
        .jsx_self_closing => |x| x.tag,
        else => null,
    };
}

/// tsc's `getContextualTypeForJsxAttribute`: the attribute's property in what the element takes.
fn jsxAttrContext(c: *Checker, attr: *Node) ?*Type {
    const el = attr.parent orelse return null;
    const targets = jsxTargets(c, el, jsxTag(el) orelse return null, false) orelse return null;
    if (targets.len != 1) return null;
    const name = attr.data.jsx_attr.name;
    if (name.data != .identifier) return null;
    const attrs = switch (el.data) {
        .jsx_opening => |x| x.attrs,
        .jsx_self_closing => |x| x.attrs,
        else => return null,
    };
    return targetProp(c, discriminateJsx(c, attrs, targets[0]), name.data.identifier);
}

/// tsc's `discriminateContextualTypeByJSXAttributes`, as `discriminate` does for object literals.
fn discriminateJsx(c: *Checker, attrs: []*Node, t: *Type) *Type {
    if (t.data != .union_) return t;
    const types = t.data.union_;
    const keep = c.a.alloc(Keep, types.len) catch oom();
    for (types, keep) |m, *k| k.* = if (m.data == .obj or m.data == .inter or m.data == .param or m.data == .access) .yes else .no;
    for (attrs) |a| {
        if (a.data != .jsx_attr) continue;
        const x = a.data.jsx_attr;
        if (x.name.data != .identifier or !relate.isDiscriminant(c, types, x.name.data.identifier)) continue;
        const value = if (x.value) |v| blk: {
            const e = if (v.data == .jsx_expr) v.data.jsx_expr.expr orelse continue else v;
            if (!possiblyDiscriminant(e)) continue;
            break :blk contextFree(c, e);
        } else c.t_true;
        keepMatching(c, types, keep, x.name.data.identifier, value);
    }
    // An attribute left out reads as `undefined`, and that discriminates too.
    outer: for (d.propsOf(c, types[0])) |x| {
        for (attrs) |a| if (a.data == .jsx_attr and a.data.jsx_attr.name.data == .identifier and std.mem.eql(u8, a.data.jsx_attr.name.data.identifier, x.name)) continue :outer;
        if (partlyOptional(c, types, x.name) and relate.isDiscriminant(c, types, x.name)) keepMatching(c, types, keep, x.name, c.t_undefined);
    }
    if (std.mem.indexOfScalar(Keep, keep, .no) == null) return t;
    var rest = c.newList(*Type);
    for (types, keep) |m, k| if (k == .yes) rest.append(c.a, m) catch oom();
    return if (rest.items.len == 0) t else c.getUnion(rest.items);
}

/// tsc's `getContextualTypeForChildJsxExpression`: the children property, or its element at the
/// child's place when there are several.
fn jsxChildContext(c: *Checker, child: *Node, elem: *Node) ?*Type {
    const open = elem.data.jsx_element.open;
    const name = jsxChildrenName(c, open) orelse return null;
    const targets = jsxTargets(c, open, jsxTag(open) orelse return null, false) orelse return null;
    if (targets.len != 1) return null;
    const ct = targetProp(c, discriminateJsx(c, open.data.jsx_opening.attrs, targets[0]), name) orelse return null;
    var count: usize = 0;
    var index: usize = 0;
    for (elem.data.jsx_element.children) |k| {
        if (!isSemanticChild(k)) continue;
        if (k == child) index = count;
        count += 1;
    }
    if (count == 1) return ct;
    return elemOfCtx(c, child, ct, index);
}

/// tsc's `getSemanticJsxChildren`: whitespace-only text and empty `{}` are not children.
fn isSemanticChild(k: *Node) bool {
    return switch (k.data) {
        .jsx_text => |text| std.mem.indexOfNone(u8, text, " \t\r\n") != null,
        .jsx_expr => |x| x.expr != null,
        else => true,
    };
}

fn jsxExport(ns: ?*Symbol, name: []const u8) ?*Symbol {
    const s = ((ns orelse return null).exports orelse return null).get(name) orelse return null;
    const r = s.resolve();
    return if (r.flags & F.type != 0) r else null;
}

/// tsc's `getNameFromJsxElementAttributesContainer`: the one member of a `JSX` interface such as
/// `ElementAttributesProperty`. Null without the interface, empty when it has no members.
fn jsxContainerName(c: *Checker, ns: ?*Symbol, container: []const u8) ?[]const u8 {
    const s = jsxExport(ns, container) orelse return null;
    const props = d.propsOf(c, d.declaredType(c, s));
    if (props.len == 0) return "";
    return if (props.len == 1) props[0].name else null;
}

fn jsxChildrenName(c: *Checker, el: *Node) ?[]const u8 {
    const ns = jsxNamespace(c, el) orelse return null;
    const name = jsxContainerName(c, ns, "ElementChildrenAttribute") orelse return null;
    return if (name.len > 0) name else null;
}

/// What the element's attributes are checked against: one type per signature the tag can be
/// called with (tsc's `getEffectiveFirstArgumentForJsxSignature`). Null when that cannot be told
/// here, which leaves the attributes unchecked.
fn jsxTargets(c: *Checker, el: *Node, tag: *Node, report: bool) ?[]*Type {
    if (isIntrinsicTag(tag)) {
        const t = intrinsicProps(c, el, tag, report) orelse return null;
        return c.a.dupe(*Type, &.{t}) catch oom();
    }
    const ns = jsxNamespace(c, el) orelse return null;
    const tt = checkExpr(c, tag);
    // A class's static side mentions its `this` type, so `vars` alone does not mean generic; the
    // props are checked for type variables below.
    if (T.isAny(tt) or tt.data == .param) return null;
    const ap = d.getApparent(c, tt);
    const ctors = d.ctorSigs(c, ap);
    const is_class = ctors.len > 0;
    const sigs = if (is_class) ctors else d.callSigs(c, ap);
    if (sigs.len == 0) return null;
    const out = c.a.alloc(*Type, sigs.len) catch oom();
    for (sigs, out) |sig, *o| {
        if (sig.tparams.len > 0) return null;
        var props = if (is_class) jsxClassProps(c, ns, sig) orelse return null else relate.typeAt(c, sig, 0) orelse c.t_unknown;
        if (jsxExport(ns, "LibraryManagedAttributes")) |lma| props = d.instantiateWithDefaults(c, lma, &.{ tt, props }) orelse props;
        if (T.isAny(props) or props.vars) return null;
        if (is_class) if (jsxExport(ns, "IntrinsicClassAttributes")) |ica| {
            const host = d.instantiateWithDefaults(c, ica, &.{d.returnOf(c, sig)}) orelse return null;
            props = c.getIntersection(&.{ host, props });
        };
        if (jsxExport(ns, "IntrinsicAttributes")) |ia| props = c.getIntersection(&.{ d.declaredType(c, ia), props });
        o.* = props;
    }
    return out;
}

/// tsc's `getJsxPropsTypeFromClassType`: where `JSX.ElementAttributesProperty` says the props are.
fn jsxClassProps(c: *Checker, ns: ?*Symbol, sig: *Sig) ?*Type {
    const name = jsxContainerName(c, ns, "ElementAttributesProperty") orelse return relate.typeAt(c, sig, 0) orelse c.t_unknown;
    const instance = d.returnOf(c, sig);
    if (name.len == 0 or T.isAny(instance)) return instance;
    const p = d.getProp(c, instance, name) orelse return null;
    return d.propType(c, p);
}

/// tsc's `createJsxAttributesTypeFromAttributesProperty` and the check `resolveJsxOpeningLikeElement`
/// makes of it. False when the attributes are left to the generic walk.
fn checkJsxAttributes(c: *Checker, el: *Node, tag: *Node, attrs: []*Node) bool {
    const targets = jsxTargets(c, el, tag, true) orelse return false;
    var m = c.membersFor(attrs.len);
    var open = false;
    var vars = false;
    var written = false;
    var unknown = false;
    for (attrs) |a| switch (a.data) {
        .jsx_attr => |x| {
            const v = if (x.value) |val| blk: {
                const e = if (val.data == .jsx_expr) val.data.jsx_expr.expr orelse break :blk c.t_err else val;
                break :blk mutableLocation(c, e, checkExpr(c, e));
            } else c.t_true;
            if (x.name.data != .identifier) {
                unknown = true;
                continue;
            }
            if (v.vars) vars = true;
            written = true;
            const name = x.name.data.identifier;
            m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = v, .decl = a })) catch oom();
        },
        .jsx_spread_attr => |x| {
            const s = checkExpr(c, x.expr);
            if (s.data != .obj or s.vars) {
                unknown = true;
                continue;
            }
            m = spreadInto(c, m, s, false, false, &open);
        },
        else => {},
    };
    if (jsxChildrenName(c, el)) |name| if (el.parent) |p| if (p.data == .jsx_element and p.data.jsx_element.open == el) {
        var kids = c.newList(*Type);
        for (p.data.jsx_element.children) |k| {
            if (!isSemanticChild(k)) continue;
            kids.append(c.a, switch (k.data) {
                .jsx_text => c.t_string,
                .jsx_expr => |x| checkSilent(c, x.expr.?),
                else => c.t_err,
            }) catch oom();
        }
        if (kids.items.len > 0) {
            const v = if (kids.items.len == 1) kids.items[0] else d.arrayOf(c, c.getUnion(kids.items));
            m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = v })) catch oom();
        }
    };
    if (unknown) return true;
    // Attributes are fresh, spreads and all, once one of them is written out.
    const s = c.newObj(.{ .kind = .anon, .members = m, .lit = written, .literal = el, .open = open });
    s.vars = vars;
    for (targets) |t| if (relate.isAssignable(c, s, t)) return true;
    if (quiet(c)) return true;
    const last = targets[targets.len - 1];
    if (targets.len > 1) {
        err(c, jsxBlame(c, s, last, attrs, tag), 2769, "No overload matches this call.");
        return true;
    }
    // tsc's `elaborateJsxComponents`: an attribute that does not fit takes the blame.
    var blamed = false;
    for (attrs) |a| {
        const x = mismatchedAttr(c, s, last, a) orelse continue;
        blamed = true;
        if (x.value) |val| if (val.data == .jsx_expr) if (val.data.jsx_expr.expr) |e| if (elaborate(c, e, x.st, x.tt)) continue;
        reportNotAssignable(c, x.st, x.tt, x.name, null);
    }
    if (blameJsxChildren(c, el, s, last)) blamed = true;
    if (!blamed) reportNotAssignable(c, s, last, tag, null);
    return true;
}

/// The children half of tsc's `elaborateJsxComponents`: a child expression that does not fit the
/// children property, or its element when there are several, takes the blame.
fn blameJsxChildren(c: *Checker, el: *Node, s: *Type, t: *Type) bool {
    const p = el.parent orelse return false;
    if (p.data != .jsx_element or p.data.jsx_element.open != el) return false;
    const name = jsxChildrenName(c, el) orelse return false;
    const sp = d.getProp(c, s, name) orelse return false;
    const tt = targetProp(c, t, name) orelse return false;
    if (relate.isAssignable(c, d.propType(c, sp), tt)) return false;
    var kids = c.newList(*Node);
    for (p.data.jsx_element.children) |k| if (isSemanticChild(k)) kids.append(c.a, k) catch oom();
    var blamed = false;
    for (kids.items, 0..) |k, i| {
        if (k.data != .jsx_expr) continue;
        const e = k.data.jsx_expr.expr.?;
        const want = if (kids.items.len == 1) tt else elemOfCtx(c, k, tt, i) orelse continue;
        const got = checkSilent(c, e);
        if (relate.isAssignable(c, got, want)) continue;
        blamed = true;
        if (!elaborate(c, e, got, want)) reportNotAssignable(c, got, want, e, null);
    }
    return blamed;
}

const AttrMismatch = struct { name: *Node, value: ?*Node, st: *Type, tt: *Type };

fn mismatchedAttr(c: *Checker, s: *Type, t: *Type, a: *Node) ?AttrMismatch {
    if (a.data != .jsx_attr) return null;
    const x = a.data.jsx_attr;
    if (x.name.data != .identifier or std.mem.indexOfScalar(u8, x.name.data.identifier, '-') != null) return null;
    const sp = d.getProp(c, s, x.name.data.identifier) orelse return null;
    const tt = targetProp(c, t, x.name.data.identifier) orelse return null;
    const st = d.propType(c, sp);
    if (relate.isAssignable(c, st, tt)) return null;
    return .{ .name = x.name, .value = x.value, .st = st, .tt = tt };
}

/// Where the check against `t` would report, which is where tsc puts a failed overload set.
fn jsxBlame(c: *Checker, s: *Type, t: *Type, attrs: []*Node, tag: *Node) *Node {
    for (attrs) |a| if (mismatchedAttr(c, s, t, a)) |x| return x.name;
    if (relate.excessProp(c, s, t)) |p| if (p.decl) |x| return propNameNode(x);
    return tag;
}

/// tsc's `getJsxNamespaceAt`: `JSX` under the factory's namespace, else the global one. Null when
/// it cannot be told here (automatic runtimes, `@jsx` pragmas); an inner null when there is none.
fn jsxNamespace(c: *Checker, at: *Node) ??*Symbol {
    const o = c.prog.cfg.options;
    switch (o.jsxMode()) {
        .react_jsx, .react_jsxdev => return null,
        else => {},
    }
    const f = d.fileOf(c, at) orelse return null;
    if (std.mem.indexOf(u8, f.src, "@jsx") != null) return null;
    const entity = o.jsxFactory orelse o.reactNamespace orelse "React";
    const root = entity[0 .. std.mem.indexOfScalar(u8, entity, '.') orelse entity.len];
    if (d.resolveName(c, at, root, F.namespace | F.alias)) |s| {
        const target = c.prog.resolveAlias(s, 0) orelse return null;
        if (target.resolve().exports) |e| if (e.get("JSX")) |exported| {
            const jsx = (c.prog.resolveAlias(exported, 0) orelse return null).resolve();
            if (jsx.flags & F.namespace != 0) return jsx;
        };
    }
    const global = d.globalSym(c, "JSX") orelse return @as(?*Symbol, null);
    return global.resolve();
}

pub fn checkExpr(c: *Checker, n: *Node) *Type {
    const saved = c.current_node;
    const saved_is_type = c.current_is_type;
    const saved_signature = c.context_for_signature;
    c.current_node = n;
    c.current_is_type = false;
    c.context_for_signature = false;
    defer {
        c.current_node = saved;
        c.current_is_type = saved_is_type;
        c.context_for_signature = saved_signature;
    }
    return switch (n.data) {
        .identifier, .prop_access => checkRef(c, n),
        .string_lit, .no_subst_template => |v| c.freshOf(c.strLit(v)),
        .numeric_lit => |v| c.freshOf(c.numLit((emit.parseNumber(v) orelse 0))),
        .bigint_lit => |v| c.freshOf(c.bigLit(v)),
        .regex_lit => d.globalType(c, "RegExp") orelse c.t_err,
        .true_lit => c.freshOf(c.t_true),
        .false_lit => c.freshOf(c.t_false),
        .null_lit => c.t_null,
        .this_expr => blk: {
            checkThisPlace(c, n);
            checkBeforeSuper(c, n, 17009, "'super' must be called before accessing 'this' in the constructor of a derived class.");
            const t = checkThisAt(c, n);
            if (n.flow() == null or T.isAny(t)) break :blk t;
            break :blk flow.flowType(c, n, t, t, containingFunc(n));
        },
        .super_expr => superType(c, n),
        .paren => |x| checkExpr(c, x.expr),
        .template_expr => checkTemplate(c, n),
        .tagged_template => checkTagged(c, n),
        .array_lit => checkArrayLit(c, n),
        .object_lit => checkObjectLit(c, n),
        .elem_access => checkElemAccess(c, n),
        .call => checkCall(c, n),
        .new_expr => checkNew(c, n),
        .prefix => checkPrefix(c, n),
        .postfix => |x| blk: {
            const t = checkExpr(c, x.expr);
            _ = isReadonlyTarget(c, x.expr);
            incOperand(c, t, x.expr);
            break :blk if (isBigLike(c, t)) c.t_bigint else c.t_number;
        },
        .typeof_expr => |x| blk: {
            _ = checkExpr(c, x.expr);
            break :blk c.t_typeof;
        },
        .void_expr => |x| blk: {
            _ = checkExpr(c, x.expr);
            break :blk c.t_undefined;
        },
        .delete_expr => |x| blk: {
            _ = checkExpr(c, x.expr);
            if (!quiet(c)) checkDeleteOperand(c, binder.stripParens(x.expr));
            break :blk c.t_boolean;
        },
        .await_expr => |x| awaitedOf(c, checkExpr(c, x.expr)),
        .yield_expr => checkYield(c, n),
        .binary => checkBinary(c, n),
        .conditional => |x| blk: {
            checkTruthiness(c, checkExpr(c, x.cond), x.cond);
            const a = checkExpr(c, x.then);
            const b = checkExpr(c, x.els);
            break :blk reduceSubtypes(c, &.{ a, b });
        },
        .expr_with_type_args => |x| instantiationExpr(c, checkExpr(c, x.expr), x.type_args.items),
        .as_expr => |x| checkAsExpr(c, n, x.expr, x.type),
        .type_assertion => |x| checkAsExpr(c, n, x.expr, x.type),
        .satisfies_expr => |x| blk: {
            const s = checkExpr(c, x.expr);
            const t = d.typeFromNode(c, x.type);
            if (!T.isAny(t) and !relate.isAssignable(c, s, t) and !quiet(c)) {
                if (!elaborate(c, x.expr, s, t)) {
                    if (relate.excessProp(c, s, t)) |p| {
                        err(c, if (p.decl) |y| propNameNode(y) else x.expr, 2353, c.fmt("Object literal may only specify known properties, and '{s}' does not exist in type '{s}'.", .{ p.name, show(c, t) }));
                    } else err(c, x.expr, 1360, c.fmt("Type '{s}' does not satisfy the expected type '{s}'.", .{ show(c, s), show(c, t) }));
                }
            }
            break :blk s;
        },
        .non_null => |x| nonNull(c, checkExpr(c, x.expr)),
        .func => checkFunctionExpr(c, n),
        .class => blk: {
            if (!quiet(c)) c.deferred.append(c.a, n) catch oom();
            break :blk if (n.symbol()) |s| d.typeOfSymbol(c, s) else c.t_err;
        },
        .spread_elem => |x| iteratedOf(c, x.expr, checkExpr(c, x.expr), false),
        .meta_property => c.t_err,
        .jsx_element, .jsx_self_closing, .jsx_fragment => blk: {
            checkJsx(c, n);
            break :blk c.t_err;
        },
        .omitted_expr => c.t_undefined,
        else => c.t_err,
    };
}
