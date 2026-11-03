//! tsc's `checkExternalEmitHelpers`: under `importHelpers`, syntax that compiles to a call into
//! `tslib` needs the helper it calls exported from the module `tslib` resolves to.
const std = @import("std");
const ast = @import("ast.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const expr = @import("expr.zig");
const checker = @import("checker.zig");
const project = @import("project.zig");
const Node = ast.Node;
const Checker = T.Checker;
const Symbol = @import("binder.zig").Symbol;
const oom = T.oom;

/// In tsgo's `ExternalEmitHelpers` order, which is the order missing ones are reported in.
const Helper = enum(u5) {
    rest,
    decorate,
    metadata,
    param,
    awaiter,
    @"await",
    async_generator,
    async_delegator,
    async_values,
    export_star,
    import_star,
    import_default,
    make_template_object,
    private_get,
    private_set,
    private_in,
    set_function_name,
    prop_key,
    disposable,
    rewrite_extension,

    fn bit(h: Helper) u32 {
        return @as(u32, 1) << @intFromEnum(h);
    }
};

fn set(hs: []const Helper) u32 {
    var m: u32 = 0;
    for (hs) |h| m |= h.bit();
    return m;
}

fn names(c: *Checker, h: Helper) []const []const u8 {
    return switch (h) {
        .rest => &.{"__rest"},
        .decorate => if (legacyDecorators(c)) &.{"__decorate"} else &.{ "__esDecorate", "__runInitializers" },
        .metadata => &.{"__metadata"},
        .param => &.{"__param"},
        .awaiter => &.{"__awaiter"},
        .@"await" => &.{"__await"},
        .async_generator => &.{"__asyncGenerator"},
        .async_delegator => &.{"__asyncDelegator"},
        .async_values => &.{"__asyncValues"},
        .export_star => &.{"__exportStar"},
        .import_star => &.{"__importStar"},
        .import_default => &.{"__importDefault"},
        .make_template_object => &.{"__makeTemplateObject"},
        .private_get => &.{"__classPrivateFieldGet"},
        .private_set => &.{"__classPrivateFieldSet"},
        .private_in => &.{"__classPrivateFieldIn"},
        .set_function_name => &.{"__setFunctionName"},
        .prop_key => &.{"__propKey"},
        .disposable => &.{ "__addDisposableResource", "__disposeResources" },
        .rewrite_extension => &.{"__rewriteRelativeImportExtension"},
    };
}

fn legacyDecorators(c: *Checker) bool {
    return c.prog.cfg.options.experimentalDecorators orelse false;
}

fn below(c: *Checker, year: u32) bool {
    return d.targetYear(c.prog.cfg.options.target orelse "esnext") < year;
}

/// ESNext, where `using` and standard decorators need no rewriting.
const esnext = std.math.maxInt(u32);

/// tsc's `GetEmitModuleFormatOfFile` is CommonJS.
fn emitsCommonJs(c: *Checker, f: *ast.File) bool {
    return switch (c.prog.cfg.options.moduleFormat()) {
        .cjs => true,
        .node => f.implied_cjs,
        else => std.mem.endsWith(u8, f.path, ".cts") or std.mem.endsWith(u8, f.path, ".cjs"),
    };
}

pub fn check(c: *Checker, n: *Node) void {
    if (!(c.prog.cfg.options.importHelpers orelse false)) return;
    const f = d.fileOf(c, n) orelse return;
    if (!f.is_module or f.is_dts) return;
    switch (n.data) {
        .func => |x| {
            if (x.body == null) return;
            if (x.asterisk and n.mods.async) {
                if (below(c, 2018)) request(c, f, x.name orelse n, set(&.{ .@"await", .async_generator }));
            } else if (n.mods.async and below(c, 2017)) {
                request(c, f, x.name orelse n, Helper.awaiter.bit());
            }
        },
        .for_of => |x| if (x.is_await and below(c, 2018)) {
            const owner = container(n) orelse return;
            if (owner.data == .func and owner.mods.async) request(c, f, n, Helper.async_values.bit());
        },
        .yield_expr => |x| if (x.star and below(c, 2018)) {
            const owner = generator(n) orelse return;
            if (owner.mods.async) request(c, f, n, set(&.{ .@"await", .async_delegator, .async_values }));
        },
        .var_list => |x| if ((x.kind == .using or x.kind == .await_using) and below(c, esnext)) request(c, f, n, Helper.disposable.bit()),
        .binding_elem => |x| if (x.dotdotdot and n.parent.?.data == .object_pattern and below(c, 2018)) request(c, f, x.name, Helper.rest.bit()),
        .spread_assign => if (below(c, 2018) and n.parent.?.data == .object_lit and expr.isPatternTarget(n.parent.?)) request(c, f, n, Helper.rest.bit()),
        .prop_access => |x| if (x.name.data == .private_name and privateNamesRewritten(c)) {
            const kind = assignment(n);
            if (kind != .none) request(c, f, n, Helper.private_set.bit());
            if (kind != .definite) request(c, f, n, Helper.private_get.bit());
        },
        .binary => |x| if (x.op == .kw_in and x.left.data == .private_name and privateNamesRewritten(c)) request(c, f, x.left, Helper.private_in.bit()),
        .import_decl => |x| {
            const clause = x.clause orelse return;
            const cl = clause.data.import_clause;
            if (cl.type_only or !emitsCommonJs(c, f)) return;
            const star = if (cl.bindings) |b| b.data == .namespace_import else false;
            if (star) request(c, f, n, Helper.import_star.bit());
            if (cl.name != null and !star) request(c, f, n, Helper.import_default.bit());
        },
        .import_spec => |x| if (!x.type_only and isDefault(x.prop_name orelse x.name) and emitsCommonJs(c, f)) request(c, f, n, Helper.import_default.bit()),
        .export_decl => |x| if (x.specifier != null and !x.type_only and emitsCommonJs(c, f)) {
            if (x.clause) |cl| {
                if (cl.data == .namespace_export) request(c, f, n, Helper.import_star.bit());
            } else request(c, f, n, Helper.export_star.bit());
        },
        .export_spec => |x| {
            const decl = n.parent.?.parent.?;
            if (decl.data != .export_decl or decl.data.export_decl.specifier == null or x.type_only) return;
            if (isDefault(x.prop_name orelse x.name) and emitsCommonJs(c, f)) request(c, f, n, Helper.import_default.bit());
        },
        .decorator => decorated(c, f, n),
        else => {},
    }
}

fn privateNamesRewritten(c: *Checker) bool {
    return below(c, esnext) or !expr.useDefineForClassFields(c);
}

fn isDefault(n: *Node) bool {
    return switch (n.data) {
        .identifier => |s| std.mem.eql(u8, s, "default"),
        .string_lit => |s| std.mem.eql(u8, s, "default"),
        else => false,
    };
}

/// tsc's `getContainingFunctionOrClassStaticBlock`.
fn container(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) switch (x.data) {
        .func, .static_block => return x,
        else => {},
    };
    return null;
}

