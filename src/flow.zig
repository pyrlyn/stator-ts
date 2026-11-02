//! Control-flow analysis: what a reference's type is at a point, and whether a point is reachable.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const expr = @import("expr.zig");
const relate = @import("relate.zig");
const Node = ast.Node;
const FlowNode = binder.FlowNode;
const Checker = T.Checker;
const Type = T.Type;
const F = binder.F;
const oom = T.oom;

/// `(x as T)` is a new reference, unlike the wrappers below: a test on it says nothing about `x`.
fn strip(n: *Node) *Node {
    var cur = n;
    while (true) switch (cur.data) {
        .paren => |x| cur = x.expr,
        .non_null => |x| cur = x.expr,
        .satisfies_expr => |x| cur = x.expr,
        else => return cur,
    };
}

/// `(x = f()) !== null` tests `x`.
fn refCandidate(n0: *Node) *Node {
    const n = strip(n0);
    if (n.data != .binary) return n;
    const x = n.data.binary;
    return switch (x.op) {
        .assign, .pipe2_assign, .amp2_assign, .qq_assign => refCandidate(x.left),
        .comma => refCandidate(x.right),
        else => n,
    };
}

fn accessName(c: *Checker, n: *Node) ?[]const u8 {
    return switch (n.data) {
        .prop_access => |x| ast.memberText(x.name),
        .qualified_name => |x| ast.memberText(x.right),
        .elem_access => |x| switch (strip(x.index).data) {
            .string_lit, .no_subst_template => |v| v,
            .numeric_lit => |v| d.numName(c, (@import("emit.zig").parseNumber(v) orelse 0)),
            .identifier, .prop_access => constKeyName(c, strip(x.index)),
            else => null,
        },
        else => null,
    };
}

/// `o[KEY]` and `o.x` are one reference when `KEY` is a constant holding "x", imported or not.
fn constKeyName(c: *Checker, k: *Node) ?[]const u8 {
    const gop = c.const_keys.getOrPut(c.a, k) catch oom();
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = null;
    const s = keySymbol(c, k) orelse return null;
    if (s.flags & F.enum_member == 0 and !expr.isConstVar(s)) return null;
    // From the symbol, not the expression: checking `k` runs flow analysis, and this runs inside it.
    const name = d.literalName(c, d.typeOfSymbol(c, s));
    c.const_keys.put(c.a, k, name) catch oom();
    return name;
}

fn keySymbol(c: *Checker, k: *Node) ?*binder.Symbol {
    switch (k.data) {
        .identifier => return d.targetOf(c, expr.symbolOf(c, k) orelse return null),
        .prop_access => |x| {
            const o = keySymbol(c, strip(x.expr)) orelse return null;
            const table = o.exports orelse return null;
            return d.targetOf(c, table.get(ast.memberText(x.name)) orelse return null);
        },
        else => return null,
    }
}

/// `o[k]` narrows like a property while nothing can change `k`.
fn constKeySym(c: *Checker, n: *Node) ?*@import("binder.zig").Symbol {
    if (n.data != .elem_access) return null;
    const k = strip(n.data.elem_access.index);
    if (k.data != .identifier) return null;
    const s = expr.symbolOf(c, k) orelse return null;
    return if (expr.isStableBinding(c, s)) s else null;
}

/// A reference no assignment can invalidate between an aliased condition and its use.
fn isConstantRef(c: *Checker, n0: *Node) bool {
    const n = strip(n0);
    if (c.constant_refs.get(n)) |known| return known;
    const v = computeConstantRef(c, n);
    c.constant_refs.put(c.a, n, v) catch oom();
    return v;
}

fn computeConstantRef(c: *Checker, n: *Node) bool {
    switch (n.data) {
        .this_expr => return true,
        .identifier => {
            const s = expr.symbolOf(c, n) orelse return false;
            return expr.isStableBinding(c, s);
        },
        .prop_access, .elem_access => {
            const o = accessObject(n) orelse return false;
            if (!isConstantRef(c, o)) return false;
            const name = accessName(c, n) orelse return false;
            const p = d.getProp(c, operand(c, o), name) orelse return false;
            return p.readonly;
        },
        else => return false,
    }
}

fn plainBindingName(c: *Checker, el: *Node) ?[]const u8 {
    const e = el.data.binding_elem;
    if (e.init != null or e.dotdotdot) return null;
    const pat = el.parent orelse return null;
    if (pat.data == .array_pattern) {
        const i = std.mem.indexOfScalar(*Node, pat.data.array_pattern.elems, el) orelse return null;
        return d.numName(c, @floatFromInt(i));
    }
    return expr.propNameOf(c, e.prop_name orelse e.name);
}

fn accessObject(n: *Node) ?*Node {
    return switch (n.data) {
        .prop_access => |x| x.expr,
        .elem_access => |x| x.expr,
        .qualified_name => |x| x.left,
        else => null,
    };
}

fn chainObject(n: *Node) ?*Node {
    return switch (n.data) {
        .call => |x| x.callee,
        // tsc does not look into a dotted name here, so assigning `o` leaves `typeof o.v` narrowed.
        .qualified_name => null,
        else => accessObject(n),
    };
}

pub fn matchingRef(c: *Checker, r0: *Node, n0: *Node) bool {
    const r = strip(r0);
    const n = strip(n0);
    switch (n.data) {
        .identifier => {
            // Every step of a walk lands here: the names rule out nearly all of them without a lookup.
            if (r.data != .identifier or !std.mem.eql(u8, r.data.identifier, n.data.identifier)) return false;
            const s = expr.symbolOf(c, r) orelse return false;
            return s == expr.symbolOf(c, n);
        },
        .var_decl, .binding_elem => {
            const s = n.symbol() orelse return false;
            if (r.data != .identifier or !std.mem.eql(u8, r.data.identifier, s.name)) return false;
            return expr.symbolOf(c, r) == s;
        },
        .this_expr => return r.data == .this_expr,
        .super_expr => return r.data == .super_expr,
        .prop_access, .elem_access => {
            const a = accessName(c, n) orelse {
                const k = constKeySym(c, n);
                if (k == null or k != constKeySym(c, r)) return false;
                return matchingRef(c, accessObject(r).?, accessObject(n).?);
            };
            const b = accessName(c, r) orelse return false;
            if (!std.mem.eql(u8, a, b)) return false;
            return matchingRef(c, accessObject(r).?, accessObject(n).?);
        },
        .binary => |x| {
            if (x.op == .comma) return matchingRef(c, r0, x.right);
            return x.op.isAssignment() and matchingRef(c, r0, x.left);
        },
        else => return false,
    }
}

fn containsRef(c: *Checker, source: *Node, target: *Node) bool {
    var cur = strip(source);
    while (chainObject(cur)) |o| {
        cur = strip(o);
        // `(x = f())?.y` tests `x`: the assignment is what stands in the chain.
        if (matchingRef(c, cur, target) or matchingRef(c, target, cur)) return true;
    }
    return false;
}

fn refKey(c: *Checker, n0: *Node) u64 {
    const n = strip(n0);
    return switch (n.data) {
        .identifier => @intFromPtr(expr.symbolOf(c, n)),
        .this_expr => 1,
        .super_expr => 2,
        .prop_access, .elem_access => blk: {
            const name = accessName(c, n) orelse std.mem.asBytes(&constKeySym(c, n));
            break :blk std.hash.Wyhash.hash(refKey(c, accessObject(n).?), name);
        },
        else => @intFromPtr(n),
    };
}

/// What a loop assigns or compares with can read what is assigned elsewhere in it, and with nothing
/// final to cache those reads multiply. One evaluation per round of the outermost loop is enough,
/// as the rounds themselves carry the types around the loop.
fn oncePerRound(c: *Checker, memo: *T.IdMap(*Node, Checker.Provisional), n: *Node, comptime eval: anytype) ?*Type {
    if (c.flow_active.count() == 0) return eval(c, n);
    if (memo.get(n)) |a| {
        c.flow_touched = @min(c.flow_touched, a.touched);
        return a.ty;
    }
    const touched = c.flow_touched;
    c.flow_touched = T.flow_untouched;
    defer c.flow_touched = @min(touched, c.flow_touched);
    const t = eval(c, n) orelse return null;
    memo.put(c.a, n, .{ .ty = t, .touched = c.flow_touched }) catch oom();
    return t;
}

