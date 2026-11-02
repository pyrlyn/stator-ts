//! tsc's `checkGrammarModifiers` for keyword modifiers. Decorators are `checkDecorators`' job.
const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const T = @import("types.zig");
const d = @import("decls.zig");
const checker = @import("checker.zig");
const Node = ast.Node;
const Tok = lexer.Tok;
const Checker = T.Checker;

const Mod = struct { tok: Tok, start: u32, end: u32 };

const Flags = packed struct(u16) {
    @"export": bool = false,
    default: bool = false,
    ambient: bool = false,
    abstract: bool = false,
    public: bool = false,
    private: bool = false,
    protected: bool = false,
    static: bool = false,
    readonly: bool = false,
    override: bool = false,
    async: bool = false,
    accessor: bool = false,
    in: bool = false,
    out: bool = false,
    _: u2 = 0,

    fn accessibility(f: Flags) bool {
        return f.public or f.private or f.protected;
    }
};

pub fn check(c: *Checker, n: *Node) void {
    var m = n.mods;
    m.decorated = false;
    // The parser keeps the keyword of `static {}` as a modifier.
    const block = n.data == .static_block;
    if (block) m.static = false;
    if (m == ast.Mods{}) return;
    switch (n.data) {
        // `export` and `default` there are syntax, not modifiers.
        .export_assign, .export_decl => return,
        else => {},
    }
    const f = d.fileOf(c, n) orelse return;
    // tsc reports grammar only in files that parse.
    if (f.diags.len != 0) return;
    var buf: [16]Mod = undefined;
    var mods = scan(c, f.src, n, &buf);
    if (block and mods.len > 0 and mods[mods.len - 1].tok == .kw_static) mods = mods[0 .. mods.len - 1];
    if (mods.len == 0) return;
    if (firstIllegal(n, mods)) |x| return at(c, n, x, 1184, "Modifiers cannot appear here.");
    checkList(c, n, mods);
}

/// The node keeps its modifiers only as flags, so their tokens are read again from its start,
/// stepping over decorators, up to its name.
fn scan(c: *Checker, src: []const u8, n: *Node, buf: []Mod) []Mod {
    const limit: u32 = switch (n.data) {
        .func => |x| if (x.name) |nm| nm.start else n.end,
        .property_decl => |x| x.name.start,
        .property_sig => |x| x.name.start,
        .param => |x| x.name.start,
        .type_param => |x| x.name.start,
        // `const` there declares the variables.
        .var_stmt => |x| x.list.start,
        else => n.end,
    };
    var lx = lexer.Lexer{ .src = src, .a = c.a, .pos = n.start };
    var len: usize = 0;
    while (len < buf.len) {
        const tok = lx.next();
        if (lx.start >= limit) break;
        if (tok == .at) {
            const dec = decoratorAt(n, lx.start) orelse break;
            lx.pos = dec.end;
            continue;
        }
        if (!isModifier(tok)) break;
        buf[len] = .{ .tok = tok, .start = lx.start, .end = lx.pos };
        len += 1;
    }
    return buf[0..len];
}

fn decoratorAt(n: *Node, pos: u32) ?*Node {
    const list: []*Node = switch (n.data) {
        .func => |x| x.decorators,
        .class => |x| x.decorators,
        .param => |x| x.decorators,
        .property_decl => |x| x.decorators,
        else => &.{},
    };
    for (list) |x| if (x.start == pos) return x;
    return null;
}

fn isModifier(tok: Tok) bool {
    return switch (tok) {
        .kw_export, .kw_default, .kw_declare, .kw_abstract, .kw_public, .kw_private, .kw_protected, .kw_static, .kw_readonly, .kw_override, .kw_async, .kw_const, .kw_accessor, .kw_in, .kw_out => true,
        else => false,
    };
}

fn text(tok: Tok) []const u8 {
    return switch (tok) {
        .kw_export => "export",
        .kw_default => "default",
        .kw_declare => "declare",
        .kw_abstract => "abstract",
        .kw_public => "public",
        .kw_private => "private",
        .kw_protected => "protected",
        .kw_static => "static",
        .kw_readonly => "readonly",
        .kw_override => "override",
        .kw_async => "async",
        .kw_const => "const",
        .kw_accessor => "accessor",
        .kw_in => "in",
        .kw_out => "out",
        else => "",
    };
}

fn at(c: *Checker, n: *Node, m: Mod, code: u32, msg: []const u8) void {
    d.reportSpan(c, n, m.start, m.end, code, msg);
}

