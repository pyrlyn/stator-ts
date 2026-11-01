//! Type relations (assignable, comparable, subtype, identity) and generic inference.
const std = @import("std");
const T = @import("types.zig");
const d = @import("decls.zig");
const flow = @import("flow.zig");
const expr = @import("expr.zig");
const binder = @import("binder.zig");
const ast = @import("ast.zig");
const Checker = T.Checker;
const Type = T.Type;
const Sig = T.Sig;
const Prop = T.Prop;
const Relation = T.Relation;
const InferCtx = T.InferCtx;
const InferInfo = T.InferInfo;
const Priority = T.Priority;
const Mapper = T.Mapper;
const oom = T.oom;

pub fn isAssignable(c: *Checker, s: *Type, t: *Type) bool {
    return fresh(c, s, t, .assignable);
}

pub fn isComparable(c: *Checker, s: *Type, t: *Type) bool {
    return fresh(c, s, t, .comparable);
}

pub fn isSubtype(c: *Checker, s: *Type, t: *Type) bool {
    return fresh(c, s, t, .subtype);
}

pub fn isIdentical(c: *Checker, s: *Type, t: *Type) bool {
    return fresh(c, s, t, .identity);
}

/// A question asked from outside starts over, as in tsc's `checkTypeRelatedTo`: a conditional type
/// resolved halfway through a relation must not inherit how deep that relation had got.
fn fresh(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const outer = enterStacks(c);
    defer leaveStacks(c, outer);
    return related(c, s, t, rel);
}

const Stacks = struct { base: u32, expanding: u2 };

fn enterStacks(c: *Checker) Stacks {
    const outer = Stacks{ .base = c.relation_base, .expanding = c.relation_expanding };
    c.relation_base = c.relation_depth;
    c.relation_expanding = 0;
    return outer;
}

fn leaveStacks(c: *Checker, outer: Stacks) void {
    c.relation_base = outer.base;
    c.relation_expanding = outer.expanding;
}

pub fn related(c: *Checker, s0: *Type, t0: *Type, rel: Relation) bool {
    if (s0 == t0) return true;
    var s = s0;
    var t = t0;
    if (s.regular) |r| if (s.data != .obj) {
        s = r;
    };
    if (t.regular) |r| t = r;
    if (s.data == .noinfer) s = s.data.noinfer;
    if (t.data == .noinfer) t = t.data.noinfer;
    if (s == t) return true;
    if (d.isNeverReduced(c, s)) s = c.t_never;
    if (d.isNeverReduced(c, t)) t = c.t_never;
    if (s == c.t_pending_fn) return pendingFits(c, t);
    if (s.data == .err or t.data == .err) return true;
    if (rel == .identity) return identical(c, s, t);
    if (simple(c, s, t, rel)) |v| {
        if (v or rel != .comparable) return v;
    }
    if (rel == .comparable) if (simple(c, t, s, rel)) |v| if (v) return true;
    if (!structuredKind(s) and !structuredKind(t)) return false;
    return cached(c, s, t, rel);
}

/// A lambda waiting for its context has no shape yet, but it is still a function: it cannot
/// satisfy `string` or a required property, and that is what sends overload search onward.
fn pendingFits(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .union_ => |u| for (u) |m| {
            if (pendingFits(c, m)) break true;
        } else false,
        .inter => |u| for (u) |m| {
            if (!pendingFits(c, m)) break false;
        } else true,
        .obj => blk: {
            if (d.callSigs(c, t).len > 0 or d.ctorSigs(c, t).len > 0) break :blk true;
            if (t.data.obj.sym) |s| if (std.mem.eql(u8, s.name, "Function")) break :blk true;
            for (d.propsOf(c, t)) |p| if (!p.optional) break :blk false;
            break :blk true;
        },
        .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_lit, .enum_, .null, .undefined, .void, .never, .tmpl, .strmap, .keyof => false,
        else => true,
    };
}

fn identical(c: *Checker, s: *Type, t: *Type) bool {
    if (std.meta.activeTag(s.data) != std.meta.activeTag(t.data)) return false;
    if (!structuredKind(s)) return false;
    return related(c, s, t, .strict_subtype) and related(c, t, s, .strict_subtype);
}

fn structuredKind(t: *Type) bool {
    return switch (t.data) {
        .obj, .union_, .inter, .param, .keyof, .access, .cond, .tmpl, .strmap => true,
        else => false,
    };
}

fn enumValuesEq(a: T.EnumValue, b: T.EnumValue) bool {
    return switch (a) {
        .num => |v| b == .num and b.num == v,
        .str => |v| b == .str and std.mem.eql(u8, b.str, v),
        .none => false,
    };
}

/// One enum seen through two copies of a package counts as the same enum when the members agree.
fn enumsRelated(c: *Checker, s0: *binder.Symbol, t0: *binder.Symbol) bool {
    const s = s0.resolve();
    const t = t0.resolve();
    if (s == t) return true;
    if (!std.mem.eql(u8, s.name, t.name) or s.flags & binder.F.regular_enum == 0 or t.flags & binder.F.regular_enum == 0) return false;
    const se = s.exports orelse return true;
    const te = t.exports orelse return false;
    var it = se.map.iterator();
    while (it.next()) |kv| {
        const sm = kv.value_ptr.*.resolve();
        if (sm.flags & binder.F.enum_member == 0) continue;
        const tm = te.get(kv.key_ptr.*) orelse return false;
        if (tm.flags & binder.F.enum_member == 0) return false;
        const sv = d.typeOfSymbol(c, sm);
        const tv = d.typeOfSymbol(c, tm);
        if (sv.data != .enum_lit or tv.data != .enum_lit) continue;
        const a = sv.data.enum_lit.value;
        const b = tv.data.enum_lit.value;
        if (enumValuesEq(a, b)) continue;
        if ((a != .none and b != .none) or a == .str or b == .str) return false;
    }
    return true;
}

fn enumValueEq(s: T.EnumValue, n: f64) bool {
    return s == .num and s.num == n;
}

fn simple(c: *Checker, s: *Type, t: *Type, rel: Relation) ?bool {
    const loose = rel == .assignable or rel == .comparable;
    switch (t.data) {
        .any, .unknown => return true,
        .never => return s.data == .never,
        else => {},
    }
    if (s.data == .never) return true;
    if (s.data == .any) return loose;
    if (s.data == .undefined) {
        if (!c.strict_null or t.data == .undefined or t.data == .void) return true;
    }
    if (s.data == .null) {
        if (!c.strict_null or t.data == .null) return true;
    }
    if (s.data == .enum_lit and !(t.data == .enum_lit)) {
        const v = s.data.enum_lit.value;
        if (t.data == .str_lit and v == .str and std.mem.eql(u8, t.data.str_lit, v.str)) return true;
        if (t.data == .num_lit and v == .num and t.data.num_lit == v.num) return true;
    }
    switch (t.data) {
        .string => switch (s.data) {
            .str_lit, .tmpl, .strmap => return true,
            .enum_lit => |e| return e.value == .str,
            else => {},
        },
        .number => switch (s.data) {
            .num_lit, .enum_ => return true,
            .enum_lit => |e| return e.value != .str,
            else => {},
        },
        .bigint => if (s.data == .big_lit) return true,
        .symbol => if (s.data == .unique) return true,
        .nonprim => if (s.data == .obj) return true,
        .enum_ => |e| switch (s.data) {
            .enum_ => |x| return enumsRelated(c, x, e),
            .enum_lit => |x| return enumsRelated(c, x.parent, e),
            .number, .num_lit => if (loose) return true,
            else => {},
        },
        .enum_lit => |e| switch (s.data) {
            .enum_ => |x| return loose and x.resolve() == e.parent.resolve(),
            .enum_lit => |x| return x.sym.resolve() == e.sym.resolve() or (enumValuesEq(x.value, e.value) and enumsRelated(c, x.parent, e.parent)),
            .num_lit => |v| if (loose) return enumValueEq(e.value, v),
            .number => if (loose and e.value != .str) return true,
            else => {},
        },
        else => {},
    }
    return if (structuredKind(s) or structuredKind(t)) null else false;
}

fn cached(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const key = Checker.key2(s.id, t.id);
    const slot = &c.relation_cache[@intFromEnum(rel)];
    if (slot.get(key)) |v| return v;
    const active_key = key ^ (@as(u64, @intFromEnum(rel)) << 61);
    if (c.relation_active.contains(active_key)) return true;
    if (c.relation_depth >= c.relation_sources.len) return true;
    const depth = c.relation_depth;
    c.relation_sources[depth] = s;
    c.relation_targets[depth] = t;
    const expanding = c.relation_expanding;
    defer c.relation_expanding = expanding;
    if (expanding & 1 == 0 and deeplyNested(c, s, c.relation_sources[c.relation_base .. depth + 1], 3)) c.relation_expanding |= 1;
    if (expanding & 2 == 0 and deeplyNested(c, t, c.relation_targets[c.relation_base .. depth + 1], 3)) c.relation_expanding |= 2;
    // Both sides unfolding one declaration never end on their own, and `optional(): ZodOptional<this>`
    // would build a fresh pair per level. Assume it holds, without recording the assumption.
    if (c.relation_expanding == 3) return true;
    c.relation_active.put(c.a, active_key, {}) catch oom();
    c.relation_depth += 1;
    const unknown = c.relation_unknown;
    const v = structured(c, s, t, rel);
    c.relation_depth -= 1;
    _ = c.relation_active.remove(active_key);
    // A yes that leaned on a measurement in progress holds only for that measurement.
    if (!v or c.relation_unknown == unknown) slot.put(c.a, key, v) catch oom();
    return v;
}

/// What repeats when a recursive declaration unfolds: every instantiation of one declaration
/// answers to the same identity. Arrays do not: three arrays in a row are usually three written
/// arrays of unrelated things, and tsc tells those apart by their node.
fn recursionIdentity(c: *Checker, t0: *Type) *const anyopaque {
    var t = t0;
    switch (t.data) {
        .obj => |o| {
            if (o.lit or o.was_lit or o.kind == .tuple or c.isArrayType(t)) return t;
            if (o.sym) |sym| if (o.kind != .anon or sym.flags & binder.F.class == 0) return sym;
            return o.target orelse t;
        },
        .access => {
            while (t.data == .access) t = t.data.access.obj;
            return t;
        },
        .cond => |x| return x.branches,
        else => return t,
    }
}

fn hasIdentity(c: *Checker, t: *Type, id: *const anyopaque) bool {
    if (t.data == .inter) {
        for (t.data.inter) |m| if (recursionIdentity(c, m) == id) return true;
        return false;
    }
    return recursionIdentity(c, t) == id;
}

/// `limit` levels of one declaration, each newer than the last: ids grow with instantiation, so
/// an older type met again is a reference back, not recursion producing new types. A union's
/// members all pair with the same other side, and that one type is not a level.
fn deeplyNested(c: *Checker, t: *Type, stack: []const *Type, limit: u32) bool {
    if (stack.len < limit) return false;
    if (t.data == .inter) {
        for (t.data.inter) |m| if (deeplyNested(c, m, stack, limit)) return true;
        return false;
    }
    const id = recursionIdentity(c, t);
    var count: u32 = 0;
    var last: u32 = 0;
    for (stack) |x| {
        if (x.id <= last or !hasIdentity(c, x, id)) continue;
        count += 1;
        if (count >= limit) return true;
        last = x.id;
    }
    return false;
}

fn condRelated(c: *Checker, x: *T.Cond, t: *Type, rel: Relation) bool {
    // A conditional that keeps naming itself in its branches never bottoms out.
    if (c.cond_relating >= 10) return true;
    c.cond_relating += 1;
    defer c.cond_relating -= 1;
    if (related(c, d.defaultCondConstraint(c, x), t, rel)) return true;
    if (t.data == .cond) return false;
    const k = d.condDistributive(c, x) orelse return false;
    return related(c, k, t, rel);
}

