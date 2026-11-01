//! The type model and the per-thread `Checker`. Every type belongs to one checker: types are
//! never shared across threads, which is what lets files be checked in parallel without locks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const project = @import("project.zig");
const relate = @import("relate.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;

pub fn oom() noreturn {
    @panic("out of memory");
}

pub const StrMapKind = enum { upper, lower, capitalize, uncapitalize };

pub const EnumValue = union(enum) { num: f64, str: []const u8, none };

pub const EnumLit = struct { sym: *Symbol, parent: *Symbol, value: EnumValue };

pub const Tmpl = struct { texts: []const []const u8, types: []*Type };

pub const Alias = struct { sym: *Symbol, args: []*Type };

/// The two largest variants sit behind pointers: every type pays for the widest one.
pub const Data = union(enum) {
    any,
    /// `any` that came from a failure or from something the checker does not model: never reported on.
    err,
    unknown,
    never,
    void,
    undefined,
    null,
    string,
    number,
    bigint,
    symbol,
    nonprim,
    str_lit: []const u8,
    num_lit: f64,
    big_lit: []const u8,
    bool_lit: bool,
    unique: *Symbol,
    enum_lit: *const EnumLit,
    enum_: *Symbol,
    union_: []*Type,
    inter: []*Type,
    obj: *Obj,
    param: *TParam,
    keyof: *Type,
    access: struct { obj: *Type, index: *Type },
    cond: *Cond,
    tmpl: *const Tmpl,
    /// `NoInfer<T>`: only ever generic, a concrete argument unwraps on instantiation.
    noinfer: *Type,
    strmap: struct { kind: StrMapKind, ty: *Type },
};

/// For `std.sort.binarySearch` over a list sorted by id, as union members are.
pub fn compareId(id: u32, t: *Type) std.math.Order {
    return std.math.order(id, t.id);
}

pub const Type = struct {
    id: u32,
    data: Data,
    /// May mention a type variable, so instantiation has to look inside.
    vars: bool = false,
    alias: ?*Alias = null,
    /// On a fresh literal or fresh object literal: the same type without freshness.
    regular: ?*Type = null,
    fresh: ?*Type = null,
    is_boolean: bool = false,
    enum_sym: ?*Symbol = null,
};

pub const TParam = struct {
    sym: ?*Symbol = null,
    name: []const u8,
    constraint: ?*Type = null,
    constraint_done: bool = false,
    default: ?*Type = null,
    default_done: bool = false,
    is_this: bool = false,
    decl: ?*Node = null,
    is_const: bool = false,
    /// A fresh parameter cloned from `target` for a generic signature's instantiation.
    mapper: ?*Mapper = null,
    target: ?*Type = null,
};

pub const ObjKind = enum { iface, ref, anon, tuple, mapped };

pub const ElemFlag = enum { required, optional, rest, variadic };

/// What a declared class or interface adds. Objects run to the millions and declarations to the
/// thousands, so this stays out of `Obj`.
pub const Iface = struct {
    tparams: []*Type = &.{},
    local_tparams: []*Type = &.{},
    this_type: ?*Type = null,
    bases: ?[]*Type = null,
};

pub const Tuple = struct {
    elems: []*Type = &.{},
    eflags: []ElemFlag = &.{},
    names: []const ?[]const u8 = &.{},
};

const no_tuple: Tuple = .{};

pub const Obj = struct {
    kind: ObjKind,
    sym: ?*Symbol = null,
    node: ?*Node = null,
    is_class: bool = false,
    iface: ?*Iface = null,
    bases_resolving: bool = false,
    any_base: bool = false,
    target: ?*Type = null,
    args: ?[]*Type = null,
    this_arg: ?*Type = null,
    mapper: ?*Mapper = null,
    tuple: *const Tuple = &no_tuple,
    readonly: bool = false,
    members: ?*Members = null,
    resolving: bool = false,
    lit: bool = false,
    /// Written as an object literal, fresh or not.
    was_lit: bool = false,
    /// Where the literal stands, which decides the type parameters an instantiation can touch.
    literal: ?*Node = null,
    /// Holds a lambda that inference has not reached yet.
    non_inferrable: bool = false,
    /// Built from a JS-side spread or a computed key, so absent properties prove nothing.
    open: bool = false,
    /// A spread brings properties nobody wrote here, so excess property checks do not apply.
    spread: bool = false,
    /// Reversed from a declared type, which has no implicit index signature to pass on.
    closed: bool = false,

    pub fn tparams(o: *const Obj) []*Type {
        return if (o.iface) |i| i.tparams else &.{};
    }

    pub fn localTparams(o: *const Obj) []*Type {
        return if (o.iface) |i| i.local_tparams else &.{};
    }

    pub fn thisType(o: *const Obj) ?*Type {
        return if (o.iface) |i| i.this_type else null;
    }
};

pub const PendingConstraint = struct { nodes: []*Node, params: []*Type, args: []*Type };

pub const CondBranches = struct { then: ?*Type = null, els: ?*Type = null };

pub const Cond = struct {
    node: *Node,
    check: *Type,
    extends: *Type,
    /// Shared by every copy. Built on first use, because a branch may name the alias being declared.
    branches: *CondBranches,
    distributive: bool,
    infer_params: []*Type,
    outer: []*Type,
    mapper: ?*Mapper = null,
    instantiated_check: ?*Type = null,
    then_inst: ?*Type = null,
    els_inst: ?*Type = null,
    default_constraint: ?*Type = null,
};

pub const Prop = struct {
    name: []const u8,
    sym: ?*Symbol = null,
    ty: ?*Type = null,
    mapper: ?*Mapper = null,
    optional: bool = false,
    readonly: bool = false,
    method: bool = false,
    private: bool = false,
    protected: bool = false,
    abstract: bool = false,
    static: bool = false,
    decl: ?*Node = null,
    /// Lazily computed members of a mapped type carry their key here.
    mapped_key: ?*Type = null,
    mapped_owner: ?*Type = null,
    /// `-?` takes `undefined` off only the properties that had the `?`.
    mapped_required: bool = false,
    owner: ?*Type = null,
    /// The uninstantiated property, for ones with no symbol of their own to go back to.
    origin: ?*Prop = null,
    /// Union property that some constituents lack; only readable through narrowing.
    partial: bool = false,
};

pub const Index = struct { key: *Type, ty: *Type, readonly: bool = false, decl: ?*Node = null };

pub const Members = struct {
    props: PropTable = .empty,
    calls: []*Sig = &.{},
    ctors: []*Sig = &.{},
    indexes: []Index = &.{},
};

pub const SigParam = struct {
    name: []const u8,
    ty: ?*Type = null,
    sym: ?*Symbol = null,
    optional: bool = false,
};

pub const Pred = struct { asserts: bool, param_index: i32, is_this: bool, ty: ?*Type, name: []const u8 };

pub const Sig = struct {
    decl: ?*Node = null,
    tparams: []*Type = &.{},
    params: []SigParam = &.{},
    has_rest: bool = false,
    min_args: u32 = 0,
    ret: ?*Type = null,
    ret_resolving: bool = false,
    this_ty: ?*Type = null,
    pred: ?*Pred = null,
    pred_done: bool = false,
    /// What a union's call signature was combined from; its predicate is worked out on demand.
    composite: []*Sig = &.{},
    target: ?*Sig = null,
    mapper: ?*Mapper = null,
    erased: ?*Sig = null,
    shape: ?*Sig = null,
    base: ?*Sig = null,
    is_ctor: bool = false,
    abstract: bool = false,
};

/// Maps from pointers and ids sit on every hot path of the checker, and their keys are already
/// unique integers, so one multiply mixes them as well as wyhash does at a fraction of the cost.
fn IdContext(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), k: K) u64 {
            const v: u64 = if (@typeInfo(K) == .pointer) @intFromPtr(k) >> 3 else k;
            const h = v *% 0x9e3779b97f4a7c15;
            return h ^ (h >> 32);
        }

        pub fn eql(_: @This(), l: K, r: K) bool {
            return l == r;
        }
    };
}