fn atNode(c: *Checker, n: *Node, code: u32, msg: []const u8) void {
    // tsc's `getErrorSpanForNode` points at the name of a property.
    const target = switch (n.data) {
        .property_decl => |x| x.name,
        .func => |x| x.name orelse n,
        else => n,
    };
    d.report(c, target, code, msg);
}

/// tsc's `findFirstIllegalModifier`.
fn firstIllegal(n: *Node, mods: []const Mod) ?Mod {
    const first = mods[0];
    switch (n.data) {
        .static_block, .property_assign, .shorthand_assign, .namespace_export_decl => return first,
        .func => |x| switch (x.kind) {
            .decl => {},
            .constructor_type => return if (first.tok != .kw_abstract) first else null,
            else => return null,
        },
        .property_decl, .property_sig, .index_sig, .module_decl, .import_decl, .import_equals, .param, .type_param => return null,
        else => {},
    }
    const p = n.parent orelse return null;
    if (p.data == .source_file or p.data == .module_block) return null;
    return switch (n.data) {
        .func => if (first.tok != .kw_async) first else null,
        .class => |x| if (x.is_expr or first.tok != .kw_abstract) first else null,
        .enum_decl => if (first.tok != .kw_const) first else null,
        .interface, .type_alias, .var_stmt => first,
        else => null,
    };
}

const Kind = enum { ctor, method, accessor, method_sig, property, property_sig, index_sig, param, type_param, func, arrow, class_decl, ctor_type, enum_decl, import, other };

fn kindOf(n: *Node) Kind {
    return switch (n.data) {
        .func => |x| switch (x.kind) {
            .ctor => .ctor,
            .method => .method,
            .getter, .setter, .getter_sig, .setter_sig => .accessor,
            .method_sig => .method_sig,
            .decl, .expr => .func,
            .arrow => .arrow,
            .constructor_type => .ctor_type,
            else => .other,
        },
        .property_decl => .property,
        .property_sig => .property_sig,
        .index_sig => .index_sig,
        .param => .param,
        .type_param => .type_param,
        .class => |x| if (x.is_expr) .other else .class_decl,
        .enum_decl => .enum_decl,
        .import_decl, .import_equals => .import,
        else => .other,
    };
}

