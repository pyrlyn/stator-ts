const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const decls = @import("decls.zig");
const emit = @import("emit.zig");
const parser = @import("parser.zig");
const Node = ast.Node;

fn oom() noreturn {
    @panic("out of memory");
}

pub const F = struct {
    pub const none: u32 = 0;
    pub const func_var: u32 = 1 << 0;
    pub const block_var: u32 = 1 << 1;
    pub const property: u32 = 1 << 2;
    pub const enum_member: u32 = 1 << 3;
    pub const function: u32 = 1 << 4;
    pub const class: u32 = 1 << 5;
    pub const interface: u32 = 1 << 6;
    pub const const_enum: u32 = 1 << 7;
    pub const regular_enum: u32 = 1 << 8;
    pub const value_module: u32 = 1 << 9;
    pub const namespace_module: u32 = 1 << 10;
    pub const type_literal: u32 = 1 << 11;
    pub const object_literal: u32 = 1 << 12;
    pub const method: u32 = 1 << 13;
    pub const constructor: u32 = 1 << 14;
    pub const getter: u32 = 1 << 15;
    pub const setter: u32 = 1 << 16;
    pub const signature: u32 = 1 << 17;
    pub const type_param: u32 = 1 << 18;
    pub const type_alias: u32 = 1 << 19;
    pub const alias: u32 = 1 << 20;
    pub const optional: u32 = 1 << 21;
    pub const param: u32 = 1 << 23;
    /// Declared by `f.x = 1`, which a variable of the same name may join.
    pub const assignment: u32 = 1 << 24;

    pub const variable = func_var | block_var;
    pub const enum_any = const_enum | regular_enum;
    pub const value = variable | property | enum_member | object_literal | function | class | enum_any | value_module | method | getter | setter;
    pub const @"type" = class | interface | enum_any | enum_member | type_literal | type_param | type_alias;
    pub const namespace = value_module | namespace_module | enum_any;
    pub const module_any = value_module | namespace_module;
    pub const accessor = getter | setter;

    pub const func_var_ex = value & ~func_var;
    pub const block_var_ex = value;
    pub const param_ex = value;
    pub const enum_member_ex = value | @"type";
    pub const function_ex = value & ~(function | value_module | class);
    pub const class_ex = (value | @"type") & ~(value_module | interface | function);
    pub const interface_ex = @"type" & ~(interface | class);
    pub const regular_enum_ex = (value | @"type") & ~(regular_enum | value_module);
    pub const const_enum_ex = (value | @"type") & ~const_enum;
    pub const value_module_ex = value & ~(function | class | regular_enum | value_module);
    pub const method_ex = value & ~method;
    pub const getter_ex = value & ~setter;
    pub const setter_ex = value & ~getter;
    pub const type_param_ex = @"type" & ~type_param;
    pub const type_alias_ex = @"type";
    pub const alias_ex = alias;
};

pub const Symbol = struct {
    name: []const u8,
    flags: u32 = 0,
    decls: []*Node = &.{},
    value_decl: ?*Node = null,
    members: ?*SymbolTable = null,
    exports: ?*SymbolTable = null,
    parent: ?*Symbol = null,
    /// Set when a merge folded this symbol into another; lookups must follow it.
    merged: ?*Symbol = null,
    file: ?*ast.File = null,
    rare: ?*RareParts = null,

    /// Next to none of a million symbols have these, and the rest would pay 48 bytes each.
    pub const RareParts = struct {
        /// `export *` declarations of a module; `declare module "x"` bodies have their own.
        stars: []*Node = &.{},
        /// Members named by `[KEY]`: only the checker can tell what name a constant holds.
        late_members: []*Symbol = &.{},
        late_statics: []*Symbol = &.{},
    };

    pub fn resolve(s: *Symbol) *Symbol {
        var c = s;
        while (c.merged) |m| c = m;
        return c;
    }

    pub fn stars(s: *const Symbol) []*Node {
        return if (s.rare) |r| r.stars else &.{};
    }

    pub fn lateMembers(s: *const Symbol) []*Symbol {
        return if (s.rare) |r| r.late_members else &.{};
    }

    pub fn lateStatics(s: *const Symbol) []*Symbol {
        return if (s.rare) |r| r.late_statics else &.{};
    }

    pub fn rareParts(s: *Symbol, a: Allocator) *RareParts {
        if (s.rare) |r| return r;
        const r = a.create(RareParts) catch oom();
        r.* = .{};
        s.rare = r;
        return r;
    }
};

/// Name lookups outnumber everything else in binding and checking, and names are short.
pub const NameContext = struct {
    pub fn hashOf(name: []const u8) u64 {
        var h: u64 = name.len;
        var rest = name;
        while (rest.len >= 8) : (rest = rest[8..]) {
            h = (std.math.rotl(u64, h, 5) ^ std.mem.readInt(u64, rest[0..8], .little)) *% 0x517cc1b727220a95;
        }
        var tail: u64 = 0;
        for (rest) |b| tail = tail << 8 | b;
        h = (std.math.rotl(u64, h, 5) ^ tail) *% 0x517cc1b727220a95;
        return h ^ (h >> 32);
    }

    pub fn hash(_: NameContext, name: []const u8) u64 {
        return hashOf(name);
    }

    pub fn eql(_: NameContext, l: []const u8, r: []const u8) bool {
        return std.mem.eql(u8, l, r);
    }
};

/// Holding only the symbol, whose name is the key, keeps a table to a third of the size, and the
/// tables of a large project run to hundreds of megabytes. A symbol known by another name here sits
/// behind a stand-in of that name.
pub const SymbolTable = struct {
    map: std.HashMapUnmanaged(*Symbol, void, SymbolContext, 80) = .empty,

    /// The entry as it stands, which may be a stand-in or a symbol since merged.
    pub fn raw(t: *const SymbolTable, name: []const u8) ?*Symbol {
        return t.map.getKeyAdapted(HashedName.of(name), HashedContext{});
    }

    pub fn get(t: *const SymbolTable, name: []const u8) ?*Symbol {
        return t.getHashed(HashedName.of(name));
    }

    pub fn getHashed(t: *const SymbolTable, name: HashedName) ?*Symbol {
        return if (t.map.getKeyAdapted(name, HashedContext{})) |s| s.resolve() else null;
    }

    pub fn contains(t: *const SymbolTable, name: []const u8) bool {
        return t.raw(name) != null;
    }

    /// A new slot's key must be set to a symbol of this name before the table is used again.
    pub fn slot(t: *SymbolTable, a: Allocator, name: []const u8) Slot {
        const gop = t.map.getOrPutAdapted(a, HashedName.of(name), HashedContext{}) catch oom();
        return .{ .symbol = gop.key_ptr, .found_existing = gop.found_existing };
    }

    pub fn put(t: *SymbolTable, a: Allocator, name: []const u8, s: *Symbol) void {
        var entry = s;
        if (!std.mem.eql(u8, s.name, name)) {
            entry = a.create(Symbol) catch oom();
            entry.* = s.*;
            entry.name = name;
            entry.merged = s;
        }
        t.slot(a, name).symbol.* = entry;
    }

    pub fn remove(t: *SymbolTable, name: []const u8) void {
        _ = t.map.removeAdapted(HashedName.of(name), HashedContext{});
    }

    pub const Slot = struct { symbol: **Symbol, found_existing: bool };
};

const SymbolContext = struct {
    pub fn hash(_: SymbolContext, s: *Symbol) u64 {
        return NameContext.hashOf(s.name);
    }

    pub fn eql(_: SymbolContext, l: *Symbol, r: *Symbol) bool {
        return l == r;
    }
};

/// A name asked of every scope on the way out needs hashing only once.
pub const HashedName = struct {
    name: []const u8,
    hash: u64,

    pub fn of(name: []const u8) HashedName {
        return .{ .name = name, .hash = NameContext.hashOf(name) };
    }
};

const HashedContext = struct {
    pub fn hash(_: HashedContext, k: HashedName) u64 {
        return k.hash;
    }

    pub fn eql(_: HashedContext, k: HashedName, s: *Symbol) bool {
        return std.mem.eql(u8, k.name, s.name);
    }
};

pub const FlowKind = enum { start, unreachable_end, assign, true_cond, false_cond, branch, loop, switch_clause, call, reduce };

pub const FlowNode = struct {
    kind: FlowKind,
    node: ?*Node = null,
    antecedent: ?*FlowNode = null,
    antecedents: []*FlowNode = &.{},
    clause_start: u32 = 0,
    clause_end: u32 = 0,
    /// A `true_cond` for `a?.`: it proves `a` is not nullish, which is less than truthy.
    present: bool = false,
    /// For `reduce`: past a `finally`, only `antecedents` of this label can have led here.
    reduce_target: ?*FlowNode = null,
};

const Label = struct {
    kind: FlowKind,
    list: std.ArrayList(*FlowNode) = .empty,
    /// Loop labels exist before their back edges, so the flow node is shared and patched.
    node: ?*FlowNode = null,
};

const NamedLabel = struct { name: []const u8, brk: *Label, cont: ?*Label, parent: ?*NamedLabel };

const VarScope = enum { function, block };

/// A function's block as `bindBody` left it for one checker.
pub const Body = struct {
    block: *Node,
    /// Null when control cannot fall off the end.
    end_flow: ?*FlowNode,
    /// The function's scope with the block's declarations in it.
    locals: ?*SymbolTable,
    /// Executable statements no path reaches.
    dead: []*Node = &.{},
};