fn generator(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) if (x.data == .func and x.data.func.kind != .arrow) return if (x.data.func.asterisk) x else null;
    return null;
}

/// tsc's `getAssignmentTargetKind`: `x = 1` writes only, `x += 1` and `x++` read too.
fn assignment(n: *Node) enum { none, definite, compound } {
    const p = n.parent orelse return .none;
    return switch (p.data) {
        .binary => |x| if (x.left != n or !expr.isAssignOp(x.op)) .none else if (x.op == .assign) .definite else .compound,
        .prefix => |x| if (x.op == .plus2 or x.op == .minus2) .compound else .none,
        .postfix => .compound,
        else => if (expr.isPatternTarget(n)) .definite else .none,
    };
}

/// tsc's `checkDecorators`, for the first decorator of a declaration that can have one.
fn decorated(c: *Checker, f: *ast.File, n: *Node) void {
    const owner = n.parent orelse return;
    const first = switch (owner.data) {
        .class => |x| x.decorators,
        .func => |x| x.decorators,
        .property_decl => |x| x.decorators,
        .param => |x| x.decorators,
        else => return,
    };
    if (first.len == 0 or first[0] != n) return;
    if (!canBeDecorated(owner)) return;
    if (legacyDecorators(c)) {
        request(c, f, n, Helper.decorate.bit());
        if (owner.data == .param) request(c, f, n, Helper.param.bit());
    } else if (below(c, esnext)) {
        request(c, f, n, Helper.decorate.bit());
        switch (owner.data) {
            .class => |x| if (x.name == null) request(c, f, n, Helper.set_function_name.bit()),
            .func, .property_decl => {
                const name = memberName(owner) orelse return;
                const callable = owner.data == .func or owner.mods.accessor;
                if (name.data == .private_name and callable) request(c, f, n, Helper.set_function_name.bit());
                if (name.data == .computed_name) request(c, f, n, Helper.prop_key.bit());
            },
            else => {},
        }
    }
    if (c.prog.cfg.options.emitDecoratorMetadata orelse false) request(c, f, n, Helper.metadata.bit());
}