fn checkList(c: *Checker, n: *Node, mods: []const Mod) void {
    const kind = kindOf(n);
    const parent = n.parent.?;
    const in_class = parent.data == .class;
    const top = parent.data == .source_file or parent.data == .module_block;
    const private_name = in_class and switch (n.data) {
        .property_decl => |x| x.name.data == .private_name,
        .func => |x| x.name != null and x.name.?.data == .private_name,
        else => false,
    };
    const using: ?[]const u8 = if (n.data == .var_stmt) switch (n.data.var_stmt.list.data.var_list.kind) {
        .using => "using",
        .await_using => "await using",
        else => null,
    } else null;
    var flags = Flags{};
    var last_static: ?Mod = null;
    var last_declare: ?Mod = null;
    var last_async: ?Mod = null;
    var last_override: ?Mod = null;
    for (mods) |m| {
        const t = text(m.tok);
        if (m.tok != .kw_readonly) {
            if (kind == .property_sig or kind == .method_sig) return at(c, n, m, 1070, c.fmt("'{s}' modifier cannot appear on a type member.", .{t}));
            if (kind == .index_sig and (m.tok != .kw_static or !in_class)) return at(c, n, m, 1071, c.fmt("'{s}' modifier cannot appear on an index signature.", .{t}));
        }
        if (m.tok != .kw_in and m.tok != .kw_out and m.tok != .kw_const and kind == .type_param) {
            return at(c, n, m, 1273, c.fmt("'{s}' modifier cannot appear on a type parameter", .{t}));
        }
        switch (m.tok) {
            .kw_const => {
                if (kind != .enum_decl and kind != .type_param) return atNode(c, n, 1248, "A class member cannot have the 'const' keyword.");
                if (kind == .type_param and !constTypeParamOwner(parent)) {
                    return at(c, n, m, 1277, "'const' modifier can only appear on a type parameter of a function, method or class");
                }
            },
            .kw_override => {
                if (flags.override) return seen(c, n, m);
                if (flags.ambient) return with(c, n, m, "override", "declare");
                if (flags.readonly) return precede(c, n, m, "override", "readonly");
                if (flags.accessor) return precede(c, n, m, "override", "accessor");
                if (flags.async) return precede(c, n, m, "override", "async");
                flags.override = true;
                last_override = m;
            },
            .kw_public, .kw_protected, .kw_private => {
                if (flags.accessibility()) return at(c, n, m, 1028, "Accessibility modifier already seen.");
                if (flags.override) return precede(c, n, m, t, "override");
                if (flags.static) return precede(c, n, m, t, "static");
                if (flags.accessor) return precede(c, n, m, t, "accessor");
                if (flags.readonly) return precede(c, n, m, t, "readonly");
                if (flags.async) return precede(c, n, m, t, "async");
                if (top) return at(c, n, m, 1044, c.fmt("'{s}' modifier cannot appear on a module or namespace element.", .{t}));
                if (flags.abstract) {
                    if (m.tok == .kw_private) return with(c, n, m, t, "abstract");
                    return precede(c, n, m, t, "abstract");
                }
                if (private_name) return at(c, n, m, 18010, "An accessibility modifier cannot be used with a private identifier.");
                switch (m.tok) {
                    .kw_public => flags.public = true,
                    .kw_protected => flags.protected = true,
                    else => flags.private = true,
                }
            },
            .kw_static => {
                if (flags.static) return seen(c, n, m);
                if (flags.readonly) return precede(c, n, m, "static", "readonly");
                if (flags.async) return precede(c, n, m, "static", "async");
                if (flags.accessor) return precede(c, n, m, "static", "accessor");
                if (top) return at(c, n, m, 1044, "'static' modifier cannot appear on a module or namespace element.");
                if (kind == .param) return onParam(c, n, m);
                if (flags.abstract) return with(c, n, m, "static", "abstract");
                if (flags.override) return precede(c, n, m, "static", "override");
                flags.static = true;
                last_static = m;
            },
            .kw_accessor => {
                if (flags.accessor) return seen(c, n, m);
                if (flags.readonly) return with(c, n, m, "accessor", "readonly");
                if (flags.ambient) return with(c, n, m, "accessor", "declare");
                if (kind != .property) return at(c, n, m, 1275, "'accessor' modifier can only appear on a property declaration.");
                flags.accessor = true;
            },
            .kw_readonly => {
                if (flags.readonly) return seen(c, n, m);
                if (kind != .property and kind != .property_sig and kind != .index_sig and kind != .param) {
                    return at(c, n, m, 1024, "'readonly' modifier can only appear on a property declaration or index signature.");
                }
                if (flags.accessor) return with(c, n, m, "readonly", "accessor");
                flags.readonly = true;
            },
            .kw_export => {
                if (flags.@"export") return seen(c, n, m);
                if (flags.ambient) return precede(c, n, m, "export", "declare");
                if (flags.abstract) return precede(c, n, m, "export", "abstract");
                if (flags.async) return precede(c, n, m, "export", "async");
                if (in_class) return onClassElement(c, n, m);
                if (kind == .param) return onParam(c, n, m);
                if (using) |u| return onUsing(c, n, m, u);
                flags.@"export" = true;
            },
            .kw_default => {
                const container = if (parent.data == .source_file) parent else parent.parent orelse parent;
                if (container.data == .module_decl and !checker.isAmbientModule(container)) {
                    return at(c, n, m, 1319, "A default export can only be used in an ECMAScript-style module.");
                }
                if (using) |u| return onUsing(c, n, m, u);
                if (!flags.@"export") return precede(c, n, m, "export", "default");
                flags.default = true;
            },
            .kw_declare => {
                if (flags.ambient) return seen(c, n, m);
                if (flags.async) return ambientContext(c, n, m, "async");
                if (flags.override) return ambientContext(c, n, m, "override");
                if (in_class and kind != .property) return onClassElement(c, n, m);
                if (kind == .param) return onParam(c, n, m);
                if (using) |u| return onUsing(c, n, m, u);
                if (parent.data == .module_block and checker.isAmbient(c, parent)) {
                    return at(c, n, m, 1038, "A 'declare' modifier cannot be used in an already ambient context.");
                }
                if (private_name) return at(c, n, m, 18019, "'declare' modifier cannot be used with a private identifier.");
                if (flags.accessor) return with(c, n, m, "declare", "accessor");
                flags.ambient = true;
                last_declare = m;
            },
            .kw_abstract => {
                if (flags.abstract) return seen(c, n, m);
                if (kind != .class_decl and kind != .ctor_type) {
                    if (kind != .method and kind != .property and kind != .accessor) {
                        return at(c, n, m, 1242, "'abstract' modifier can only appear on a class, method, or property declaration.");
                    }
                    if (!(parent.data == .class and !parent.data.class.is_expr and parent.mods.abstract)) {
                        if (kind == .property) return at(c, n, m, 1253, "Abstract properties can only appear within an abstract class.");
                        return at(c, n, m, 1244, "Abstract methods can only appear within an abstract class.");
                    }
                    if (flags.static) return with(c, n, m, "static", "abstract");
                    if (flags.private) return with(c, n, m, "private", "abstract");
                    if (flags.async) if (last_async) |a| return with(c, n, a, "async", "abstract");
                    if (flags.override) return precede(c, n, m, "abstract", "override");
                    if (flags.accessor) return precede(c, n, m, "abstract", "accessor");
                }
                if (private_name) return at(c, n, m, 18019, "'abstract' modifier cannot be used with a private identifier.");
                flags.abstract = true;
            },
            .kw_async => {
                if (flags.async) return seen(c, n, m);
                if (flags.ambient or checker.isAmbient(c, parent)) return ambientContext(c, n, m, "async");
                if (kind == .param) return onParam(c, n, m);
                if (flags.abstract) return with(c, n, m, "async", "abstract");
                flags.async = true;
                last_async = m;
            },
            .kw_in, .kw_out => {
                if (kind != .type_param or !(parent.data == .interface or parent.data == .class or parent.data == .type_alias)) {
                    return at(c, n, m, 1274, c.fmt("'{s}' modifier can only appear on a type parameter of a class, interface or type alias", .{t}));
                }
                const is_in = m.tok == .kw_in;
                if (if (is_in) flags.in else flags.out) return seen(c, n, m);
                if (is_in and flags.out) return precede(c, n, m, "in", "out");
                if (is_in) flags.in = true else flags.out = true;
            },
            else => {},
        }
    }
    if (kind == .ctor) {
        if (last_static) |m| return onCtor(c, n, m);
        if (last_override) |m| return onCtor(c, n, m);
        if (last_async) |m| return onCtor(c, n, m);
        return;
    }
    if (kind == .import) if (last_declare) |m| return at(c, n, m, 1079, "A 'declare' modifier cannot be used with an import declaration.");
    if (kind == .param and (flags.accessibility() or flags.readonly or flags.override)) {
        const x = n.data.param;
        if (x.name.data == .object_pattern or x.name.data == .array_pattern) return d.report(c, n, 1187, "A parameter property may not be declared using a binding pattern.");
        if (x.dotdotdot) return d.report(c, n, 1317, "A parameter property cannot be declared using a rest parameter.");
    }
    if (last_async) |m| switch (kind) {
        .method, .func, .arrow => {},
        else => at(c, n, m, 1042, "'async' modifier cannot be used here."),
    };
}