pub const Binder = struct {
    a: Allocator,
    /// Labels guide construction; only flow nodes and completed edge lists escape binding.
    temps: Allocator,
    file: *ast.File,
    /// Nearest function-like scope: where `var` lands.
    container: *Node,
    /// Nearest block: where `let`, `const` and classes land.
    block: *Node,
    flow: *FlowNode,
    unreachable_flow: *FlowNode,
    /// Where the current optional chain rejoins: right after its first `?.` operand.
    chain_exit: ?*FlowNode = null,
    /// Inside `try`: every mutation may be the last thing to happen before a throw.
    exc: ?*Label = null,
    brk: ?*Label = null,
    cont: ?*Label = null,
    ret: ?*Label = null,
    labels: ?*NamedLabel = null,
    diags: std.ArrayList(lexer.Diag) = .empty,
    /// tsc's `NodeFlagsUnreachable`, kept aside: few statements are unreachable.
    dead: std.ArrayList(*Node) = .empty,
    /// Target of the next `:` label applied to a loop, so `continue label` finds it.
    pending_label: ?*NamedLabel = null,
    in_ambient: bool = false,
    /// In an ambient module without `export` statements every declaration is exported.
    export_context: bool = false,
    /// The function whose block `bindBody` is binding: part of a tree others are reading.
    frozen: ?*Node = null,
    /// `frozen`'s scope, as this block adds to it.
    frozen_locals: ?*SymbolTable = null,
    /// `this.x = 1` in the class being bound, declared once its own members are all in place.
    this_props: std.ArrayList(ThisProp) = .empty,

    fn mkSym(b: *Binder, name: []const u8, flags: u32) *Symbol {
        const s = b.a.create(Symbol) catch oom();
        s.* = .{ .name = name, .flags = flags, .file = b.file };
        return s;
    }

    fn table(b: *Binder) *SymbolTable {
        const t = b.a.create(SymbolTable) catch oom();
        t.* = .{};
        return t;
    }

    fn localsOf(b: *Binder, n: *Node) *SymbolTable {
        if (n == b.frozen) {
            if (b.frozen_locals == null) {
                b.frozen_locals = b.table();
                if (n.locals()) |l| b.frozen_locals.?.map = l.map.clone(b.a) catch oom();
            }
            return b.frozen_locals.?;
        }
        if (n.locals() == null) n.setLocals(b.a, b.table());
        return n.locals().?;
    }

    fn scopeOf(b: *const Binder, n: *Node) ?*SymbolTable {
        return if (n == b.frozen and b.frozen_locals != null) b.frozen_locals else n.locals();
    }

    /// `var x` can join the parameter `x`, whose symbol is in the frozen tree.
    fn writable(b: *Binder, slot: **Symbol) *Symbol {
        const s = slot.*.resolve();
        const shared = (b.frozen orelse return s).locals() orelse return s;
        if (shared.raw(s.name) != s) return s;
        const own = b.a.create(Symbol) catch oom();
        own.* = s.*;
        // `append` writes in place below the next power of two.
        const room = b.a.alloc(*Node, std.math.ceilPowerOfTwoAssert(usize, @max(s.decls.len, 1))) catch oom();
        @memcpy(room[0..s.decls.len], s.decls);
        own.decls = room[0..s.decls.len];
        slot.* = own;
        return own;
    }

    fn addDecl(b: *Binder, s: *Symbol, n: *Node, flags: u32) void {
        s.flags |= flags;
        s.decls = append(b.a, s.decls, n);
        if (flags & F.value != 0 and (s.value_decl == null or (s.value_decl.?.data != .class and n.data == .class))) s.value_decl = n;
        if (n.symbol() == null) n.setSymbol(b.a, s);
    }

    fn declare(b: *Binder, t: *SymbolTable, parent: ?*Symbol, n: *Node, name: []const u8, flags: u32, excludes: u32, err_node: ?*Node) *Symbol {
        const entry = t.slot(b.a, name);
        if (entry.found_existing) {
            const s = b.writable(entry.symbol);
            if (s.flags & excludes == 0 or (flags & F.variable != 0 and s.flags & F.assignment != 0)) {
                b.addDecl(s, n, flags);
                return s;
            }
            b.reportDuplicate(s, flags, name, err_node orelse n);
            // Keep the declaration reachable so the code that follows it still checks.
            const fresh = b.mkSym(name, flags);
            fresh.parent = parent;
            b.addDecl(fresh, n, flags);
            n.setSymbol(b.a, fresh);
            return fresh;
        }
        const s = b.mkSym(name, 0);
        s.parent = parent;
        entry.symbol.* = s;
        b.addDecl(s, n, flags);
        return s;
    }

    fn reportDuplicate(b: *Binder, s: *Symbol, flags: u32, name: []const u8, at: *Node) void {
        // Declarations whose name failed to parse all share the empty name.
        if (name.len == 0) return;
        // The wording goes by what was there first: `let x` over a parameter is a plain duplicate.
        const block = s.flags & F.block_var != 0;
        const enums = (s.flags | flags) & F.enum_any != 0;
        const code: u32 = if (enums) 2567 else if (block) 2451 else 2300;
        const msg = if (enums)
            "Enum declarations can only merge with namespace or other enum declarations."
        else if (block)
            std.fmt.allocPrint(b.a, "Cannot redeclare block-scoped variable '{s}'.", .{name}) catch oom()
        else
            std.fmt.allocPrint(b.a, "Duplicate identifier '{s}'.", .{name}) catch oom();
        const target = nameNode(at) orelse at;
        b.diags.append(b.a, .{ .start = target.start, .len = target.end - target.start, .code = code, .msg = msg }) catch oom();
        for (s.decls) |d| {
            const dn = nameNode(d) orelse d;
            b.diags.append(b.a, .{ .start = dn.start, .len = dn.end - dn.start, .code = code, .msg = msg }) catch oom();
        }
    }

    fn fileSym(b: *Binder) *Symbol {
        if (b.file.symbol == null) {
            const s = b.mkSym(b.file.path, F.value_module);
            s.exports = b.table();
            b.file.symbol = s;
        }
        return b.file.symbol.?;
    }

    /// Module scope holds exports on the symbol and locals on the node.
    fn moduleScope(b: *Binder) ?*Symbol {
        const c = b.container;
        if (c.data == .source_file) return if (b.file.is_module) b.fileSym() else null;
        if (c.data == .module_decl) return c.symbol();
        return null;
    }

    fn declareModuleMember(b: *Binder, n: *Node, name: []const u8, flags: u32, excludes: u32, mods: ast.Mods, err_node: ?*Node) *Symbol {
        const ms = b.moduleScope();
        const exported = mods.@"export" or (b.export_context and flags & F.alias == 0);
        if (ms != null and exported) {
            if (ms.?.exports == null) ms.?.exports = b.table();
            const exported_name = if (mods.default) "default" else name;
            const s = b.declare(ms.?.exports.?, ms, n, exported_name, flags, excludes, err_node);
            if (mods.default and name.len > 0) {
                const lt = b.localsOf(b.container);
                lt.put(b.a, name, s);
            } else if (b.container.data == .source_file) {
                const lt = b.localsOf(b.container);
                // `interface X` beside `export const X` is not exported, and name lookup reaches the export past it.
                const beside = if (lt.get(name)) |old| old != s and old.flags & (excludes | F.alias) == 0 else false;
                if (!beside) lt.put(b.a, name, s);
            }
            return s;
        }
        const lt = b.localsOf(b.container);
        if (ms) |m| if (b.container.data == .source_file and flags & F.alias == 0) if (m.exports) |e| if (e.get(name)) |x| {
            if (x.flags & excludes == 0 and lt.get(name) == x) lt.remove(name);
        };
        return b.declare(lt, null, n, name, flags, excludes, err_node);
    }

    fn declareBlock(b: *Binder, n: *Node, name: []const u8, flags: u32, excludes: u32, mods: ast.Mods, err_node: ?*Node) *Symbol {
        if (b.block == b.container) return b.declareModuleMember(n, name, flags, excludes, mods, err_node);
        return b.declare(b.localsOf(b.block), null, n, name, flags, excludes, err_node);
    }

    fn createFlow(b: *Binder, kind: FlowKind, node: ?*Node, ante: ?*FlowNode) *FlowNode {
        const f = b.a.create(FlowNode) catch oom();
        f.* = .{ .kind = kind, .node = node, .antecedent = ante };
        return f;
    }

    fn newLabel(b: *Binder, kind: FlowKind) *Label {
        const l = b.temps.create(Label) catch oom();
        l.* = .{ .kind = kind, .node = if (kind == .loop) b.createFlow(kind, null, null) else null };
        return l;
    }

    fn addAnte(b: *Binder, l: *Label, f: *FlowNode) void {
        if (f.kind == .unreachable_end) return;
        for (l.list.items) |e| if (e == f) return;
        // Only a completed join copies its edges into the persistent graph.
        if (l.list.items.len == l.list.capacity) l.list.ensureTotalCapacityPrecise(b.temps, @max(2, l.list.capacity * 2)) catch oom();
        l.list.appendAssumeCapacity(f);
    }

    fn finish(b: *Binder, l: *Label) *FlowNode {
        if (l.list.items.len == 0) return if (l.kind == .loop) l.node.? else b.unreachable_flow;
        if (l.list.items.len == 1 and l.kind != .loop) return l.list.items[0];
        const node = b.labelNode(l);
        node.antecedents = b.a.dupe(*FlowNode, l.list.items) catch oom();
        return node;
    }

    fn labelNode(b: *Binder, label: *Label) *FlowNode {
        if (label.node == null) label.node = b.createFlow(label.kind, null, null);
        return label.node.?;
    }

    fn condFlow(b: *Binder, kind: FlowKind, ante: *FlowNode, e: *Node) *FlowNode {
        if (ante.kind == .unreachable_end) return ante;
        const wanted = kind == .true_cond;
        // tsc folds only a bare `true` or `false`: `(true)` and `!false` keep both branches live.
        // `a ?? true` is a default, not a constant: `a` can still be `false`.
        const defaulted = if (e.parent) |p| p.data == .binary and p.data.binary.op == .qq else false;
        if (!defaulted and ((e.data == .true_lit and !wanted) or (e.data == .false_lit and wanted))) return b.unreachable_flow;
        if (e.data == .true_lit or e.data == .false_lit) return ante;
        if (!isNarrowing(e)) return ante;
        return b.createFlow(kind, e, ante);
    }

    /// Mirrors tsc's `bindCondition`: logical operators split into separate edges.
    fn bindCond(b: *Binder, e: ?*Node, t: *Label, f: *Label) void {
        const node = e orelse {
            b.addAnte(t, b.flow);
            return;
        };
        // tsc's `isLogicalExpression`: parens and `!` split only around `&&`, `||` and `??`.
        if (isLogicalExpr(node)) switch (node.data) {
            .paren => |p| return b.bindCond(p.expr, t, f),
            .prefix => |p| return b.bindCond(p.expr, f, t),
            else => {},
        };
        switch (node.data) {
            .binary => |x| switch (x.op) {
                .amp2 => {
                    const mid = b.newLabel(.branch);
                    b.bindCond(x.left, mid, f);
                    b.flow = b.finish(mid);
                    b.bindCond(x.right, t, f);
                    return;
                },
                .pipe2, .qq => {
                    const mid = b.newLabel(.branch);
                    b.bindCond(x.left, t, mid);
                    b.flow = b.finish(mid);
                    b.bindCond(x.right, t, f);
                    return;
                },
                else => {},
            },
            else => {},
        }
        b.bind(node);
        b.addAnte(t, b.condFlow(.true_cond, b.flow, node));
        b.addAnte(f, b.condFlow(.false_cond, b.flow, node));
    }

    fn mutate(b: *Binder, target: *Node) void {
        if (isReference(target) and b.flow.kind != .unreachable_end) b.flowEffect(.assign, target);
    }

    fn bindTarget(b: *Binder, target: *Node) void {
        const t = stripParens(target);
        switch (t.data) {
            .array_lit => |x| for (x.elems) |el| b.bindTarget(if (el.data == .spread_elem) el.data.spread_elem.expr else el),
            .object_lit => |x| for (x.props) |pr| switch (pr.data) {
                .property_assign => |q| b.bindTarget(q.value),
                .shorthand_assign => |q| b.mutate(q.name),
                .spread_assign => |q| b.bindTarget(q.expr),
                else => {},
            },
            .binary => |x| if (x.op == .assign) b.bindTarget(x.left),
            else => b.mutate(t),
        }
    }

    fn bindPatternDecls(b: *Binder, pat: *Node, kind: ast.VarKind, mods: ast.Mods) void {
        switch (pat.data) {
            .identifier => |name| if (name.len > 0) b.declareVar(pat.parent.?, name, kind, mods),
            .object_pattern => |x| for (x.elems) |el| b.bindElem(el, kind, mods),
            .array_pattern => |x| for (x.elems) |el| if (el.data == .binding_elem) b.bindElem(el, kind, mods),
            else => {},
        }
    }

    fn bindElem(b: *Binder, el: *Node, kind: ast.VarKind, mods: ast.Mods) void {
        const be = el.data.binding_elem;
        if (be.prop_name) |pn| b.bindComputed(pn);
        if (be.init) |i| b.bindInitializer(i);
        b.bindPatternDecls(be.name, kind, mods);
    }

    /// tsc's `bindInitializer`: a default runs only when the value is `undefined`, so what follows
    /// is reached with or without it.
    fn bindInitializer(b: *Binder, i: *Node) void {
        const entry = b.flow;
        b.bind(i);
        if (entry.kind == .unreachable_end or entry == b.flow) return;
        const exit = b.newLabel(.branch);
        b.addAnte(exit, entry);
        b.addAnte(exit, b.flow);
        b.flow = b.finish(exit);
    }

    fn bindComputed(b: *Binder, name: *Node) void {
        if (name.data == .computed_name) b.bind(name.data.computed_name.expr);
    }

    fn declareVar(b: *Binder, n: *Node, name: []const u8, kind: ast.VarKind, mods: ast.Mods) void {
        if (kind == .@"var") {
            _ = b.declareModuleMember(n, name, F.func_var, F.func_var_ex, mods, null);
        } else {
            _ = b.declareBlock(n, name, F.block_var, F.block_var_ex, mods, null);
        }
    }

    fn propName(b: *Binder, name: *Node) ?[]const u8 {
        return switch (name.data) {
            .identifier, .string_lit, .private_name, .bigint_lit => |v| v,
            .numeric_lit => |v| numericName(b.a, v),
            .no_subst_template => |v| v,
            .computed_name => |c| b.computedName(c.expr),
            else => null,
        };
    }

    fn isEntityName(e: *Node) bool {
        return switch (e.data) {
            .identifier => true,
            .prop_access => |x| isEntityName(x.expr),
            else => false,
        };
    }

    fn computedName(b: *Binder, e: *Node) ?[]const u8 {
        switch (e.data) {
            .string_lit, .no_subst_template => |v| return v,
            .numeric_lit => |v| return numericName(b.a, v),
            .prop_access => |x| if (x.expr.data == .identifier and std.mem.eql(u8, x.expr.data.identifier, "Symbol")) {
                return std.fmt.allocPrint(b.a, "__@{s}", .{x.name.data.identifier}) catch oom();
            },
            else => {},
        }
        return null;
    }

    fn declareMember(b: *Binder, sym: *Symbol, static: bool, n: *Node, name_node: *Node, flags: u32, excludes: u32) ?*Symbol {
        const name = b.propName(name_node) orelse {
            // Only a name reachable as an entity can be bound late. `[f()]` declares no member at all.
            if (name_node.data != .computed_name or !isEntityName(name_node.data.computed_name.expr)) return null;
            const s = b.mkSym("__computed", 0);
            s.parent = sym;
            b.addDecl(s, n, flags);
            const rare = sym.rareParts(b.a);
            if (static) {
                rare.late_statics = append(b.a, rare.late_statics, s);
            } else {
                rare.late_members = append(b.a, rare.late_members, s);
            }
            return null;
        };
        if (static) {
            if (sym.exports == null) sym.exports = b.table();
            return b.declare(sym.exports.?, sym, n, name, flags, excludes, name_node);
        }
        if (sym.members == null) sym.members = b.table();
        return b.declare(sym.members.?, sym, n, name, flags, excludes, name_node);
    }

    fn enterTypeParams(b: *Binder, scope: *Node, list: ast.TypeList) void {
        for (list.items) |tp| b.bindTypeParam(scope, tp);
    }

    fn bindTypeParam(b: *Binder, scope: *Node, tp: *Node) void {
        const d = tp.data.type_param;
        _ = b.declare(b.localsOf(scope), null, tp, d.name.data.identifier, F.type_param, F.type_param_ex, d.name);
        if (d.constraint) |c| b.bind(c);
        if (d.default) |c| b.bind(c);
    }

    fn bindList(b: *Binder, list: []*Node) void {
        // Function declarations hoist, so their symbols exist before any statement's flow.
        for (list) |s| if (s.data == .func) b.bind(s);
        for (list) |s| if (s.data != .func) b.bind(s);
    }

    /// A getter and a setter of one name in a literal are one property.
    fn literalAccessor(b: *Binder, n: *Node, flag: u32) void {
        const name = if (n.data.func.name) |x| b.propName(x) else null;
        if (name) |nm| for (n.parent.?.data.object_lit.props) |p| {
            if (p == n) break;
            const s = p.symbol() orelse continue;
            if (p.data != .func or s.flags & (F.getter | F.setter) == 0 or !std.mem.eql(u8, s.name, nm)) continue;
            s.flags |= flag;
            b.addDecl(s, n, 0);
            n.setSymbol(b.a, s);
            return;
        };
        const s = b.mkSym(name orelse "__computed", flag);
        b.addDecl(s, n, 0);
        s.value_decl = n;
        n.setSymbol(b.a, s);
    }

    fn bindFunc(b: *Binder, n: *Node) void {
        const f = n.data.func;
        const owner = n.parent;
        switch (f.kind) {
            .decl => {
                const name = if (f.name) |x| x.data.identifier else "default";
                const mods = n.mods;
                _ = b.declareBlockFunction(n, name, mods);
            },
            .expr => if (f.name) |x| {
                _ = b.declare(b.localsOf(n), null, n, x.data.identifier, F.function, F.none, null);
            },
            .method, .method_sig => if (owner != null and owner.?.symbol() != null and f.name != null) {
                const opt: u32 = if (f.question) F.optional else 0;
                _ = b.declareMember(owner.?.symbol().?, n.mods.static, n, f.name.?, F.method | opt, F.method_ex & ~F.optional);
            } else if (owner != null and owner.?.data == .object_lit) {
                n.setSymbol(b.a, b.mkSym(if (f.name) |x| b.propName(x) orelse "__computed" else "__computed", F.method));
                n.symbol().?.value_decl = n;
            },
            .getter, .getter_sig => if (owner != null and owner.?.symbol() != null and f.name != null) {
                _ = b.declareMember(owner.?.symbol().?, n.mods.static, n, f.name.?, F.getter, F.getter_ex);
            } else if (owner != null and owner.?.data == .object_lit) b.literalAccessor(n, F.getter),
            .setter, .setter_sig => if (owner != null and owner.?.symbol() != null and f.name != null) {
                _ = b.declareMember(owner.?.symbol().?, n.mods.static, n, f.name.?, F.setter, F.setter_ex);
            } else if (owner != null and owner.?.data == .object_lit) b.literalAccessor(n, F.setter),
            .ctor => if (owner != null and owner.?.symbol() != null) {
                const s = owner.?.symbol().?;
                if (s.members == null) s.members = b.table();
                _ = b.declare(s.members.?, s, n, "__constructor", F.constructor, F.none, null);
            },
            .call_sig, .construct_sig => if (owner != null and owner.?.symbol() != null) {
                const s = owner.?.symbol().?;
                if (s.members == null) s.members = b.table();
                _ = b.declare(s.members.?, s, n, if (f.kind == .call_sig) "__call" else "__new", F.signature, F.none, null);
            },
            .function_type, .constructor_type, .arrow => {
                const s = b.mkSym(if (f.kind == .arrow) "__function" else "__type", if (f.kind == .arrow) F.function else F.type_literal);
                b.addDecl(s, n, 0);
                n.setSymbol(b.a, s);
            },
        }
        if (f.name) |x| b.bindComputed(x);
        for (f.decorators) |d| b.bind(d);

        const save = .{ b.container, b.block, b.flow, b.brk, b.cont, b.ret, b.labels, b.exc };
        b.exc = null;
        const start_node: ?*Node = if (f.kind == .arrow or f.kind == .expr or f.kind == .method or f.kind == .getter or f.kind == .setter) n else null;
        if (start_node != null) n.setFlow(b.a, b.flow);
        // Run on the spot, the body is part of the code around it and a `return` lands after the call.
        const in_place = calledOnTheSpot(n) and !n.mods.async and !f.asterisk;
        b.container = n;
        b.block = n;
        if (!in_place) b.flow = b.createFlow(.start, start_node, null);
        b.brk = null;
        b.cont = null;
        b.labels = null;
        // Only an immediately invoked function rejoins its return paths in the enclosing flow.
        const ret = if (in_place) b.newLabel(.branch) else null;
        b.ret = ret;

        b.enterTypeParams(n, f.type_params);
        for (f.params) |p| b.bindParam(n, p);
        if (f.ret) |r| b.bind(r);
        // Run on the spot, its `return`s take part in the flow of the code around it.
        if (in_place) if (f.body) |body| if (body.data == .lazy_body) {
            const parsed = parser.parseBody(b.a, b.file, n);
            f.body = parsed.block;
            if (!parsed.ok) b.file.bad_body = true;
        };
        if (f.body) |body| {
            if (body.data == .lazy_body) {
                body.setFlow(b.a, b.flow);
                for (body.data.lazy_body.specs) |s| b.moduleSpec(s);
            } else {
                if (body.data == .block) b.bindList(body.data.block.stmts) else b.bind(body);
                f.end_flow = if (b.flow.kind == .unreachable_end) null else b.flow;
            }
        }
        if (ret) |r| b.addAnte(r, b.flow);
        b.container = save[0];
        b.block = save[1];
        b.flow = if (ret) |r| b.finish(r) else save[2];
        b.brk = save[3];
        b.cont = save[4];
        b.ret = save[5];
        b.exc = save[7];
        b.labels = save[6];
    }

    fn declareBlockFunction(b: *Binder, n: *Node, name: []const u8, mods: ast.Mods) *Symbol {
        // Inside a block a function is block-scoped in ES modules and strict code.
        if (b.block != b.container) return b.declare(b.localsOf(b.block), null, n, name, F.function, F.function_ex, n.data.func.name);
        return b.declareModuleMember(n, name, F.function, F.function_ex, mods, n.data.func.name);
    }

    fn bindParam(b: *Binder, func: *Node, p: *Node) void {
        const d = p.data.param;
        for (d.decorators) |x| b.bind(x);
        if (d.type) |t| b.bind(t);
        if (d.init) |i| b.bindInitializer(i);
        switch (d.name.data) {
            .identifier => |name| {
                if (name.len > 0 and !std.mem.eql(u8, name, "this")) {
                    _ = b.declare(b.localsOf(func), null, p, name, F.func_var | F.param, F.param_ex, d.name);
                }
                const fd = func.data.func;
                if (fd.kind == .ctor and (p.mods.public or p.mods.private or p.mods.protected or p.mods.readonly or p.mods.override)) {
                    if (func.parent) |cls| if (cls.symbol()) |sym| {
                        if (sym.members == null) sym.members = b.table();
                        const opt: u32 = if (d.question) F.optional else 0;
                        const saved = p.symbol();
                        _ = b.declare(sym.members.?, sym, p, name, F.property | opt, F.none, d.name);
                        p.setSymbol(b.a, saved);
                    };
                }
            },
            else => b.bindParamPattern(func, d.name),
        }
    }

    fn bindParamPattern(b: *Binder, func: *Node, pat: *Node) void {
        const elems = switch (pat.data) {
            .object_pattern => |x| x.elems,
            .array_pattern => |x| x.elems,
            else => return,
        };
        for (elems) |el| {
            if (el.data != .binding_elem) continue;
            const be = el.data.binding_elem;
            if (be.prop_name) |pn| b.bindComputed(pn);
            if (be.init) |i| b.bindInitializer(i);
            if (be.name.data == .identifier) {
                if (be.name.data.identifier.len > 0) _ = b.declare(b.localsOf(func), null, el, be.name.data.identifier, F.func_var | F.param, F.param_ex, be.name);
            } else b.bindParamPattern(func, be.name);
        }
    }

    fn bindClass(b: *Binder, n: *Node) void {
        const c = n.data.class;
        const name = if (c.name) |x| x.data.identifier else "";
        if (c.is_expr) {
            const s = b.mkSym(if (name.len > 0) name else "__class", 0);
            b.addDecl(s, n, F.class);
            n.setSymbol(b.a, s);
            if (name.len > 0) b.localsOf(n).put(b.a, name, s);
        } else {
            _ = b.declareBlock(n, if (name.len > 0) name else "default", F.class, F.class_ex, n.mods, c.name);
        }
        const save = .{ b.container, b.block, b.flow };
        b.enterTypeParams(n, c.type_params);
        for (c.decorators) |d| b.bind(d);
        for (c.heritage) |h| b.bind(h);
        const outer = b.this_props;
        b.this_props = .empty;
        for (c.members) |m| {
            m.parent = n;
            b.bindMember(n, m);
        }
        for (b.this_props.items) |x| b.declareThisProperty(n, x.left, x.static);
        b.this_props = outer;
        b.container = save[0];
        b.block = save[1];
        b.flow = save[2];
    }

    /// Field initializers run later, on their own flow.
    fn bindMember(b: *Binder, cls: *Node, m: *Node) void {
        const sym = cls.symbol() orelse return;
        switch (m.data) {
            .property_decl => |d| {
                for (d.decorators) |x| b.bind(x);
                const flags = F.property | (if (d.question) F.optional else 0);
                _ = b.declareMember(sym, m.mods.static, m, d.name, flags, F.none);
                b.bindComputed(d.name);
                if (d.type) |t| b.bind(t);
                if (d.init) |i| {
                    const save = b.flow;
                    b.flow = b.createFlow(.start, null, null);
                    b.bind(i);
                    b.flow = save;
                }
            },
            .index_sig => {
                if (sym.members == null) sym.members = b.table();
                _ = b.declare(sym.members.?, sym, m, "__index", F.signature, F.none, null);
                b.bindChildren(m);
            },
            .static_block => |d| {
                const save = .{ b.container, b.block, b.flow };
                b.container = m;
                b.block = m;
                b.flow = b.createFlow(.start, null, null);
                if (d.body.data == .block) b.bindList(d.body.data.block.stmts);
                m.data.static_block.end_flow = if (b.flow.kind == .unreachable_end) null else b.flow;
                b.container = save[0];
                b.block = save[1];
                b.flow = save[2];
            },
            else => b.bind(m),
        }
    }

    fn bindTypeMembers(b: *Binder, owner: *Node, members: []*Node) void {
        const sym = owner.symbol() orelse return;
        for (members) |m| {
            m.parent = owner;
            switch (m.data) {
                .property_sig => |d| {
                    const flags = F.property | (if (d.question) F.optional else 0);
                    _ = b.declareMember(sym, false, m, d.name, flags, F.none);
                    b.bindComputed(d.name);
                    if (d.type) |t| b.bind(t);
                },
                .index_sig => {
                    if (sym.members == null) sym.members = b.table();
                    _ = b.declare(sym.members.?, sym, m, "__index", F.signature, F.none, null);
                    b.bindChildren(m);
                },
                else => b.bind(m),
            }
        }
    }

    fn bindEnum(b: *Binder, n: *Node) void {
        const d = n.data.enum_decl;
        const name = d.name.data.identifier;
        const is_const = n.mods.@"const";
        const s = b.declareBlock(n, name, if (is_const) F.const_enum else F.regular_enum, if (is_const) F.const_enum_ex else F.regular_enum_ex, n.mods, d.name);
        for (d.members) |m| {
            m.parent = n;
            const md = m.data.enum_member;
            // Invalid computed names can still contain functions visited by the checker.
            b.bindComputed(md.name);
            if (b.propName(md.name)) |mn| {
                if (s.exports == null) s.exports = b.table();
                _ = b.declare(s.exports.?, s, m, mn, F.enum_member, F.enum_member_ex, md.name);
            }
            if (md.init) |i| b.bind(i);
        }
    }

    pub fn isInstantiatedDecl(n: *Node) bool {
        return isInstantiated(n, 0);
    }

    fn isInstantiated(n: *Node, depth: u32) bool {
        const stmts = switch (n.data) {
            .module_block => |x| x.stmts,
            .module_decl => |x| return if (x.body) |c| isInstantiated(c, depth) else false,
            .interface, .type_alias => return false,
            else => return true,
        };
        for (stmts) |s| {
            switch (s.data) {
                .import_decl => {},
                .import_equals => if (s.mods.@"export") return true,
                .export_decl => |x| if (exportsValue(x, depth)) return true,
                else => if (isInstantiated(s, depth)) return true,
            }
        }
        return false;
    }

    fn exportsValue(x: *ast.ExportDecl, depth: u32) bool {
        if (x.specifier != null) return true;
        const clause = x.clause orelse return true;
        if (clause.data != .named_exports) return true;
        for (clause.data.named_exports.elems) |spec| if (aliasesValue(spec, depth)) return true;
        return false;
    }

    /// A name found nowhere, or found only as an import, may be a value.
    fn aliasesValue(spec: *Node, depth: u32) bool {
        // Namespaces exporting each other in a circle have no value in them.
        if (depth > 16) return false;
        const x = spec.data.export_spec;
        const name = specName(x.prop_name orelse x.name);
        var p = spec.parent;
        while (p) |scope| : (p = scope.parent) {
            const stmts = switch (scope.data) {
                .module_block => |b| b.stmts,
                .source_file => |b| b.stmts,
                else => continue,
            };
            var found = false;
            for (stmts) |s| {
                const named = nameNode(s) orelse continue;
                if (named.data != .identifier or !std.mem.eql(u8, named.data.identifier, name)) continue;
                found = true;
                if (s.data == .import_equals or isInstantiated(s, depth + 1)) return true;
            }
            if (found) return false;
        }
        return true;
    }

    fn bindModule(b: *Binder, n: *Node) void {
        const d = n.data.module_decl;
        const save_ambient = b.in_ambient;
        if (n.mods.declare or b.file.is_dts) b.in_ambient = true;
        defer b.in_ambient = save_ambient;
        if (d.is_global) {
            const s = b.mkSym("__global", F.namespace_module);
            s.exports = b.table();
            b.addDecl(s, n, 0);
            n.setSymbol(b.a, s);
            if (b.frozen == null) b.file.global_augs = append(b.a, b.file.global_augs, s);
        } else if (d.name.data == .string_lit) {
            const name = d.name.data.string_lit;
            const s = b.mkSym(name, F.value_module);
            s.exports = b.table();
            b.addDecl(s, n, 0);
            n.setSymbol(b.a, s);
            if (b.frozen != null) {
                // Not legal in a function, and the file is no longer this binder's to change.
            } else if (b.file.is_module) {
                b.moduleSpec(d.name);
                b.file.augmentations = append(b.a, b.file.augmentations, s);
            } else {
                b.file.ambient_modules = append(b.a, b.file.ambient_modules, s);
            }
        } else {
            const name = d.name.data.identifier;
            const inst = isInstantiated(n, 0);
            const flags = if (inst) F.value_module else F.namespace_module;
            const ex = if (inst) F.value_module_ex else F.none;
            if (n.parent != null and n.parent.?.data == .module_decl) {
                // `namespace A.B`: the inner segment is an implicit export of the outer.
                const outer = n.parent.?.symbol().?;
                if (outer.exports == null) outer.exports = b.table();
                _ = b.declare(outer.exports.?, outer, n, name, flags, ex, d.name);
            } else {
                _ = b.declareBlock(n, name, flags, ex, n.mods, d.name);
            }
            if (n.symbol().?.exports == null) n.symbol().?.exports = b.table();
        }
        const save = .{ b.container, b.block, b.flow, b.export_context };
        b.container = n;
        b.block = n;
        b.flow = b.createFlow(.start, null, null);
        if (d.body) |body| switch (body.data) {
            .module_block => |x| {
                b.export_context = b.in_ambient and !hasExportStatements(x.stmts);
                b.bindList(x.stmts);
            },
            .module_decl => {
                body.parent = n;
                b.bindModule(body);
            },
            else => {},
        };
        b.container = save[0];
        b.block = save[1];
        b.flow = save[2];
        b.export_context = save[3];
    }

    fn hasExportStatements(stmts: []*Node) bool {
        for (stmts) |s| if (s.data == .export_decl or s.data == .export_assign) return true;
        return false;
    }

    fn exportTable(b: *Binder) ?*SymbolTable {
        const s = b.moduleScope() orelse return null;
        if (s.exports == null) s.exports = b.table();
        return s.exports;
    }

    fn bindImport(b: *Binder, n: *Node) void {
        const d = n.data.import_decl;
        const clause = d.clause orelse return;
        const c = clause.data.import_clause;
        const lt = b.localsOf(b.container);
        if (c.name) |name| _ = b.declare(lt, null, clause, name.data.identifier, F.alias, F.alias_ex, name);
        const bindings = c.bindings orelse return;
        switch (bindings.data) {
            .namespace_import => |x| _ = b.declare(lt, null, bindings, x.name.data.identifier, F.alias, F.alias_ex, x.name),
            .named_imports => |x| for (x.elems) |spec| {
                const local = spec.data.import_spec.name;
                _ = b.declare(lt, null, spec, specName(local), F.alias, F.alias_ex, local);
            },
            else => {},
        }
    }

    fn bindExport(b: *Binder, n: *Node) void {
        const d = n.data.export_decl;
        const t = b.exportTable() orelse return;
        if (d.clause == null) {
            const m = b.moduleScope().?;
            const rare = m.rareParts(b.a);
            rare.stars = append(b.a, rare.stars, n);
            return;
        }
        switch (d.clause.?.data) {
            .namespace_export => |x| _ = b.declare(t, b.moduleScope(), d.clause.?, specName(x.name), F.alias, F.alias_ex, x.name),
            .named_exports => |x| for (x.elems) |spec| {
                const name = spec.data.export_spec.name;
                _ = b.declare(t, b.moduleScope(), spec, specName(name), F.alias, F.alias_ex, name);
            },
            else => {},
        }
    }

    fn bindExportAssign(b: *Binder, n: *Node) void {
        const d = n.data.export_assign;
        b.bind(d.expr);
        const t = b.exportTable() orelse return;
        const name = if (d.is_equals) "export=" else "default";
        const flags: u32 = if (stripParens(d.expr).data == .identifier or stripParens(d.expr).data == .prop_access) F.alias else F.property;
        _ = b.declare(t, b.moduleScope(), n, name, flags, F.none, null);
    }

    fn moduleSpec(b: *Binder, n: *Node) void {
        if (n.data == .string_lit and b.frozen == null) b.file.module_specs = append(b.a, b.file.module_specs, n);
    }

    /// `import` and `export` name a module of the file only at its top level or directly in an
    /// ambient module. Anywhere else they are an error, and tsc does not load what they name.
    fn statementSpec(b: *Binder, stmt: *Node, n: *Node) void {
        const p = stmt.parent orelse return b.moduleSpec(n);
        const ambient = p.data == .module_block and p.parent != null and p.parent.?.data == .module_decl and p.parent.?.data.module_decl.name.data == .string_lit;
        if (p.data == .source_file or ambient) b.moduleSpec(n);
    }

    fn continuesChain(n: *Node) bool {
        const p = n.parent orelse return false;
        return switch (p.data) {
            .prop_access => |x| x.expr == n,
            .elem_access => |x| x.expr == n,
            .call => |x| x.callee == n,
            else => false,
        };
    }

    fn enterChain(b: *Binder, n: *Node) ?*FlowNode {
        if (continuesChain(n)) return null;
        const saved = b.chain_exit;
        b.chain_exit = null;
        return saved;
    }

    fn leaveChain(b: *Binder, n: *Node, saved: ?*FlowNode) void {
        if (continuesChain(n)) return;
        if (b.chain_exit) |f| b.flow = f;
        b.chain_exit = saved;
    }

    /// What follows `a?.` runs only when `a` is present, like the right side of `a && ...`.
    fn chainRest(b: *Binder, operand: *Node) void {
        if (b.chain_exit == null) b.chain_exit = b.flow;
        if (b.flow.kind == .unreachable_end or !isNarrowing(operand)) return;
        const f = b.createFlow(.true_cond, operand, b.flow);
        f.present = true;
        b.flow = f;
    }

    fn bindChildren(b: *Binder, n: *Node) void {
        ast.forEachChild(n, b, struct {
            fn f(self: *Binder, c: *Node) void {
                self.bind(c);
            }
        }.f);
    }

    fn enterBlock(b: *Binder, n: *Node, stmts: []*Node) void {
        const save = b.block;
        b.block = n;
        b.bindList(stmts);
        b.block = save;
    }

    fn loopLabels(b: *Binder, brk: *Label, cont: *Label) struct { ?*Label, ?*Label } {
        const save = .{ b.brk, b.cont };
        b.brk = brk;
        b.cont = cont;
        if (b.pending_label) |l| {
            l.cont = cont;
            b.pending_label = null;
        }
        return save;
    }

    fn bindLoopBody(b: *Binder, body: *Node) void {
        b.pending_label = null;
        b.bind(body);
    }

    pub fn bind(b: *Binder, n: *Node) void {
        if (b.flow.kind == .unreachable_end) {
            if (isPotentiallyExecutable(n)) b.dead.append(b.a, n) catch oom();
        } else if (isStatement(n)) n.setFlow(b.a, b.flow);
        switch (n.data) {
            .identifier, .this_expr, .super_expr => n.setFlow(b.a, b.flow),
            // `typeof a.b` is a read like any other and sees what `a.b` was narrowed to.
            .qualified_name => {
                n.setFlow(b.a, b.flow);
                b.bindChildren(n);
            },
            .prop_access => |x| {
                const saved = b.enterChain(n);
                b.bind(x.expr);
                if (x.optional) b.chainRest(x.expr);
                b.bind(x.name);
                n.setFlow(b.a, b.flow);
                b.leaveChain(n, saved);
            },
            .elem_access => |x| {
                const saved = b.enterChain(n);
                b.bind(x.expr);
                if (x.optional) b.chainRest(x.expr);
                b.bind(x.index);
                n.setFlow(b.a, b.flow);
                b.leaveChain(n, saved);
            },
            .func => b.bindFunc(n),
            .class => b.bindClass(n),
            .interface => |d| {
                const s = b.declareBlock(n, d.name.data.identifier, F.interface, F.interface_ex, n.mods, d.name);
                if (s.members == null) s.members = b.table();
                n.setSymbol(b.a, s);
                b.enterTypeParams(n, d.type_params);
                for (d.heritage) |h| b.bind(h);
                b.bindTypeMembers(n, d.members);
            },
            .type_literal => |d| {
                const s = b.mkSym("__type", F.type_literal);
                s.members = b.table();
                b.addDecl(s, n, 0);
                n.setSymbol(b.a, s);
                b.bindTypeMembers(n, d.members);
            },
            .type_alias => |d| {
                _ = b.declareBlock(n, d.name.data.identifier, F.type_alias, F.type_alias_ex, n.mods, d.name);
                b.enterTypeParams(n, d.type_params);
                b.bind(d.type);
            },
            .mapped_type => |d| {
                _ = b.declare(b.localsOf(n), null, n, d.tparam_name.data.identifier, F.type_param, F.none, null);
                b.bind(d.constraint);
                if (d.name_type) |t| b.bind(t);
                if (d.type) |t| b.bind(t);
            },
            .infer_type => |d| {
                var c = n.parent;
                var prev = n;
                // `infer` belongs to the nearest conditional whose `extends` clause holds it.
                while (c) |p| : (c = p.parent) {
                    if (p.data == .conditional_type and p.data.conditional_type.extends == prev) break;
                    prev = p;
                }
                const scope = c orelse n;
                const td = d.tparam.data.type_param;
                const existing = if (scope.locals()) |l| l.raw(td.name.data.identifier) else null;
                if (existing) |e| {
                    b.addDecl(e, d.tparam, 0);
                } else _ = b.declare(b.localsOf(scope), null, d.tparam, td.name.data.identifier, F.type_param, F.none, null);
                if (td.constraint) |x| b.bind(x);
            },
            .enum_decl => b.bindEnum(n),
            .module_decl => b.bindModule(n),
            .import_decl => |d| {
                b.statementSpec(n, d.specifier);
                b.bindImport(n);
            },
            .export_decl => |d| {
                if (d.specifier) |s| b.statementSpec(n, s);
                b.bindExport(n);
            },
            .import_type => |d| {
                if (d.arg.data == .literal_type) b.moduleSpec(d.arg.data.literal_type.lit);
                b.bindChildren(n);
            },
            .export_assign => b.bindExportAssign(n),
            .import_equals => |d| {
                if (d.ref.data == .external_module_ref) b.statementSpec(n, d.ref.data.external_module_ref.expr);
                _ = b.declareModuleMember(n, d.name.data.identifier, F.alias, F.alias_ex, n.mods, d.name);
            },
            .namespace_export_decl => |d| {
                b.file.umd_name = d.name.data.identifier;
            },
            .block => |d| {
                if (n.parent != null and n.parent.?.data == .func) {
                    b.bindList(d.stmts);
                } else b.enterBlock(n, d.stmts);
            },
            .module_block => |d| b.bindList(d.stmts),
            .var_list => |d| {
                for (d.decls) |decl| b.bindVarDecl(decl, d.kind, n.parent.?.mods);
            },
            .if_stmt => |d| {
                const t = b.newLabel(.branch);
                const f = b.newLabel(.branch);
                const end = b.newLabel(.branch);
                b.bindCond(d.cond, t, f);
                b.flow = b.finish(t);
                b.bind(d.then);
                b.addAnte(end, b.flow);
                b.flow = b.finish(f);
                if (d.els) |e| b.bind(e);
                b.addAnte(end, b.flow);
                b.flow = b.finish(end);
            },
            .while_stmt => |d| {
                const pre = b.newLabel(.loop);
                b.addAnte(pre, b.flow);
                const t = b.newLabel(.branch);
                const post = b.newLabel(.branch);
                b.flow = pre.node.?;
                b.bindCond(d.cond, t, post);
                b.flow = b.finish(t);
                const save = b.loopLabels(post, pre);
                b.bindLoopBody(d.body);
                b.addAnte(pre, b.flow);
                b.brk = save[0];
                b.cont = save[1];
                _ = b.finish(pre);
                b.flow = b.finish(post);
            },
            .do_stmt => |d| {
                const pre = b.newLabel(.loop);
                b.addAnte(pre, b.flow);
                const cont = b.newLabel(.branch);
                const post = b.newLabel(.branch);
                b.flow = pre.node.?;
                const save = b.loopLabels(post, cont);
                b.bindLoopBody(d.body);
                b.addAnte(cont, b.flow);
                b.brk = save[0];
                b.cont = save[1];
                b.flow = b.finish(cont);
                b.bindCond(d.cond, pre, post);
                _ = b.finish(pre);
                b.flow = b.finish(post);
            },
            .for_stmt => |d| {
                const save_block = b.block;
                b.block = n;
                if (d.init) |i| b.bind(i);
                const pre = b.newLabel(.loop);
                b.addAnte(pre, b.flow);
                const t = b.newLabel(.branch);
                const post = b.newLabel(.branch);
                const cont = b.newLabel(.branch);
                b.flow = pre.node.?;
                b.bindCond(d.cond, t, post);
                b.flow = b.finish(t);
                const save = b.loopLabels(post, cont);
                b.bindLoopBody(d.body);
                b.addAnte(cont, b.flow);
                b.brk = save[0];
                b.cont = save[1];
                b.flow = b.finish(cont);
                if (d.update) |u| b.bind(u);
                b.addAnte(pre, b.flow);
                _ = b.finish(pre);
                b.flow = b.finish(post);
                b.block = save_block;
            },
            .for_in => |d| b.bindForEach(n, d.init, d.expr, d.body),
            .for_of => |d| b.bindForEach(n, d.init, d.expr, d.body),
            .return_stmt => |d| {
                if (d.expr) |e| b.bind(e);
                if (b.ret) |r| b.addAnte(r, b.flow);
                b.flow = b.unreachable_flow;
            },
            .throw_stmt => |d| {
                b.bind(d.expr);
                b.flow = b.unreachable_flow;
            },
            .break_stmt => |d| {
                var target = b.brk;
                if (d.label) |l| {
                    var c = b.labels;
                    while (c) |x| : (c = x.parent) {
                        if (std.mem.eql(u8, x.name, l.data.identifier)) {
                            target = x.brk;
                            break;
                        }
                    }
                }
                if (target) |x| b.addAnte(x, b.flow);
                b.flow = b.unreachable_flow;
            },
            .continue_stmt => |d| {
                var target = b.cont;
                if (d.label) |l| {
                    var c = b.labels;
                    while (c) |x| : (c = x.parent) {
                        if (std.mem.eql(u8, x.name, l.data.identifier)) {
                            target = x.cont;
                            break;
                        }
                    }
                }
                if (target) |x| b.addAnte(x, b.flow);
                b.flow = b.unreachable_flow;
            },
            .labeled => |d| {
                const post = b.newLabel(.branch);
                const nl = b.temps.create(NamedLabel) catch oom();
                nl.* = .{ .name = d.label.data.identifier, .brk = post, .cont = null, .parent = b.labels };
                b.labels = nl;
                b.pending_label = nl;
                b.bind(d.stmt);
                b.pending_label = null;
                b.labels = nl.parent;
                b.addAnte(post, b.flow);
                b.flow = b.finish(post);
            },
            .switch_stmt => |d| b.bindSwitch(n, d.expr, d.clauses),
            .try_stmt => |d| b.bindTry(d.block, d.catch_clause, d.finally),
            .catch_clause => |d| {
                const save = b.block;
                b.block = n;
                if (d.decl) |decl| {
                    decl.parent = n;
                    b.bindVarDecl(decl, .let, .{});
                }
                b.bind(d.block);
                b.block = save;
            },
            .conditional => |d| {
                const t = b.newLabel(.branch);
                const f = b.newLabel(.branch);
                const end = b.newLabel(.branch);
                b.bindCond(d.cond, t, f);
                b.flow = b.finish(t);
                b.bind(d.then);
                b.addAnte(end, b.flow);
                b.flow = b.finish(f);
                b.bind(d.els);
                b.addAnte(end, b.flow);
                b.flow = b.finish(end);
            },
            .binary => |d| b.bindBinary(d.left, d.op, d.right),
            .prefix => |d| {
                b.bind(d.expr);
                if (d.op == .plus2 or d.op == .minus2) b.mutate(stripParens(d.expr));
            },
            .postfix => |d| {
                b.bind(d.expr);
                b.mutate(stripParens(d.expr));
            },
            .call => |d| {
                if (d.callee.data == .import_kw and d.args.len > 0) b.moduleSpec(d.args[0]);
                const saved = b.enterChain(n);
                const inlined = stripParens(d.callee).data == .func and !d.optional;
                if (!inlined) {
                    b.bind(d.callee);
                    if (d.optional) b.chainRest(d.callee);
                }
                // `f<typeof import('x')>()` is the only reference some modules get.
                for (d.type_args.items) |x| b.bind(x);
                for (d.args) |x| b.bind(x);
                // The arguments of a function run on the spot are evaluated before its body.
                if (inlined) b.bind(d.callee);
                n.setFlow(b.a, b.flow);
                b.leaveChain(n, saved);
                if (n.parent) |p| if (p.data == .expr_stmt and isDotted(d.callee)) {
                    b.flowEffect(.call, n);
                };
            },
            .new_expr => {
                b.bindChildren(n);
                n.setFlow(b.a, b.flow);
            },
            else => b.bindChildren(n),
        }
    }

    fn bindVarDecl(b: *Binder, decl: *Node, kind: ast.VarKind, mods: ast.Mods) void {
        const d = decl.data.var_decl;
        if (d.type) |t| b.bind(t);
        if (d.init) |i| b.bind(i);
        switch (d.name.data) {
            .identifier => |name| {
                if (name.len > 0) b.declareVar(decl, name, kind, mods);
                if (d.init != null and b.flow.kind != .unreachable_end) b.flowEffect(.assign, decl);
            },
            else => {
                b.bindPatternDecls(d.name, kind, mods);
                if (d.init != null and b.flow.kind != .unreachable_end) b.flowPattern(d.name);
            },
        }
    }

    fn flowPattern(b: *Binder, pat: *Node) void {
        const elems = switch (pat.data) {
            .object_pattern => |x| x.elems,
            .array_pattern => |x| x.elems,
            else => return,
        };
        for (elems) |el| {
            if (el.data != .binding_elem) continue;
            const be = el.data.binding_elem;
            if (be.name.data == .identifier) {
                b.flowEffect(.assign, el);
            } else b.flowPattern(be.name);
        }
    }

    fn bindForEach(b: *Binder, n: *Node, init_node: *Node, expr: *Node, body: *Node) void {
        const save_block = b.block;
        b.block = n;
        b.bind(expr);
        const pre = b.newLabel(.loop);
        b.addAnte(pre, b.flow);
        const post = b.newLabel(.branch);
        b.flow = pre.node.?;
        b.addAnte(post, b.flow);
        b.bind(init_node);
        if (init_node.data == .var_list) {
            for (init_node.data.var_list.decls) |decl| {
                const name = decl.data.var_decl.name;
                if (name.data == .identifier) {
                    b.flowEffect(.assign, decl);
                } else b.flowPattern(name);
            }
        } else b.bindTarget(init_node);
        if (n.data == .for_in and b.flow.kind != .unreachable_end and isNarrowing(expr)) {
            // Nothing is enumerated from a nullish object, so the body sees it present.
            const f = b.createFlow(.true_cond, expr, b.flow);
            f.present = true;
            b.flow = f;
        }
        const save = b.loopLabels(post, pre);
        b.bindLoopBody(body);
        b.addAnte(pre, b.flow);
        b.brk = save[0];
        b.cont = save[1];
        _ = b.finish(pre);
        b.flow = b.finish(post);
        b.block = save_block;
    }

    fn bindSwitch(b: *Binder, n: *Node, expr: *Node, clauses: []*Node) void {
        b.bind(expr);
        const post = b.newLabel(.branch);
        const save_brk = b.brk;
        b.brk = post;
        const pre_flow = b.flow;
        const save_block = b.block;
        b.block = n;
        var has_default = false;
        var fall: *FlowNode = b.unreachable_flow;
        for (clauses, 0..) |c, i| {
            const stmts = switch (c.data) {
                .case_clause => |x| x.stmts,
                .default_clause => |x| x.stmts,
                else => continue,
            };
            if (c.data == .default_clause) has_default = true;
            if (c.data == .case_clause) {
                b.flow = pre_flow;
                b.bind(c.data.case_clause.expr);
            }
            const entry = b.newLabel(.branch);
            const clause_flow = b.createFlow(.switch_clause, n, pre_flow);
            clause_flow.clause_start = @intCast(i);
            clause_flow.clause_end = @intCast(i + 1);
            b.addAnte(entry, clause_flow);
            b.addAnte(entry, fall);
            b.flow = b.finish(entry);
            b.bindList(stmts);
            fall = b.flow;
        }
        b.addAnte(post, fall);
        if (!has_default) {
            const none = b.createFlow(.switch_clause, n, pre_flow);
            none.clause_start = 0;
            none.clause_end = 0;
            b.addAnte(post, none);
        }
        b.block = save_block;
        b.brk = save_brk;
        b.flow = b.finish(post);
    }

    fn flowEffect(b: *Binder, kind: FlowKind, node: *Node) void {
        b.flow = b.createFlow(kind, node, b.flow);
        if (b.exc) |x| x.list.append(b.temps, b.flow) catch oom();
    }

    fn reduceFlow(b: *Binder, target: *FlowNode, list: []*FlowNode) *FlowNode {
        const f = b.createFlow(.reduce, null, b.flow);
        f.reduce_target = target;
        f.antecedents = b.a.dupe(*FlowNode, list) catch oom();
        return f;
    }

    fn bindTry(b: *Binder, block: *Node, catch_clause: ?*Node, finally: ?*Node) void {
        const save_ret = b.ret;
        const save_exc = b.exc;
        const normal = b.newLabel(.branch);
        const returns = b.newLabel(.branch);
        var exc = b.newLabel(.branch);
        if (finally != null) b.ret = returns;
        b.addAnte(exc, b.flow);
        b.exc = exc;
        b.bind(block);
        b.addAnte(normal, b.flow);
        if (catch_clause) |c| {
            b.flow = b.finish(exc);
            exc = b.newLabel(.branch);
            b.addAnte(exc, b.flow);
            b.exc = exc;
            b.bind(c);
            b.addAnte(normal, b.flow);
        }
        b.ret = save_ret;
        b.exc = save_exc;
        const f = finally orelse {
            b.flow = b.finish(normal);
            return;
        };
        const label = b.newLabel(.branch);
        for (normal.list.items) |x| b.addAnte(label, x);
        for (exc.list.items) |x| b.addAnte(label, x);
        for (returns.list.items) |x| b.addAnte(label, x);
        const join = b.labelNode(label);
        join.antecedents = b.a.dupe(*FlowNode, label.list.items) catch oom();
        b.flow = if (label.list.items.len > 0) join else b.unreachable_flow;
        b.bind(f);
        if (b.flow.kind == .unreachable_end) return;
        if (b.ret) |r| if (returns.list.items.len > 0) b.addAnte(r, b.reduceFlow(join, returns.list.items));
        if (b.exc) |x| if (exc.list.items.len > 0) b.addAnte(x, b.reduceFlow(join, exc.list.items));
        b.flow = if (normal.list.items.len > 0) b.reduceFlow(join, normal.list.items) else b.unreachable_flow;
    }

    /// `f.x = 1` beside `f`'s own declaration adds a member to the function.
    fn bindExpando(b: *Binder, left: *Node, right: *Node) void {
        const target, const name = switch (left.data) {
            .prop_access => |x| .{ x.expr, ast.memberText(x.name) },
            .elem_access => |x| switch (x.index.data) {
                .string_lit, .numeric_lit, .no_subst_template => .{ x.expr, b.propName(x.index).? },
                else => return b.bindLateExpando(left, x.expr, x.index),
            },
            else => return,
        };
        if (right.data == .object_lit and std.mem.eql(u8, name, "prototype")) return;
        var value = right;
        while (value.data == .binary and value.data.binary.op == .assign) value = value.data.binary.right;
        if (value.data == .void_expr) return;
        const s = b.expandoOwner(target) orelse return;
        if (s.exports == null) s.exports = b.table();
        _ = b.declare(s.exports.?, s, left, name, F.property | F.assignment, F.none, null);
    }

    /// In JavaScript, `this.x = 1` inside a class member declares `x` on the class.
    fn noteThisProperty(b: *Binder, left: *Node) void {
        if (!isJsPath(b.file.path)) return;
        switch (left.data) {
            .prop_access => |x| if (x.expr.data != .this_expr or x.name.data != .identifier) return,
            .elem_access => |x| switch (x.index.data) {
                .string_lit, .numeric_lit, .no_subst_template => if (x.expr.data != .this_expr) return,
                else => return,
            },
            else => return,
        }
        // Arrow functions see the `this` around them; any other function has its own.
        var prev = left;
        var cur = left.parent;
        while (cur) |x| : ({
            prev = x;
            cur = x.parent;
        }) switch (x.data) {
            .func => |f| {
                if (f.kind == .arrow) continue;
                const owner = x.parent orelse return;
                if (owner.data != .class) return;
                switch (f.kind) {
                    .ctor, .method, .getter, .setter => {},
                    else => return,
                }
                if (prev != f.body) return;
                return b.this_props.append(b.temps, .{ .left = left, .static = x.mods.static }) catch oom();
            },
            .static_block => return b.this_props.append(b.temps, .{ .left = left, .static = true }) catch oom(),
            .property_decl => |d| {
                if (prev != d.init) return;
                return b.this_props.append(b.temps, .{ .left = left, .static = x.mods.static }) catch oom();
            },
            .class, .source_file, .module_block => return,
            else => {},
        };
    }

    /// A member the class declares itself always wins over `this.x = 1`: tsc keeps the pattern
    /// `this.m = this.m.bind(this)` from clashing with the method `m`.
    fn declareThisProperty(b: *Binder, cls: *Node, left: *Node, static: bool) void {
        const sym = cls.symbol() orelse return;
        const name = switch (left.data) {
            .prop_access => |x| ast.memberText(x.name),
            .elem_access => |x| b.propName(x.index) orelse return,
            else => return,
        };
        const slot = if (static) &sym.exports else &sym.members;
        if (slot.* == null) slot.* = b.table();
        if (slot.*.?.get(name)) |s| if (!isThisProperty(s)) return;
        _ = b.declare(slot.*.?, sym, left, name, F.property | F.assignment, F.none, null);
    }

    /// `f[KEY] = 1`: only the checker can tell what name a constant holds.
    fn bindLateExpando(b: *Binder, left: *Node, target: *Node, key: *Node) void {
        if (!isEntityName(key)) return;
        const s = b.expandoOwner(target) orelse return;
        const late = b.mkSym("__computed", 0);
        late.parent = s;
        b.addDecl(late, left, F.property | F.assignment);
        const rare = s.rareParts(b.a);
        rare.late_members = append(b.a, rare.late_members, late);
    }

    fn expandoOwner(b: *Binder, target: *Node) ?*Symbol {
        const s = b.accessSymbol(target, b.block) orelse b.accessSymbol(target, b.container) orelse return null;
        return if (holdsExpandos(s)) s else null;
    }

    /// The symbol `x` of `x` or `x.y` as seen from `scope`, before any name resolution exists.
    fn accessSymbol(b: *const Binder, n: *Node, scope: *Node) ?*Symbol {
        switch (n.data) {
            .identifier => |name| {
                if (b.scopeOf(scope)) |l| if (l.get(name)) |s| return s;
                // A function's exports are its expandos, in the frozen tree and not in scope anyway.
                if (scope == b.frozen) return null;
                const owner = scope.symbol() orelse return null;
                return (owner.exports orelse return null).get(name);
            },
            .prop_access => |x| {
                const owner = b.accessSymbol(x.expr, scope) orelse return null;
                return (owner.exports orelse return null).get(ast.memberText(x.name));
            },
            else => return null,
        }
    }

    fn bindBinary(b: *Binder, left: *Node, op: lexer.Tok, right: *Node) void {
        switch (op) {
            .amp2, .pipe2, .qq, .amp2_assign, .pipe2_assign, .qq_assign => {
                const t = b.newLabel(.branch);
                const f = b.newLabel(.branch);
                const end = b.newLabel(.branch);
                b.bind(left);
                const is_and = op == .amp2 or op == .amp2_assign;
                b.addAnte(t, b.condFlow(.true_cond, b.flow, left));
                b.addAnte(f, b.condFlow(.false_cond, b.flow, left));
                b.flow = b.finish(if (is_and) t else f);
                b.bind(right);
                if (op == .amp2_assign or op == .pipe2_assign or op == .qq_assign) b.mutate(stripParens(left));
                b.addAnte(end, b.flow);
                b.addAnte(end, b.finish(if (is_and) f else t));
                b.flow = b.finish(end);
            },
            else => {
                b.bind(left);
                b.bind(right);
                if (op.isAssignment()) {
                    if (op == .assign) b.bindTarget(left) else b.mutate(stripParens(left));
                    if (op == .assign) b.bindExpando(left, right);
                    if (op == .assign) b.noteThisProperty(left);
                }
            },
        }
    }
};