fn forgetRound(c: *Checker) void {
    c.flow_assigned.clearRetainingCapacity();
    c.flow_operands.clearRetainingCapacity();
}

fn assignedOnce(c: *Checker, n: *Node) ?*Type {
    return oncePerRound(c, &c.flow_assigned, n, expr.assignedType);
}

fn operandType(c: *Checker, n: *Node) ?*Type {
    return expr.checkSilent(c, n);
}

fn operand(c: *Checker, n: *Node) *Type {
    return oncePerRound(c, &c.flow_operands, n, operandType).?;
}

const St = struct {
    c: *Checker,
    ref: *Node,
    declared: *Type,
    initial: *Type,
    container: ?*Node,
    key: u64,
    loops: u32 = 0,
    /// Depth of conditions followed through `const ok = x != null`, capped like tsc.
    inlined: u32 = 0,
    /// What read an unsettled loop cannot go in the shared cache, yet the sequential `if`s of a
    /// loop body fan out exponentially without one. This holds for one fixpoint round only.
    round: T.IdMap(*FlowNode, Checker.Provisional) = .empty,

    /// Past a `finally`, the walk sees its label with fewer antecedents. Flow nodes are shared
    /// between checkers, so that view lives here and is part of every cache key.
    over: ?*Over = null,

    const Over = struct { f: *FlowNode, prev: ?*Over };

    fn cacheKey(st: *St, f: *FlowNode) Checker.FlowKey {
        const salt: u64 = if (st.over) |o| @intFromPtr(o.f) else 0;
        return .{ .flow = f, .ref = st.key +% salt, .declared = st.declared.id };
    }

    fn go(st: *St, f0: *FlowNode) *Type {
        const c = st.c;
        var f = f0;
        while (true) {
            switch (f.kind) {
                .assign => {
                    if (st.assignment(f)) |t| return t;
                    f = f.antecedent orelse return st.initial;
                },
                .call => {
                    if (st.callNode(f)) |t| return t;
                    f = f.antecedent orelse return st.initial;
                },
                .true_cond, .false_cond => return st.condition(f),
                .switch_clause => return st.switchClause(f),
                .branch => return st.branch(f),
                .loop => return st.loop(f),
                .reduce => {
                    var o = Over{ .f = f, .prev = st.over };
                    st.over = &o;
                    defer st.over = o.prev;
                    return st.go(f.antecedent.?);
                },
                .start => {
                    const n = f.node orelse return st.initial;
                    if (n == st.container or strip(st.ref).data != .identifier) return st.initial;
                    f = n.flow() orelse return st.initial;
                },
                .unreachable_end => return c.t_unreachable,
            }
        }
    }

    fn assignment(st: *St, f: *FlowNode) ?*Type {
        const c = st.c;
        const n = f.node orelse return null;
        if (matchingRef(c, st.ref, n)) {
            if (st.declared == c.t_auto) {
                // `x += 1` keeps what `x` already was.
                if (expr.isCompound(n)) return null;
                // A chain of `a = f(a)` reads every earlier link, so each is worked out once.
                const k = st.cacheKey(f);
                if (st.recall(k, f)) |t| return t;
                const touched = c.flow_touched;
                c.flow_touched = T.flow_untouched;
                const t = assignedOnce(c, n) orelse {
                    c.flow_touched = @min(touched, c.flow_touched);
                    return if (n.data == .var_decl) null else st.declared;
                };
                const r = expr.widenInit(c, n, t, false);
                st.settle(k, f, r, touched);
                return r;
            }
            if (st.declared.data != .union_) return st.declared;
            const assigned = assignedOnce(c, n) orelse return st.declared;
            return reduceAssigned(c, st.declared, assigned);
        }
        if (containsRef(c, st.ref, n)) {
            // `const f = () => {}; f.x = 1`: declaring `f` does not reset `f.x`, it starts it.
            if (n.data == .var_decl) if (n.symbol()) |s| if (binder.holdsExpandos(s)) return null;
            return st.declared;
        }
        return null;
    }

    fn callNode(st: *St, f: *FlowNode) ?*Type {
        const c = st.c;
        const n = f.node orelse return null;
        const sig = expr.effectsSig(c, n) orelse return null;
        if (d.predOf(c, sig)) |p| if (p.asserts) {
            const t = st.go(f.antecedent orelse return st.initial);
            return st.byPredicate(t, n, p, true);
        };
        if (d.returnOf(c, sig).data == .never) return c.t_unreachable;
        return null;
    }

    fn condition(st: *St, f: *FlowNode) *Type {
        const c = st.c;
        const t = st.go(f.antecedent orelse return st.initial);
        if (t.data == .never) return t;
        const n = f.node orelse return t;
        if (f.present) return st.byPresence(t, n);
        return st.narrow(t, n, f.kind == .true_cond) orelse c.t_never;
    }

    fn branch(st: *St, f: *FlowNode) *Type {
        const c = st.c;
        const k = st.cacheKey(f);
        if (st.recall(k, f)) |t| return t;
        const touched = c.flow_touched;
        c.flow_touched = T.flow_untouched;
        var bypass: ?*FlowNode = null;
        var antecedents = f.antecedents;
        const over = st.over;
        defer st.over = over;
        if (over) |o| if (o.f.reduce_target == f) {
            antecedents = o.f.antecedents;
            st.over = o.prev;
        };
        var parts = std.ArrayList(*Type).initCapacity(c.a, antecedents.len) catch oom();
        for (antecedents) |a| {
            if (bypass == null and a.kind == .switch_clause and a.clause_start == a.clause_end) {
                bypass = a;
                continue;
            }
            const t = st.go(a);
            if (t == st.declared and st.declared == st.initial) {
                st.settle(k, f, t, touched);
                return t;
            }
            parts.appendAssumeCapacity(t);
        }
        // The unmatched path of a switch only counts when some value can actually take it.
        if (bypass) |b| {
            const t = st.go(b);
            if (t.data != .never and std.mem.indexOfScalar(*Type, parts.items, t) == null and !expr.isExhaustive(c, b.node.?)) {
                parts.appendAssumeCapacity(t);
            }
        }
        const r = joinTypes(c, st.declared, parts.items);
        st.settle(k, f, r, touched);
        return r;
    }

    /// `touched` is what `flow_touched` held when this node started. A result that read no unsettled
    /// loop is final; any other was computed from a temporary type and lives for this walk only.
    fn settle(st: *St, k: Checker.FlowKey, f: *FlowNode, t: *Type, touched: u32) void {
        const c = st.c;
        if (c.flow_touched == T.flow_untouched) {
            c.flow_cache.put(c.a, k, t) catch oom();
        } else if (st.over == null) st.round.put(c.a, f, .{ .ty = t, .touched = c.flow_touched }) catch oom();
        c.flow_touched = @min(touched, c.flow_touched);
    }

    fn recall(st: *St, k: Checker.FlowKey, f: *FlowNode) ?*Type {
        const c = st.c;
        if (c.flow_cache.get(k)) |t| return t;
        if (st.over != null) return null;
        const p = st.round.get(f) orelse return null;
        c.flow_touched = @min(c.flow_touched, p.touched);
        return p.ty;
    }

    fn loop(st: *St, f: *FlowNode) *Type {
        const c = st.c;
        const k = st.cacheKey(f);
        if (st.recall(k, f)) |t| return t;
        if (c.flow_active.get(k)) |a| {
            c.flow_touched = @min(c.flow_touched, a.depth);
            return a.ty;
        }
        if (f.antecedents.len == 0) return st.initial;
        const depth: u32 = @intCast(c.flow_active.count());
        const touched = c.flow_touched;
        c.flow_touched = T.flow_untouched;
        if (depth == 0) forgetRound(c);
        // After an endless loop nothing enters this one, so its first edge can lead back here.
        c.flow_active.put(c.a, k, .{ .ty = c.t_unreachable, .depth = depth }) catch oom();
        var cur = st.go(f.antecedents[0]);
        _ = c.flow_active.remove(k);
        // The declared type is as wide as it gets: walking the back edges could only reach calls
        // whose assertion check needs the very variable being resolved.
        if (cur != st.declared) {
            const outer_round = st.round;
            st.loops += 1;
            var round: u32 = 0;
            while (round < 4) : (round += 1) {
                st.round = .empty;
                if (depth == 0) forgetRound(c);
                c.flow_active.put(c.a, k, .{ .ty = cur, .depth = depth }) catch oom();
                var parts = c.newList(*Type);
                parts.append(c.a, cur) catch oom();
                for (f.antecedents[1..]) |a| {
                    const t = st.go(a);
                    parts.append(c.a, t) catch oom();
                    if (t == st.declared) break;
                }
                const next = joinTypes(c, st.declared, parts.items);
                if (next == cur) break;
                cur = next;
            }
            _ = c.flow_active.remove(k);
            st.loops -= 1;
            st.round = outer_round;
        }
        // Having read itself is fine now that it has settled; only outer loops still count.
        if (c.flow_touched >= depth) c.flow_touched = T.flow_untouched;
        st.settle(k, f, cur, touched);
        return cur;
    }

    fn switchClause(st: *St, f: *FlowNode) *Type {
        const c = st.c;
        const t = st.go(f.antecedent orelse return st.initial);
        if (t.data == .never) return t;
        const sw = f.node orelse return t;
        const x = sw.data.switch_stmt;
        const e = strip(x.expr);
        if (matchingRef(c, st.ref, e)) return narrowSwitch(c, t, sw, f.clause_start, f.clause_end);
        if (e.data == .typeof_expr and matchingRef(c, st.ref, e.data.typeof_expr.expr)) {
            return narrowSwitchTypeof(c, t, sw, f.clause_start, f.clause_end);
        }
        if (e.data == .true_lit) {
            var cur = t;
            for (x.clauses[f.clause_start..f.clause_end]) |cl| {
                if (cl.data != .case_clause) continue;
                return st.narrow(cur, cl.data.case_clause.expr, true) orelse c.t_never;
            }
            if (f.clause_start == f.clause_end) {
                for (x.clauses) |cl| {
                    if (cl.data == .case_clause) cur = st.narrow(cur, cl.data.case_clause.expr, false) orelse c.t_never;
                }
            }
            return cur;
        }
        var cur = t;
        // `switch (a?.b)` with no clause matching undefined proves `a` present in that clause.
        if (c.strict_null and f.clause_start != f.clause_end and containsRef(c, e, st.ref) and isOptionalChain(e)) {
            const every = for (x.clauses[f.clause_start..f.clause_end]) |cl| {
                if (cl.data != .case_clause) break false;
                const v = operand(c, cl.data.case_clause.expr);
                if (v.data == .undefined or v.data == .never) break false;
            } else true;
            if (every) cur = expr.nonNull(c, cur);
        }
        if (st.discriminant(e, cur)) |name| {
            return st.byDiscriminant(cur, name, struct {
                sw: *Node,
                s: u32,
                e: u32,
                fn run(self: @This(), cc: *Checker, pt: *Type) *Type {
                    return narrowSwitch(cc, pt, self.sw, self.s, self.e);
                }
            }{ .sw = sw, .s = f.clause_start, .e = f.clause_end });
        }
        return cur;
    }

    /// The property name when `n` reads a discriminant of the reference, as in `x.kind`.
    /// The property `n` stands for, when it reads one from this reference: `x.kind`, or a
    /// constant that holds it, or a sibling binding when the reference is the pattern itself.
    fn candidateName(st: *St, n: *Node) ?[]const u8 {
        const c = st.c;
        if (st.ref.data == .object_pattern or st.ref.data == .array_pattern) {
            if (n.data != .identifier) return null;
            const s = expr.symbolOf(c, n) orelse return null;
            const dn = s.value_decl orelse return null;
            if (dn.data != .binding_elem or dn.parent != st.ref) return null;
            return plainBindingName(c, dn);
        }
        switch (n.data) {
            .prop_access, .elem_access => {
                if (!matchingRef(c, st.ref, accessObject(n).?)) return null;
                return accessName(c, n);
            },
            .identifier => {
                const s = expr.symbolOf(c, n) orelse return null;
                if (!expr.isConstVar(s)) return null;
                const dn = s.value_decl orelse return null;
                switch (dn.data) {
                    .var_decl => |v| {
                        if (v.type != null) return null;
                        const i = strip(v.init orelse return null);
                        if (i.data != .prop_access and i.data != .elem_access) return null;
                        if (!matchingRef(c, st.ref, accessObject(i).?)) return null;
                        return accessName(c, i);
                    },
                    .binding_elem => {
                        const owner = (dn.parent orelse return null).parent orelse return null;
                        if (owner.data != .var_decl or owner.data.var_decl.type != null) return null;
                        const i = strip(owner.data.var_decl.init orelse return null);
                        if (i.data != .identifier and i.data != .prop_access and i.data != .elem_access) return null;
                        if (!matchingRef(c, st.ref, i)) return null;
                        return plainBindingName(c, dn);
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    fn discriminant(st: *St, n: *Node, t: *Type) ?[]const u8 {
        const c = st.c;
        const name = st.candidateName(n) orelse return null;
        if (st.declared.data != .union_ and t.data != .union_) return null;
        const u = if (st.declared.data == .union_) st.declared else t;
        return if (relate.isDiscriminant(c, u.data.union_, name)) name else null;
    }

    fn byDiscriminant(st: *St, t: *Type, name: []const u8, op: anytype) *Type {
        const c = st.c;
        const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
        var small: [d.small_list]*Type = undefined;
        const parts = d.smallList(c, &small, members.len);
        defer if (parts.len > small.len) c.a.free(parts);
        var count: usize = 0;
        for (members) |m| {
            const p = d.getProp(c, m, name) orelse {
                parts[count] = m;
                count += 1;
                continue;
            };
            const pt = d.propType(c, p);
            const narrowed = op.run(c, pt);
            if (narrowed.data != .never) {
                parts[count] = m;
                count += 1;
            }
        }
        return c.getUnion(parts[0..count]);
    }

    fn truthyAccess(st: *St, t: *Type, n: *Node, assume: bool) ?*Type {
        const name = st.discriminant(n, t) orelse return null;
        return st.byDiscriminant(t, name, struct {
            assume: bool,
            fn run(self: @This(), cc: *Checker, pt: *Type) *Type {
                return byTruthiness(cc, pt, self.assume);
            }
        }{ .assume = assume });
    }

    fn narrow(st: *St, t: *Type, n0: *Node, assume: bool) ?*Type {
        const c = st.c;
        const n = switch (n0.data) {
            .paren => |x| x.expr,
            .non_null => |x| x.expr,
            else => n0,
        };
        if (n != n0) return st.narrow(t, n, assume);
        if (isNullishLeft(n)) return st.byOptionality(t, n, assume);
        switch (n.data) {
            .identifier, .this_expr, .super_expr, .prop_access, .elem_access => {
                if (matchingRef(c, st.ref, n)) {
                    // A false `a?.b` may be a missing `a`, and then `b` was never looked at.
                    return if (!assume and isOptionalChain(n)) t else byTruthiness(c, t, assume);
                }
                if (n.data == .identifier and st.inlined < 5) if (expr.aliasedCondition(c, n)) |init| {
                    if (isConstantRef(c, st.ref)) {
                        st.inlined += 1;
                        defer st.inlined -= 1;
                        return st.narrow(t, init, assume);
                    }
                };
                // `r?.ok` proves `r` present, and then still discriminates what is left of it.
                const cur = if (assume and c.strict_null and containsRef(c, n, st.ref) and isOptionalChain(n)) expr.nonNull(c, t) else t;
                if (st.truthyAccess(cur, strip(n), assume)) |r| return r;
                return cur;
            },
            .call => return st.byCall(t, n, assume),
            .prefix => |x| {
                if (x.op == .bang) return st.narrow(t, x.expr, !assume);
                return t;
            },
            .binary => |x| return st.byBinary(t, n, x.left, x.op, x.right, assume),
            else => return t,
        }
    }

    /// `a ?? b` asks whether `a` is present, not whether it is truthy.
    fn byOptionality(st: *St, t: *Type, n: *Node, present: bool) *Type {
        if (present) return st.byPresence(t, n);
        const c = st.c;
        if (matchingRef(c, st.ref, n)) return if (T.isAny(t)) t else narrowNullish(c, t, c.t_undefined, true, true);
        if (st.discriminant(strip(n), t)) |name| {
            return st.byDiscriminant(t, name, struct {
                fn run(_: @This(), cc: *Checker, pt: *Type) *Type {
                    return if (T.isAny(pt)) pt else narrowNullish(cc, pt, cc.t_undefined, true, true);
                }
            }{});
        }
        return t;
    }

    fn byPresence(st: *St, t: *Type, n: *Node) *Type {
        const c = st.c;
        if (matchingRef(c, st.ref, n)) return expr.nonNull(c, t);
        if (st.discriminant(strip(n), t)) |name| {
            return st.byDiscriminant(t, name, struct {
                fn run(_: @This(), cc: *Checker, pt: *Type) *Type {
                    return expr.nonNull(cc, pt);
                }
            }{});
        }
        return t;
    }

    /// Runs on every condition met on the way back from a reference, so it must stay syntactic:
    /// resolving the call first would make long runs of assertions quadratic per reference.
    fn hasMatchingArgument(st: *St, n: *Node) bool {
        const c = st.c;
        if (n.data != .call) return true;
        const call = n.data.call;
        for (call.args) |a| {
            if (matchingRef(c, st.ref, a) or containsRef(c, st.ref, a)) return true;
            if (isOptionalChain(a) and containsRef(c, a, st.ref)) return true;
        }
        const callee = strip(call.callee);
        if (callee.data != .prop_access) return false;
        const o = callee.data.prop_access.expr;
        return matchingRef(c, st.ref, o) or containsRef(c, st.ref, o);
    }

    fn byCall(st: *St, t0: *Type, n: *Node, assume: bool) *Type {
        const c = st.c;
        const t = if (assume and c.strict_null and containsRef(c, n, st.ref) and isOptionalChain(n)) expr.nonNull(c, t0) else t0;
        if (!st.hasMatchingArgument(n)) return t;
        const sig = expr.resolvedSig(c, n) orelse return t;
        const p = d.predOf(c, sig) orelse return t;
        if (p.ty == null) return t;
        return st.byPredicate(t, n, p, assume);
    }

    fn byPredicate(st: *St, t: *Type, n: *Node, p: *T.Pred, assume: bool) *Type {
        const c = st.c;
        const call = n.data.call;
        var arg: ?*Node = null;
        if (p.is_this) {
            const callee = strip(call.callee);
            arg = accessObject(callee);
        } else if (p.param_index >= 0 and p.param_index < call.args.len) {
            arg = call.args[@intCast(p.param_index)];
        }
        const a = arg orelse return t;
        if (p.ty) |ty| {
            if (T.isAny(t) and (ty == d.globalType(c, "Object") or ty == d.globalType(c, "Function"))) return t;
            if (matchingRef(c, st.ref, a)) return narrowedType(c, t, ty, assume, false);
            const present = assume and c.strict_null and containsRef(c, a, st.ref) and isOptionalChain(a);
            const cur = if (present) expr.nonNull(c, t) else t;
            if (st.discriminant(strip(a), cur)) |name| {
                return st.byDiscriminant(cur, name, struct {
                    ty: *Type,
                    assume: bool,
                    fn run(self: @This(), cc: *Checker, pt: *Type) *Type {
                        return narrowedType(cc, pt, self.ty, self.assume, false);
                    }
                }{ .ty = ty, .assume = assume });
            }
            return cur;
        }
        return st.byAssertion(t, a);
    }

    fn byAssertion(st: *St, t: *Type, a0: *Node) *Type {
        const c = st.c;
        const a = strip(a0);
        if (a.data == .false_lit) return c.t_unreachable;
        if (a.data == .binary) {
            const x = a.data.binary;
            if (x.op == .amp2) return st.byAssertion(st.byAssertion(t, x.left), x.right);
            if (x.op == .pipe2) return c.getUnion(&.{ st.byAssertion(t, x.left), st.byAssertion(t, x.right) });
        }
        return st.narrow(t, a, true) orelse t;
    }

    fn byBinary(st: *St, t: *Type, n: *Node, left: *Node, op: @import("lexer.zig").Tok, right: *Node, assume: bool) *Type {
        const c = st.c;
        switch (op) {
            .assign => {
                if (matchingRef(c, st.ref, left)) return byTruthiness(c, t, assume);
                return st.narrow(t, right, assume) orelse t;
            },
            .amp2 => {
                if (assume) return st.narrow(st.narrow(t, left, true) orelse t, right, true) orelse t;
                const a = st.narrow(t, left, false) orelse t;
                const b = st.narrow(st.narrow(t, left, true) orelse t, right, false) orelse t;
                return c.getUnion(&.{ a, b });
            },
            .pipe2 => {
                if (!assume) return st.narrow(st.narrow(t, left, false) orelse t, right, false) orelse t;
                const a = st.narrow(t, left, true) orelse t;
                const b = st.narrow(st.narrow(t, left, false) orelse t, right, true) orelse t;
                return c.getUnion(&.{ a, b });
            },
            .eq2, .eq3, .neq, .neq3 => {
                const l = refCandidate(left);
                const r = refCandidate(right);
                if (l.data == .typeof_expr and isStringLit(r)) return st.byTypeof(t, l, r, op, assume);
                if (r.data == .typeof_expr and isStringLit(l)) return st.byTypeof(t, r, l, op, assume);
                if (matchingRef(c, st.ref, l)) return byEquality(c, t, op, right, assume);
                if (matchingRef(c, st.ref, r)) return byEquality(c, t, op, left, assume);
                // `a?.b === 1` proves `a` present, before any discriminant applies to it.
                var cur = t;
                if (c.strict_null) {
                    if (containsRef(c, l, st.ref) and isOptionalChain(l) and proveDefined(c, op, right, assume)) cur = expr.nonNull(c, cur);
                    if (containsRef(c, r, st.ref) and isOptionalChain(r) and proveDefined(c, op, left, assume)) cur = expr.nonNull(c, cur);
                }
                if (st.discriminant(l, cur)) |name| return st.discEq(cur, name, op, right, assume);
                if (st.discriminant(r, cur)) |name| return st.discEq(cur, name, op, left, assume);
                if (isConstructorOf(c, st.ref, l)) return byConstructor(c, cur, op, right, assume);
                if (isConstructorOf(c, st.ref, r)) return byConstructor(c, cur, op, left, assume);
                return cur;
            },
            .kw_instanceof => {
                const l = refCandidate(left);
                if (!matchingRef(c, st.ref, l)) {
                    // `a?.b instanceof C` holds only when `a` is there.
                    return if (assume and isOptionalChain(l) and containsRef(c, l, st.ref)) expr.nonNull(c, t) else t;
                }
                return byInstanceof(c, t, right, assume);
            },
            .kw_in => {
                if (!matchingRef(c, st.ref, refCandidate(right))) return t;
                const key = operand(c, left);
                const name = d.literalName(c, key.regular orelse key) orelse return t;
                return byIn(c, t, name, assume);
            },
            .comma => return st.narrow(t, right, assume) orelse t,
            else => {
                _ = n;
                return t;
            },
        }
    }

    fn discEq(st: *St, t: *Type, name: []const u8, op: @import("lexer.zig").Tok, value: *Node, assume: bool) *Type {
        return st.byDiscriminant(t, name, struct {
            op: @import("lexer.zig").Tok,
            value: *Node,
            assume: bool,
            fn run(self: @This(), cc: *Checker, pt: *Type) *Type {
                return byEquality(cc, pt, self.op, self.value, self.assume);
            }
        }{ .op = op, .value = value, .assume = assume });
    }

    fn byTypeof(st: *St, t: *Type, tn: *Node, lit: *Node, op: @import("lexer.zig").Tok, assume0: bool) *Type {
        const c = st.c;
        const assume = if (op == .neq or op == .neq3) !assume0 else assume0;
        const word = if (lit.data == .string_lit) lit.data.string_lit else lit.data.no_subst_template;
        const target = refCandidate(tn.data.typeof_expr.expr);
        if (!matchingRef(c, st.ref, target)) {
            const present = assume != std.mem.eql(u8, word, "undefined");
            const r = if (c.strict_null and present and containsRef(c, target, st.ref) and isOptionalChain(target)) expr.nonNull(c, t) else t;
            const name = st.discriminant(target, r) orelse return r;
            return st.byDiscriminant(r, name, struct {
                word: []const u8,
                assume: bool,
                fn run(self: @This(), cc: *Checker, pt: *Type) *Type {
                    return narrowTypeof(cc, pt, self.word, self.assume);
                }
            }{ .word = word, .assume = assume });
        }
        return narrowTypeof(c, t, word, assume);
    }
};

fn isStringLit(n: *Node) bool {
    return n.data == .string_lit or n.data == .no_subst_template;
}

fn proveDefined(c: *Checker, op: @import("lexer.zig").Tok, value: *Node, assume: bool) bool {
    const v = operand(c, value);
    const eq = op == .eq2 or op == .eq3;
    if (eq == assume) return !mayBeNullish(v, op == .eq2 or op == .neq);
    return (v.data == .undefined or v.data == .null) and (op == .neq or op == .eq2 or v.data == .undefined);
}

fn mayBeNullish(t: *Type, loose: bool) bool {
    return switch (t.data) {
        .undefined, .any, .err, .unknown => true,
        .null => loose,
        .union_ => |u| for (u) |m| {
            if (mayBeNullish(m, loose)) break true;
        } else false,
        else => false,
    };
}

pub fn isOptionalChain(n0: *Node) bool {
    var n = strip(n0);
    while (true) {
        switch (n.data) {
            .prop_access => |x| {
                if (x.optional) return true;
                n = strip(x.expr);
            },
            .elem_access => |x| {
                if (x.optional) return true;
                n = strip(x.expr);
            },
            .call => |x| {
                if (x.optional) return true;
                n = strip(x.callee);
            },
            else => return false,
        }
    }
}

fn reduceAssigned(c: *Checker, declared: *Type, assigned0: *Type) *Type {
    if (T.isAny(assigned0)) return declared;
    const assigned = assigned0.regular orelse assigned0;
    var parts = c.newList(*Type);
    for (declared.data.union_) |m| {
        if (mayAssign(c, assigned, m)) parts.append(c.a, m) catch oom();
    }
    var r = c.getUnion(parts.items);
    if (r.data == .never or !relate.isAssignable(c, assigned, r)) return declared;
    // `const x: boolean = false` stays a value that inference may still widen to `boolean`.
    if (r.data == .bool_lit and assigned0.regular != null) r = c.freshOf(r);
    return r;
}

fn mayAssign(c: *Checker, s: *Type, t: *Type) bool {
    if (s.data == .union_) {
        for (s.data.union_) |m| if (relate.isAssignable(c, m, t)) return true;
        return false;
    }
    return relate.isAssignable(c, s, t);
}

fn joinTypes(c: *Checker, declared: *Type, parts: []const *Type) *Type {
    _ = declared;
    var small: [d.small_list]*Type = undefined;
    var list = std.ArrayList(*Type).initBuffer(d.smallList(c, &small, parts.len));
    for (parts) |t| if (t != c.t_unreachable) list.appendAssumeCapacity(t);
    if (list.items.len == 0) return c.t_unreachable;
    return recombineUnknown(c, c.getUnion(list.items));
}

/// Both sides of a test on `unknown` meet again as the union it was split into.
fn recombineUnknown(c: *Checker, t: *Type) *Type {
    if (t.data != .union_ or t.data.union_.len != 3) return t;
    var seen: u8 = 0;
    for (t.data.union_) |m| {
        if (m == c.t_empty) seen |= 1 else if (m == c.t_null) seen |= 2 else if (m == c.t_undefined) seen |= 4;
    }
    return if (seen == 7) c.t_unknown else t;
}

pub fn byTruthiness(c: *Checker, t: *Type, assume: bool) *Type {
    // Past a truthy test it is a plain `any`: the flow has found something, so nothing is reported.
    if (t == c.t_auto and assume) return c.t_any;
    switch (t.data) {
        .union_ => |u| {
            var small: [d.small_list]*Type = undefined;
            var parts = std.ArrayList(*Type).initBuffer(d.smallList(c, &small, u.len));
            for (u) |m| {
                const r = byTruthiness(c, m, assume);
                if (r.data != .never) parts.appendAssumeCapacity(r);
            }
            if (parts.items.len == u.len and t != c.t_boolean) {
                var same = true;
                for (parts.items, u) |x, y| if (x != y) {
                    same = false;
                };
                if (same) return t;
            }
            return c.getUnion(parts.items);
        },
        .null, .undefined, .void => return if (assume) c.t_never else t,
        .bool_lit => |v| return if (v == assume) t else c.t_never,
        .str_lit => |v| return if ((v.len > 0) == assume) t else c.t_never,
        .num_lit => |v| return if ((v != 0 and v == v) == assume) t else c.t_never,
        .big_lit => |v| return if ((!std.mem.eql(u8, v, "0")) == assume) t else c.t_never,
        .enum_lit => |e| switch (e.value) {
            .num => |v| return if ((v != 0) == assume) t else c.t_never,
            .str => |v| return if ((v.len > 0) == assume) t else c.t_never,
            .none => return t,
        },
        .obj, .nonprim, .unique => return if (assume) t else if (t.data == .obj and isEmptyLike(c, t)) t else c.t_never,
        .inter => |ms| {
            // Objects next to a primitive are only tags. Otherwise every member has a say.
            const tagged = for (ms) |m| {
                if (expr.isPrimitiveValue(c, m)) break true;
            } else false;
            for (ms) |m| {
                if (!(tagged and m.data == .obj) and byTruthiness(c, m, assume).data == .never) return c.t_never;
            }
            return t;
        },
        .unknown => return if (assume and c.strict_null) c.t_empty else t,
        .param, .access => return if (assume and c.strict_null) expr.definite(c, t) else t,
        else => return t,
    }
}

fn isEmptyLike(c: *Checker, t: *Type) bool {
    if (t.data.obj.kind == .mapped) return false;
    const m = d.shallowMembers(c, t);
    return m.calls.len == 0 and m.ctors.len == 0 and m.indexes.len == 0 and d.hasNoProps(c, t);
}

/// An interface extending `Function` declares no call signature and is still called.
fn isFunctionObject(c: *Checker, t: *Type) bool {
    if (d.callSigs(c, t).len > 0 or d.ctorSigs(c, t).len > 0) return true;
    if (d.getProp(c, t, "bind") == null) return false;
    return relate.isSubtype(c, t, d.globalType(c, "Function") orelse return false);
}

pub fn typeofKind(c: *Checker, t: *Type) ?[]const u8 {
    return switch (t.data) {
        .string, .str_lit, .tmpl, .strmap => "string",
        .number, .num_lit, .enum_ => "number",
        .enum_lit => |e| if (e.value == .str) "string" else "number",
        .bigint, .big_lit => "bigint",
        .bool_lit => "boolean",
        .symbol, .unique => "symbol",
        .undefined, .void => "undefined",
        .null, .nonprim => "object",
        .obj => if (isFunctionObject(c, t)) "function" else if (isEmptyLike(c, t)) null else "object",
        .inter => |ms| {
            var kind: ?[]const u8 = null;
            var generic = false;
            for (ms) |m| {
                const k = typeofKind(c, m) orelse {
                    // An empty member says nothing next to one that does.
                    generic = generic or m.data != .obj;
                    continue;
                };
                // Objects next to a primitive are only tags: `string & { brand: 1 }` is a string.
                if (m.data != .obj) return k;
                if (kind == null or k[0] == 'f') kind = k;
            }
            return if (generic) null else kind;
        },
        else => null,
    };
}

fn typeofTarget(c: *Checker, word: []const u8) ?*Type {
    const eq = std.mem.eql;
    if (eq(u8, word, "string")) return c.t_string;
    if (eq(u8, word, "number")) return c.t_number;
    if (eq(u8, word, "bigint")) return c.t_bigint;
    if (eq(u8, word, "boolean")) return c.t_boolean;
    if (eq(u8, word, "symbol")) return c.t_symbol;
    if (eq(u8, word, "undefined")) return c.t_undefined;
    if (eq(u8, word, "object")) return c.getUnion(&.{ c.t_nonprim, c.t_null });
    if (eq(u8, word, "function")) return d.globalType(c, "Function");
    return null;
}

pub fn narrowTypeof(c: *Checker, t: *Type, word: []const u8, assume: bool) *Type {
    const target = typeofTarget(c, word) orelse return t;
    if (t.data == .any) {
        if (!assume) return t;
        return if (std.mem.eql(u8, word, "function") or std.mem.eql(u8, word, "object")) t else target;
    }
    if (t.data == .err) return t;
    if (t.data == .unknown) return if (assume) target else t;
    // `null` passes `typeof x === "object"` as itself; anything still generic can only be an object.
    const implied = if (std.mem.eql(u8, word, "object")) c.t_nonprim else target;
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var parts = c.newList(*Type);
    for (members) |m| {
        const kind = typeofKind(c, m);
        if (kind) |k| {
            if (std.mem.eql(u8, k, word) == assume) {
                parts.append(c.a, if (assume and m.data == .void) c.t_undefined else m) catch oom();
            } else if (assume and m.data == .obj and !m.vars and relate.isSubtype(c, implied, m)) {
                // `String` and `Object` hold what `typeof` found, though they are objects themselves.
                parts.append(c.a, implied) catch oom();
            }
        } else if (assume) {
            if (m.data == .obj) {
                // A named empty type is an object already; `{}` also stands for primitives.
                if (std.mem.eql(u8, word, "object") and m.data.obj.kind != .anon) {
                    parts.append(c.a, m) catch oom();
                } else if (!std.mem.eql(u8, word, "undefined")) parts.append(c.a, implied) catch oom();
            } else if (m.data == .inter) {
                parts.append(c.a, c.getIntersection(&.{ m, implied })) catch oom();
            } else if (m.data == .param or m.data == .access) {
                const base = d.baseConstraint(c, m);
                if (base.data == .unknown or base == m) {
                    parts.append(c.a, c.getIntersection(&.{ m, implied })) catch oom();
                } else {
                    const narrowed = narrowTypeof(c, base, word, true);
                    if (narrowed.data != .never) parts.append(c.a, c.getIntersection(&.{ m, implied })) catch oom();
                }
            } else if (m.data == .any or m.data == .err) {
                parts.append(c.a, m) catch oom();
            } else parts.append(c.a, implied) catch oom();
        } else parts.append(c.a, m) catch oom();
    }
    return c.getUnion(parts.items);
}

fn byEquality(c: *Checker, t: *Type, op: @import("lexer.zig").Tok, value: *Node, assume0: bool) *Type {
    if (T.isAny(t)) return t;
    const assume = if (op == .neq or op == .neq3) !assume0 else assume0;
    const v0 = operand(c, value);
    const v = v0.regular orelse v0;
    const loose = op == .eq2 or op == .neq;
    if (v.data == .null or v.data == .undefined) {
        if (!c.strict_null) return t;
        return narrowNullish(c, t, v, loose, assume);
    }
    if (assume) {
        const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
        // `{}` and `unknown` say nothing about the value, so what it was compared with says it all.
        if (!loose and (t.data == .unknown or hasEmptyMember(c, members))) {
            if (v.data == .obj) return if (isEmptyAnon(c, v)) v else c.t_nonprim;
            if (v.data != .union_ or v == c.t_boolean) return v;
        }
        if (t.data == .unknown) return t;
        var small: [d.small_list]*Type = undefined;
        var parts = std.ArrayList(*Type).initBuffer(d.smallList(c, &small, members.len));
        for (members) |m| {
            if (loose and (m.data == .null or m.data == .undefined)) continue;
            if (relate.isComparable(c, m, v) or relate.isComparable(c, v, m)) {
                parts.appendAssumeCapacity(if (relate.isUnitType(v) and !relate.isUnitType(m) and m.data != .param and m.data != .obj and m.data != .inter) v else m);
            }
        }
        return c.getUnion(parts.items);
    }
    if (relate.isUnitType(v)) {
        const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
        var small: [d.small_list]*Type = undefined;
        var parts = std.ArrayList(*Type).initBuffer(d.smallList(c, &small, members.len));
        for (members) |m| {
            const reg = m.regular orelse m;
            // A string enum member and the string it holds are one value.
            if (relate.isUnitType(reg) and (reg == v or relate.isComparable(c, reg, v) or relate.isComparable(c, v, reg))) continue;
            parts.appendAssumeCapacity(m);
        }
        return c.getUnion(parts.items);
    }
    return t;
}

fn isEmptyAnon(c: *Checker, t: *Type) bool {
    return t == c.t_empty or t.data == .obj and t.data.obj.kind == .anon and isEmptyLike(c, t);
}

fn hasEmptyMember(c: *Checker, members: []const *Type) bool {
    for (members) |m| if (isEmptyAnon(c, m)) return true;
    return false;
}

fn isNullishLeft(n: *Node) bool {
    const p = n.parent orelse return false;
    if (p.data != .binary) return false;
    const x = p.data.binary;
    return x.left == n and (x.op == .qq or x.op == .qq_assign);
}

fn narrowNullish(c: *Checker, t: *Type, v: *Type, loose: bool, assume: bool) *Type {
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var parts = c.newList(*Type);
    if (assume) {
        if (t.data == .unknown) return if (loose) c.getUnion(&.{ c.t_null, c.t_undefined }) else v;
        for (members) |m| {
            if (m == v or (loose and (m.data == .null or m.data == .undefined))) {
                parts.append(c.a, m) catch oom();
            } else if (m.data == .void and v.data == .undefined) {
                parts.append(c.a, m) catch oom();
            } else if (m.data == .param or m.data == .access or m.data == .unknown) {
                parts.append(c.a, m) catch oom();
            }
        }
        return c.getUnion(parts.items);
    }
    // `unknown` is `{} | null | undefined` here, so ruling one out leaves the others.
    if (t.data == .unknown) return if (loose) c.t_empty else c.getUnion(&.{ c.t_empty, if (v.data == .null) c.t_undefined else c.t_null });
    const other = if (v.data == .null) c.t_undefined else c.t_null;
    const has_other = std.mem.indexOfScalar(*Type, members, other) != null;
    for (members) |m| {
        const drop = m == v or (loose and (m.data == .null or m.data == .undefined)) or (m.data == .void and (loose or v.data == .undefined));
        if (drop or (m.data == .inter and std.mem.indexOfScalar(*Type, m.data.inter, v) != null)) continue;
        parts.append(c.a, if (loose) expr.definite(c, m) else withoutNullish(c, m, v, other, has_other)) catch oom();
    }
    return c.getUnion(parts.items);
}

/// A `T` may hold `null` and `undefined` both, so ruling out one leaves it `T & ({} | undefined)`,
/// or just `T & {}` when the rest of the union speaks for the other one.
fn withoutNullish(c: *Checker, t: *Type, v: *Type, other: *Type, has_other: bool) *Type {
    if (t.data != .param and t.data != .access) return t;
    const k = d.baseConstraint(c, t);
    if (k.data != .unknown and !admits(k, v)) return t;
    const plain = c.intersect(&.{ t, c.t_empty }, false);
    if (has_other or (k.data != .unknown and !admits(k, other))) return plain;
    return c.getUnion(&.{ plain, c.getIntersection(&.{ t, other }) });
}

fn admits(t: *Type, v: *Type) bool {
    if (t.data != .union_) return t == v;
    return std.mem.indexOfScalar(*Type, t.data.union_, v) != null;
}

fn narrowSwitch(c: *Checker, t: *Type, sw: *Node, start: u32, end: u32) *Type {
    const clauses = sw.data.switch_stmt.clauses;
    var has_default = start == end;
    var values = c.newList(*Type);
    for (clauses[start..end]) |cl| {
        if (cl.data == .default_clause) {
            has_default = true;
            continue;
        }
        const v = operand(c, cl.data.case_clause.expr);
        values.append(c.a, v.regular orelse v) catch oom();
    }
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var cases = c.newList(*Type);
    if (t.data == .unknown and !has_default) return unknownByClauses(c, t, values.items);
    if (t.data == .unknown or T.isAny(t)) return t;
    for (values.items) |v| {
        for (members) |m| {
            if (relate.isComparable(c, m, v) or relate.isComparable(c, v, m)) {
                cases.append(c.a, if (relate.isUnitType(v) and !relate.isUnitType(m) and m.data != .obj and m.data != .param) v else m) catch oom();
            }
        }
    }
    const case_t = c.getUnion(cases.items);
    if (!has_default) return case_t;
    var all = c.newList(*Type);
    for (clauses) |cl| {
        if (cl.data != .case_clause) continue;
        const v = operand(c, cl.data.case_clause.expr);
        all.append(c.a, v.regular orelse v) catch oom();
    }
    var rest = c.newList(*Type);
    for (members) |m| {
        const reg = m.regular orelse m;
        const hit = for (all.items) |v| {
            if (v == reg and relate.isUnitType(reg)) break true;
        } else false;
        if (!hit) rest.append(c.a, m) catch oom();
    }
    // Only the clauses after the first match are reachable by falling through; a default sees the rest.
    return if (case_t.data == .never) c.getUnion(rest.items) else c.getUnion(&.{ case_t, c.getUnion(rest.items) });
}

/// Only a primitive compares by value; a matching object can be any object.
fn unknownByClauses(c: *Checker, t: *Type, values: []*Type) *Type {
    const out = c.a.alloc(*Type, values.len) catch oom();
    for (values, out) |v, *o| o.* = switch (v.data) {
        .obj => c.t_nonprim,
        .string, .number, .bigint, .symbol, .str_lit, .num_lit, .big_lit, .bool_lit, .null, .undefined, .void, .enum_, .enum_lit, .unique, .tmpl, .nonprim => v,
        else => if (v == c.t_boolean) v else return t,
    };
    return c.getUnion(out);
}

fn narrowSwitchTypeof(c: *Checker, t: *Type, sw: *Node, start: u32, end: u32) *Type {
    const clauses = sw.data.switch_stmt.clauses;
    var has_default = start == end;
    var words = c.newList([]const u8);
    for (clauses[start..end]) |cl| {
        if (cl.data == .default_clause) {
            has_default = true;
            continue;
        }
        const e = strip(cl.data.case_clause.expr);
        if (!isStringLit(e)) return t;
        words.append(c.a, if (e.data == .string_lit) e.data.string_lit else e.data.no_subst_template) catch oom();
    }
    if (has_default) {
        var cur = t;
        for (clauses) |cl| {
            if (cl.data != .case_clause) continue;
            const e = strip(cl.data.case_clause.expr);
            if (!isStringLit(e)) return t;
            const w = if (e.data == .string_lit) e.data.string_lit else e.data.no_subst_template;
            var inside = false;
            for (words.items) |x| if (std.mem.eql(u8, x, w)) {
                inside = true;
            };
            if (!inside) cur = narrowTypeof(c, cur, w, false);
        }
        return cur;
    }
    var parts = c.newList(*Type);
    for (words.items) |w| parts.append(c.a, narrowTypeof(c, t, w, true)) catch oom();
    return c.getUnion(parts.items);
}

pub fn hasBase(c: *Checker, t: *Type, base: *Type) bool {
    if (t.data == .inter) {
        for (t.data.inter) |m| if (hasBase(c, m, base)) return true;
        return false;
    }
    if (t.data != .obj) return false;
    const o = t.data.obj;
    if (o.kind != .ref and o.kind != .iface) return false;
    const target = o.target orelse t;
    if (target == base) return true;
    for (d.basesOf(c, target)) |b| if (hasBase(c, b, base)) return true;
    return false;
}

/// Nominal, unlike the subtype relation: `instanceof` must not drop a structurally equal class.
fn derivedFrom(c: *Checker, s: *Type, t: *Type) bool {
    if (s.data == .union_) {
        for (s.data.union_) |m| if (!derivedFrom(c, m, t)) return false;
        return true;
    }
    if (t.data == .union_) {
        for (t.data.union_) |m| if (derivedFrom(c, s, m)) return true;
        return false;
    }
    if (s.data == .inter) {
        for (s.data.inter) |m| if (derivedFrom(c, m, t)) return true;
        return false;
    }
    if (s.data == .param or s.data == .access or s.data == .cond) return derivedFrom(c, d.baseConstraint(c, s), t);
    const is_object = s.data == .obj or s.data == .nonprim;
    if (t.data == .obj and t.data.obj.kind == .anon and isEmptyLike(c, t)) return is_object;
    if (t == d.globalType(c, "Object")) return is_object and !(s.data == .obj and s.data.obj.kind == .anon and isEmptyLike(c, s));
    if (t == d.globalType(c, "Function")) return s.data == .obj and d.callSigs(c, s).len > 0;
    if (t.data != .obj) return false;
    if (hasBase(c, s, t.data.obj.target orelse t)) return true;
    return c.isMutableArray(t) and hasBase(c, s, c.global_readonly_array orelse return false);
}

fn isSubset(s: *Type, t: *Type) bool {
    if (s == t) return true;
    if (t.data == .union_) for (t.data.union_) |m| if (m == s) return true;
    return false;
}

pub fn narrowedType(c: *Checker, t: *Type, candidate: *Type, assume: bool, check_derived: bool) *Type {
    if (T.isAny(candidate)) return t;
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var parts = c.newList(*Type);
    if (!assume) {
        if (t == candidate) return c.t_never;
        if (T.isAny(t)) return t;
        if (check_derived) {
            if (t.data == .unknown) return t;
            for (members) |m| if (!derivedFrom(c, m, candidate)) parts.append(c.a, m) catch oom();
            return c.getUnion(parts.items);
        }
        // `unknown` is `{} | null | undefined` here: what `x is Object` rules out is the `{}`.
        const split = if (t.data == .unknown) c.getUnion(&.{ c.t_empty, c.t_null, c.t_undefined }) else t;
        const yes = narrowedType(c, split, candidate, true, false);
        for (if (split.data == .union_) split.data.union_ else members) |m| if (!isSubset(m, yes)) parts.append(c.a, m) catch oom();
        return recombineUnknown(c, c.getUnion(parts.items));
    }
    if (T.isAny(t) or t.data == .unknown or t == candidate) return candidate;
    const cands: []const *Type = if (candidate.data == .union_) candidate.data.union_ else &.{candidate};
    for (cands) |k| {
        var hit = false;
        for (members) |m| {
            const pick: ?*Type = if (check_derived)
                (if (derivedFrom(c, m, k)) m else if (derivedFrom(c, k, m)) k else null)
            else
                (if (relate.isStrictSubtype(c, m, k)) m else if (relate.isStrictSubtype(c, k, m)) k else if (relate.isSubtype(c, m, k)) m else if (relate.isSubtype(c, k, m)) k else null);
            if (pick) |x| {
                parts.append(c.a, x) catch oom();
                hit = true;
            }
        }
        if (hit) continue;
        for (members) |m| {
            if (!m.vars) continue;
            const base = d.baseConstraint(c, m);
            if (if (check_derived) derivedFrom(c, k, base) else relate.isSubtype(c, k, base)) parts.append(c.a, c.getIntersection(&.{ m, k })) catch oom();
        }
    }
    if (parts.items.len > 0) return c.getUnion(parts.items);
    if (relate.isSubtype(c, candidate, t)) return candidate;
    if (relate.isAssignable(c, t, candidate)) return t;
    if (relate.isAssignable(c, candidate, t)) return candidate;
    return c.getIntersection(&.{ t, candidate });
}

/// `ref.constructor` or `ref["constructor"]`.
fn isConstructorOf(c: *Checker, ref: *Node, n: *Node) bool {
    const object, const key = switch (n.data) {
        .prop_access => |x| .{ x.expr, x.name },
        .elem_access => |x| .{ x.expr, x.index },
        else => return false,
    };
    const name = switch (key.data) {
        .identifier => |x| if (n.data == .prop_access) x else return false,
        .string_lit, .no_subst_template => |x| if (n.data == .elem_access) x else return false,
        else => return false,
    };
    return std.mem.eql(u8, name, "constructor") and matchingRef(c, ref, object);
}

fn symbolOfObj(t: *Type) ?*binder.Symbol {
    if (t.data != .obj) return null;
    return (t.data.obj.target orelse t).data.obj.sym;
}

fn isClassObj(t: *Type) bool {
    return t.data == .obj and (t.data.obj.target orelse t).data.obj.is_class;
}

/// `x.constructor === C` keeps what `C` constructs; tsc matches a class only by its own symbol,
/// so a derived class is not constructed by its base.
fn byConstructor(c: *Checker, t: *Type, op: @import("lexer.zig").Tok, ctor: *Node, assume: bool) *Type {
    // Only the branch where the two are equal says anything.
    if (assume != (op == .eq2 or op == .eq3)) return t;
    const r = operand(c, ctor);
    if (d.callSigs(c, r).len == 0 and d.ctorSigs(c, r).len == 0) return t;
    const p = d.getProp(c, r, "prototype") orelse return t;
    const k = d.propType(c, p);
    if (T.isAny(k) or k == d.globalType(c, "Object") or k == d.globalType(c, "Function")) return t;
    if (T.isAny(t)) return k;
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    var parts = c.newList(*Type);
    for (members) |m| {
        const kept = if (isClassObj(m) or isClassObj(k)) symbolOfObj(m) == symbolOfObj(k) else relate.isSubtype(c, m, k);
        if (kept) parts.append(c.a, m) catch oom();
    }
    return c.getUnion(parts.items);
}

fn byInstanceof(c: *Checker, t: *Type, right: *Node, assume: bool) *Type {
    const r = operand(c, right);
    if (T.isAny(r)) return t;
    var candidate: ?*Type = null;
    if (d.getProp(c, r, "prototype")) |p| {
        const pt = d.propType(c, p);
        if (!T.isAny(pt)) candidate = pt;
    }
    if (candidate == null) {
        const sigs = d.ctorSigs(c, r);
        if (sigs.len > 0) {
            var parts = c.newList(*Type);
            for (sigs) |s| parts.append(c.a, d.returnOf(c, s)) catch oom();
            candidate = c.getUnion(parts.items);
        }
    }
    const k = candidate orelse return t;
    if (T.isAny(t) and (k == d.globalType(c, "Object") or k == d.globalType(c, "Function"))) return t;
    return narrowedType(c, t, k, assume, true);
}

fn byIn(c: *Checker, t: *Type, name: []const u8, assume: bool) *Type {
    const members: []const *Type = if (t.data == .union_) t.data.union_ else &.{t};
    const known = for (members) |m| {
        if (mayHaveProp(c, m, name, true)) break true;
    } else false;
    if (known) {
        var parts = c.newList(*Type);
        for (members) |m| {
            if (mayHaveProp(c, m, name, assume)) parts.append(c.a, m) catch oom();
        }
        return c.getUnion(parts.items);
    }
    if (!assume or T.isAny(t)) return t;
    // TS 4.9: an unknown key adds `Record<K, unknown>`.
    const m = c.emptyMembers();
    m.props.put(c.a, name, c.create(T.Prop, .{ .name = name, .ty = c.t_unknown })) catch oom();
    return c.getIntersection(&.{ t, c.newObj(.{ .kind = .anon, .members = m }) });
}

fn mayHaveProp(c: *Checker, t: *Type, name: []const u8, assume: bool) bool {
    if (d.getProp(c, t, name)) |p| return p.optional or assume;
    // A string index signature says nothing about a `unique symbol` key.
    const key = if (std.mem.startsWith(u8, name, "__@")) c.t_symbol else c.t_string;
    return d.indexValue(c, t, key) != null or !assume;
}

/// `container` stops the walk at the function whose own flow the reference belongs to.
pub fn flowType(c: *Checker, ref: *Node, declared: *Type, initial: *Type, container: ?*Node) *Type {
    const flow = ref.flow() orelse return declared;
    if (c.flow_depth > 120) {
        _ = c.metCycle();
        return declared;
    }
    c.flow_depth += 1;
    defer c.flow_depth -= 1;
    // The walk reads conditions that have nothing to do with `ref`, which tsc never looks at.
    c.pushResolution(null);
    defer _ = c.popResolution();
    const r = walk(c, ref, declared, initial, container, flow);
    // Dead code has no assignments to read, and reporting them would only follow up on its own error.
    if (r == c.t_unreachable) return if (declared == c.t_auto) c.t_any else declared;
    // `x!` where `x` was narrowed to nothing but nullish: the author insists it has changed since.
    if (ref.parent) |p| if (p.data == .non_null and r.data != .never and expr.nonNull(c, r).data == .never) return declared;
    return r;
}

/// Narrows `ref` as if it occurred at `at`, for references that have no flow node of their own.
pub fn flowAt(c: *Checker, ref: *Node, at: *FlowNode, declared: *Type) *Type {
    if (c.flow_depth > 120) {
        _ = c.metCycle();
        return declared;
    }
    c.flow_depth += 1;
    defer c.flow_depth -= 1;
    const r = walk(c, ref, declared, declared, null, at);
    return if (r == c.t_unreachable) declared else r;
}

/// What `e` being true proves about a parameter, when being false proves the opposite.
pub fn refinedParam(c: *Checker, name: *Node, e: *Node, func: *Node, init: *Type) ?*Type {
    const ante = e.flow() orelse blk: {
        if (e.parent) |p| if (p.data == .return_stmt) if (p.flow()) |x| break :blk x;
        break :blk c.create(FlowNode, .{ .kind = .start });
    };
    const on_true = c.create(FlowNode, .{ .kind = .true_cond, .node = e, .antecedent = ante });
    const yes = walk(c, name, init, init, func, on_true);
    if (yes == init) return null;
    const on_false = c.create(FlowNode, .{ .kind = .false_cond, .node = e, .antecedent = on_true });
    return if (holdsNothing(c, walk(c, name, init, yes, func, on_false))) yes else null;
}

fn holdsNothing(c: *Checker, t: *Type) bool {
    return switch (t.data) {
        .never => true,
        .inter => d.isNeverReduced(c, t),
        .union_ => |u| for (u) |m| {
            if (!holdsNothing(c, m)) break false;
        } else true,
        else => false,
    };
}

fn walk(c: *Checker, ref: *Node, declared: *Type, initial: *Type, container: ?*Node, flow: *FlowNode) *Type {
    const key = std.hash.Wyhash.hash(refKey(c, ref) ^ @as(u64, initial.id) << 32, std.mem.asBytes(&container));
    var st = St{ .c = c, .ref = ref, .declared = declared, .initial = initial, .container = container, .key = key };
    return st.go(flow);
}

fn assertsFalse(c: *Checker, call: *Node, s: *T.Sig) bool {
    const p = d.predOf(c, s) orelse return false;
    if (!p.asserts or p.ty != null or p.is_this or p.param_index < 0) return false;
    const args = call.data.call.args;
    const i: usize = @intCast(p.param_index);
    return i < args.len and isFalseExpr(args[i]);
}

/// Written `false` only: `assert(0)` goes on, as the check is on the syntax and not on a type.
fn isFalseExpr(n0: *Node) bool {
    const n = binder.stripParens(n0);
    return switch (n.data) {
        .false_lit => true,
        .binary => |x| switch (x.op) {
            .amp2 => isFalseExpr(x.left) or isFalseExpr(x.right),
            .pipe2 => isFalseExpr(x.left) and isFalseExpr(x.right),
            else => false,
        },
        else => false,
    };
}

pub fn isReachable(c: *Checker, f0: ?*FlowNode) bool {
    var f = f0 orelse return true;
    var steps: u32 = 0;
    while (true) : (steps += 1) {
        if (c.reach_cache.get(f)) |v| return v;
        if (steps > 100_000) return true;
        switch (f.kind) {
            // Past a `finally` only its own exits count: the block itself cannot end the path
            // unless it throws, and then the binder has already made the rest unreachable.
            .reduce => {
                for (f.antecedents) |x| if (isReachable(c, x)) return true;
                return false;
            },
            .start => return true,
            .unreachable_end => return false,
            .assign, .true_cond, .false_cond => f = f.antecedent orelse return true,
            .call => {
                if (f.node) |n| if (expr.effectsSig(c, n)) |s| {
                    if (assertsFalse(c, n, s) or d.returnOf(c, s).data == .never) return false;
                };
                f = f.antecedent orelse return true;
            },
            .switch_clause => {
                if (f.clause_start == f.clause_end) if (f.node) |n| if (expr.isExhaustive(c, n)) return false;
                f = f.antecedent orelse return true;
            },
            .loop, .branch => {
                c.reach_cache.put(c.a, f, false) catch oom();
                var r = false;
                for (f.antecedents) |a| if (isReachable(c, a)) {
                    r = true;
                    break;
                };
                c.reach_cache.put(c.a, f, r) catch oom();
                return r;
            },
        }
    }
}