pub fn IdMap(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, IdContext(K), 80);
}

const PropContext = struct {
    pub fn hash(_: PropContext, name: []const u8) u32 {
        return @truncate(binder.NameContext.hashOf(name));
    }

    pub fn eql(_: PropContext, l: []const u8, r: []const u8, _: usize) bool {
        return std.mem.eql(u8, l, r);
    }
};

pub const PropTable = std.ArrayHashMapUnmanaged([]const u8, *Prop, PropContext, true);

/// Keys are short and nearly all ids, which wyhash spends far more time on than they need.
pub const IdsContext = struct {
    pub fn hash(_: IdsContext, key: []const u32) u64 {
        var h: u64 = key.len;
        for (key) |x| h = (std.math.rotl(u64, h, 5) ^ x) *% 0x517cc1b727220a95;
        return h ^ (h >> 32);
    }

    pub fn eql(_: IdsContext, l: []const u32, r: []const u32) bool {
        return std.mem.eql(u32, l, r);
    }
};

pub const InternMap = std.HashMapUnmanaged([]const u32, *Type, IdsContext, 80);

pub const Mapper = union(enum) {
    /// `to` is as long as `from` or longer.
    array: struct { from: []*Type, to: [*]*Type },
    composite: struct { m1: *Mapper, m2: *Mapper },
    infer: *InferCtx,
    erase,
};

pub const Priority = struct {
    pub const naked_var: u32 = 1 << 0;
    pub const speculative: u32 = 1 << 1;
    pub const homomorphic: u32 = 1 << 3;
    pub const partial_homomorphic: u32 = 1 << 4;
    pub const mapped_constraint: u32 = 1 << 5;
    pub const contravariant_conditional: u32 = 1 << 6;
    pub const return_type: u32 = 1 << 7;
    pub const literal_keyof: u32 = 1 << 8;
    pub const always_strict: u32 = 1 << 10;
    pub const max: u32 = 1 << 11;
};

pub const InferInfo = struct {
    param: *Type,
    candidates: std.ArrayList(*Type) = .empty,
    contra: std.ArrayList(*Type) = .empty,
    priority: u32 = Priority.max,
    top_level: bool = true,
    fixed: bool = false,
    inferred: ?*Type = null,
};

pub const InferCtx = struct {
    infos: []InferInfo,
    mapper: *Mapper,
    /// Fixes nothing: used while still gathering inferences for a contextual type.
    non_fixing: *Mapper,
    /// Like `non_fixing`, but a parameter without candidates stays open instead of defaulting.
    no_default: *Mapper,
    is_return: bool = false,
    /// For `infer` in a conditional type, where a generic source is exact rather than a stopgap.
    conditional: bool = false,
    return_mapper: ?*Mapper = null,
    /// The signature's return type: a parameter at its top keeps literals for the caller.
    ret: ?*Type = null,
    /// What the arguments wrote as array literals: an interned type does not remember it.
    array_lits: std.AutoHashMapUnmanaged(*Type, void) = .empty,
};

pub const Diag = struct { file: *ast.File, start: u32, len: u32, code: u32, msg: []const u8 };