/// Grows by doubling without a stored capacity: a list built here always has room for the next
/// power of two, so an in-place store is safe until the length reaches one. Lists written by
/// anyone else (the project merge concatenates them) are never appended to afterwards.
fn append(a: Allocator, list: anytype, s: @typeInfo(@TypeOf(list)).pointer.child) @TypeOf(list) {
    if (list.len == 0 or std.math.isPowerOfTwo(list.len)) {
        const out = a.alloc(@typeInfo(@TypeOf(list)).pointer.child, if (list.len == 0) 1 else list.len * 2) catch oom();
        @memcpy(out[0..list.len], list);
        out[list.len] = s;
        return out[0 .. list.len + 1];
    }
    list.ptr[list.len] = s;
    return list.ptr[0 .. list.len + 1];
}

/// tsc stores `1.0`, `0x10` and `1_000` as the number they denote, so `{ 1.0: T }` and `x[1]` meet.
fn numericName(a: Allocator, raw: []const u8) []const u8 {
    // A literal too large to parse keeps its spelling: as `0` it would collide with a real `0` member.
    return decls.numNameAlloc(a, emit.parseNumber(raw) orelse return raw);
}

pub fn specName(n: *Node) []const u8 {
    return switch (n.data) {
        .identifier, .string_lit => |v| v,
        else => "",
    };
}

