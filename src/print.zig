//! Types as text, in the form tsc's node builder and printer give them.
const std = @import("std");
const ast = @import("ast.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const expr = @import("expr.zig");
const api = @import("api.zig");
const binder = @import("binder.zig");
const lexer = @import("lexer.zig");
const relate = @import("relate.zig");
const syntax = @import("syntax.zig");
const Checker = T.Checker;
const Type = T.Type;
const Node = ast.Node;
const oom = T.oom;

/// What no real type comes near. Past it instantiation may be running away, which tsc's own limit
/// on instantiation stops before printing ever sees such a type.
const full_depth = 96;
const full_size = 1 << 20;

const P = struct {
    c: *Checker,
    out: std.ArrayList(u8) = .empty,
    depth: u32 = 0,
    /// tsc's `NoTruncation`: a diagnostic is cut short, an answer to a client is not.
    full: bool = false,
    /// Anonymous types being printed, for a type that holds itself.
    open: std.ArrayList(*Type) = .empty,

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

    fn tooDeep(p: *const P, limit: u32) bool {
        return if (p.full) p.depth > full_depth or p.out.items.len > full_size else p.depth > limit;
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
        if (t.data.obj.sym) |s| if (writtenAsTypeof(s)) return false;
        const m = d.shallowMembers(p.c, t);
        return m.calls.len + m.ctors.len == 1 and m.indexes.len == 0 and d.hasNoProps(p.c, t);
    }

    fn quoted(p: *P, v: []const u8) void {
        p.quotedWith(v, '"', false);
    }

    /// As tsc's printer spells a string: a literal keeps its text, and `ascii` is for a property
    /// name, which is printed without the flag that lets non-ASCII through.
    fn quotedWith(p: *P, v: []const u8, quote: u8, ascii: bool) void {
        p.out.append(p.c.a, quote) catch oom();
        var i: usize = 0;
        while (i < v.len) {
            const b = v[i];
            if (b >= 0x80) {
                const len = wtf8Length(v[i..]);
                const cp = wtf8Decode(v[i..][0..len]);
                if (ascii) {
                    p.escapeNonAscii(cp);
                } else if (cp == 0x2028 or cp == 0x2029 or cp == 0x85) {
                    p.w(p.c.fmt("\\u{X:0>4}", .{cp}));
                } else if (cp >= 0xd800 and cp <= 0xdfff) {
                    // WTF-8 for a lone surrogate, which no output can carry.
                    p.w("\u{fffd}");
                } else p.w(v[i..][0..len]);
                i += len;
                continue;
            }
            i += 1;
            switch (b) {
                '\\' => p.w("\\\\"),
                '\n' => p.w("\\n"),
                '\r' => p.w("\\r"),
                '\t' => p.w("\\t"),
                0x0b => p.w("\\v"),
                0x0c => p.w("\\f"),
                0x08 => p.w("\\b"),
                0 => p.w("\\0"),
                else => if (b == quote) {
                    p.out.append(p.c.a, '\\') catch oom();
                    p.out.append(p.c.a, b) catch oom();
                } else if (b < 0x20) {
                    p.w(p.c.fmt("\\u{X:0>4}", .{b}));
                } else p.out.append(p.c.a, b) catch oom(),
            }
        }
        p.out.append(p.c.a, quote) catch oom();
    }

    fn escapeNonAscii(p: *P, cp: u32) void {
        if (cp < 0x10000) return p.w(p.c.fmt("\\u{X:0>4}", .{cp}));
        const off = cp - 0x10000;
        p.w(p.c.fmt("\\u{X:0>4}\\u{X:0>4}", .{ 0xd800 + (off >> 10), 0xdc00 + (off & 0x3ff) }));
    }

    /// A constraint reads as it was written, with its union in the author's order.
    fn constraint(p: *P, t: *Type, k: *Type) void {
        const decl = t.data.param.decl orelse return p.ty(k);
        if (decl.data != .type_param) return p.ty(k);
        const n = decl.data.type_param.constraint orelse return p.ty(k);
        const start = p.out.items.len;
        p.written(n);
        const as_written = p.c.a.dupe(u8, p.out.items[start..]) catch oom();
        p.out.shrinkRetainingCapacity(start);
        p.ty(k);
        // Signatures of a `this`-bearing interface renew their parameters, so identity says nothing.
        if (!sameLetters(as_written, p.out.items[start..])) return;
        p.out.shrinkRetainingCapacity(start);
        p.w(as_written);
    }

    fn written(p: *P, n: *Node) void {
        switch (n.data) {
            .union_type => |x| for (x.types, 0..) |m, i| {
                if (i > 0) p.w(" | ");
                p.written(m);
            },
            .paren_type => |x| {
                p.w("(");
                p.written(x.type);
                p.w(")");
            },
            .type_literal => |x| {
                if (x.members.len != 1 or x.members[0].data != .index_sig) return p.ty(d.typeFromNode(p.c, n));
                const i = x.members[0].data.index_sig;
                const value = i.type orelse return p.ty(d.typeFromNode(p.c, n));
                if (i.params.len != 1) return p.ty(d.typeFromNode(p.c, n));
                const key = i.params[0].data.param;
                p.w("{ [");
                p.pattern(key.name);
                p.w(": ");
                p.written(key.type orelse return);
                p.w("]: ");
                p.written(value);
                p.w("; }");
            },
            else => p.ty(d.typeFromNode(p.c, n)),
        }
    }

    fn typeParams(p: *P, s: *T.Sig) void {
        if (s.tparams.len == 0) return;
        p.w("<");
        for (s.tparams, 0..) |t, i| {
            if (i > 0) p.w(", ");
            if (t.data != .param) {
                p.ty(t);
                continue;
            }
            if (t.data.param.is_const) p.w("const ");
            p.w(t.data.param.name);
            if (d.constraintOf(p.c, t)) |k| {
                p.w(" extends ");
                p.constraint(t, k);
            }
            if (d.defaultOf(p.c, t)) |x| {
                p.w(" = ");
                p.ty(x);
            }
        }
        p.w(">");
    }

    /// The parameter as written, which is what names a binding pattern.
    fn paramNode(s: *T.Sig, i: usize) ?*Node {
        var at: ?*T.Sig = s;
        const decl = while (at) |x| : (at = x.target) {
            if (x.decl) |n| break n;
        } else return null;
        if (decl.data != .func) return null;
        const f = decl.data.func;
        const skip: usize = if (d.thisParam(decl) != null) 1 else 0;
        return if (i + skip < f.params.len) f.params[i + skip] else null;
    }

    fn pattern(p: *P, n: *Node) void {
        switch (n.data) {
            .identifier => |x| p.w(x),
            .object_pattern => |x| {
                p.w("{ ");
                p.elements(x.elems);
                p.w(" }");
            },
            .array_pattern => |x| {
                p.w("[");
                p.elements(x.elems);
                p.w("]");
            },
            else => {},
        }
    }

    fn elements(p: *P, elems: []const *Node) void {
        for (elems, 0..) |e, i| {
            if (i > 0) p.w(", ");
            if (e.data != .binding_elem) continue;
            const x = e.data.binding_elem;
            if (x.dotdotdot) p.w("...");
            if (x.prop_name) |k| if (k.data == .identifier) {
                p.w(k.data.identifier);
                p.w(": ");
            };
            p.pattern(x.name);
        }
    }

    fn sig(p: *P, s: *T.Sig, arrow: bool) void {
        const c = p.c;
        p.typeParams(s);
        p.w("(");
        if (s.this_ty) |x| {
            p.w("this: ");
            p.ty(x);
            if (s.params.len > 0) p.w(", ");
        }
        for (s.params, 0..) |a, i| {
            if (i > 0) p.w(", ");
            if (s.has_rest and i + 1 == s.params.len) {
                const r = d.paramTypeAt(c, s, i);
                if (expandsToParams(r)) {
                    p.tupleParams(r, a.name);
                    break;
                }
            }
            if (s.has_rest and i + 1 == s.params.len) p.w("...");
            const pat: ?*Node = if (paramNode(s, i)) |n| n.data.param.name else null;
            if (pat != null and pat.?.data != .identifier) p.pattern(pat.?) else p.w(a.name);
            if (a.optional and !(s.has_rest and i + 1 == s.params.len)) p.w("?");
            p.w(": ");
            // A default leaves its parameter optional but never `undefined` as declared.
            const defaulted = if (paramNode(s, i)) |n| n.data.param.init != null else false;
            const t = d.paramTypeAt(c, s, i);
            p.ty(if (defaulted) relate.removeDefinitelyUndefined(c, t) else t);
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

    /// `(...args: [a: number, string])` takes the arguments the tuple lists, and tsc writes those.
    fn tupleParams(p: *P, r: *Type, rest_name: []const u8) void {
        const c = p.c;
        const rest = r.data.obj.tuple;
        const labels = c.a.alloc([]const u8, rest.elems.len) catch oom();
        for (labels, 0..) |*l, i| {
            const own = if (i < rest.names.len) rest.names[i] else null;
            l.* = own orelse c.fmt("{s}_{d}", .{ rest_name, i });
        }
        for (labels, 0..) |*l, i| {
            var n: usize = 1;
            const stem = l.*;
            while (isTaken(labels[0..i], l.*)) : (n += 1) l.* = c.fmt("{s}_{d}", .{ stem, n });
        }
        for (rest.elems, rest.eflags, labels, 0..) |e, f, l, i| {
            if (i > 0) p.w(", ");
            if (f == .rest or f == .variadic) p.w("...");
            p.w(l);
            if (f == .optional) p.w("?");
            p.w(": ");
            p.ty(switch (f) {
                .rest => d.arrayOf(c, e),
                .optional => d.addMissing(c, e),
                else => e,
            });
        }
    }

    fn object(p: *P, t: *Type) void {
        const c = p.c;
        const o = t.data.obj;
        switch (o.kind) {
            .iface => return p.name(o.sym, o.tparams(), false),
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
                return p.name(o.sym, o.args.?, isIterableFamily(o.sym));
            },
            .tuple => return p.tuple(o),
            .mapped => if (p.mappedSyntax(t)) return,
            .anon => {},
        }
        if (o.sym) |s| if (writtenAsTypeof(s)) return p.typeofSymbol(s);
        // A type that holds itself is written out once: `...`, or `any` where nothing is cut short.
        if (std.mem.indexOfScalar(*Type, p.open.items, t) != null) {
            if (o.sym) |s| if (isNamedFunction(s)) return p.typeofSymbol(s);
            return p.w(if (p.full) "any" else "...");
        }
        p.open.append(c.a, t) catch oom();
        defer _ = p.open.pop();
        const m = d.membersOf(c, t);
        if (m.props.count() == 0 and m.indexes.len == 0) {
            if (m.calls.len == 1 and m.ctors.len == 0) return p.sig(m.calls[0], true);
            if (m.ctors.len == 1 and m.calls.len == 0) {
                if (m.ctors[0].abstract) p.w("abstract ");
                p.w("new ");
                return p.sig(m.ctors[0], true);
            }
            if (m.calls.len == 0 and m.ctors.len == 0) return p.w("{}");
        }
        if (p.tooDeep(3)) return p.w("...");
        p.depth += 1;
        defer p.depth -= 1;
        p.w("{ ");
        for (m.calls) |s| {
            p.sig(s, false);
            p.w("; ");
        }
        for (m.ctors) |s| {
            if (s.abstract) p.w("abstract ");
            p.w("new ");
            p.sig(s, false);
            p.w("; ");
        }
        for (m.indexes) |i| {
            if (i.readonly) p.w("readonly ");
            p.w("[");
            p.w(indexParamName(i));
            p.w(": ");
            p.ty(i.key);
            p.w("]: ");
            p.ty(i.ty);
            p.w("; ");
        }
        for (m.props.values()) |x| p.property(x);
        p.w("}");
    }

    /// `m(): T`, one line for each overload, is how a method reads.
    fn property(p: *P, x: *T.Prop) void {
        const c = p.c;
        const t = d.nonMissingPropType(c, x);
        const callable = x.method or if (x.sym) |s| s.flags & (binder.F.method | binder.F.function) != 0 else false;
        if (callable and !x.readonly) {
            const f = relate.removeDefinitelyUndefined(c, t);
            if (f.data == .obj and d.hasNoProps(c, f)) {
                const sigs = d.callSigs(c, f);
                for (sigs) |s| {
                    p.propName(x);
                    if (x.optional) p.w("?");
                    p.sig(s, false);
                    p.w("; ");
                }
                if (sigs.len > 0 or !x.optional) return;
            }
        }
        if (x.readonly) p.w("readonly ");
        p.propName(x);
        if (x.optional) p.w("?");
        p.w(": ");
        p.ty(t);
        p.w("; ");
    }

    /// tsc goes by how the name was written: `'a-b'` keeps its quotes, and `"10"` stays a string
    /// next to `10`.
    fn propName(p: *P, x: *T.Prop) void {
        const decls: []const *Node = if (x.sym) |s| s.decls else if (x.decl) |*n| @as(*const [1]*Node, n) else &.{};
        if (std.mem.startsWith(u8, x.name, "__@")) return p.computedName(x.name[3..], decls);
        var string_named = decls.len > 0;
        var single = decls.len > 0;
        for (decls) |n| {
            const k = syntax.nameOfDeclaration(n);
            if (k == null or !p.isStringNamed(k.?)) string_named = false;
            if (k == null or k.?.data != .string_lit or !p.startsWithSingleQuote(k.?)) single = false;
        }
        if (isIdentifierText(x.name) and !(x.method and std.mem.eql(u8, x.name, "new"))) return p.w(x.name);
        if (!string_named and isNumericName(p.c, x.name)) {
            if (x.name[0] != '-') return p.w(x.name);
            p.w("[");
            p.w(x.name);
            return p.w("]");
        }
        p.quotedWith(x.name, if (single) '\'' else '"', true);
    }

    fn unresolvedParents(p: *P, s: *binder.Symbol) void {
        const up = s.parent orelse return;
        p.unresolvedParents(up);
        p.w(up.name);
        p.w(".");
    }

    fn isStringNamed(p: *P, k: *Node) bool {
        return switch (k.data) {
            .string_lit => true,
            .computed_name => |z| api.typeFlags(expr.checkSilent(p.c, z.expr)).has(.string_like),
            else => false,
        };
    }

    fn startsWithSingleQuote(p: *P, n: *Node) bool {
        const f = d.fileOf(p.c, n) orelse return false;
        return n.start < f.src.len and f.src[n.start] == '\'';
    }

    /// `[Symbol.iterator]`, or `[key]` for a unique symbol of the program's.
    fn computedName(p: *P, name_text: []const u8, decls: []const *Node) void {
        p.w("[");
        defer p.w("]");
        for (decls) |n| {
            const k = syntax.nameOfDeclaration(n) orelse continue;
            if (k.data != .computed_name) continue;
            return p.entity(k.data.computed_name.expr);
        }
        p.w("Symbol.");
        p.w(name_text);
    }

    fn entity(p: *P, n: *Node) void {
        switch (n.data) {
            .identifier => |x| p.w(x),
            .prop_access => |x| {
                p.entity(x.expr);
                p.w(".");
                p.entity(x.name);
            },
            else => {},
        }
    }

    fn tuple(p: *P, o: *T.Obj) void {
        const c = p.c;
        if (o.readonly) p.w("readonly ");
        p.w("[");
        for (o.tuple.elems, o.tuple.eflags, 0..) |e, f, i| {
            if (i > 0) p.w(", ");
            const label: ?[]const u8 = if (i < o.tuple.names.len) o.tuple.names[i] else null;
            if (f == .rest or f == .variadic) p.w("...");
            // Without the exact option an optional element's `undefined` is part of its type.
            const x = if (f != .optional) e else if (c.exact_optional) d.removeMissing(c, e) else d.addOptional(c, e);
            if (label) |l| {
                p.w(l);
                if (f == .optional) p.w("?");
                p.w(": ");
                if (f == .rest) p.part(x) else p.ty(x);
                if (f == .rest) p.w("[]");
                continue;
            }
            if (f == .rest or f == .optional) p.part(x) else p.ty(x);
            if (f == .rest) p.w("[]");
            if (f == .optional) p.w("?");
        }
        p.w("]");
    }

    /// A mapped type over keys still unknown has nothing to list but what it was written as.
    fn mappedSyntax(p: *P, t: *Type) bool {
        const c = p.c;
        const o = t.data.obj;
        const node = o.node orelse return false;
        const x = node.data.mapped_type;
        const keys = d.instantiate(c, d.typeFromNode(c, x.constraint), o.mapper);
        if (!keys.vars) return false;
        p.w("{ ");
        if (x.readonly_mod == .plus or x.readonly_mod == .kw_readonly) p.w("readonly ");
        if (x.readonly_mod == .minus) p.w("-readonly ");
        p.w("[");
        p.pattern(x.tparam_name);
        p.w(" in ");
        p.ty(keys);
        if (x.name_type) |n| {
            p.w(" as ");
            p.ty(d.instantiate(c, d.typeFromNode(c, n), o.mapper));
        }
        p.w("]");
        if (x.question_mod == .plus or x.question_mod == .question) p.w("?");
        if (x.question_mod == .minus) p.w("-?");
        p.w(": ");
        if (x.type) |n| p.ty(d.instantiate(c, d.typeFromNode(c, n), o.mapper)) else p.w("any");
        p.w("; }");
        return true;
    }

    fn typeofSymbol(p: *P, s: *binder.Symbol) void {
        p.w("typeof ");
        if (moduleSpecifierOf(s)) |m| {
            p.w("import(");
            p.quoted(m);
            p.w(")");
            return;
        }
        p.w(symbolName(s));
    }

    /// `/src/a.ts` or `"a"`, for a module that has a file or a quoted name rather than a name.
    fn moduleSpecifierOf(s: *binder.Symbol) ?[]const u8 {
        // A file's symbol is the file's own, and it declares nothing a node could stand for.
        if (s.flags & binder.F.value_module != 0 and s.decls.len == 0 and s.file != null) {
            for ([_][]const u8{ ".d.ts", ".d.mts", ".d.cts", ".tsx", ".ts", ".mts", ".cts", ".jsx", ".js", ".mjs", ".cjs" }) |e| {
                if (std.mem.endsWith(u8, s.name, e)) return s.name[0 .. s.name.len - e.len];
            }
            return s.name;
        }
        if (s.decls.len == 0) return null;
        const n = s.decls[0];
        return switch (n.data) {
            .module_decl => |x| if (x.name.data == .string_lit) x.name.data.string_lit else null,
            else => null,
        };
    }

    /// tsc's `getNameOfSymbolAsWritten`: a class expression goes by the variable that holds it.
    fn symbolName(s: *binder.Symbol) []const u8 {
        if (std.mem.eql(u8, s.name, "default")) for (s.decls) |x| {
            const own = syntax.nameOfDeclaration(x) orelse continue;
            if (own.data == .identifier) return own.data.identifier;
        };
        if (!std.mem.eql(u8, s.name, "__class")) return s.name;
        if (s.decls.len > 0) if (s.decls[0].parent) |o| switch (o.data) {
            .var_decl => |x| if (x.name.data == .identifier) return x.name.data.identifier,
            .binary => |x| if (x.op == .assign and x.right == s.decls[0] and x.left.data == .identifier) return x.left.data.identifier,
            else => {},
        };
        return "(Anonymous class)";
    }

    fn name(p: *P, sym: ?*binder.Symbol, args: []const *Type, elide_defaults: bool) void {
        p.w(if (sym) |s| symbolName(s) else "?");
        var shown = p.c.newList(*Type);
        for (args) |a| if (!(a.data == .param and a.data.param.is_this)) shown.append(p.c.a, a) catch oom();
        if (elide_defaults) p.elideDefaults(sym.?, &shown);
        if (shown.items.len == 0) return;
        p.w("<");
        p.list(shown.items, ", ");
        p.w(">");
    }

    /// `Iterable<number>` hides that it has three parameters, which tsc does for this family alone.
    fn elideDefaults(p: *P, sym: *binder.Symbol, shown: *std.ArrayList(*Type)) void {
        const declared = d.declaredType(p.c, sym);
        if (declared.data != .obj) return;
        const params = declared.data.obj.tparams();
        while (shown.items.len > 0 and shown.items.len <= params.len) {
            const at = shown.items.len - 1;
            const dflt = d.defaultOf(p.c, params[at]) orelse return;
            if (!relate.isIdentical(p.c, shown.items[at], dflt)) return;
            shown.items.len = at;
        }
    }

    fn ty(p: *P, t: *Type) void {
        const c = p.c;
        if (p.tooDeep(6)) return p.w(if (p.full) "any" else "...");
        p.depth += 1;
        defer p.depth -= 1;
        if (t.alias) |a| {
            // Only a name that resolved to nothing has a parent in hand and no scope to find it in.
            if (t.data == .err) p.unresolvedParents(a.sym);
            p.w(a.sym.name);
            if (a.args.len > 0) {
                p.w("<");
                p.list(a.args, ", ");
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
                var i: usize = 0;
                while (i < u.len) : (i += 1) {
                    const m = u[i];
                    if (m.data == .null or m.data == .undefined) {
                        if (tail.items.len == 0 or @as(std.meta.Tag(T.Data), tail.items[tail.items.len - 1].data) != m.data) tail.append(c.a, m) catch oom();
                    } else if (enumOfRun(c, u, i)) |e| {
                        head.append(c.a, e) catch oom();
                        i += e.data.union_.len - 1;
                    } else if (m.data != .bool_lit or bools < 2 or m.data.bool_lit == false) {
                        head.append(c.a, m) catch oom();
                    }
                }
                if (tail.items.len == 2 and tail.items[0].data == .undefined) std.mem.swap(*Type, &tail.items[0], &tail.items[1]);
                var first = true;
                for (head.items) |m| {
                    if (!first) p.w(" | ");
                    first = false;
                    // `true` and `false` collapse into a `boolean` that stands where they stood.
                    if (m.data == .bool_lit and bools == 2) p.w("boolean") else p.part(m);
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
                p.part(x);
            },
            .access => |x| {
                p.part(x.obj);
                p.w("[");
                p.ty(x.index);
                p.w("]");
            },
            .cond => |x| {
                p.part(x.check);
                p.w(" extends ");
                p.part(x.extends);
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

/// A class, an enum or a namespace reads as `typeof` itself, and so does a function given members.
fn wtf8Length(v: []const u8) usize {
    const need: usize = if (v[0] >= 0xf0) 4 else if (v[0] >= 0xe0) 3 else if (v[0] >= 0xc0) 2 else 1;
    return @min(need, v.len);
}

fn wtf8Decode(v: []const u8) u32 {
    const head: u32 = switch (v.len) {
        4 => v[0] & 0x07,
        3 => v[0] & 0x0f,
        2 => v[0] & 0x1f,
        else => v[0],
    };
    var cp = head;
    for (v[1..]) |b| cp = cp << 6 | (b & 0x3f);
    return cp;
}

fn writtenAsTypeof(s: *binder.Symbol) bool {
    if (s.flags & (binder.F.class | binder.F.enum_any | binder.F.value_module) != 0) return true;
    if (s.flags & binder.F.function == 0) return false;
    const members = s.exports orelse return false;
    return members.map.count() > 0;
}

/// A function that can be named from anywhere, which is how a function holding itself gets out:
/// a static method, or one declared at the top of a file or namespace.
fn isNamedFunction(s: *binder.Symbol) bool {
    if (s.flags & binder.F.method != 0) {
        for (s.decls) |x| if (x.mods.static) return true;
        return false;
    }
    if (s.flags & binder.F.function == 0) return false;
    if (s.parent != null) return true;
    for (s.decls) |x| if (x.parent) |p| if (p.data == .source_file or p.data == .module_block) return true;
    return false;
}

/// Where a union holds every member of an enum in a row, tsc writes the enum. Its members have the
/// enum's order because both go by id.
fn enumOfRun(c: *Checker, u: []const *Type, at: usize) ?*Type {
    const m = u[at];
    if (m.data != .enum_lit) return null;
    const e = d.declaredType(c, m.data.enum_lit.parent);
    if (e.data != .union_) return null;
    const count = e.data.union_.len;
    if (at + count > u.len) return null;
    return if ((u[at + count - 1].regular orelse u[at + count - 1]) == e.data.union_[count - 1]) e else null;
}

fn isIterableFamily(sym: ?*binder.Symbol) bool {
    const s = sym orelse return false;
    if (s.parent != null) return false;
    for ([_][]const u8{ "Iterable", "IterableIterator", "AsyncIterable", "AsyncIterableIterator" }) |n| {
        if (std.mem.eql(u8, s.name, n)) return true;
    }
    return false;
}

fn indexParamName(i: T.Index) []const u8 {
    const n = i.decl orelse return "x";
    if (n.data != .index_sig or n.data.index_sig.params.len == 0) return "x";
    const name = n.data.index_sig.params[0].data.param.name;
    return if (name.data == .identifier) name.data.identifier else "x";
}

/// Only the last parameter may be a rest, so a tuple open in the middle stays one.
fn expandsToParams(r: *Type) bool {
    if (!T.isTupleType(r)) return false;
    const flags = r.data.obj.tuple.eflags;
    if (flags.len == 0) return true;
    for (flags[0 .. flags.len - 1]) |f| if (f == .rest or f == .variadic) return false;
    return true;
}

fn sameLetters(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var count: [256]i64 = @splat(0);
    for (a) |x| count[x] += 1;
    for (b) |x| count[x] -= 1;
    for (count) |n| if (n != 0) return false;
    return true;
}

fn isTaken(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// A lone surrogate reads as no character at all, so no name holding one can go unquoted.
fn isIdentifierText(s: []const u8) bool {
    for (s, 0..) |b, i| if (b == 0xED and i + 1 < s.len and s[i + 1] >= 0xA0) return false;
    return lexer.isIdentifierText(s);
}

/// tsc's `isNumericLiteralName`: the name is how the number it reads as prints.
fn isNumericName(c: *Checker, s: []const u8) bool {
    const v = std.fmt.parseFloat(f64, s) catch return false;
    return std.mem.eql(u8, d.numName(c, v), s);
}

pub fn typeToString(c: *Checker, t: *Type) []const u8 {
    var p = P{ .c = c };
    p.ty(t);
    return p.out.items;
}

/// `typeToString` with nothing cut short, tsc's `NoTruncation`.
pub fn fullTypeToString(c: *Checker, t: *Type) []const u8 {
    var p = P{ .c = c, .full = true };
    p.ty(t);
    return p.out.items;
}