/// `T & undefined` is no `never`: an unconstrained `T` only stood in as `{}` for its apparent type.
fn hasFreeMember(c: *Checker, s: *Type) bool {
    for (s.data.inter) |m| {
        if (m.data == .param or m.data == .access) if (d.baseConstraint(c, m).data == .unknown) return true;
    }
    return false;
}

fn genericTarget(t: *Type) bool {
    return switch (t.data) {
        .keyof, .access, .cond, .strmap => true,
        .tmpl => t.vars,
        else => false,
    };
}

fn structured(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    if (s.data == .obj and s.data.obj.lit) {
        if (excessProp(c, s, t) != null) return false;
    }
    // A fresh `{}` is closed under subtyping, so a real type wins over it as a common supertype.
    if ((rel == .subtype or rel == .strict_subtype) and s.data == .obj and t.data == .obj and t.data.obj.lit and isEmptyObject(c, t) and !isEmptyObject(c, s)) return false;
    if (s.data == .union_) {
        if (rel == .comparable) {
            for (s.data.union_) |m| if (related(c, m, t, rel)) return true;
            return false;
        }
        for (s.data.union_) |m| if (!related(c, m, t, rel)) return false;
        return true;
    }
    // Freshness was spent on the whole target above; one member of it need not know every property.
    const plain = if (s.data == .obj and s.data.obj.lit) expr.regularize(c, s) else s;
    if (t.data == .union_) {
        // Members are sorted by id, so the common hit needs no relation at all.
        if (std.sort.binarySearch(*Type, t.data.union_, plain.id, T.compareId) != null) return true;
        for (t.data.union_) |m| if (related(c, plain, m, rel)) return true;
        if (s.data == .obj or s.data == .inter) {
            if (relatedToDiscriminated(c, plain, t, rel)) return true;
        }
        // `keyof T` still has its constraint `string | number | symbol` to try against the whole union.
        if (s.data != .param and s.data != .access and s.data != .cond and s.data != .inter and s.data != .keyof) return false;
    }
    if (t.data == .inter) {
        // Weakness is a property of the whole target, not of each member.
        const shaped = s.data == .obj or s.data == .inter;
        if (shaped and weakCheck(s, rel)) {
            var all_weak = true;
            var common = false;
            for (t.data.inter) |m| {
                if (!isWeak(c, m)) all_weak = false else if (hasCommonProp(c, s, m)) common = true;
            }
            if (all_weak and !common) return false;
        }
        for (t.data.inter) |m| {
            if (shaped and weakCheck(s, rel) and isWeak(c, m)) {
                if (!propsRelated(c, plain, m, rel)) return false;
            } else if (s.vars and !shaped and isWeak(c, m)) {
                if (!constraintFitsWeak(c, s, m, rel)) return false;
            } else if (!related(c, plain, m, rel)) return false;
        }
        return true;
    }
    if (s.data == .inter) {
        for (s.data.inter) |m| if (related(c, m, t, rel)) return true;
        // A generic member's constraint may be what supplies the target's shape.
        const ap = d.getApparent(c, s);
        if (ap != s and (ap.data != .never or !hasFreeMember(c, s)) and related(c, ap, t, rel)) return true;
    }
    if (t.data == .param) {
        if (rel == .comparable) {
            if (d.constraintOf(c, t)) |k| return related(c, s, k, rel);
            return true;
        }
        // A variable can still reach the target through its own constraint chain.
        if (s.data == .param) {
            const k = d.constraintOf(c, s) orelse return false;
            return k != s and related(c, k, t, rel);
        }
        if (s.data == .cond) return condRelated(c, s.data.cond, t, rel);
        if (s.data == .obj and s.data.obj.kind == .mapped and mappedHolds(c, s, t, rel)) return true;
        // `this` is a subtype of its class, but only a value already typed `this` can be it.
        return false;
    }
    if (s.data == .access and t.data == .access) if (accessesRelated(c, s, t, rel)) |v| return v;
    if (genericTarget(t)) return true;
    if (t.vars and t.data == .obj and t.data.obj.kind == .mapped) return true;
    if (t.data == .tmpl) {
        return switch (s.data) {
            .str_lit => |v| matchesTemplate(c, v, t),
            .string => false,
            else => true,
        };
    }
    switch (s.data) {
        .param, .access => {
            const k = d.baseConstraint(c, s);
            if (k == s) return true;
            if (k.data == .unknown) {
                return !c.strict_null and t.data == .obj and isEmptyObject(c, t);
            }
            return related(c, k, t, rel);
        },
        .cond => |x| return condRelated(c, x, t, rel),
        .keyof => return related(c, c.t_key, t, rel),
        .tmpl, .strmap => return related(c, c.t_string, t, rel),
        else => {},
    }
    if (t.data != .obj) return false;
    if (t.data.obj.open) return true;
    if (t.data.obj.kind == .mapped and t.vars) return true;
    const src = switch (s.data) {
        .obj => s,
        // Past the constraints above, `T & undefined` is apparently `undefined`, with no shape to compare.
        .inter => if (expr.isNullish(s)) return false else s,
        .null, .undefined, .void => return false,
        .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_, .enum_lit => blk: {
            // The wrapper below is an object, the value is not, and a string index wants one.
            for (d.indexesOf(c, t)) |x| if (x.key.data == .string) return false;
            break :blk d.getApparent(c, s);
        },
        else => d.getApparent(c, s),
    };
    if (src.data == .obj and src.data.obj.kind == .mapped and src.vars) return genericMappedRelated(c, src, t, rel);
    if (src.data == .obj and src.data.obj.open) return true;
    if (src.data != .obj and src.data != .inter) return false;
    return relateObjects(c, src, t, rel);
}

/// `{ [P in Q]: X }` can stand for `T` when `keyof T` fits `Q` and `X` fits `T[P]`: `Readonly<T>`
/// holds everything `T` does, `Partial<T>` does not.
fn mappedHolds(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const o = s.data.obj;
    const n = o.node orelse return false;
    const m = n.data.mapped_type;
    if (m.name_type != null) return false;
    const tpl = m.type orelse return false;
    if (m.question_mod == .question or m.question_mod == .plus) return false;
    const keys = d.instantiate(c, d.typeFromNode(c, m.constraint), o.mapper);
    if (!related(c, d.getIndexType(c, t), keys, rel)) return false;
    const held = d.instantiate(c, d.typeFromNode(c, tpl), o.mapper);
    return related(c, held, d.getIndexedAccess(c, t, d.mappedParam(c, n)), rel);
}

pub fn isEmptyObject(c: *Checker, t: *Type) bool {
    if (t.data != .obj) return false;
    const m = d.membersOf(c, t);
    return m.props.count() == 0 and m.calls.len == 0 and m.ctors.len == 0 and m.indexes.len == 0;
}

fn matchesTemplate(c: *Checker, v: []const u8, t: *Type) bool {
    const x = t.data.tmpl;
    if (!std.mem.startsWith(u8, v, x.texts[0])) return false;
    var pos = x.texts[0].len;
    for (x.types, 0..) |ty, i| {
        const lit = x.texts[i + 1];
        const last = i + 1 == x.types.len;
        const end = if (last) (if (std.mem.endsWith(u8, v, lit) and v.len - lit.len >= pos) v.len - lit.len else return false) else if (lit.len == 0) @min(pos + 1, v.len) else (std.mem.indexOfPos(u8, v, pos, lit) orelse return false);
        if (!templateSlot(c, v[pos..end], ty)) return false;
        pos = end + lit.len;
    }
    return true;
}

fn templateSlot(c: *Checker, v: []const u8, t: *Type) bool {
    return switch (t.data) {
        .number => (std.fmt.parseFloat(f64, v) catch return false) == (std.fmt.parseFloat(f64, v) catch 0) and v.len > 0,
        .bigint => (std.fmt.parseInt(i128, v, 10) catch return false) != 0 or v.len > 0,
        .union_ => |u| for (u) |m| {
            if (templateSlot(c, v, m)) break true;
        } else false,
        else => true,
    };
}

/// `{ kind: 'a' | 'b' }` against a discriminated union: each combination has to land on a member,
/// and every member landed on has to take the rest of the object.
fn relatedToDiscriminated(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const members = t.data.union_;
    var keys = c.newList(*Prop);
    var combinations: usize = 1;
    for (d.propsOf(c, s)) |p| {
        if (!isDiscriminant(c, members, p.name)) continue;
        combinations *= choiceCount(d.propType(c, p));
        if (combinations > 25) return false;
        keys.append(c.a, p) catch oom();
    }
    if (keys.items.len == 0) return false;
    const picks = c.a.alloc(usize, keys.items.len) catch oom();
    @memset(picks, 0);
    var matching = c.newList(*Type);
    while (true) {
        var matched = false;
        outer: for (members) |m| {
            for (keys.items, picks) |k, pick| {
                const tp = d.getProp(c, m, k.name) orelse continue :outer;
                if (tp != k and !related(c, choice(d.propType(c, k), pick), d.propType(c, tp), rel)) continue :outer;
            }
            matched = true;
            if (std.mem.indexOfScalar(*Type, matching.items, m) == null) matching.append(c.a, m) catch oom();
        }
        if (!matched) return false;
        var i: usize = 0;
        while (i < picks.len) : (i += 1) {
            picks[i] += 1;
            if (picks[i] < choiceCount(d.propType(c, keys.items[i]))) break;
            picks[i] = 0;
        }
        if (i == picks.len) break;
    }
    for (matching.items) |m| if (!restRelated(c, s, m, keys.items, rel)) return false;
    return true;
}

fn choiceCount(t: *Type) usize {
    return if (t.data == .union_) t.data.union_.len else 1;
}

fn choice(t: *Type, i: usize) *Type {
    return if (t.data == .union_) t.data.union_[i] else t;
}

fn restRelated(c: *Checker, s: *Type, t: *Type, skip: []const *Prop, rel: Relation) bool {
    if (t.data != .obj and t.data != .inter) return false;
    next: for (d.propsOf(c, t)) |tp| {
        for (skip) |k| if (std.mem.eql(u8, tp.name, k.name)) continue :next;
        const sp = d.getProp(c, s, tp.name) orelse {
            if (tp.optional) continue;
            return false;
        };
        if (!related(c, d.propType(c, sp), d.propType(c, tp), rel)) return false;
    }
    return true;
}

pub fn isUnitType(t: *Type) bool {
    return switch (t.data) {
        .str_lit, .num_lit, .big_lit, .bool_lit, .null, .undefined, .enum_lit, .unique => true,
        else => false,
    };
}

fn isLiteralType(t: *Type) bool {
    return switch (t.data) {
        .enum_, .tmpl => true,
        .union_ => |x| for (x) |m| {
            if (!isUnitType(m)) break false;
        } else true,
        else => isUnitType(t),
    };
}

/// A property that tells the members of a union apart: at least one of them gives it a literal
/// type and they do not all agree.
pub fn isDiscriminant(c: *Checker, members: []const *Type, name: []const u8) bool {
    var literal = false;
    var first: ?*Type = null;
    var varies = false;
    for (members) |m| {
        const p = d.getProp(c, m, name) orelse continue;
        const t = d.propType(c, p);
        if (t.data == .param or t.data == .access) return false;
        if (isLiteralType(t.regular orelse t)) literal = true;
        if (first) |x| {
            if (x != t) varies = true;
        } else first = t;
    }
    return literal and varies;
}

// ---- objects ----

pub const Variance = enum { covariant, contravariant, bivariant, independent, invariant };

var array_variances = [_]Variance{.covariant};