const ThisProp = struct { left: *Node, static: bool };

fn isJsPath(path: []const u8) bool {
    return @import("project.zig").isJs(path);
}

/// Declared by nothing but `this.x = ...` assignments.
pub fn isThisProperty(s: *const Symbol) bool {
    if (s.decls.len == 0) return false;
    for (s.decls) |d| {
        const obj = switch (d.data) {
            .prop_access => |x| x.expr,
            .elem_access => |x| x.expr,
            else => return false,
        };
        if (obj.data != .this_expr) return false;
    }
    return true;
}

/// `let` and `var` can be reassigned, so only a function or a `const` holding one takes members.
pub fn holdsExpandos(s: *Symbol) bool {
    const n = s.value_decl orelse return false;
    switch (n.data) {
        .func => return s.flags & F.function != 0,
        .var_decl => |v| {
            const value = v.init orelse return false;
            if (value.data != .func) return false;
            const list = n.parent orelse return false;
            return list.data == .var_list and list.data.var_list.kind != .let and list.data.var_list.kind != .@"var";
        },
        else => return false,
    }
}

/// The variable whose expandos belong to the function expression it was initialized with.
pub fn expandoHolder(func: *Node) ?*Symbol {
    const v = func.parent orelse return null;
    if (v.data != .var_decl or v.data.var_decl.init != func) return null;
    return v.symbol();
}