pub const Relation = enum { assignable, comparable, identity, subtype, strict_subtype };

pub const flow_untouched = std.math.maxInt(u32);

pub const Checker = struct {
    a: Allocator,
    prog: *project.Program,
    next_id: u32 = 1,
    enum_eval_depth: u32 = 0,
    strict_null: bool,
    no_implicit_any: bool,
    strict_fn: bool,
    strict_prop_init: bool,
    no_implicit_this: bool,
    unknown_in_catch: bool,
    bind_call_apply: bool,
    exact_optional: bool,
    no_unchecked_index: bool,

    t_any: *Type = undefined,
    /// The declared type of a property that only assignments in the constructor give a type.
    t_auto: *Type = undefined,
    t_err: *Type = undefined,
    /// A `t_err` that stands for a name already reported as missing, not for something the checker
    /// cannot model: it is known to say nothing, while the other one might have said something.
    t_unresolved: *Type = undefined,
    t_unknown: *Type = undefined,
    t_never: *Type = undefined,
    /// An outer parameter nothing has voted on yet; inference ignores it as a source.
    t_silent_never: *Type = undefined,
    t_void: *Type = undefined,
    t_undefined: *Type = undefined,
    t_null: *Type = undefined,
    t_string: *Type = undefined,
    t_number: *Type = undefined,
    t_bigint: *Type = undefined,
    t_symbol: *Type = undefined,
    t_nonprim: *Type = undefined,
    t_true: *Type = undefined,
    t_false: *Type = undefined,
    t_boolean: *Type = undefined,
    t_empty: *Type = undefined,
    t_key: *Type = undefined,
    /// The result of the `typeof` operator.
    t_typeof: *Type = undefined,
    /// A distinct `never` for points flow analysis cannot reach, which must not look like narrowing.
    t_unreachable: *Type = undefined,
    /// Stands for a context-sensitive function while inference skips it.
    t_pending_fn: *Type = undefined,

    global_array: ?*Type = null,
    global_readonly_array: ?*Type = null,
    global_cache: std.StringHashMapUnmanaged(?*Type) = .empty,

    str_lits: std.StringHashMapUnmanaged(*Type) = .empty,
    big_lits: std.StringHashMapUnmanaged(*Type) = .empty,
    num_lits: IdMap(u64, *Type) = .empty,
    interned: InternMap = .empty,
    key_buf: std.ArrayList(u32) = .empty,
    visited_pool: std.ArrayList(IdMap(u64, i64)) = .empty,
    skip_patterns: u32 = 0,
    never_reduced: std.AutoHashMapUnmanaged(*Type, bool) = .empty,
    /// Every property of a literal asks for the context of the literal, which may be a large union.
    discriminated: std.AutoHashMapUnmanaged(struct { *Node, *Type }, *Type) = .empty,
    union_in: std.ArrayList(*Type) = .empty,
    union_out: std.ArrayList(*Type) = .empty,
    uniques: IdMap(*Symbol, *Type) = .empty,

    sym_types: IdMap(*Symbol, *Type) = .empty,
    sym_resolving: IdMap(*Symbol, void) = .empty,
    write_types: IdMap(*Symbol, *Type) = .empty,
    declared: IdMap(*Symbol, *Type) = .empty,
    declared_resolving: IdMap(*Symbol, void) = .empty,
    node_types: IdMap(*Node, *Type) = .empty,
    node_resolving: IdMap(*Node, void) = .empty,
    node_tparams: IdMap(*Node, []*Type) = .empty,
    node_refs: IdMap(*Node, []*Type) = .empty,
    sig_of_decl: IdMap(*Node, *Sig) = .empty,
    sig_list: IdMap(*Symbol, []*Sig) = .empty,
    ctor_list: IdMap(*Symbol, []*Sig) = .empty,
    alias_params: IdMap(*Symbol, []*Type) = .empty,
    apparent_cache: IdMap(*Type, *Type) = .empty,
    resolved_calls: IdMap(*Node, *Sig) = .empty,
    call_results: IdMap(*Node, *Type) = .empty,
    name_syms: IdMap(*Node, ?*Symbol) = .empty,
    const_keys: IdMap(*Node, ?[]const u8) = .empty,
    binding_busy: IdMap(*Node, void) = .empty,
    checked_funcs: IdMap(*Node, void) = .empty,
    /// A lambda's parameters get their contextual types once, from the first signature to reach it.
    context_assigned: IdMap(*Node, void) = .empty,
    context_assigning: IdMap(*Node, void) = .empty,
    param_types: IdMap(*Node, *Type) = .empty,
    param_init_undefined: IdMap(*Node, bool) = .empty,
    relation_cache: [5]IdMap(u64, bool) = .{ .empty, .empty, .empty, .empty, .empty },
    relation_active: IdMap(u64, void) = .empty,
    variances: IdMap(*Type, []relate.Variance) = .empty,
    variance_busy: IdMap(*Type, void) = .empty,
    /// The instantiations a measurement compares: these go through their members, unlike every
    /// other reference to the type being measured.
    variance_markers: IdMap(*Type, void) = .empty,
    /// Bumped each time a relation answers on behalf of a measurement still in progress.
    relation_unknown: u32 = 0,
    relation_depth: u32 = 0,
    /// Where the stacks of the question being answered start.
    relation_base: u32 = 0,
    relation_sources: [80]*Type = undefined,
    relation_targets: [80]*Type = undefined,
    /// Bit 0: the source side is unfolding a recursive declaration, bit 1: the target side.
    relation_expanding: u2 = 0,
    instantiation_depth: u32 = 0,
    instantiation_cache: InternMap = .empty,
    keyof_cache: IdMap(*Type, *Type) = .empty,
    cond_depth: u32 = 0,
    cond_relating: u32 = 0,
    instantiation_count: u32 = 0,
    /// End of the last assignment to a binding, as a source offset.
    assigned_syms: IdMap(*Symbol, u32) = .empty,
    assigned_files: IdMap(*ast.File, void) = .empty,
    /// Contextual types pushed for an expression that is being checked against a candidate.
    ctx_stack: std.ArrayList(CtxEntry) = .empty,
    infer_depth: u32 = 0,
    flow_cache: std.AutoHashMapUnmanaged(FlowKey, *Type) = .empty,
    /// Loops still settling, each with its type so far and how many were open when it started.
    flow_active: std.AutoHashMapUnmanaged(FlowKey, ActiveLoop) = .empty,
    /// The outermost unsettled loop read since the last reset; `flow_untouched` if none was.
    flow_touched: u32 = flow_untouched,
    flow_assigned: IdMap(*Node, Provisional) = .empty,
    flow_operands: IdMap(*Node, Provisional) = .empty,
    flow_depth: u32 = 0,
    reach_cache: IdMap(*binder.FlowNode, bool) = .empty,

    diags: std.ArrayList(Diag) = .empty,
    seen_diags: std.StringHashMapUnmanaged(void) = .empty,
    /// Files this checker answers for. Another checker owns the rest and reports on them itself.
    owned: IdMap(*ast.File, void) = .empty,
    /// Function bodies wait until the expression that holds them has been fully typed.
    deferred: std.ArrayList(*Node) = .empty,
    pending_constraints: std.ArrayList(PendingConstraint) = .empty,
    /// Above zero while trying overloads and gathering inferences: nothing checked then is final.
    silent: u32 = 0,
    skip_sensitive: bool = false,
    /// Where array literals report themselves while a generic call's arguments are checked.
    array_sink: ?*std.AutoHashMapUnmanaged(*Type, void) = null,
    effects: IdMap(*Node, ?*Sig) = .empty,
    resolving_calls: IdMap(*Node, void) = .empty,
    regular_objs: IdMap(*Type, *Type) = .empty,
    declaring_enums: std.AutoHashMapUnmanaged(*binder.Symbol, void) = .empty,
    logical_left: IdMap(*Node, *Type) = .empty,
    current_node: ?*Node = null,
    current_is_type: bool = false,
    context_for_signature: bool = false,
    widened_objs: IdMap(*Type, *Type) = .empty,
    constant_refs: IdMap(*Node, bool) = .empty,
    /// Position of each element of a large array literal, which its context asks for per element.
    elem_index: IdMap(*Node, u32) = .empty,
    /// Whether an argument holds a context-sensitive lambda: pure syntax, asked once per candidate.
    sensitive_args: IdMap(*Node, bool) = .empty,

    pub const CtxEntry = struct { node: *Node, ty: ?*Type, ctx: ?*InferCtx };
    pub const FlowKey = struct { flow: *binder.FlowNode, ref: u64, declared: u32 };
    pub const ActiveLoop = struct { ty: *Type, depth: u32 };
    pub const Provisional = struct { ty: *Type, touched: u32 };

    pub fn new(a: Allocator, prog: *project.Program) *Checker {
        const o = prog.cfg.options;
        const c = a.create(Checker) catch oom();
        c.* = .{
            .a = a,
            .prog = prog,
            .strict_null = o.flag("strictNullChecks"),
            .no_implicit_any = o.flag("noImplicitAny"),
            .strict_fn = o.flag("strictFunctionTypes"),
            .strict_prop_init = o.flag("strictPropertyInitialization"),
            .no_implicit_this = o.flag("noImplicitThis"),
            .unknown_in_catch = o.flag("useUnknownInCatchVariables"),
            .bind_call_apply = o.flag("strictBindCallApply"),
            .exact_optional = o.exactOptionalPropertyTypes orelse false,
            .no_unchecked_index = o.noUncheckedIndexedAccess orelse false,
        };
        c.t_any = c.mk(.any);
        c.t_auto = c.mk(.any);
        c.t_err = c.mk(.err);
        c.t_unresolved = c.mk(.err);
        c.t_unknown = c.mk(.unknown);
        c.t_never = c.mk(.never);
        c.t_silent_never = c.mk(.never);
        c.t_void = c.mk(.void);
        c.t_undefined = c.mk(.undefined);
        c.t_null = c.mk(.null);
        c.t_string = c.mk(.string);
        c.t_number = c.mk(.number);
        c.t_bigint = c.mk(.bigint);
        c.t_symbol = c.mk(.symbol);
        c.t_nonprim = c.mk(.nonprim);
        c.t_true = c.mk(.{ .bool_lit = true });
        c.t_false = c.mk(.{ .bool_lit = false });
        c.t_boolean = c.getUnion(&.{ c.t_false, c.t_true });
        c.t_boolean.is_boolean = true;
        c.t_key = c.getUnion(&.{ c.t_string, c.t_number, c.t_symbol });
        c.t_empty = c.newObj(.{ .kind = .anon, .members = c.emptyMembers() });
        c.t_unreachable = c.mk(.never);
        c.t_typeof = c.getUnion(&.{ c.strLit("string"), c.strLit("number"), c.strLit("bigint"), c.strLit("boolean"), c.strLit("symbol"), c.strLit("undefined"), c.strLit("object"), c.strLit("function") });
        c.t_pending_fn = c.newObj(.{ .kind = .anon, .members = c.emptyMembers(), .open = true, .non_inferrable = true });
        return c;
    }

    pub fn create(c: *Checker, comptime T: type, v: T) *T {
        const p = c.a.create(T) catch oom();
        p.* = v;
        return p;
    }

    /// `std.ArrayList` reserves a cache line of items on the first append, 17 pointers for a list
    /// that mostly holds two, and an arena never gets them back.
    pub fn newList(c: *Checker, comptime T: type) std.ArrayList(T) {
        return std.ArrayList(T).initCapacity(c.a, 4) catch oom();
    }

    pub fn dupe(c: *Checker, comptime T: type, v: []const T) []T {
        return c.a.dupe(T, v) catch oom();
    }

    pub fn mk(c: *Checker, data: Data) *Type {
        const t = c.a.create(Type) catch oom();
        t.* = .{ .id = c.next_id, .data = data };
        c.next_id += 1;
        return t;
    }

    pub fn emptyMembers(c: *Checker) *Members {
        return c.create(Members, .{});
    }

    /// A property table's first insert reserves nine entries, and most objects have two.
    pub fn membersFor(c: *Checker, props: usize) *Members {
        const m = c.emptyMembers();
        c.reserveProps(m, props);
        return m;
    }

    pub fn reserveProps(c: *Checker, m: *Members, more: usize) void {
        const want = m.props.count() + more;
        if (want > m.props.entries.capacity) m.props.entries.setCapacity(c.a, want) catch oom();
    }

    pub fn newObj(c: *Checker, o: Obj) *Type {
        return c.mk(.{ .obj = c.create(Obj, o) });
    }

    pub fn fmt(c: *Checker, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.a, f, args) catch oom();
    }

    pub fn strLit(c: *Checker, v: []const u8) *Type {
        const gop = c.str_lits.getOrPut(c.a, v) catch oom();
        if (!gop.found_existing) gop.value_ptr.* = c.mk(.{ .str_lit = v });
        return gop.value_ptr.*;
    }

    pub fn numLit(c: *Checker, v: f64) *Type {
        const v2 = if (v == 0) 0 else v;
        const gop = c.num_lits.getOrPut(c.a, @bitCast(v2)) catch oom();
        if (!gop.found_existing) gop.value_ptr.* = c.mk(.{ .num_lit = v2 });
        return gop.value_ptr.*;
    }

    pub fn bigLit(c: *Checker, v: []const u8) *Type {
        const gop = c.big_lits.getOrPut(c.a, v) catch oom();
        if (!gop.found_existing) gop.value_ptr.* = c.mk(.{ .big_lit = v });
        return gop.value_ptr.*;
    }

    pub fn boolLit(c: *Checker, v: bool) *Type {
        return if (v) c.t_true else c.t_false;
    }

    /// The widening form of a literal: `let x = 1` widens it, `let x: 1 = 1` does not.
    pub fn freshOf(c: *Checker, t: *Type) *Type {
        switch (t.data) {
            .str_lit, .num_lit, .big_lit, .bool_lit, .enum_lit => {},
            else => return t,
        }
        if (t.regular != null) return t;
        if (t.fresh) |f| return f;
        const f = c.mk(t.data);
        f.regular = t;
        t.fresh = f;
        return f;
    }

    pub fn regularOf(_: *Checker, t: *Type) *Type {
        return t.regular orelse t;
    }

    /// The key being built, tag first. There is one buffer, so nothing that can intern may run
    /// between filling it and looking it up.
    pub fn keyOf(c: *Checker, tag: u8, n: usize) []u32 {
        c.key_buf.resize(c.a, n + 1) catch oom();
        c.key_buf.items[0] = tag;
        return c.key_buf.items;
    }

    /// Most lookups hit, so the key is only copied out of the shared buffer on a miss.
    pub fn slot(c: *Checker, key: []const u32) InternMap.GetOrPutResult {
        const gop = c.interned.getOrPut(c.a, key) catch oom();
        if (!gop.found_existing) gop.key_ptr.* = c.a.dupe(u32, key) catch oom();
        return gop;
    }

    fn flatten(c: *Checker, out: *std.ArrayList(*Type), types: []const *Type) void {
        for (types) |t| {
            switch (t.data) {
                .union_ => |u| c.flatten(out, u),
                .never => {},
                else => out.append(c.a, t) catch oom(),
            }
        }
    }

    pub fn getUnion(c: *Checker, types: []const *Type) *Type {
        return c.unionOf(types, false);
    }

    /// For contextual types: a literal beside its primitive still asks for literals to be kept.
    pub fn getContextUnion(c: *Checker, types: []const *Type) *Type {
        return c.unionOf(types, true);
    }

    fn unionOf(c: *Checker, types: []const *Type, keep_literals: bool) *Type {
        if (types.len == 1) return types[0];
        const list = &c.union_in;
        list.clearRetainingCapacity();
        c.flatten(list, types);
        // `true | false` is `boolean` whichever form each side is in.
        var has_true = false;
        var has_false = false;
        for (list.items) |t| if (t.data == .bool_lit) {
            if (t.data.bool_lit) has_true = true else has_false = true;
        };
        if (has_true and has_false) for (list.items) |*t| if (t.*.data == .bool_lit) {
            t.* = t.*.regular orelse t.*;
        };
        var has_any = false;
        var err: ?*Type = null;
        var has_unknown = false;
        var has_string = false;
        var has_number = false;
        var has_bigint = false;
        var has_symbol = false;
        var has_other = false;
        for (list.items) |t| switch (t.data) {
            .any => has_any = true,
            .err => if (err != c.t_err) {
                err = t;
            },
            .unknown => has_unknown = true,
            .string => has_string = true,
            .number => has_number = true,
            .bigint => has_bigint = true,
            .symbol => has_symbol = true,
            .null, .undefined => {},
            else => has_other = true,
        };
        if (err) |e| return e;
        if (has_any) return c.t_any;
        if (has_unknown) return c.t_unknown;
        std.mem.sort(*Type, list.items, {}, struct {
            fn less(_: void, l: *Type, r: *Type) bool {
                return l.id < r.id;
            }
        }.less);
        const out = &c.union_out;
        out.clearRetainingCapacity();
        for (list.items, 0..) |t, i| {
            if (i > 0 and list.items[i - 1] == t) continue;
            const drop = switch (t.data) {
                .str_lit => has_string and !keep_literals,
                .num_lit => has_number and !keep_literals,
                .big_lit => has_bigint and !keep_literals,
                .unique => has_symbol and !keep_literals,
                .tmpl, .strmap => has_string and !keep_literals,
                .null, .undefined => !c.strict_null and (has_other or has_string or has_number or has_bigint or has_symbol),
                else => false,
            };
            if (drop) continue;
            // A fresh literal next to its regular form adds nothing.
            if (t.regular) |r| {
                if (std.sort.binarySearch(*Type, list.items, r.id, compareId) != null) continue;
            }
            out.append(c.a, t) catch oom();
        }
        if (out.items.len == 0) return c.t_never;
        if (out.items.len == 1) return out.items[0];
        const key = c.keyOf(if (keep_literals) 'U' else 'u', out.items.len);
        for (out.items, 1..) |t, i| key[i] = t.id;
        const gop = c.slot(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const u = c.mk(.{ .union_ = c.dupe(*Type, out.items) });
        for (out.items) |t| if (t.vars) {
            u.vars = true;
        };
        gop.value_ptr.* = u;
        return u;
    }

    pub fn getIntersection(c: *Checker, types: []const *Type) *Type {
        return c.intersect(types, false);
    }

    /// `keep_empty` is for the spelled-out `string & {}`, which people write to keep a primitive
    /// from absorbing literals in a union. Everywhere else `{}` adds nothing to a non-nullable.
    pub fn intersect(c: *Checker, types: []const *Type, keep_empty: bool) *Type {
        if (types.len == 1) return types[0];
        var list = c.newList(*Type);
        for (types) |t| {
            switch (t.data) {
                .inter => |x| for (x) |y| list.append(c.a, y) catch oom(),
                else => list.append(c.a, t) catch oom(),
            }
        }
        var out = c.newList(*Type);
        var has_union = false;
        for (list.items) |t| {
            switch (t.data) {
                .never => return c.t_never,
                .err => return t,
                .any => return c.t_any,
                .unknown => continue,
                .union_ => has_union = true,
                else => {},
            }
            var dup = false;
            for (out.items) |x| if ((x.regular orelse x) == (t.regular orelse t)) {
                dup = true;
            };
            if (!dup) out.append(c.a, t) catch oom();
        }
        for (out.items) |t| for (out.items) |o| {
            if (t != o and c.disjointPrimitives(t, o)) return c.t_never;
        };
        var has_empty = false;
        var nullable = false;
        var object = false;
        var definite = false;
        for (out.items) |t| {
            if (isEmptyAnon(c, t)) {
                has_empty = true;
                continue;
            }
            switch (t.data) {
                .null, .undefined => nullable = true,
                .obj, .nonprim => object = true,
                .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_, .enum_lit, .tmpl, .strmap => definite = true,
                else => {},
            }
        }
        if (c.strict_null and nullable and (has_empty or object)) return c.t_never;
        const drop_empty = has_empty and (definite or object) and !keep_empty;
        var reduced = c.newList(*Type);
        for (out.items) |t| {
            const widens = for (out.items) |o| {
                if (o != t and c.literalOfPrimitive(o, t)) break true;
            } else false;
            if (widens or (drop_empty and isEmptyAnon(c, t))) continue;
            reduced.append(c.a, t) catch oom();
        }
        if (reduced.items.len == 0) return c.t_unknown;
        if (reduced.items.len == 1) return reduced.items[0];
        // Unlike a union the order stays as written: it is the overload order of the merged signatures.
        if (has_union) {
            if (c.intersectPrimitiveUnions(reduced.items)) |merged| return c.intersect(merged, keep_empty);
            // As in tsc, halve first: cross products that cancel out stay small this way, and
            // only what is left is measured against the limit.
            if (reduced.items.len >= 3 and types.len > 2) {
                const mid = reduced.items.len / 2;
                return c.intersect(&.{ c.intersect(reduced.items[0..mid], keep_empty), c.intersect(reduced.items[mid..], keep_empty) }, keep_empty);
            }
            // Distribution multiplies the member counts; tsc gives up at 100,000 combinations.
            var combos: u64 = 1;
            for (reduced.items) |t| if (t.data == .union_) {
                combos *= t.data.union_.len;
                if (combos >= 100_000) {
                    @import("decls.zig").reportLimit(c, 2590, "Expression produces a union type that is too complex to represent.");
                    return c.t_err;
                }
            };
            for (reduced.items, 0..) |t, i| {
                if (t.data != .union_) continue;
                var parts = c.newList(*Type);
                for (t.data.union_) |m| {
                    const rest = c.dupe(*Type, reduced.items);
                    rest[i] = m;
                    parts.append(c.a, c.getIntersection(rest)) catch oom();
                }
                return c.getUnion(parts.items);
            }
        }
        const key = c.keyOf('i', reduced.items.len);
        for (reduced.items, 1..) |t, i| key[i] = t.id;
        const gop = c.slot(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const u = c.mk(.{ .inter = reduced.items });
        for (reduced.items) |t| if (t.vars) {
            u.vars = true;
        };
        gop.value_ptr.* = u;
        return u;
    }

    /// tsc's intersectUnionsOfPrimitiveTypes. Membership answers these in one pass, where
    /// distribution would count every pair against the limit: two literal unions of a few hundred
    /// members are common in `keyof` of DOM types and must stay legal.
    fn intersectPrimitiveUnions(c: *Checker, types: []const *Type) ?[]const *Type {
        var unions = c.newList(*Type);
        var rest = c.newList(*Type);
        var first: ?usize = null;
        for (types) |t| {
            if (isPrimitiveUnion(t)) {
                if (first == null) first = rest.items.len;
                unions.append(c.a, t) catch oom();
            } else rest.append(c.a, t) catch oom();
        }
        if (unions.items.len < 2) return null;
        var common = c.newList(*Type);
        for (unions.items) |u| {
            for (u.data.union_) |m| {
                const everywhere = for (unions.items) |other| {
                    if (!c.unionAdmits(other, m)) break false;
                } else true;
                if (everywhere) common.append(c.a, m) catch oom();
            }
        }
        rest.insert(c.a, first.?, c.getUnion(common.items)) catch oom();
        return rest.items;
    }

    /// Enum members stay out: only distribution knows what `E.A & number` is.
    fn isPrimitiveUnion(t: *Type) bool {
        if (t.data != .union_) return false;
        for (t.data.union_) |m| switch (m.data) {
            .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .null, .undefined => {},
            else => return false,
        };
        return true;
    }

    fn unionAdmits(c: *Checker, u: *Type, m: *Type) bool {
        const has = struct {
            fn at(members: []const *Type, t: *Type) bool {
                return std.sort.binarySearch(*Type, members, t.id, compareId) != null;
            }
        }.at;
        const plain = m.regular orelse m;
        if (has(u.data.union_, m) or has(u.data.union_, plain)) return true;
        const wide = switch (plain.data) {
            .str_lit => c.t_string,
            .num_lit => c.t_number,
            .big_lit => c.t_bigint,
            .unique => c.t_symbol,
            else => return false,
        };
        return has(u.data.union_, wide);
    }

    fn isEmptyAnon(c: *Checker, t: *Type) bool {
        if (t == c.t_empty) return true;
        if (t.data != .obj or t.data.obj.kind != .anon) return false;
        const n = t.data.obj.node orelse return false;
        return n.data == .type_literal and n.data.type_literal.members.len == 0;
    }

    pub fn hasEmptyMember(c: *Checker, members: []const *Type) bool {
        for (members) |m| if (isEmptyAnon(c, m)) return true;
        return false;
    }

    fn primitiveClass(t: *Type) u8 {
        return switch (t.data) {
            .string, .str_lit => 1,
            .number, .num_lit => 2,
            .bigint, .big_lit => 3,
            .bool_lit => 4,
            .symbol, .unique => 5,
            .null => 6,
            .undefined => 7,
            .void => 8,
            else => 0,
        };
    }

    fn disjointPrimitives(_: *Checker, l: *Type, r: *Type) bool {
        if (l.data == .enum_lit or r.data == .enum_lit) {
            return (l.data == .enum_lit or isUnitLiteral(l)) and (r.data == .enum_lit or isUnitLiteral(r)) and l.regular orelse l != r.regular orelse r;
        }
        const a = primitiveClass(l);
        const b = primitiveClass(r);
        if (a == 0 or b == 0) {
            if (a != 0 and r.data == .nonprim) return true;
            if (b != 0 and l.data == .nonprim) return true;
            return false;
        }
        if (a != b) return !(a == 7 and b == 8) and !(a == 8 and b == 7);
        return isUnitLiteral(l) and isUnitLiteral(r) and l.regular orelse l != r.regular orelse r;
    }

    fn isUnitLiteral(t: *Type) bool {
        return switch (t.data) {
            .str_lit, .num_lit, .big_lit, .bool_lit, .unique => true,
            else => false,
        };
    }

    /// `prim` is redundant in an intersection with a literal of the same primitive.
    fn literalOfPrimitive(_: *Checker, lit: *Type, prim: *Type) bool {
        return switch (prim.data) {
            .string => lit.data == .str_lit or lit.data == .tmpl,
            .number => lit.data == .num_lit,
            .bigint => lit.data == .big_lit,
            .symbol => lit.data == .unique,
            .void => lit.data == .undefined,
            .enum_ => |s| lit.data == .enum_lit and lit.data.enum_lit.parent.resolve() == s.resolve(),
            else => false,
        };
    }

    pub fn key2(l: u32, r: u32) u64 {
        return (@as(u64, l) << 32) | r;
    }

    pub fn internRef(c: *Checker, target: *Type, args: []*Type, this_arg: ?*Type) *Type {
        const key = c.keyOf('r', args.len + 2);
        key[1] = target.id;
        key[2] = if (this_arg) |x| x.id else 0;
        for (args, 3..) |t, i| key[i] = t.id;
        const gop = c.slot(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const o = target.data.obj;
        // Callers may pass a stack buffer: nearly every reference built already exists.
        const t = c.newObj(.{ .kind = .ref, .sym = o.sym, .target = target, .args = c.dupe(*Type, args), .this_arg = this_arg, .is_class = o.is_class });
        for (args) |x| if (x.vars) {
            t.vars = true;
        };
        if (this_arg) |x| if (x.vars) {
            t.vars = true;
        };
        gop.value_ptr.* = t;
        return t;
    }

    pub fn makeTuple(c: *Checker, elems_in: []const *Type, flags_in: []const ElemFlag, readonly: bool, names_in: []const ?[]const u8) *Type {
        // `[A, ...(X | Y)]` is `[A, ...X] | [A, ...Y]`: positions after a union stay known.
        for (elems_in, flags_in, 0..) |e, f, i| {
            if (f != .variadic or e.data != .union_) continue;
            const each = c.a.dupe(*Type, elems_in) catch oom();
            const out = c.a.alloc(*Type, e.data.union_.len) catch oom();
            for (e.data.union_, out) |m, *r| {
                each[i] = m;
                r.* = c.makeTuple(each, flags_in, readonly, names_in);
            }
            return c.getUnion(out);
        }
        var elems = c.newList(*Type);
        var flags = c.newList(ElemFlag);
        var names = c.newList(?[]const u8);
        for (elems_in, 0..) |e, i| {
            const fl = flags_in[i];
            const nm: ?[]const u8 = if (i < names_in.len) names_in[i] else null;
            if (fl == .variadic) {
                if (isTupleType(e)) {
                    const o = e.data.obj;
                    for (o.tuple.elems, o.tuple.eflags, 0..) |x, f, j| {
                        elems.append(c.a, x) catch oom();
                        flags.append(c.a, f) catch oom();
                        names.append(c.a, if (j < o.tuple.names.len) o.tuple.names[j] else null) catch oom();
                    }
                    continue;
                }
                if (c.isArrayType(e)) {
                    elems.append(c.a, e.data.obj.args.?[0]) catch oom();
                    flags.append(c.a, .rest) catch oom();
                    names.append(c.a, nm) catch oom();
                    continue;
                }
                if (e.data == .any or e.data == .err) {
                    elems.append(c.a, e) catch oom();
                    flags.append(c.a, .rest) catch oom();
                    names.append(c.a, nm) catch oom();
                    continue;
                }
            }
            elems.append(c.a, e) catch oom();
            flags.append(c.a, fl) catch oom();
            names.append(c.a, nm) catch oom();
        }
        // As in tsc, a lone rest is no tuple at all: `[...string[]]` is `string[]`.
        if (elems.items.len == 1 and flags.items[0] == .rest) {
            const decls = @import("decls.zig");
            return if (readonly) decls.readonlyArrayOf(c, elems.items[0]) else decls.arrayOf(c, elems.items[0]);
        }
        if (elems.items.len >= 10_000) {
            const decls = @import("decls.zig");
            if (c.current_is_type) {
                decls.reportLimit(c, 2799, "Type produces a tuple type that is too large to represent.");
            } else decls.reportLimit(c, 2800, "Expression produces a tuple type that is too large to represent.");
            return c.t_err;
        }
        const key = c.keyOf('t', elems.items.len * 2 + 1);
        key[1] = @intFromBool(readonly);
        for (elems.items, 0..) |t, i| {
            key[i * 2 + 2] = t.id;
            key[i * 2 + 3] = @intFromEnum(flags.items[i]);
        }
        const gop = c.slot(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const t = c.newObj(.{ .kind = .tuple, .tuple = c.create(Tuple, .{ .elems = elems.items, .eflags = flags.items, .names = names.items }), .readonly = readonly });
        for (elems.items) |x| if (x.vars) {
            t.vars = true;
        };
        gop.value_ptr.* = t;
        return t;
    }

    /// `Foo<T>` over the declared `Foo`, keeping the declared type itself for identical arguments.
    pub fn internRefOrSelf(c: *Checker, g: *Type, args: []*Type) *Type {
        if (std.mem.eql(*Type, args, g.data.obj.tparams())) return g;
        return c.internRef(g, args, null);
    }

    pub fn collectExports(c: *Checker, m: *Symbol, out: *std.ArrayList(*Symbol), seen: *std.StringHashMapUnmanaged(void), depth: u32) void {
        if (depth > 32) return;
        if (m.exports) |tbl| {
            var it = tbl.map.iterator();
            while (it.next()) |e| {
                const gop = seen.getOrPut(c.a, e.key_ptr.*) catch oom();
                if (gop.found_existing) continue;
                out.append(c.a, e.value_ptr.*.resolve()) catch oom();
            }
        }
        const sf = c.prog.sourceOf(m.file) orelse return;
        for (m.stars) |star| {
            const spec = star.data.export_decl.specifier orelse continue;
            if (spec.data != .string_lit) continue;
            const t = c.prog.resolveModuleName(sf, spec.data.string_lit) orelse continue;
            c.collectExports(t.resolve(), out, seen, depth + 1);
        }
    }

    pub fn isArrayType(c: *Checker, t: *Type) bool {
        if (t.data != .obj) return false;
        const o = t.data.obj;
        if (o.kind != .ref) return false;
        return o.target == c.global_array or o.target == c.global_readonly_array;
    }

    pub fn isMutableArray(c: *Checker, t: *Type) bool {
        return t.data == .obj and t.data.obj.kind == .ref and t.data.obj.target == c.global_array;
    }
};

pub fn isTupleType(t: *Type) bool {
    return t.data == .obj and t.data.obj.kind == .tuple;
}

pub fn isAny(t: *Type) bool {
    return t.data == .any or t.data == .err;
}

pub fn isUnion(t: *Type) bool {
    return t.data == .union_;
}

pub fn isTypeVar(t: *Type) bool {
    return t.data == .param or t.data == .access;
}