fn variancesOf(c: *Checker, g: *Type) ?[]Variance {
    // Arrays are known to be covariant, and measuring would walk every array method.
    if (g == c.global_array or g == c.global_readonly_array) return &array_variances;
    if (c.variances.get(g)) |v| return v;
    if (c.variance_busy.contains(g)) return null;
    c.variance_busy.put(c.a, g, {}) catch oom();
    defer _ = c.variance_busy.remove(g);
    const o = g.data.obj;
    const out = c.a.alloc(Variance, o.tparams().len) catch oom();
    const sup = varianceMarker(c, "$super", null);
    const sub = varianceMarker(c, "$sub", sup);
    const other = varianceMarker(c, "$other", null);
    const outer = enterStacks(c);
    defer leaveStacks(c, outer);
    for (o.tparams(), 0..) |tp, i| {
        if (declaredVariance(tp)) |v| {
            out[i] = v;
            continue;
        }
        const t1 = markerRef(c, g, i, sub);
        const t2 = markerRef(c, g, i, sup);
        const co = related(c, t1, t2, .assignable);
        const contra = related(c, t2, t1, .assignable);
        out[i] = if (co and contra) .bivariant else if (co) .covariant else if (contra) .contravariant else .invariant;
        // Related both ways may only mean nothing mentions the parameter: then even a type
        // unrelated to the marker gets through.
        if (co and contra and related(c, markerRef(c, g, i, other), t2, .assignable)) out[i] = .independent;
    }
    c.variances.put(c.a, g, out) catch oom();
    return out;
}

fn varianceMarker(c: *Checker, name: []const u8, k: ?*Type) *Type {
    const m = c.mk(.{ .param = c.create(T.TParam, .{ .name = name, .constraint = k, .constraint_done = true }) });
    m.vars = true;
    return m;
}

/// `Eq<T>` hands inference only its arguments, so what they mean has to be measured.
fn aliasVariances(c: *Checker, s: *binder.Symbol) ?[]Variance {
    const key = d.declaredType(c, s);
    if (c.variances.get(key)) |v| return v;
    if (c.variance_busy.contains(key)) return null;
    c.variance_busy.put(c.a, key, {}) catch oom();
    defer _ = c.variance_busy.remove(key);
    const params = d.aliasParams(c, s);
    const out = c.a.alloc(Variance, params.len) catch oom();
    const sup = varianceMarker(c, "$super", null);
    const sub = varianceMarker(c, "$sub", sup);
    const outer = enterStacks(c);
    defer leaveStacks(c, outer);
    for (params, 0..) |tp, i| {
        if (declaredVariance(tp)) |v| {
            out[i] = v;
            continue;
        }
        const args = c.dupe(*Type, params);
        args[i] = sub;
        const t1 = d.instantiateAlias(c, s, params, c.dupe(*Type, args));
        args[i] = sup;
        const t2 = d.instantiateAlias(c, s, params, args);
        const co = related(c, t1, t2, .assignable);
        const contra = related(c, t2, t1, .assignable);
        out[i] = if (co and contra) .bivariant else if (co) .covariant else if (contra) .contravariant else .invariant;
    }
    c.variances.put(c.a, key, out) catch oom();
    return out;
}

fn markerRef(c: *Checker, g: *Type, i: usize, marker: *Type) *Type {
    const args = c.dupe(*Type, g.data.obj.tparams());
    args[i] = marker;
    const t = c.internRef(g, args, null);
    c.variance_markers.put(c.a, t, {}) catch oom();
    return t;
}

fn declaredVariance(tp: *Type) ?Variance {
    const mods = (tp.data.param.decl orelse return null).mods;
    if (mods.in) return if (mods.out) .invariant else .contravariant;
    return if (mods.out) .covariant else null;
}

/// Written variance is taken at its word, so looking at the members could only contradict it.
fn isAnnotated(g: *Type) bool {
    for (g.data.obj.tparams()) |tp| if (declaredVariance(tp) == null) return false;
    return true;
}

fn argsRelated(c: *Checker, vs: []const Variance, sa: []*Type, ta: []*Type, rel: Relation) bool {
    for (sa, ta, vs) |x, y, v| {
        if (x == y) continue;
        const ok = switch (v) {
            .covariant => related(c, x, y, rel),
            .contravariant => related(c, y, x, rel),
            .bivariant => related(c, x, y, rel) or related(c, y, x, rel),
            .independent => true,
            .invariant => related(c, x, y, rel) and related(c, y, x, rel),
        };
        if (!ok) return false;
    }
    return true;
}

fn relateObjects(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    if (s.data == .obj and t.data == .obj) {
        const so = s.data.obj;
        const to = t.data.obj;
        if (so.kind == .ref and to.kind == .ref and so.target == to.target and so.this_arg == null and to.this_arg == null) {
            if (variancesOf(c, so.target.?)) |vs| {
                if (argsRelated(c, vs, so.args.?, to.args.?, rel)) return true;
                if (so.target == c.global_array or so.target == c.global_readonly_array or isAnnotated(so.target.?)) return false;
            } else if (!c.variance_markers.contains(s) and !c.variance_markers.contains(t)) {
                // As in tsc, a type's variance comes from uses outside its own recursive
                // instantiations. Walking those too would unfold `ZodType` until the stack ran out.
                c.relation_unknown += 1;
                return true;
            }
        }
        // tsc's shortcut too: arrays only differ from readonly arrays by mutators.
        if (to.target != null and to.target == c.global_readonly_array and c.isMutableArray(s)) return related(c, so.args.?[0], to.args.?[0], rel);
        if (c.isArrayType(t)) {
            if (T.isTupleType(s)) {
                if (so.readonly and c.isMutableArray(t)) return false;
                const e = to.args.?[0];
                for (so.tuple.elems, so.tuple.eflags) |x, f| {
                    const v = if (f == .optional) d.addOptional(c, x) else x;
                    if (f == .variadic) continue;
                    if (!related(c, v, e, rel)) return false;
                }
                return true;
            }
        }
        if (T.isTupleType(t)) {
            if (T.isTupleType(s)) return tuplesRelated(c, s, t, rel);
            if (c.isArrayType(s)) {
                if (rel != .comparable) return false;
            }
        }
    }
    if (weakCheck(s, rel) and isWeak(c, t) and s != d.globalType(c, "Object") and !hasCommonProp(c, s, t)) return false;
    if (!propsRelated(c, s, t, rel)) return false;
    if (!sigsRelated(c, s, t, rel, false)) return false;
    if (!sigsRelated(c, s, t, rel, true)) return false;
    return indexesRelated(c, s, t, rel);
}

/// The same goes for `T` against `T & { a?: string }`: `T` may well have no property in common.
fn constraintFitsWeak(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const k = d.baseConstraint(c, s);
    if (k == s) return related(c, s, t, rel);
    for (if (k.data == .union_) k.data.union_ else &.{k}) |m| {
        const fits = if (m.data == .obj or m.data == .inter) propsRelated(c, m, t, rel) else related(c, m, t, rel);
        if (!fits) return false;
    }
    return true;
}

fn weakCheck(s: *Type, rel: Relation) bool {
    return rel == .assignable or (rel == .comparable and isUnitType(s));
}

pub fn isWeak(c: *Checker, t: *Type) bool {
    if (t.data != .obj) return false;
    const m = d.membersOf(c, t);
    if (m.calls.len > 0 or m.ctors.len > 0 or m.indexes.len > 0 or m.props.count() == 0) return false;
    for (m.props.values()) |p| if (!p.optional) return false;
    return true;
}

pub fn hasCommonProp(c: *Checker, s: *Type, t: *Type) bool {
    if (s.data == .obj) {
        const m = d.membersOf(c, s);
        if (m.calls.len > 0 or m.ctors.len > 0) return true;
        if (d.genericMappedOrigin(c, s)) |f| return hasCommonProp(c, f, t);
        if (s.data.obj.open or s.data.obj.any_base) return true;
    }
    const props = d.propsOf(c, s);
    if (props.len == 0) return true;
    for (props) |p| if (d.membersOf(c, t).props.contains(p.name)) return true;
    return false;
}

fn tuplesRelated(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const so = s.data.obj;
    const to = t.data.obj;
    if (so.readonly and !to.readonly) return false;
    const open_t = openAt(to);
    const open_s = openAt(so);
    if (open_t == null and open_s != null) return false;
    // Required elements may follow a rest (`[...string[], number]`), so they are counted, not positioned.
    var min_t: usize = 0;
    for (to.tuple.eflags) |f| if (f == .required) {
        min_t += 1;
    };
    var min_s: usize = 0;
    for (so.tuple.eflags) |f| if (f == .required) {
        min_s += 1;
    };
    if (open_s == null and so.tuple.elems.len < min_t) return false;
    if (open_t == null and (to.tuple.elems.len < min_s or so.tuple.elems.len > to.tuple.elems.len)) return false;
    // As in tsc, elements before the target's rest align from the front and those after it from
    // the end; a source position in between meets the rest element itself.
    const start_t = open_t orelse to.tuple.elems.len;
    const end_t = if (open_t) |k| to.tuple.elems.len - 1 - k else 0;
    // A variadic element has no length yet, so nothing from there on can be aligned.
    const unaligned = std.mem.indexOfScalar(T.ElemFlag, to.tuple.eflags, .variadic) != null;
    for (so.tuple.elems, so.tuple.eflags, 0..) |x, f, i| {
        if (f == .variadic or (unaligned and i >= start_t)) return true;
        const from_end = so.tuple.elems.len - 1 - i;
        const j = if (open_t != null and i >= start_t) to.tuple.elems.len - 1 - @min(from_end, end_t) else i;
        const tf = to.tuple.eflags[j];
        if (tf == .variadic) return true;
        if (tf == .required and f != .required) return false;
        const sv = if (f == .optional) d.addOptional(c, x) else x;
        const tv = if (tf == .optional) d.addOptional(c, to.tuple.elems[j]) else to.tuple.elems[j];
        if (!related(c, sv, tv, rel)) return false;
    }
    return true;
}

fn openAt(o: *T.Obj) ?usize {
    for (o.tuple.eflags, 0..) |f, i| if (f == .rest or f == .variadic) return i;
    return null;
}

fn propsRelated(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const tprops = d.propsOf(c, t);
    const open = s.data == .obj and (s.data.obj.any_base or s.data.obj.open);
    // A subtype has to declare even what is optional, unless it is a literal that simply left it out.
    const written = s.data == .obj and (s.data.obj.lit or s.data.obj.was_lit or s.data.obj.kind == .tuple);
    const need_optional = (rel == .subtype or rel == .strict_subtype) and !written;
    for (tprops) |tp| {
        const sp = d.getProp(c, s, tp.name) orelse {
            if ((tp.optional and !need_optional) or open) continue;
            if (isPrototypeProp(tp)) continue;
            return false;
        };
        if (sp == tp) continue;
        if (tp.private or tp.protected or sp.private or sp.protected) {
            if (tp.private or sp.private) {
                if (tp.decl != sp.decl) return false;
            } else if (tp.protected) {
                if (!validOverride(c, sp, tp)) return false;
            } else if (sp.protected) return false;
        }
        if (sp.optional and !tp.optional and rel != .comparable) return false;
        if (!related(c, d.propType(c, sp), d.propType(c, tp), rel)) return false;
    }
    return true;
}

/// A subclass may widen `protected` to public, so what counts is who declares the property.
fn validOverride(c: *Checker, sp: *Prop, tp: *Prop) bool {
    const from = sp.owner orelse return true;
    const to = tp.owner orelse return true;
    if (to.data != .obj) return true;
    return flow.hasBase(c, from, to.data.obj.target orelse to);
}

fn isPrototypeProp(p: *Prop) bool {
    return std.mem.eql(u8, p.name, "prototype") and p.sym == null;
}