pub fn calledOnTheSpot(fnode: *Node) bool {
    return callOnTheSpot(fnode) != null;
}

pub fn callOnTheSpot(fnode: *Node) ?*Node {
    if (fnode.data != .func or (fnode.data.func.kind != .arrow and fnode.data.func.kind != .expr)) return null;
    var callee = fnode;
    var p = fnode.parent;
    while (p) |x| : (p = x.parent) {
        if (x.data != .paren) return if (x.data == .call and x.data.call.callee == callee) x else null;
        callee = x;
    }
    return null;
}

/// Parentheses alone: unlike `stripParens` this keeps an assertion, which changes the type.
pub fn skipParens(n: *Node) *Node {
    var x = n;
    while (x.data == .paren) x = x.data.paren.expr;
    return x;
}

pub fn stripParens(n: *Node) *Node {
    var c = n;
    while (true) switch (c.data) {
        .paren => |x| c = x.expr,
        .non_null => |x| c = x.expr,
        .as_expr => |x| c = x.expr,
        .satisfies_expr => |x| c = x.expr,
        .type_assertion => |x| c = x.expr,
        else => return c,
    };
}

fn isDotted(n: *Node) bool {
    return switch (n.data) {
        .identifier, .this_expr, .super_expr => true,
        .prop_access => |x| isDotted(x.expr),
        .paren => |x| isDotted(x.expr),
        .non_null => |x| isDotted(x.expr),
        else => false,
    };
}

