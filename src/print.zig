//! Types as text, for diagnostics.
const std = @import("std");
const T = @import("types.zig");
const d = @import("decls.zig");
const binder = @import("binder.zig");
const Checker = T.Checker;
const Type = T.Type;
const oom = T.oom;

const P = struct {
    c: *Checker,
    out: std.ArrayList(u8) = .empty,
    depth: u32 = 0,

    fn w(p: *P, s: []const u8) void {
        p.out.appendSlice(p.c.a, s) catch oom();
    }

    fn list(p: *P, types: []const *Type, sep: []const u8) void {
        for (types, 0..) |t, i| {
            if (i > 0) p.w(sep);
            p.ty(t);
        }
    }

    /// A type written next to ` | `, ` & ` or `[]` keeps its own extent, as tsc's parenthesizer does.
    fn part(p: *P, t: *Type) void {
        const wrap = t.alias == null and t != p.c.t_boolean and t.enum_sym == null and (t.data == .union_ or t.data == .inter or t.data == .cond or p.isArrow(t));
        if (wrap) p.w("(");
        p.ty(t);
        if (wrap) p.w(")");
    }

    /// Printed with a keyword in front, which `[]` would not bind to.
    fn isOperator(c: *Checker, t: *Type) bool {
        if (t.alias != null) return false;
        if (t.data == .keyof) return true;
        if (t.data != .obj) return false;
        const o = t.data.obj;
        return o.kind == .tuple and o.readonly or o.kind == .ref and o.target == c.global_readonly_array;
    }

    fn isArrow(p: *P, t: *Type) bool {
        if (t.data != .obj or t.data.obj.kind != .anon) return false;
        const m = d.membersOf(p.c, t);
        return m.calls.len == 1 and m.props.count() == 0 and m.indexes.len == 0 and m.ctors.len == 0;
    }

    fn quoted(p: *P, v: []const u8) void {
        p.w("\"");
        p.w(v);
        p.w("\"");
    }

    fn sig(p: *P, s: *T.Sig, arrow: bool) void {
        const c = p.c;
        p.w("(");
        if (s.this_ty) |x| {
            p.w("this: ");
            p.ty(x);
            if (s.params.len > 0) p.w(", ");
        }
        for (s.params, 0..) |a, i| {
            if (i > 0) p.w(", ");
            if (s.has_rest and i + 1 == s.params.len) p.w("...");
            p.w(a.name);
            if (a.optional and !(s.has_rest and i + 1 == s.params.len)) p.w("?");
            p.w(": ");
            p.ty(d.paramTypeAt(c, s, i));
        }
        p.w(if (arrow) ") => " else "): ");
        const q = d.predOf(c, s) orelse return p.ty(d.returnOf(c, s));
        if (q.asserts) p.w("asserts ");
        p.w(if (q.is_this) "this" else q.name);
        if (q.ty) |x| {
            p.w(" is ");
            p.ty(x);
        }
    }

    fn object(p: *P, t: *Type) void {
        const c = p.c;
        const o = t.data.obj;
        switch (o.kind) {
            .iface => return p.name(o.sym, o.tparams),
            .ref => {
                if (c.isArrayType(t)) {
                    const e = o.args.?[0];
                    const ro = o.target == c.global_readonly_array;
                    if (ro) p.w("readonly ");
                    const op = isOperator(c, e);
                    if (op) p.w("(");
                    p.part(e);
                    if (op) p.w(")");
                    p.w("[]");
                    return;
                }
                return p.name(o.sym, o.args.?);
            },
            .tuple => {
                if (o.readonly) p.w("readonly ");
                p.w("[");
                for (o.elems, 0..) |e, i| {
                    if (i > 0) p.w(", ");
                    if (o.eflags[i] == .rest or o.eflags[i] == .variadic) p.w("...");
                    p.ty(e);
                    if (o.eflags[i] == .rest) p.w("[]");
                    if (o.eflags[i] == .optional) p.w("?");
                }
                p.w("]");
                return;
            },
            .mapped => {
                p.w("{ [x: string]: ");
                p.w("any; }");
                return;
            },
            .anon => {},
        }
        if (o.sym) |s| {
            if (s.flags & binder.F.class != 0) {
                p.w("typeof ");
                p.w(symbolName(s));
                return;
            }
            if (s.flags & binder.F.enum_any != 0) {
                p.w("typeof ");
                p.w(s.name);
                return;
            }
            if (s.flags & binder.F.value_module != 0) {
                p.w("typeof ");
                p.w(s.name);
                return;
            }
        }
        const m = d.membersOf(c, t);
        if (m.props.count() == 0 and m.indexes.len == 0 and m.ctors.len == 0) {
            if (m.calls.len == 1) return p.sig(m.calls[0], true);
            if (m.calls.len == 0) return p.w("{}");
        }
        if (p.depth > 3) return p.w("...");
        p.depth += 1;
        defer p.depth -= 1;
        p.w("{ ");
        for (m.calls) |s| {
            p.sig(s, false);
            p.w("; ");
        }
        for (m.indexes) |i| {
            p.w("[x: ");
            p.ty(i.key);
            p.w("]: ");
            p.ty(i.ty);
            p.w("; ");
        }
        for (m.props.values()) |x| {
            if (x.readonly) p.w("readonly ");
            p.w(x.name);
            if (x.optional) p.w("?");
            p.w(": ");
            p.ty(d.propType(c, x));
            p.w("; ");
        }
        p.w("}");
    }

    fn symbolName(s: *binder.Symbol) []const u8 {
        return if (std.mem.eql(u8, s.name, "__class")) "(Anonymous class)" else s.name;
    }

    fn name(p: *P, sym: ?*binder.Symbol, args: []const *Type) void {
        p.w(if (sym) |s| symbolName(s) else "?");
        var shown = p.c.newList(*Type);
        for (args) |a| if (!(a.data == .param and a.data.param.is_this)) shown.append(p.c.a, a) catch oom();
        if (shown.items.len == 0) return;
        p.w("<");
        p.list(shown.items, ", ");
        p.w(">");
    }

    fn ty(p: *P, t: *Type) void {
        const c = p.c;
        if (p.depth > 6) return p.w("...");
        p.depth += 1;
        defer p.depth -= 1;
        if (t.alias) |a| {
            p.w(a.name);
            if (t.alias_args.len > 0) {
                p.w("<");
                p.list(t.alias_args, ", ");
                p.w(">");
            }
            return;
        }
        switch (t.data) {
            .any, .err => p.w("any"),
            .unknown => p.w("unknown"),
            .never => p.w("never"),
            .void => p.w("void"),
            .undefined => p.w("undefined"),
            .null => p.w("null"),
            .string => p.w("string"),
            .number => p.w("number"),
            .bigint => p.w("bigint"),
            .symbol => p.w("symbol"),
            .nonprim => p.w("object"),
            .str_lit => |v| p.quoted(v),
            .num_lit => |v| p.w(d.numName(c, v)),
            .big_lit => |v| p.w(c.fmt("{s}n", .{v})),
            .bool_lit => |v| p.w(if (v) "true" else "false"),
            .unique => |s| {
                p.w("typeof ");
                p.w(s.name);
            },
            .enum_lit => |e| {
                p.w(e.parent.name);
                p.w(".");
                p.w(e.sym.name);
            },
            .enum_ => |s| p.w(s.name),
            .union_ => |u| {
                if (t == c.t_boolean) return p.w("boolean");
                if (t.enum_sym) |s| return p.w(s.name);
                var tail = p.c.newList(*Type);
                var head = p.c.newList(*Type);
                var bools: u32 = 0;
                for (u) |m| {
                    if (m.data == .bool_lit) bools += 1;
                }
                for (u) |m| {
                    if (m.data == .null or m.data == .undefined) {
                        tail.append(c.a, m) catch oom();
                    } else if (m.data != .bool_lit or bools < 2) head.append(c.a, m) catch oom();
                }
                if (tail.items.len == 2 and tail.items[0].data == .undefined) std.mem.swap(*Type, &tail.items[0], &tail.items[1]);
                var first = true;
                for (head.items) |m| {
                    if (!first) p.w(" | ");
                    first = false;
                    p.part(m);
                }
                if (bools == 2) {
                    if (!first) p.w(" | ");
                    first = false;
                    p.w("boolean");
                }
                for (tail.items) |m| {
                    if (!first) p.w(" | ");
                    first = false;
                    p.ty(m);
                }
            },
            .inter => |u| for (u, 0..) |m, i| {
                if (i > 0) p.w(" & ");
                p.part(m);
            },
            .obj => p.object(t),
            .param => |x| p.w(x.name),
            .keyof => |x| {
                p.w("keyof ");
                p.ty(x);
            },
            .access => |x| {
                p.ty(x.obj);
                p.w("[");
                p.ty(x.index);
                p.w("]");
            },
            .cond => |x| {
                p.ty(x.check);
                p.w(" extends ");
                p.ty(x.extends);
                p.w(" ? ");
                p.ty(@import("decls.zig").condThen(p.c, x));
                p.w(" : ");
                p.ty(@import("decls.zig").condEls(p.c, x));
            },
            .tmpl => |x| {
                p.w("`");
                for (x.types, 0..) |y, i| {
                    p.w(x.texts[i]);
                    p.w("${");
                    p.ty(y);
                    p.w("}");
                }
                p.w(x.texts[x.texts.len - 1]);
                p.w("`");
            },
            .noinfer => |x| {
                p.w("NoInfer<");
                p.ty(x);
                p.w(">");
            },
            .strmap => |x| {
                p.w(switch (x.kind) {
                    .upper => "Uppercase<",
                    .lower => "Lowercase<",
                    .capitalize => "Capitalize<",
                    .uncapitalize => "Uncapitalize<",
                });
                p.ty(x.ty);
                p.w(">");
            },
        }
    }
};

pub fn typeToString(c: *Checker, t: *Type) []const u8 {
    var p = P{ .c = c };
    p.ty(t);
    return p.out.items;
}