fn memberName(n: *Node) ?*Node {
    return switch (n.data) {
        .func => |x| x.name,
        .property_decl => |x| x.name,
        else => null,
    };
}

/// tsc's `nodeCanBeDecorated`: a class, its members, and parameters of its methods.
fn canBeDecorated(n: *Node) bool {
    const p = n.parent orelse return false;
    return switch (n.data) {
        .class => true,
        .func, .property_decl => p.data == .class,
        .param => p.data == .func and p.parent != null and p.parent.?.data == .class and p.data.func.body != null,
        else => false,
    };
}

fn request(c: *Checker, f: *ast.File, at: *Node, helpers: u32) void {
    if (checker.isAmbient(c, at)) return;
    const m = helpersModule(c, f, at) orelse return;
    const gop = c.helpers_requested.getOrPut(c.a, f) catch oom();
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const unchecked = helpers & ~gop.value_ptr.*;
    gop.value_ptr.* |= helpers;
    if (unchecked == 0) return;
    for (std.enums.values(Helper)) |h| {
        if (unchecked & h.bit() == 0) continue;
        for (names(c, h)) |name| {
            const s = c.prog.exportOf(m, name) orelse {
                expr.err(c, at, 2343, c.fmt("This syntax requires an imported helper named '{s}' which does not exist in '{s}'. Consider upgrading your version of '{s}'.", .{ name, project.helpers_module, project.helpers_module }));
                continue;
            };
            const arity: usize = switch (h) {
                .private_get => 4,
                .private_set => 5,
                else => continue,
            };
            if (!hasArity(c, s, arity)) expr.err(c, at, 2807, c.fmt("This syntax requires an imported helper named '{s}' with {d} parameters, which is not compatible with the one in '{s}'. Consider upgrading your version of '{s}'.", .{ name, arity, project.helpers_module, project.helpers_module }));
        }
    }
}

fn hasArity(c: *Checker, s: *Symbol, arity: usize) bool {
    for (d.membersOf(c, d.typeOfSymbol(c, s.resolve())).calls) |sig| if (sig.params.len >= arity) return true;
    return false;
}

/// tsc's `resolveHelpersModule`: one lookup per file, and one report when it fails.
fn helpersModule(c: *Checker, f: *ast.File, at: *Node) ?*Symbol {
    const gop = c.helpers_module.getOrPut(c.a, f) catch oom();
    if (gop.found_existing) return gop.value_ptr.*;
    const sf = c.prog.sourceOf(f);
    gop.value_ptr.* = if (sf) |x| c.prog.resolveModuleName(x, project.helpers_module) else null;
    if (gop.value_ptr.* == null) expr.err(c, at, 2354, c.fmt("This syntax requires an imported helper but module '{s}' cannot be found.", .{project.helpers_module}));
    return gop.value_ptr.*;
}