fn seen(c: *Checker, n: *Node, m: Mod) void {
    at(c, n, m, 1030, c.fmt("'{s}' modifier already seen.", .{text(m.tok)}));
}

fn precede(c: *Checker, n: *Node, m: Mod, first: []const u8, second: []const u8) void {
    at(c, n, m, 1029, c.fmt("'{s}' modifier must precede '{s}' modifier.", .{ first, second }));
}

fn with(c: *Checker, n: *Node, m: Mod, first: []const u8, second: []const u8) void {
    at(c, n, m, 1243, c.fmt("'{s}' modifier cannot be used with '{s}' modifier.", .{ first, second }));
}

fn onParam(c: *Checker, n: *Node, m: Mod) void {
    at(c, n, m, 1090, c.fmt("'{s}' modifier cannot appear on a parameter.", .{text(m.tok)}));
}

fn onClassElement(c: *Checker, n: *Node, m: Mod) void {
    at(c, n, m, 1031, c.fmt("'{s}' modifier cannot appear on class elements of this kind.", .{text(m.tok)}));
}

fn onCtor(c: *Checker, n: *Node, m: Mod) void {
    at(c, n, m, 1089, c.fmt("'{s}' modifier cannot appear on a constructor declaration.", .{text(m.tok)}));
}

fn ambientContext(c: *Checker, n: *Node, m: Mod, name: []const u8) void {
    at(c, n, m, 1040, c.fmt("'{s}' modifier cannot be used in an ambient context.", .{name}));
}

fn onUsing(c: *Checker, n: *Node, m: Mod, using: []const u8) void {
    const code: u32 = if (using.len == 5) 1491 else 1495;
    at(c, n, m, code, c.fmt("'{s}' modifier cannot appear on a{s} '{s}' declaration.", .{ text(m.tok), if (code == 1495) "n" else "", using }));
}

fn constTypeParamOwner(p: *Node) bool {
    return switch (p.data) {
        .class => true,
        .func => |x| switch (x.kind) {
            .decl, .expr, .arrow, .method, .ctor, .getter, .setter, .function_type, .constructor_type, .call_sig, .construct_sig, .method_sig => true,
            else => false,
        },
        else => false,
    };
}