pub fn isReference(n: *Node) bool {
    return switch (n.data) {
        .identifier, .this_expr, .super_expr => true,
        .prop_access => |x| isReference(x.expr),
        .elem_access => |x| isReference(x.expr),
        .paren => |x| isReference(x.expr),
        .non_null => |x| isReference(x.expr),
        else => false,
    };
}

fn isLogicalExpr(n: *Node) bool {
    return switch (n.data) {
        .paren => |x| isLogicalExpr(x.expr),
        .prefix => |x| x.op == .bang and isLogicalExpr(x.expr),
        .binary => |x| x.op == .amp2 or x.op == .pipe2 or x.op == .qq,
        else => false,
    };
}

fn isNarrowing(n: *Node) bool {
    return switch (n.data) {
        .identifier, .this_expr, .super_expr, .prop_access, .elem_access, .call, .typeof_expr, .delete_expr, .await_expr, .as_expr, .satisfies_expr, .type_assertion => true,
        .paren => |x| isNarrowing(x.expr),
        .non_null => |x| isNarrowing(x.expr),
        .prefix => |x| x.op == .bang and isNarrowing(x.expr),
        .binary => |x| switch (x.op) {
            .eq2, .neq, .eq3, .neq3, .kw_instanceof, .kw_in, .assign, .amp2, .pipe2, .qq => true,
            else => false,
        },
        else => false,
    };
}