fn sigsRelated(c: *Checker, s: *Type, t: *Type, rel: Relation, ctor: bool) bool {
    const tsigs = if (ctor) d.ctorSigs(c, t) else d.callSigs(c, t);
    if (tsigs.len == 0) return true;
    const ssigs = if (ctor) d.ctorSigs(c, s) else d.callSigs(c, s);
    if (ssigs.len == 0) {
        if (s.data == .obj and (s.data.obj.any_base or s.data.obj.open)) return true;
        return false;
    }
    if (ctor) if (ssigs[0].abstract and !tsigs[0].abstract) return false;
    if (ssigs.len == tsigs.len) {
        // Two instantiations of one declaration line up, and the N*M search below is what
        // made comparing lib types like `Array<A>` and `Array<B>` slow.
        var same = true;
        for (ssigs, tsigs) |x, y| {
            if (x.target == null or x.target != y.target) same = false;
        }
        if (same) {
            for (ssigs, tsigs) |x, y| if (!sigRelated(c, erased(c, x), erased(c, y), rel)) return false;
            return true;
        }
    }
    if (ssigs.len == 1 and tsigs.len == 1) {
        if (rel == .comparable) return sigRelated(c, erased(c, ssigs[0]), erased(c, tsigs[0]), rel);
        return sigRelated(c, ssigs[0], tsigs[0], rel);
    }
    // Overloads compare with their own type parameters erased, as in tsc: otherwise `reduce<U>`
    // never matches and `Array<T>` loses its covariance.
    for (tsigs) |y| {
        var ok = false;
        for (ssigs) |x| {
            if (sigRelated(c, erased(c, x), erased(c, y), rel)) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

/// Unlike `erased`, keeps the signature's own `this`. Inference reaches the same generic source
/// again and again, so the copy is kept on the signature.
fn erasedToShape(c: *Checker, s: *Sig) *Sig {
    if (s.shape) |e| return e;
    const e = d.instSig(c, s, c.create(Mapper, .erase));
    s.shape = e;
    return e;
}

/// A generic source as `infer` sees it: its own parameters read as their constraints, which may
/// name each other.
fn baseSignature(c: *Checker, s: *Sig) *Sig {
    if (s.base) |e| return e;
    const tps = s.tparams;
    const limits = c.a.alloc(*Type, tps.len) catch oom();
    for (tps, limits) |p, *l| l.* = d.constraintOf(c, p) orelse c.t_unknown;
    const to_limits = d.arrayMapper(c, tps, c.dupe(*Type, limits));
    for (1..tps.len) |_| {
        for (limits) |*l| l.* = d.instantiate(c, l.*, to_limits);
    }
    const anys = c.a.alloc(*Type, tps.len) catch oom();
    @memset(anys, c.t_any);
    const eraser = d.arrayMapper(c, tps, anys);
    for (limits) |*l| l.* = d.instantiate(c, l.*, eraser);
    const e = d.applySig(c, s, d.arrayMapper(c, tps, limits));
    s.base = e;
    return e;
}

fn erased(c: *Checker, s: *Sig) *Sig {
    if (s.tparams.len == 0) return s;
    if (s.erased) |e| return e;
    const anys = c.a.alloc(*Type, s.tparams.len) catch oom();
    @memset(anys, c.t_any);
    const e = d.applySig(c, s, d.arrayMapper(c, s.tparams, anys));
    s.erased = e;
    return e;
}

pub const Arity = struct { min: u32, max: ?u32 };

pub fn restType(c: *Checker, s: *Sig) ?*Type {
    if (!s.has_rest or s.params.len == 0) return null;
    return d.paramTypeAt(c, s, s.params.len - 1);
}

pub fn arityOf(c: *Checker, s: *Sig) Arity {
    var a = declaredArity(c, s);
    // A trailing parameter that accepts `void` may be left out.
    while (a.min > 0) : (a.min -= 1) {
        const t = typeAt(c, s, a.min - 1) orelse break;
        if (!acceptsVoid(t)) break;
    }
    return a;
}

fn acceptsVoid(t: *Type) bool {
    if (t.data == .void) return true;
    if (t.data != .union_) return false;
    for (t.data.union_) |m| if (m.data == .void) return true;
    return false;
}

fn declaredArity(c: *Checker, s: *Sig) Arity {
    if (restType(c, s)) |r| {
        if (T.isTupleType(r)) {
            const o = r.data.obj;
            var min = s.min_args;
            var max: ?u32 = @intCast(s.params.len - 1);
            for (o.tuple.eflags) |f| {
                switch (f) {
                    .required => {
                        max = if (max) |m| m + 1 else null;
                        min = max orelse min;
                    },
                    .optional => max = if (max) |m| m + 1 else null,
                    else => max = null,
                }
            }
            return .{ .min = min, .max = max };
        }
        return .{ .min = s.min_args, .max = null };
    }
    return .{ .min = s.min_args, .max = @intCast(s.params.len) };
}

/// The type an argument at position `i` meets: expands rest arrays and rest tuples.
pub fn typeAt(c: *Checker, s: *Sig, i: usize) ?*Type {
    const fixed = if (s.has_rest) s.params.len - 1 else s.params.len;
    if (i < fixed) return d.paramTypeAt(c, s, i);
    const r = restType(c, s) orelse return null;
    if (c.isArrayType(r)) return r.data.obj.args.?[0];
    if (T.isTupleType(r)) {
        const o = r.data.obj;
        const j = i - fixed;
        if (openAt(o)) |k| if (j >= k) {
            // From the rest on, a position may hold the rest element or any element written after it.
            for (o.tuple.eflags[k..]) |f| if (f == .variadic) return c.t_err;
            return if (o.tuple.elems.len - k == 1) o.tuple.elems[k] else c.getUnion(o.tuple.elems[k..]);
        };
        if (j < o.tuple.elems.len) {
            return if (o.tuple.eflags[j] == .optional) d.addOptional(c, o.tuple.elems[j]) else o.tuple.elems[j];
        }
        return null;
    }
    if (T.isAny(r)) return r;
    if (r.data == .param or r.data == .access) return d.getIndexedAccess(c, r, c.numLit(@floatFromInt(i - fixed)));
    return c.t_err;
}

pub fn isMethodLike(s: *Sig) bool {
    const n = s.decl orelse return false;
    if (n.data != .func) return false;
    return switch (n.data.func.kind) {
        .method, .method_sig, .ctor, .construct_sig => true,
        else => false,
    };
}

pub fn sigRelated(c: *Checker, s0: *Sig, t: *Sig, rel: Relation) bool {
    return sigRel(c, s0, t, rel, .normal);
}

/// Inside a callback parameter tsc checks parameters one way only, and return types both ways
/// under a bivariant outer signature; that is what keeps `reduce` covariant in its array type.
const SigMode = enum { normal, strict_callback, bivariant_callback };

fn hasAllCandidates(ctx: *InferCtx) bool {
    for (ctx.infos) |x| if (x.candidates.items.len == 0 and x.contra.items.len == 0) return false;
    return true;
}

/// The signature of a plain function type, the only shape treated as a callback.
fn singleCall(c: *Checker, t0: *Type) ?*Sig {
    const t = expr.nonNull(c, t0);
    if (t.data != .obj) return null;
    const sigs = d.callSigs(c, t);
    if (sigs.len != 1 or d.ctorSigs(c, t).len != 0 or d.propsOf(c, t).len != 0 or d.indexesOf(c, t).len != 0) return null;
    return sigs[0];
}

fn genericAt(c: *Checker, s: *Sig, i: usize) bool {
    return d.isGeneric(c, typeAt(c, s.target orelse return false, i) orelse return false);
}

fn sigRel(c: *Checker, s0: *Sig, t: *Sig, rel: Relation, mode: SigMode) bool {
    if (s0 == t) return true;
    var s = s0;
    if (s.tparams.len > 0 and s.tparams.ptr != t.tparams.ptr) s = sigInContext(c, s, t);
    const sa = arityOf(c, s);
    const ta = arityOf(c, t);
    if (sa.min > (ta.max orelse std.math.maxInt(u32))) return false;
    const strict = mode == .normal and c.strict_fn and !isMethodLike(t);
    const count: usize = @max(fixedCount(c, s), fixedCount(c, t));
    for (0..count + 1) |i| {
        const x = typeAt(c, s, i) orelse break;
        const y = typeAt(c, t, i) orelse break;
        if (x == y) continue;
        if (mode == .normal and !genericAt(c, s, i) and !genericAt(c, t, i)) {
            if (singleCall(c, x)) |xs| if (singleCall(c, y)) |ys| {
                if (d.predOf(c, xs) == null and d.predOf(c, ys) == null and sameNullability(x, y)) {
                    if (!sigRel(c, ys, xs, rel, if (strict) .strict_callback else .bivariant_callback)) return false;
                    continue;
                }
            };
        }
        if (related(c, y, x, rel)) continue;
        if (mode == .normal and !strict and related(c, x, y, rel)) continue;
        return false;
    }
    const tr = d.returnOf(c, t);
    if (tr.data == .void or T.isAny(tr)) return true;
    const sr = d.returnOf(c, s);
    if (d.predOf(c, t)) |tp| {
        const sp = d.predOf(c, s) orelse return false;
        if (sp.is_this != tp.is_this or sp.asserts != tp.asserts or (!tp.is_this and sp.param_index != tp.param_index)) return false;
        if (sp.ty == tp.ty) return true;
        return sp.ty != null and tp.ty != null and related(c, sp.ty.?, tp.ty.?, rel);
    }
    if (sr == tr) return true;
    if (mode == .bivariant_callback and related(c, tr, sr, rel)) return true;
    return related(c, sr, tr, rel);
}

fn sameNullability(a: *Type, b: *Type) bool {
    return hasNullable(a) == hasNullable(b);
}

fn hasNullable(t: *Type) bool {
    if (t.data == .null or t.data == .undefined) return true;
    if (t.data == .union_) for (t.data.union_) |m| if (m.data == .null or m.data == .undefined) return true;
    return false;
}

fn fixedCount(c: *Checker, s: *Sig) usize {
    const a = arityOf(c, s);
    return a.max orelse s.params.len;
}

pub fn sigInContext(c: *Checker, s: *Sig, t: *Sig) *Sig {
    const ctx = newInferCtx(c, s.tparams, 0);
    const n = @min(fixedCount(c, s), fixedCount(c, t));
    for (0..n) |i| {
        const x = typeAt(c, t, i) orelse break;
        const y = typeAt(c, s, i) orelse break;
        inferTypes(c, ctx, x, y, 0);
    }
    inferTypes(c, ctx, d.returnOf(c, t), d.returnOf(c, s), Priority.return_type);
    return d.applySig(c, s, ctx.mapper);
}

/// `S[K]` is settled by its parts, or else by what `T[J]` accepts when `J` is one known key.
fn accessesRelated(c: *Checker, s: *Type, t: *Type, rel: Relation) ?bool {
    const a = s.data.access;
    const b = t.data.access;
    if (related(c, a.obj, b.obj, rel) and related(c, a.index, b.index, rel)) return true;
    if (b.index.data != .str_lit and b.index.data != .num_lit) return null;
    const k = d.baseConstraint(c, t);
    if (k.data == .err or k.data == .unknown) return null;
    return related(c, s, k, rel);
}

/// Keys that are still generic cover at least what their origin is known to have, and one
/// template says what any of them holds.
fn genericMappedRelated(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const value = d.genericMappedTemplate(c, s) orelse return true;
    const origin = d.genericMappedOrigin(c, s);
    if (origin) |f| if (expr.holdsArrays(c, f)) return true;
    if (d.callSigs(c, t).len > 0 or d.ctorSigs(c, t).len > 0) return false;
    if (weakCheck(s, rel) and isWeak(c, t) and !hasCommonProp(c, s, t)) return false;
    const q = s.data.obj.node.?.data.mapped_type.question_mod;
    for (d.propsOf(c, t)) |tp| {
        const sp = if (origin) |f| d.getProp(c, f, tp.name) else null;
        if (sp == null) {
            if (tp.optional or isPrototypeProp(tp)) continue;
            return false;
        }
        if (tp.private or tp.protected) return false;
        const optional = q == .question or q == .plus or sp.?.optional and q != .minus;
        if (optional and !tp.optional and rel != .comparable) return false;
        if (!related(c, d.genericMappedMember(c, s, tp.name) orelse continue, d.propType(c, tp), rel)) return false;
    }
    const indexes = d.indexesOf(c, t);
    for (indexes) |x| {
        if (x.key.data != .string) continue;
        for (indexes) |ti| {
            if (rel != .strict_subtype and T.isAny(ti.ty)) continue;
            if (!related(c, value, ti.ty, rel)) return false;
        }
        break;
    }
    return true;
}

fn indexesRelated(c: *Checker, s: *Type, t: *Type, rel: Relation) bool {
    const indexes = d.indexesOf(c, t);
    // `{ [k: string]: any }` asks only for an object, whoever declared it.
    const any_object = rel != .strict_subtype and (s.data == .obj or s.data == .inter) and for (indexes) |x| {
        if (x.key.data == .string) break true;
    } else false;
    for (indexes) |ti| {
        if (any_object and T.isAny(ti.ty)) continue;
        if (d.indexValue(c, s, ti.key)) |v| {
            if (!related(c, v, ti.ty, rel)) return false;
            continue;
        }
        // Only literal-shaped types get an implicit index signature from their properties.
        if (!hasInferableIndex(c, s) and rel != .comparable) {
            if (s.data == .inter) continue;
            return false;
        }
        for (d.propsOf(c, s)) |p| {
            if (!keyApplies(c, ti.key, p.name)) continue;
            var pt = d.propType(c, p);
            // A property that can only be undefined keeps it: `{ a?: never }` is not `{ [k: string]: T }`.
            if (p.optional and pt.data != .undefined) pt = removeDefinitelyUndefined(c, pt);
            if (!related(c, pt, ti.ty, rel)) return false;
        }
    }
    return true;
}

/// Subtyping without an index signature the source only implies, so `{}` and
/// `Record<string, unknown>` are ordered instead of being each other's subtype.
/// Two instantiations of one generic, by its variances alone: comparing them member by member lets
/// methods answer bivariantly, and `Promise<unknown>` would pass for a `Promise<number>`.
pub fn variantSubtype(c: *Checker, s: *Type, t: *Type) ?bool {
    const so = s.data.obj;
    const to = t.data.obj;
    if (so.kind != .ref or to.kind != .ref or so.target != to.target or so.this_arg != null or to.this_arg != null) return null;
    return argsRelated(c, variancesOf(c, so.target.?) orelse return null, so.args.?, to.args.?, .subtype);
}

pub fn isStrictSubtype(c: *Checker, s: *Type, t: *Type) bool {
    if (!isSubtype(c, s, t)) return false;
    if (s.data != .obj or s.data.obj.lit or t.data != .obj) return true;
    for (d.indexesOf(c, t)) |ti| if (d.indexValue(c, s, ti.key) == null) return false;
    return true;
}

fn hasInferableIndex(c: *Checker, s: *Type) bool {
    // The `{}` that stands for "not null or undefined" comes from `unknown`
    // and has no declaration, so nothing about its properties is known.
    if (s == c.t_empty) return false;
    return switch (s.data) {
        .inter => |x| for (x) |y| {
            if (!hasInferableIndex(c, y)) break false;
        } else true,
        .obj => |o| !o.closed and (o.kind == .mapped or (o.kind == .anon and (o.lit or isTypeLiteralLike(s)))),
        else => false,
    };
}

fn isTypeLiteralLike(s: *Type) bool {
    const o = s.data.obj;
    const sym = o.sym orelse return true;
    return sym.flags & (binder.F.type_literal | binder.F.object_literal) != 0;
}

fn keyApplies(_: *Checker, key: *Type, name: []const u8) bool {
    return switch (key.data) {
        .string => !std.mem.startsWith(u8, name, "__@"),
        .number => (std.fmt.parseFloat(f64, name) catch return false) == (std.fmt.parseFloat(f64, name) catch 0),
        .symbol => std.mem.startsWith(u8, name, "__@"),
        else => true,
    };
}

pub fn removeDefinitelyUndefined(c: *Checker, t: *Type) *Type {
    if (t.data == .undefined) return c.t_never;
    if (t.data != .union_) return t;
    for (t.data.union_) |m| {
        if (m.data == .undefined) break;
    } else return t;
    var small: [d.small_list]*Type = undefined;
    var out = std.ArrayList(*Type).initBuffer(d.smallList(c, &small, t.data.union_.len));
    for (t.data.union_) |m| if (m.data != .undefined) out.appendAssumeCapacity(m);
    return c.getUnion(out.items);
}

pub fn permissive(c: *Checker, t: *Type) *Type {
    return d.instantiate(c, t, c.create(Mapper, .erase));
}

pub fn restrictive(_: *Checker, t: *Type) *Type {
    return t;
}

// ---- excess properties and error detail ----

fn isKnown(c: *Checker, t: *Type, name: []const u8) bool {
    switch (t.data) {
        .obj => |o| {
            if (o.open or o.any_base or (o.kind == .mapped and t.vars)) return true;
            if (d.membersOf(c, t).props.contains(name)) return true;
            // A string index has always let symbol names through here, unlike in an element access.
            for (d.indexesOf(c, t)) |i| if (keyApplies(c, i.key, name) or i.key == c.t_string) return true;
            return false;
        },
        .union_ => |x| {
            for (x) |m| if (!isPrimitive(m) and isKnown(c, m, name)) return true;
            return false;
        },
        .inter => |x| {
            for (x) |m| if (isKnown(c, m, name)) return true;
            return false;
        },
        else => return true,
    }
}

fn isPrimitive(t: *Type) bool {
    return switch (t.data) {
        .void, .undefined, .null, .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .unique, .enum_lit, .enum_ => true,
        else => false,
    };
}

fn excessTarget(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .obj => !isEmptyObject(c, t) and !isObjectGlobal(c, t),
        .union_, .inter => |x| blk: {
            var any = false;
            for (x) |m| {
                if (m.data == .param or m.data == .access or m.data == .cond or m.data == .keyof) break :blk false;
                if (m.data == .obj and m.vars and m.data.obj.kind == .mapped) break :blk false;
                if (m.data == .obj and (isEmptyObject(c, m) or isObjectGlobal(c, m))) break :blk false;
                if (m.data == .nonprim) break :blk false;
                if (m.data == .obj or m.data == .inter) any = true;
            }
            break :blk any;
        },
        else => false,
    };
}

fn isObjectGlobal(c: *Checker, t: *Type) bool {
    return d.globalType(c, "Object") == t;
}

pub fn excessProp(c: *Checker, s: *Type, t: *Type) ?*Prop {
    if (s.data != .obj or !s.data.obj.lit or s.data.obj.open or s.data.obj.spread) return null;
    if (!excessTarget(c, t)) return null;
    for (d.membersOf(c, s).props.values()) |p| {
        if (!isKnown(c, t, p.name)) return p;
    }
    return null;
}

pub fn missingProps(c: *Checker, s: *Type, t: *Type) []const []const u8 {
    var out = c.newList([]const u8);
    if (t.data != .obj and t.data != .inter) return out.items;
    const owner = d.genericMappedOrigin(c, s) orelse s;
    for (d.propsOf(c, t)) |p| {
        if (p.optional or isPrototypeProp(p)) continue;
        if (std.mem.startsWith(u8, p.name, "__@")) continue;
        if (d.getProp(c, owner, p.name) == null) out.append(c.a, p.name) catch oom();
    }
    return out.items;
}

// ---- inference ----

fn hasUnmatchedProp(c: *Checker, s: *Type, t: *Type, discriminants: bool) bool {
    for (d.propsOf(c, t)) |tp| {
        if (tp.optional) continue;
        const sp = d.getProp(c, s, tp.name) orelse return true;
        if (!discriminants) continue;
        const want = d.propType(c, tp);
        if (!isUnitType(want)) continue;
        const have = d.propType(c, sp);
        if (!T.isAny(have) and (have.regular orelse have) != (want.regular orelse want)) return true;
    }
    return false;
}

/// Each side lacks something the other requires, so no value can be both and whatever their
/// shared members say about a type parameter would be noise.
fn definitelyUnrelated(c: *Checker, s: *Type, t: *Type) bool {
    return hasUnmatchedProp(c, s, t, true) and hasUnmatchedProp(c, t, s, false);
}

fn isNonInferrable(c: *Checker, t: *Type) bool {
    if (t == c.t_silent_never or t == c.t_auto) return true;
    return switch (t.data) {
        .obj => |o| {
            if (o.non_inferrable) return true;
            if (o.args) |args| for (args) |a| if (isNonInferrable(c, a)) return true;
            // `Box<never>` over an unresolved parameter says as little as that parameter.
            if (t.alias) |al| for (al.args) |a| if (isNonInferrable(c, a)) return true;
            return false;
        },
        .union_, .inter => |x| for (x) |m| {
            if (isNonInferrable(c, m)) break true;
        } else false,
        else => false,
    };
}

pub fn newInferCtx(c: *Checker, params: []const *Type, _: u32) *InferCtx {
    const infos = c.a.alloc(InferInfo, params.len) catch oom();
    for (params, 0..) |p, i| infos[i] = .{ .param = p };
    const ctx = c.a.create(InferCtx) catch oom();
    ctx.* = .{ .infos = infos, .mapper = c.create(Mapper, .{ .infer = ctx }) };
    return ctx;
}

/// A context is made for every generic call and most never need this.
pub fn nonFixing(c: *Checker, ctx: *InferCtx) *Mapper {
    if (ctx.non_fixing == null) ctx.non_fixing = c.create(Mapper, .{ .infer = ctx });
    return ctx.non_fixing.?;
}

pub fn noDefault(c: *Checker, ctx: *InferCtx) *Mapper {
    if (ctx.no_default == null) ctx.no_default = c.create(Mapper, .{ .infer = ctx });
    return ctx.no_default.?;
}

/// Maps only the parameters that have candidates; null when none has.
pub fn inferredPart(c: *Checker, ctx: *InferCtx) ?*T.Mapper {
    var params = c.newList(*Type);
    var sources = c.newList(*T.InferInfo);
    for (ctx.infos) |*info| {
        if (info.candidates.items.len == 0 and info.contra.items.len == 0) continue;
        params.append(c.a, info.param) catch oom();
        sources.append(c.a, info) catch oom();
    }
    if (params.items.len == 0) return null;
    // Parameters that heard nothing stay generic in the others' constraints: `Object.freeze`
    // keeps its literals through the `U extends string` in the constraint of its `T`.
    const part = newInferCtx(c, params.items, 0);
    part.ret = ctx.ret;
    const to = c.a.alloc(*Type, params.items.len) catch oom();
    for (part.infos, sources.items) |*info, from| {
        info.candidates = from.candidates;
        info.contra = from.contra;
        info.priority = from.priority;
        info.top_level = from.top_level;
    }
    for (0..part.infos.len) |i| to[i] = getInferred(c, part, i);
    return d.arrayMapper(c, params.items, to);
}

pub fn inferMap(c: *Checker, ctx: *InferCtx, t: *Type, m: *T.Mapper) *Type {
    for (ctx.infos, 0..) |*info, i| {
        if (info.param != t) continue;
        if (m == ctx.no_default and info.candidates.items.len == 0 and info.contra.items.len == 0) return c.t_silent_never;
        if (m == ctx.mapper and !info.fixed) {
            info.inferred = null;
            info.fixed = true;
            return getInferred(c, ctx, i);
        }
        return getInferred(c, ctx, i);
    }
    return t;
}

fn hasPrimitiveConstraint(c: *Checker, p: *Type) bool {
    const k = d.constraintOf(c, p) orelse return false;
    return primitiveish(c, if (k.data == .cond) d.baseConstraint(c, k) else k);
}

fn primitiveish(c: *Checker, k: *Type) bool {
    return switch (k.data) {
        .string, .number, .bigint, .symbol, .bool_lit, .str_lit, .num_lit, .big_lit, .enum_lit, .enum_, .null, .undefined, .keyof, .tmpl, .strmap => true,
        .union_ => |u| for (u) |m| {
            if (primitiveish(c, m)) break true;
        } else false,
        .inter => |u| for (u) |m| {
            if (primitiveish(c, m)) break true;
        } else false,
        else => false,
    };
}

fn commonSupertype(c: *Checker, list: []const *Type) *Type {
    // Shapes compete on their own: `T[] | undefined` must lose to `readonly T[]`, and its `undefined` comes back at the end.
    var nulls = c.newList(*Type);
    var primary = c.newList(*Type);
    for (list) |x| {
        if (isNullType(x)) {
            nulls.append(c.a, x) catch oom();
        } else if (x.data == .union_) {
            var kept = c.newList(*Type);
            for (x.data.union_) |m| (if (isNullType(m)) &nulls else &kept).append(c.a, m) catch oom();
            primary.append(c.a, if (kept.items.len == x.data.union_.len) x else c.getUnion(kept.items)) catch oom();
        } else primary.append(c.a, x) catch oom();
    }
    if (primary.items.len == 0 or sameLiteralBase(c, primary.items)) return c.getUnion(list);
    var best = primary.items[0];
    for (primary.items[1..]) |x| {
        if (isSubtype(c, best, x)) best = x;
    }
    if (!c.strict_null or nulls.items.len == 0) return best;
    nulls.append(c.a, best) catch oom();
    return c.getUnion(nulls.items);
}

fn isNullType(t: *Type) bool {
    return t.data == .null or t.data == .undefined;
}

fn paramAtTop(t: *Type, p: *Type) bool {
    if (t == p) return true;
    return switch (t.data) {
        .union_, .inter => |u| for (u) |m| {
            if (paramAtTop(m, p)) break true;
        } else false,
        else => false,
    };
}

pub fn literalBase(c: *Checker, t: *Type) *Type {
    return switch (t.data) {
        .str_lit => c.t_string,
        .num_lit => c.t_number,
        .big_lit => c.t_bigint,
        .bool_lit => c.t_boolean,
        .enum_lit => |e| if (e.parent.flags & @import("binder.zig").F.enum_any != 0) d.declaredType(c, e.parent) else t,
        .union_ => |u| {
            var parts = c.newList(*Type);
            for (u) |m| parts.append(c.a, literalBase(c, m)) catch oom();
            return c.getUnion(parts.items);
        },
        else => t,
    };
}

/// Literals of one base unite (`true | false`); no one of them is a supertype of the others.
fn sameLiteralBase(c: *Checker, list: []const *Type) bool {
    var base: ?*Type = null;
    for (list) |x| {
        if (x.data == .never) continue;
        const b = literalBase(c, x);
        if (b == x) return false;
        if (base != null and base.? != b) return false;
        base = b;
    }
    return true;
}

fn isObjectLiteral(t: *Type) bool {
    return t.data == .obj and (t.data.obj.lit or t.data.obj.was_lit);
}

/// Literals written side by side describe one value each, so none has to be a supertype of the rest.
fn uniteLiteralCandidates(c: *Checker, ctx: *InferCtx, list: []const *Type) []const *Type {
    if (list.len < 2) return list;
    for (list) |x| {
        if (isObjectLiteral(x) or ctx.array_lits.contains(x)) break;
    } else return list;
    var literals = c.newList(*Type);
    var out = c.newList(*Type);
    for (list) |x| (if (isObjectLiteral(x) or ctx.array_lits.contains(x)) &literals else &out).append(c.a, x) catch oom();
    out.append(c.a, expr.reduceSubtypes(c, literals.items)) catch oom();
    return out.items;
}

fn covariantInference(c: *Checker, ctx: *InferCtx, i: usize) *Type {
    const info = &ctx.infos[i];
    const prim = hasPrimitiveConstraint(c, info.param) or info.param.data.param.is_const;
    const widen = !prim and info.top_level and (info.fixed or ctx.ret == null or !paramAtTop(ctx.ret.?, info.param));
    const candidates = uniteLiteralCandidates(c, ctx, info.candidates.items);
    const base = c.a.alloc(*Type, candidates.len) catch oom();
    for (candidates, 0..) |x, j| {
        base[j] = if (prim) x.regular orelse x else if (widen) expr.widenFresh(c, x) else x;
    }
    const combine = info.priority & Priority.return_type != 0;
    // A fresh literal must not meet the constraint: `T extends Item` lets `T` have more members.
    return expr.widenObjectLiterals(c, if (combine) c.getUnion(base) else commonSupertype(c, base));
}

fn fittingMembers(c: *Checker, t: *Type, k: *Type) *Type {
    if (t.data != .union_) return if (isAssignable(c, t, k)) t else c.t_never;
    var kept = c.newList(*Type);
    for (t.data.union_) |m| if (isAssignable(c, m, k)) kept.append(c.a, m) catch oom();
    return c.getUnion(kept.items);
}

pub fn getInferred(c: *Checker, ctx: *InferCtx, i: usize) *Type {
    const info = &ctx.infos[i];
    if (info.inferred) |t| return t;
    var inferred: *Type = undefined;
    var inferred_any = true;
    var fallback: ?*Type = null;
    if (info.candidates.items.len > 0 or info.contra.items.len > 0) {
        const cov: ?*Type = if (info.candidates.items.len > 0) covariantInference(c, ctx, i) else null;
        var contra: ?*Type = null;
        if (info.contra.items.len > 1 and ctx.conditional) {
            // There is no call to fit here, only what every position asks of the same type:
            // `UnionToIntersection` rests on this.
            contra = c.getIntersection(info.contra.items);
        } else if (info.contra.items.len > 0) {
            var best = info.contra.items[0];
            for (info.contra.items[1..]) |x| if (isSubtype(c, x, best)) {
                best = x;
            };
            contra = best;
        }
        const prefer_cov = cov != null and (contra == null or ctx.conditional or preferCovariant(c, ctx, info, cov.?));
        inferred = if (prefer_cov) cov.? else contra.?;
        fallback = if (prefer_cov) contra else cov;
    } else if (d.defaultOf(c, info.param)) |x| {
        info.inferred = c.t_unknown;
        inferred = d.instantiate(c, x, nonFixing(c, ctx));
    } else {
        inferred = c.t_unknown;
        inferred_any = false;
    }
    info.inferred = inferred;
    if (d.constraintOf(c, info.param)) |k0| {
        const k = d.instantiate(c, k0, nonFixing(c, ctx));
        if (!inferred_any or !isAssignable(c, inferred, k)) {
            // A return position only wished for a type: `T | undefined` still says `T`.
            const fitting = if (inferred_any and info.priority == Priority.return_type) fittingMembers(c, inferred, k) else c.t_never;
            inferred = if (fitting.data != .never) fitting else if (fallback) |x| (if (isAssignable(c, x, k)) x else k) else k;
            info.inferred = inferred;
        }
    }
    return inferred;
}

/// `f(make, { from: "raw" })` with `make: (d: A | B) => R`: the literal has lost its discriminant
/// by the time it votes, and the parameter that wants `A | B` knows better.
fn preferCovariant(c: *Checker, ctx: *InferCtx, info: *InferInfo, cov: *Type) bool {
    if (cov.data == .never or T.isAny(cov)) return false;
    const fits = for (info.contra.items) |x| {
        if (isAssignable(c, cov, x)) break true;
    } else false;
    if (!fits) return false;
    for (ctx.infos) |*other| {
        if (other == info or d.constraintOf(c, other.param) != info.param) continue;
        for (other.candidates.items) |x| if (!isAssignable(c, x, cov)) return false;
    }
    return true;
}

const no_inference: i64 = std.math.maxInt(i64);
const circularity: i64 = -1;

const max_infer_depth = 49;

const Infer = struct {
    c: *Checker,
    ctx: *InferCtx,
    priority: u32,
    contra: bool = false,
    bivariant: bool = false,
    depth: u32 = 0,
    /// The object pairs being walked: recursive declarations unfold forever, and whatever turns
    /// up that deep is about the unfolding and not about the arguments.
    sources: [max_infer_depth]*Type = undefined,
    targets: [max_infer_depth]*Type = undefined,
    nested: u32 = 0,
    expanding: u2 = 0,
    visited: T.IdMap(u64, i64) = .empty,
    /// The best priority of any inference made since this was last reset.
    made: i64 = no_inference,
    /// While inferring through a homomorphic mapped template, `T[K]` stands for the unknown value.
    reverse: ?*Type = null,
    reverse_out: std.ArrayList(*Type) = .empty,

    /// Inference runs for every generic call, and a table that grows from nothing each time
    /// leaves all its old sizes behind in the arena.
    fn recycle(st: *Infer) void {
        if (st.visited.capacity() == 0) return;
        st.visited.clearRetainingCapacity();
        st.c.visited_pool.append(st.c.a, st.visited) catch oom();
    }

    fn infoOf(st: *Infer, t: *Type) ?*InferInfo {
        for (st.ctx.infos) |*i| if (i.param == t) return i;
        return null;
    }

    fn add(st: *Infer, info: *InferInfo, s: *Type, top: bool) void {
        // A literal with a lambda still waiting says nothing yet about what it is as a whole.
        const c = st.c;
        if (isNonInferrable(c, s)) return;
        st.made = @min(st.made, @as(i64, st.priority));
        if (info.fixed) return;
        if (st.priority < info.priority) {
            info.candidates = .empty;
            info.contra = .empty;
            info.top_level = true;
            info.priority = st.priority;
        }
        if (st.priority == info.priority) {
            const list = if (st.contra and !st.bivariant) &info.contra else &info.candidates;
            for (list.items) |x| if (x == s) return;
            if (list.capacity == 0) list.* = c.newList(*Type);
            list.append(c.a, s) catch oom();
            info.inferred = null;
        }
        if (!top and st.priority & Priority.return_type == 0) info.top_level = false;
    }

    fn go(st: *Infer, s0: *Type, t: *Type) void {
        const c = st.c;
        if (!t.vars) return;
        if (st.depth >= max_infer_depth) return;
        st.depth += 1;
        defer st.depth -= 1;
        if (s0 == c.t_pending_fn or s0 == c.t_silent_never) return;
        var s = s0;
        if (st.reverse) |r| if (t == r) {
            st.reverse_out.append(c.a, s) catch oom();
            return;
        };
        if (s.alias) |a| if (t.alias) |b| if (a.sym == b.sym and a.args.len == b.args.len) {
            st.args(aliasVariances(st.c, a.sym), a.args, b.args);
            return;
        };
        if (s.data == .noinfer) s = s.data.noinfer;
        switch (t.data) {
            .noinfer => return,
            .union_ => return st.toUnion(s, t),
            .inter => return st.toIntersection(s, t),
            .param => {
                const info = st.infoOf(t) orelse return;
                st.add(info, s, st.depth == 1);
                return;
            },
            .access => |x| {
                if (s.data == .access) {
                    st.go(s.data.access.obj, x.obj);
                    st.go(s.data.access.index, x.index);
                }
                return;
            },
            .keyof => |x| {
                if (s.data == .keyof) {
                    const save = st.contra;
                    st.contra = !st.contra;
                    st.go(s.data.keyof, x);
                    st.contra = save;
                    return;
                }
                // tsc builds an object with those keys; a silent candidate keeps the call quiet.
                if (x.data == .param and (isLiteralType(s) or s.data == .string)) if (st.infoOf(x)) |info| st.add(info, c.t_err, false);
                return;
            },
            .strmap => |x| {
                if (s.data == .strmap and s.data.strmap.kind == x.kind) st.go(s.data.strmap.ty, x.ty);
                return;
            },
            .cond => |x| {
                if (s.data == .cond) {
                    const y = s.data.cond;
                    st.go(y.check, x.check);
                    st.go(y.extends, x.extends);
                    st.go(d.condThen(c, y), d.condThen(c, x));
                    st.go(d.condEls(c, y), d.condEls(c, x));
                } else {
                    if (x.then_inst == null) x.then_inst = d.instantiate(c, d.condThen(c, x), x.mapper);
                    if (x.els_inst == null) x.els_inst = d.instantiate(c, d.condEls(c, x), x.mapper);
                    const arms = [_]*Type{ x.then_inst.?, x.els_inst.? };
                    for (arms) |m| if (st.infoOf(m) == null) st.go(s, m);
                    // A bare type parameter in one branch says less than what the other branch finds.
                    const save = st.priority;
                    defer st.priority = save;
                    st.priority |= Priority.naked_var;
                    for (arms) |m| if (st.infoOf(m) != null) st.go(s, m);
                }
                return;
            },
            .tmpl => return st.toTemplate(s, t),
            else => {},
        }
        if (s.data == .union_) {
            for (s.data.union_) |m| st.go(m, t);
            return;
        }
        if (s.data != .obj and s.data != .inter) {
            s = d.getApparent(c, s);
            if (s.data != .obj and s.data != .inter) return;
        }
        if (t.data != .obj) return;
        const key = Checker.key2(s.id, t.id);
        if (st.visited.capacity() == 0) st.visited = c.visited_pool.pop() orelse .empty;
        const gop = st.visited.getOrPut(c.a, key) catch oom();
        if (gop.found_existing) {
            st.made = @min(st.made, gop.value_ptr.*);
            return;
        }
        gop.value_ptr.* = circularity;
        const made = st.made;
        st.made = no_inference;
        const expanding = st.expanding;
        st.sources[st.nested] = s;
        st.targets[st.nested] = t;
        st.nested += 1;
        if (deeplyNested(c, s, st.sources[0..st.nested], 2)) st.expanding |= 1;
        if (deeplyNested(c, t, st.targets[0..st.nested], 2)) st.expanding |= 2;
        if (st.expanding == 3) st.made = circularity else st.objects(s, t);
        st.nested -= 1;
        st.expanding = expanding;
        st.visited.put(c.a, key, st.made) catch oom();
        st.made = @min(st.made, made);
    }

    fn toIntersection(st: *Infer, s0: *Type, t: *Type) void {
        const c = st.c;
        var source = s0;
        var targets: []const *Type = t.data.inter;
        const plain = for (targets) |m| {
            if (m.data != .obj or d.isGeneric(c, m)) break false;
        } else true;
        if (!plain and source.data != .union_) {
            // `string[] & { extra: any }` to `string[] & T` says `{ extra: any }` for T.
            var sources: []const *Type = if (source.data == .inter) source.data.inter else &.{source};
            st.pairOff(&sources, &targets, .same);
            if (sources.len == 0 or targets.len == 0) return;
            source = c.getIntersection(sources);
            if (targets.len == 1) {
                st.depth -= 1;
                defer st.depth += 1;
                return st.go(source, targets[0]);
            }
        }
        var naked: ?*InferInfo = null;
        var naked_n: usize = 0;
        for (targets) |m| {
            if (st.infoOf(m)) |info| {
                naked = info;
                naked_n += 1;
            } else st.go(source, m);
        }
        // Two naked parameters could share the source in any way, so neither learns anything.
        if (naked_n != 1) return;
        const save = st.priority;
        defer st.priority = save;
        st.priority |= Priority.naked_var;
        st.add(naked.?, source, st.depth == 1);
    }

    fn sameMember(c: *Checker, s: *Type, t: *Type) bool {
        return s == t or isIdentical(c, s, t);
    }

    fn identicalMember(c: *Checker, s: *Type, t: *Type) bool {
        if (s == t or (s.regular orelse s) == t) return true;
        if (t.data == .string and s.data == .str_lit or t.data == .number and s.data == .num_lit) return true;
        // Two declarations of `{ content: undefined; error: E }` must pair off, or `undefined`
        // from the failure arm of one reaches a type parameter in the success arm of the other.
        return s.data == .obj and t.data == .obj and isIdentical(c, s, t);
    }

    fn closeMember(s: *Type, t: *Type) bool {
        if (s.data == .obj and t.data == .obj) {
            const a = (s.data.obj.target orelse s).data.obj;
            const b = (t.data.obj.target orelse t).data.obj;
            if (a.sym != null and a.sym == b.sym) return true;
            if (a.node != null and a.node == b.node) return true;
        }
        const a = s.alias orelse return false;
        const b = t.alias orelse return false;
        return a.args.len > 0 and a.sym == b.sym;
    }

    /// Pairs off members that match, infers between them, and leaves the rest of both sides.
    fn pairOff(st: *Infer, sources: *[]const *Type, targets: *[]const *Type, how: enum { same, identical, close }) void {
        const c = st.c;
        var hit_s = c.newList(*Type);
        var hit_t = c.newList(*Type);
        for (targets.*) |m| {
            // A distributed conditional gives a union as wide as its source, and only itself can
            // match one of its members, so the pairs are not worth trying.
            if (m.data == .cond and m.alias == null and std.mem.indexOfScalar(*Type, sources.*, m) == null) continue;
            for (sources.*) |x| {
                const hit = switch (how) {
                    .same => sameMember(c, x, m),
                    .identical => identicalMember(c, x, m),
                    .close => closeMember(x, m),
                };
                if (!hit) continue;
                st.go(x, m);
                if (std.mem.indexOfScalar(*Type, hit_s.items, x) == null) hit_s.append(c.a, x) catch oom();
                if (std.mem.indexOfScalar(*Type, hit_t.items, m) == null) hit_t.append(c.a, m) catch oom();
            }
        }
        if (hit_s.items.len > 0) sources.* = without(c, sources.*, hit_s.items);
        if (hit_t.items.len > 0) targets.* = without(c, targets.*, hit_t.items);
    }

    fn without(c: *Checker, list: []const *Type, drop: []const *Type) []const *Type {
        var out = c.newList(*Type);
        for (list) |x| if (std.mem.indexOfScalar(*Type, drop, x) == null) out.append(c.a, x) catch oom();
        return out.items;
    }

    /// `X extends { kind: K } ? X : never` mentions `K` only in its test: nothing can land there.
    fn branchesInert(st: *Infer, m: *Type) bool {
        if (m.data != .cond) return false;
        const x = m.data.cond;
        if (x.then_inst == null) x.then_inst = d.instantiate(st.c, d.condThen(st.c, x), x.mapper);
        if (x.els_inst == null) x.els_inst = d.instantiate(st.c, d.condEls(st.c, x), x.mapper);
        return !x.then_inst.?.vars and !x.els_inst.?.vars;
    }

    fn toUnion(st: *Infer, s: *Type, t: *Type) void {
        const c = st.c;
        var sources: []const *Type = if (s.data == .union_) s.data.union_ else &.{s};
        var targets: []const *Type = t.data.union_;
        st.pairOff(&sources, &targets, .identical);
        st.pairOff(&sources, &targets, .close);
        if (targets.len == 0) return;
        const top = st.depth == 1;
        const save = st.priority;
        defer st.priority = save;
        if (sources.len == 0) {
            // Nothing left to infer from, but inferring nothing would fall back to the constraint:
            // `string` to `string | T` still says something about `T`, at a lower priority.
            st.priority |= Priority.naked_var;
            if (targets.len == 1) if (st.infoOf(targets[0])) |info| return st.add(info, s, top);
            return st.go(s, c.getUnion(targets));
        }
        const src = c.getUnion(sources);
        if (targets.len == 1 and targets[0].data != .param) {
            // One target left is no union any more: `T & D` takes the whole source at once.
            st.depth -= 1;
            defer st.depth += 1;
            return st.go(src, targets[0]);
        }
        const matched = c.a.alloc(bool, sources.len) catch oom();
        @memset(matched, false);
        var naked: ?*InferInfo = null;
        var naked_n: usize = 0;
        var circular = false;
        for (targets) |m| {
            if (st.infoOf(m)) |info| {
                naked = info;
                naked_n += 1;
                continue;
            }
            if (!m.vars or st.branchesInert(m)) continue;
            for (sources, 0..) |x, i| {
                const made = st.made;
                st.made = no_inference;
                st.go(x, m);
                if (st.made == st.priority) matched[i] = true;
                if (st.made == circularity) circular = true;
                st.made = @min(st.made, made);
            }
        }
        if (naked_n == 0) {
            // 'A | B' to 'T & (X | Y)' says 'A | B' for T.
            var only: ?*InferInfo = null;
            for (targets) |m| {
                if (m.data != .inter) return;
                var found: ?*InferInfo = null;
                for (m.data.inter) |y| if (st.infoOf(y)) |info| {
                    if (found != null) return;
                    found = info;
                };
                const info = found orelse return;
                if (only != null and only.? != info) return;
                only = info;
            }
            if (only) |info| {
                st.priority |= Priority.naked_var;
                st.add(info, src, false);
            }
            return;
        }
        if (naked_n == 1 and !circular) {
            var rest = c.newList(*Type);
            for (sources, matched) |x, hit| if (!hit) rest.append(c.a, x) catch oom();
            if (rest.items.len > 0) return st.add(naked.?, c.getUnion(rest.items), top);
        }
        st.priority |= Priority.naked_var;
        for (targets) |m| if (st.infoOf(m)) |info| st.add(info, src, top);
    }

    fn toTemplate(st: *Infer, s: *Type, t: *Type) void {
        const c = st.c;
        const x = t.data.tmpl;
        if (s.data == .str_lit) {
            const v = s.data.str_lit;
            if (!std.mem.startsWith(u8, v, x.texts[0])) return;
            var pos = x.texts[0].len;
            for (x.types, 0..) |ty, i| {
                const lit = x.texts[i + 1];
                const last = i + 1 == x.types.len;
                var end: usize = undefined;
                if (last) {
                    if (!std.mem.endsWith(u8, v, lit) or v.len - lit.len < pos) return;
                    end = v.len - lit.len;
                } else if (lit.len == 0) {
                    if (pos >= v.len) return;
                    end = pos + 1;
                } else {
                    end = std.mem.indexOfPos(u8, v, pos, lit) orelse return;
                }
                st.go(c.strLit(v[pos..end]), ty);
                pos = end + lit.len;
            }
            return;
        }
        if (s.data == .tmpl and s.data.tmpl.types.len == x.types.len) {
            for (s.data.tmpl.types, x.types) |a, b| st.go(a, b);
            return;
        }
        for (x.types) |ty| st.go(c.t_string, ty);
    }

    fn args(st: *Infer, vs: ?[]Variance, from: []*Type, to: []*Type) void {
        for (from, to, 0..) |x, y, i| {
            const contra = vs != null and vs.?[i] == .contravariant;
            if (contra) {
                const save = st.contra;
                st.contra = !st.contra;
                st.go(x, y);
                st.contra = save;
            } else st.go(x, y);
        }
    }

    fn objects(st: *Infer, s: *Type, t: *Type) void {
        const c = st.c;
        if (s.data == .obj) {
            const so = s.data.obj;
            const to = t.data.obj;
            // `readonly X[]` against `T[]` has one thing to say; walking every array method says it
            // again dozens of times.
            if (so.kind == .ref and to.kind == .ref and (so.target == to.target or c.isArrayType(s) and c.isArrayType(t))) {
                st.args(variancesOf(c, to.target.?), so.args.?, to.args.?);
                return;
            }
            if (to.kind == .tuple) return st.toTuple(s, t);
            if (so.kind == .tuple and c.isArrayType(t)) {
                st.go(c.getUnion(so.tuple.elems), to.args.?[0]);
                return;
            }
        }
        if (t.data.obj.kind == .mapped and st.toMapped(s, t)) return;
        if (definitelyUnrelated(c, s, t)) return;
        for (d.propsOf(c, t)) |tp| {
            const sp = d.getProp(c, s, tp.name) orelse continue;
            st.go(d.propType(c, sp), d.propType(c, tp));
        }
        st.signatures(d.callSigs(c, s), d.callSigs(c, t));
        st.signatures(d.ctorSigs(c, s), d.ctorSigs(c, t));
        for (d.indexesOf(c, t)) |ti| {
            if (hasInferableIndex(c, s)) {
                var parts = c.newList(*Type);
                for (d.propsOf(c, s)) |p| {
                    if (!keyApplies(c, ti.key, p.name)) continue;
                    const pt = d.propType(c, p);
                    parts.append(c.a, if (p.optional) removeDefinitelyUndefined(c, pt) else pt) catch oom();
                }
                if (d.genericMappedOrigin(c, s)) |f| for (d.propsOf(c, f)) |p| {
                    if (!keyApplies(c, ti.key, p.name)) continue;
                    const v = d.genericMappedMember(c, s, p.name) orelse continue;
                    parts.append(c.a, removeDefinitelyUndefined(c, v)) catch oom();
                };
                for (d.indexesOf(c, s)) |si| {
                    if (isAssignable(c, si.key, ti.key) or ti.key == c.t_string and si.key == c.t_number) parts.append(c.a, si.ty) catch oom();
                }
                if (parts.items.len > 0) st.go(c.getUnion(parts.items), ti.ty);
            }
            if (d.indexValue(c, s, ti.key)) |v| st.go(v, ti.ty);
        }
    }

    fn toTuple(st: *Infer, s: *Type, t: *Type) void {
        const c = st.c;
        const to = t.data.obj;
        if (s.data != .obj) return;
        if (c.isArrayType(s)) {
            const e = s.data.obj.args.?[0];
            for (to.tuple.elems, to.tuple.eflags) |y, f| {
                if (f == .variadic) st.go(s, y) else st.go(e, y);
            }
            return;
        }
        if (!T.isTupleType(s)) return;
        const so = s.data.obj;
        const n = to.tuple.elems.len;
        const var_at = openAt(to);
        if (var_at == null) {
            for (so.tuple.elems, 0..) |x, i| if (i < n) st.go(x, to.tuple.elems[i]);
            return;
        }
        const k = var_at.?;
        const tail = n - k - 1;
        if (so.tuple.elems.len < k + tail) return;
        for (0..k) |i| st.go(so.tuple.elems[i], to.tuple.elems[i]);
        const mid_end = so.tuple.elems.len - tail;
        const mid = so.tuple.elems[k..mid_end];
        if (to.tuple.eflags[k] == .variadic) {
            st.go(c.makeTuple(mid, so.tuple.eflags[k..mid_end], false, &.{}), to.tuple.elems[k]);
        } else if (mid.len > 0) {
            st.go(c.getUnion(mid), to.tuple.elems[k]);
        }
        for (0..tail) |i| st.go(so.tuple.elems[mid_end + i], to.tuple.elems[k + 1 + i]);
    }

    /// False leaves `t` to be inferred to member by member: `Readonly<Record<string, T>>` has its
    /// keys settled, so there is an index signature to reach `T` through.
    fn toMapped(st: *Infer, s: *Type, t: *Type) bool {
        const c = st.c;
        const n = t.data.obj.node orelse return true;
        const m = n.data.mapped_type;
        if (m.name_type != null) return false;
        const mapper = t.data.obj.mapper;
        const k_node = m.constraint;
        if (k_node.data == .type_operator and k_node.data.type_operator.op == .kw_keyof) {
            const x = d.instantiate(c, d.typeFromNode(c, k_node.data.type_operator.type), mapper);
            if (if (x.data == .obj and x.data.obj.kind == .mapped) !d.mappedKeysGeneric(c, x) else !d.isGeneric(c, x)) return false;
            const save = st.priority;
            st.priority |= Priority.homomorphic;
            defer st.priority = save;
            // `keyof ({ x?: boolean } & T)` still has `keyof T` in it to infer to, but `T & {}` is
            // the idiom for keeping a parameter out of inference.
            const parts: []const *Type = if (x.data != .inter) &.{x} else if (c.hasEmptyMember(x.data.inter)) return true else x.data.inter;
            for (parts) |y| if (st.infoOf(y)) |info| {
                if (st.reverseMapped(s, n, x, mapper)) |r| st.add(info, r, false);
            };
            return true;
        }
        const k = d.instantiate(c, d.typeFromNode(c, k_node), mapper);
        if (k.data == .param) {
            if (st.infoOf(k)) |info| {
                const save = st.priority;
                st.priority |= Priority.mapped_constraint;
                st.add(info, d.getIndexType(c, s), false);
                st.priority = save;
            }
            var parts = c.newList(*Type);
            for (d.propsOf(c, s)) |p| parts.append(c.a, d.propType(c, p)) catch oom();
            if (m.type) |tn| if (parts.items.len > 0) st.go(c.getUnion(parts.items), d.instantiate(c, d.typeFromNode(c, tn), mapper));
            return true;
        }
        return false;
    }

    /// The object whose mapped image would be `s`, one property at a time.
    /// A source with nothing in it says nothing about `x`, so other candidates decide.
    fn reverseMapped(st: *Infer, s: *Type, n: *ast.Node, x: *Type, mapper: ?*T.Mapper) ?*Type {
        const c = st.c;
        const m = n.data.mapped_type;
        const tn = m.type orelse return c.t_err;
        if (s.data != .obj and s.data != .inter) return c.t_err;
        const name = m.tparam_name;
        if (name.data != .identifier) return c.t_err;
        const ls = (n.locals orelse return c.t_err).get(name.data.identifier) orelse return c.t_err;
        if (d.propsOf(c, s).len == 0 and d.indexValue(c, s, c.t_string) == null) return null;
        const access = d.getIndexedAccess(c, x, d.tparamOf(c, ls));
        const template = d.instantiate(c, d.typeFromNode(c, tn), mapper);
        if (template == access) return s;
        if (c.isArrayType(s)) return d.arrayOf(c, st.reverseValue(s.data.obj.args.?[0], template, access));
        if (T.isTupleType(s)) {
            const o = s.data.obj;
            const elems = c.a.alloc(*Type, o.tuple.elems.len) catch oom();
            for (o.tuple.elems, elems) |e, *out| out.* = st.reverseValue(e, template, access);
            return c.makeTuple(elems, o.tuple.eflags, o.readonly, &.{});
        }
        const out = c.emptyMembers();
        for (d.propsOf(c, s)) |p| {
            const v = st.reverseValue(d.propType(c, p), template, access);
            out.props.put(c.a, p.name, c.create(Prop, .{ .name = p.name, .ty = v, .optional = p.optional, .readonly = p.readonly })) catch oom();
        }
        return c.newObj(.{ .kind = .anon, .members = out, .closed = !hasInferableIndex(c, s) });
    }

    fn reverseValue(st: *Infer, s: *Type, template: *Type, access: *Type) *Type {
        const c = st.c;
        var sub = Infer{ .c = c, .ctx = st.ctx, .priority = Priority.max, .reverse = access };
        sub.go(s, template);
        return if (sub.reverse_out.items.len > 0) c.getUnion(sub.reverse_out.items) else c.t_err;
    }

    fn signatures(st: *Infer, ss: []*Sig, ts: []*Sig) void {
        const n = @min(ss.len, ts.len);
        for (0..n) |i| {
            const s = ss[ss.len - n + i];
            const t = ts[ts.len - n + i];
            st.signature(if (ss.len == 1 and ts.len == 1) st.argumentInContext(s, t) else s, t);
        }
    }

    /// tsc gives a lone generic argument the parameter types its parameter already knows, so
    /// `xs.filter(isDefined)` learns from the predicate instead of from a shape.
    fn argumentInContext(st: *Infer, s: *Sig, t: *Sig) *Sig {
        const c = st.c;
        if (s.tparams.len == 0 or t.tparams.len > 0 or st.ctx.conditional) return s;
        // The parameter list itself is being inferred, so it says nothing yet.
        if (restType(c, t)) |r| if (r.vars) return erasedToShape(c, s);
        // A call that returns a function can hand the argument's parameters on to its caller.
        if (st.ctx.ret) |r| if (singleCall(c, r) != null and !hasAllCandidates(st.ctx)) return erasedToShape(c, s);
        const ctx = newInferCtx(c, s.tparams, 0);
        for (0..@min(fixedCount(c, s), fixedCount(c, t))) |i| {
            const x = d.instantiate(c, typeAt(c, t, i) orelse break, nonFixing(c, st.ctx));
            // A parameter that knows nothing yet has nothing to fix the argument with.
            if (T.isAny(x) or x.data == .unknown) return erasedToShape(c, s);
            inferTypes(c, ctx, x, typeAt(c, s, i) orelse break, 0);
        }
        return d.applySig(c, s, ctx.mapper);
    }

    fn signature(st: *Infer, s0: *Sig, t0: *Sig) void {
        const c = st.c;
        var s = s0;
        // Its own parameters mean nothing to the target, but their constraints say what they hold.
        if (s.tparams.len > 0) s = baseSignature(c, s);
        // Its own parameters say nothing either: `catch<R>(): Promise<T | R>` must not read as `T`.
        const t = erased(c, t0);
        const save_bi = st.bivariant;
        st.bivariant = st.bivariant or isMethodLike(t) or !c.strict_fn;
        const n = @max(fixedCount(c, s), fixedCount(c, t));
        if (s.this_ty) |x| if (t.this_ty) |y| st.flip(x, y);
        // `(...args: A) => R` takes the whole parameter list as one tuple.
        const fixed_t = if (t.has_rest) t.params.len - 1 else t.params.len;
        for (0..fixed_t) |i| {
            const x = typeAt(c, s, i) orelse break;
            st.flip(x, d.paramTypeAt(c, t, i));
        }
        if (restType(c, t)) |r| {
            if (r.vars) {
                if (r.data == .param or (r.data == .access)) {
                    st.flip(restFrom(c, s, fixed_t), r);
                } else {
                    var i: usize = fixed_t;
                    while (i < n) : (i += 1) {
                        const x = typeAt(c, s, i) orelse break;
                        const y = typeAt(c, t, i) orelse break;
                        st.flip(x, y);
                    }
                }
            }
        }
        st.bivariant = save_bi;
        if (d.predOf(c, s)) |ps| if (d.predOf(c, t)) |pt| {
            if (ps.is_this == pt.is_this and ps.asserts == pt.asserts and ps.ty != null and pt.ty != null) return st.go(ps.ty.?, pt.ty.?);
        };
        st.go(d.returnOf(c, s), d.returnOf(c, t));
    }

    fn flip(st: *Infer, s: *Type, t: *Type) void {
        if (st.bivariant) return st.go(s, t);
        const save = st.contra;
        st.contra = !st.contra;
        st.go(s, t);
        st.contra = save;
    }
};

/// Everything from parameter `pos` on, as the tuple `(...args: A) => R` binds to `A`.
fn restFrom(c: *Checker, s: *Sig, pos: usize) *Type {
    const rest = restType(c, s);
    const fixed = if (rest != null) s.params.len - 1 else s.params.len;
    if (rest) |r| {
        if (pos == fixed) return r;
        if (pos > fixed) return d.arrayOf(c, d.getIndexedAccess(c, r, c.t_number));
    }
    var elems = c.newList(*Type);
    var flags = c.newList(T.ElemFlag);
    const min = arityOf(c, s).min;
    for (@min(pos, fixed)..fixed) |i| {
        elems.append(c.a, d.paramTypeAt(c, s, i)) catch oom();
        flags.append(c.a, if (i >= min) .optional else .required) catch oom();
    }
    if (rest) |r| {
        elems.append(c.a, r) catch oom();
        flags.append(c.a, .variadic) catch oom();
    }
    return c.makeTuple(elems.items, flags.items, false, &.{});
}

pub fn inferTypes(c: *Checker, ctx: *InferCtx, s: *Type, t: *Type, priority: u32) void {
    var st = Infer{ .c = c, .ctx = ctx, .priority = priority };
    defer st.recycle();
    st.go(s, t);
}