pub fn nameNode(n: *Node) ?*Node {
    return switch (n.data) {
        .func => |f| f.name,
        .class => |c| c.name,
        .interface => |d| d.name,
        .type_alias => |d| d.name,
        .enum_decl => |d| d.name,
        .enum_member => |d| d.name,
        .module_decl => |d| d.name,
        .var_decl => |d| d.name,
        .binding_elem => |d| d.name,
        .param => |d| d.name,
        .property_decl => |d| d.name,
        .property_sig => |d| d.name,
        .type_param => |d| d.name,
        .import_spec => |d| d.name,
        .export_spec => |d| d.name,
        .import_clause => |d| d.name,
        .namespace_import => |d| d.name,
        .import_equals => |d| d.name,
        else => null,
    };
}

/// Binds one file. Touches only that file, so files bind in parallel.
pub fn bindFile(a: Allocator, f: *ast.File) void {
    var temps = std.heap.ArenaAllocator.init(a);
    defer temps.deinit();
    const unreachable_flow = a.create(FlowNode) catch oom();
    unreachable_flow.* = .{ .kind = .unreachable_end };
    const start = a.create(FlowNode) catch oom();
    start.* = .{ .kind = .start };
    var b = Binder{
        .a = a,
        .temps = temps.allocator(),
        .file = f,
        .container = f.root,
        .block = f.root,
        .flow = start,
        .unreachable_flow = unreachable_flow,
        .in_ambient = f.is_dts,
    };
    if (f.is_module) f.root.setSymbol(b.a, b.fileSym());
    if (f.root.locals() == null) f.root.setLocals(b.a, b.table());
    b.export_context = f.is_dts and !Binder.hasExportStatements(f.root.data.source_file.stmts);
    b.bindList(f.root.data.source_file.stmts);
    f.bind_diags = b.diags.items;
    f.dead = b.dead.items;
}

/// tsc's `isPotentiallyExecutableNode`. Blocks, empty statements and functions are not.
/// tsc's `FirstStatement`..`LastStatement`: the nodes whose entry flow the checker can ask about.
pub fn isStatement(n: *Node) bool {
    return switch (n.data) {
        .var_stmt, .expr_stmt, .if_stmt, .do_stmt, .while_stmt, .for_stmt, .for_in, .for_of, .continue_stmt, .break_stmt, .return_stmt, .with_stmt, .switch_stmt, .labeled, .throw_stmt, .try_stmt, .debugger_stmt => true,
        else => false,
    };
}

fn isPotentiallyExecutable(n: *Node) bool {
    return switch (n.data) {
        .expr_stmt, .if_stmt, .do_stmt, .while_stmt, .for_stmt, .for_in, .for_of, .continue_stmt, .break_stmt, .return_stmt, .with_stmt, .switch_stmt, .labeled, .throw_stmt, .try_stmt, .debugger_stmt, .enum_decl, .module_decl => true,
        .class => |k| !k.is_expr,
        .var_stmt => |x| x.list.data.var_list.kind != .@"var" or for (x.list.data.var_list.decls) |v| {
            if (v.data.var_decl.init != null) break true;
        } else false,
        else => false,
    };
}

/// Binds a block `parser.parseBody` read, for one checker: everything it creates lives in `a`,
/// and the file, the function and whatever else is outside the block stay as they are.
pub fn bindBody(a: Allocator, f: *ast.File, n: *Node, block: *Node) struct { body: Body, diags: []lexer.Diag } {
    var temps = std.heap.ArenaAllocator.init(a);
    defer temps.deinit();
    const unreachable_flow = a.create(FlowNode) catch oom();
    unreachable_flow.* = .{ .kind = .unreachable_end };
    var b = Binder{
        .a = a,
        .temps = temps.allocator(),
        .file = f,
        .container = n,
        .block = n,
        .flow = n.data.func.body.?.flow().?,
        .unreachable_flow = unreachable_flow,
        .frozen = n,
    };
    b.bindList(block.data.block.stmts);
    return .{
        .body = .{ .block = block, .end_flow = if (b.flow.kind == .unreachable_end) null else b.flow, .locals = b.scopeOf(n), .dead = b.dead.items },
        .diags = b.diags.items,
    };
}

/// Merged namespaces see each other's exports, but `export { X }` puts nothing in scope: inside
/// `namespace S { export { S } }` the name still means the outer `S`, not the alias itself.
pub fn isExportSpecifierOnly(s: *const Symbol) bool {
    if (s.flags != F.alias) return false;
    for (s.decls) |d| if (d.data == .export_spec or d.data == .namespace_export) return true;
    return false;
}

/// Scope lookup inside one file: enough for the emitter, which needs no global merge.
pub fn lookupLocal(from: *Node, name: []const u8, meaning: u32) ?*Symbol {
    var c: ?*Node = from;
    while (c) |n| : (c = n.parent) {
        if (n.locals()) |l| if (l.get(name)) |s| {
            if (s.flags & (meaning | F.alias) != 0) return s;
        };
        switch (n.data) {
            .module_decl, .enum_decl => if (n.symbol()) |s| if (s.exports) |e| if (e.get(name)) |x| {
                if (!isExportSpecifierOnly(x) and x.flags & (meaning | F.alias) != 0) return x;
            },
            else => {},
        }
    }
    return null;
}

test "binder declares and merges function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parser.parse(a, "t.ts", "export function f(x: number) { var y = x; let z; { let z; } }\ninterface I {a: 1}\ninterface I {b: 2}\n");
    bindFile(a, f);
    try std.testing.expectEqual(@as(usize, 0), f.bind_diags.len);
    const i = f.root.locals().?.get("I").?;
    try std.testing.expectEqual(@as(usize, 2), i.decls.len);
    try std.testing.expect(i.members.?.get("b") != null);
    try std.testing.expect(f.symbol.?.exports.?.get("f") != null);
}

test "binder stores numeric member names the way lookups spell them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parser.parse(a, "t.ts", "interface I { 1.0: string; 0x10: number; 1e3: boolean; 2_000: symbol; [3.0]: bigint }\nclass C { 1.0 = 1; static 0x10 = 2 }\n");
    bindFile(a, f);
    try std.testing.expectEqual(@as(usize, 0), f.bind_diags.len);
    const i = f.root.locals().?.get("I").?.members.?;
    for ([_][]const u8{ "1", "16", "1000", "2000", "3" }) |name| try std.testing.expect(i.get(name) != null);
    try std.testing.expect(i.get("1.0") == null);
    const c = f.root.locals().?.get("C").?;
    try std.testing.expect(c.members.?.get("1") != null);
    try std.testing.expect(c.exports.?.get("16") != null);
}

test "binder grows declaration lists in order and keeps the duplicate's value declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..9) |_| src.appendSlice(a, "interface I {}\n") catch unreachable;
    src.appendSlice(a, "let x = 1;\nlet x = 2;\n") catch unreachable;
    const f = parser.parse(a, "t.ts", src.items);
    bindFile(a, f);
    const i = f.root.locals().?.get("I").?;
    try std.testing.expectEqual(@as(usize, 9), i.decls.len);
    for (i.decls, f.root.data.source_file.stmts[0..9]) |d, s| try std.testing.expectEqual(s, d);
    const second = f.root.data.source_file.stmts[10].data.var_stmt.list.data.var_list.decls[0];
    try std.testing.expect(second.symbol() != null);
    try std.testing.expect(second.symbol().? != f.root.locals().?.get("x").?);
    try std.testing.expectEqual(second, second.symbol().?.value_decl.?);
    try std.testing.expect(second.symbol().?.flags & F.block_var != 0);
}

test "a body redeclaring a parameter leaves the shared symbol alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parser.parseLazily(a, "t.ts", "function f(x: string) { var x: string; function g() {} g.y = 1; }");
    bindFile(a, f);
    const n = f.root.data.source_file.stmts[0];
    const shared = n.locals().?.get("x").?;
    const bound = bindBody(a, f, n, parser.parseBody(a, f, n).block);
    try std.testing.expectEqual(@as(usize, 1), shared.decls.len);
    const own = bound.body.locals.?.get("x").?;
    try std.testing.expect(own != shared);
    try std.testing.expectEqual(@as(usize, 2), own.decls.len);
    try std.testing.expect(own.decls[0] == shared.decls[0]);
    try std.testing.expect(n.locals().?.get("g") == null);
    try std.testing.expect(bound.body.locals.?.get("g") != null);
}

test "a body cannot reach a file's module lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parser.parseLazily(a, "t.ts", "function f() { import('./a'); }");
    bindFile(a, f);
    try std.testing.expectEqual(@as(usize, 1), f.module_specs.len);
    const n = f.root.data.source_file.stmts[0];
    _ = bindBody(a, f, n, parser.parseBody(a, f, n).block);
    try std.testing.expectEqual(@as(usize, 1), f.module_specs.len);
}

test "flow labels preserve loop identity and simplify branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = parser.parse(a, "t.ts", "");
    var dead = FlowNode{ .kind = .unreachable_end };
    var first = FlowNode{ .kind = .start };
    var second = FlowNode{ .kind = .assign, .antecedent = &first };
    var b = Binder{ .a = a, .temps = a, .file = file, .container = file.root, .block = file.root, .flow = &first, .unreachable_flow = &dead };
    const branch = b.newLabel(.branch);
    try std.testing.expectEqual(&dead, b.finish(branch));
    b.addAnte(branch, &first);
    b.addAnte(branch, &first);
    try std.testing.expectEqual(&first, b.finish(branch));
    try std.testing.expect(branch.node == null);
    b.addAnte(branch, &second);
    const join = b.finish(branch);
    try std.testing.expectEqual(FlowKind.branch, join.kind);
    try std.testing.expectEqualSlices(*FlowNode, &.{ &first, &second }, join.antecedents);
    const loop = b.newLabel(.loop);
    const head = loop.node.?;
    try std.testing.expectEqual(head, b.finish(loop));
    b.addAnte(loop, &first);
    b.addAnte(loop, head);
    try std.testing.expectEqual(head, b.finish(loop));
    try std.testing.expectEqualSlices(*FlowNode, &.{ &first, head }, head.antecedents);
}

test "flow edges survive reuse of temporary binding storage" {
    const Bump = @import("bump.zig").Bump;
    var bump = Bump.init(std.testing.allocator);
    defer bump.deinit();
    const a = bump.allocator();
    const f = parser.parse(a, "t.ts", "function f(x: number) { let y = 0; while (x > 0) { try { if (x === 2) break; y = x; } finally { x--; } } return y; }");
    bindFile(a, f);
    const stmts = f.root.data.source_file.stmts[0].data.func.body.?.data.block.stmts;
    const root = stmts[stmts.len - 1].data.return_stmt.expr.?.flow().?;
    for (0..128) |_| @memset(try a.alloc(u8, 256), 0);
    var seen: std.AutoHashMapUnmanaged(*FlowNode, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var pending: std.ArrayList(*FlowNode) = .empty;
    defer pending.deinit(std.testing.allocator);
    try pending.append(std.testing.allocator, root);
    var loop = false;
    var reduction = false;
    while (pending.pop()) |node| {
        if ((try seen.getOrPut(std.testing.allocator, node)).found_existing) continue;
        loop = loop or node.kind == .loop;
        reduction = reduction or node.kind == .reduce;
        if (node.antecedent) |ante| try pending.append(std.testing.allocator, ante);
        if (node.reduce_target) |target| try pending.append(std.testing.allocator, target);
        try pending.appendSlice(std.testing.allocator, node.antecedents);
    }
    try std.testing.expect(loop and reduction);
    try std.testing.expect(seen.count() > 8);
}
