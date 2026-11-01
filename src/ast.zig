const std = @import("std");
const lexer = @import("lexer.zig");
const binder = @import("binder.zig");
pub const Tok = lexer.Tok;

pub const Mods = packed struct(u16) {
    @"export": bool = false,
    default: bool = false,
    declare: bool = false,
    abstract: bool = false,
    public: bool = false,
    private: bool = false,
    protected: bool = false,
    static: bool = false,
    readonly: bool = false,
    override: bool = false,
    async: bool = false,
    @"const": bool = false,
    accessor: bool = false,
    in: bool = false,
    out: bool = false,
    _pad: u1 = 0,
};

pub const Span = struct { start: u32 = 0, end: u32 = 0 };

/// Type parameters or arguments, with the span of the angle brackets so the emitter can erase them.
pub const TypeList = struct {
    items: []*Node = &.{},
    span: Span = .{},
};

pub const FuncKind = enum {
    decl,
    expr,
    arrow,
    method,
    ctor,
    getter,
    setter,
    method_sig,
    call_sig,
    construct_sig,
    function_type,
    constructor_type,
    getter_sig,
    setter_sig,
};

pub const Func = struct {
    kind: FuncKind,
    decorators: []*Node = &.{},
    name: ?*Node = null,
    asterisk: bool = false,
    question: bool = false,
    /// Position of `?` after a method name.
    q_pos: u32 = 0,
    type_params: TypeList = .{},
    params: []*Node = &.{},
    /// Span from `:` through the return type.
    ret_span: Span = .{},
    ret: ?*Node = null,
    body: ?*Node = null,
    /// Null when control cannot fall off the end; set by the binder.
    end_flow: ?*binder.FlowNode = null,
};

pub const Class = struct {
    is_expr: bool,
    decorators: []*Node = &.{},
    name: ?*Node = null,
    type_params: TypeList = .{},
    heritage: []*Node = &.{},
    members: []*Node = &.{},
};

pub const Interface = struct {
    name: *Node,
    type_params: TypeList = .{},
    heritage: []*Node = &.{},
    members: []*Node = &.{},
};

pub const Param = struct {
    decorators: []*Node = &.{},
    dotdotdot: bool = false,
    name: *Node,
    question: bool = false,
    /// `?`, `:` and the type: everything the emitter erases.
    ann_span: Span = .{},
    type: ?*Node = null,
    init: ?*Node = null,
};

pub const VarDecl = struct {
    name: *Node,
    excl: bool = false,
    ann_span: Span = .{},
    type: ?*Node = null,
    init: ?*Node = null,
};

pub const Property = struct {
    decorators: []*Node = &.{},
    name: *Node,
    question: bool = false,
    excl: bool = false,
    ann_span: Span = .{},
    type: ?*Node = null,
    init: ?*Node = null,
};

pub const Mapped = struct {
    readonly_mod: Tok = .eof,
    tparam_name: *Node,
    constraint: *Node,
    name_type: ?*Node = null,
    question_mod: Tok = .eof,
    type: ?*Node = null,
};

pub const VarKind = enum { @"var", let, @"const", using, await_using };

pub const KwType = enum { any, unknown, never, void, number, string, boolean, bigint, symbol, object, undefined, null, intrinsic };

/// These would cost every node their size if they sat in `Data`, and VS Code has 22 million nodes.
pub const Call = struct { callee: *Node, type_args: TypeList, args: []*Node, optional: bool };
pub const NewExpr = struct { callee: *Node, type_args: TypeList, args: []*Node };
pub const TypeRef = struct { name: *Node, type_args: TypeList };
pub const BindingElem = struct { prop_name: ?*Node, dotdotdot: bool, name: *Node, init: ?*Node };
pub const TemplateExpr = struct { head: []const u8, spans: []*Node };
pub const ExprWithTypeArgs = struct { expr: *Node, type_args: TypeList };
pub const ForOf = struct { is_await: bool, init: *Node, expr: *Node, body: *Node };
pub const TypeAlias = struct { name: *Node, type_params: TypeList, type: *Node };
pub const ForStmt = struct { init: ?*Node, cond: ?*Node, update: ?*Node, body: *Node };
pub const TypeQuery = struct { name: *Node, type_args: TypeList };
pub const ExportDecl = struct { clause: ?*Node, specifier: ?*Node, type_only: bool, attrs: ?*Node };
pub const ConditionalType = struct { check: *Node, extends: *Node, then: *Node, els: *Node };
pub const ImportType = struct { is_typeof: bool, arg: *Node, qualifier: ?*Node, type_args: TypeList };
pub const TaggedTemplate = struct { tag: *Node, type_args: TypeList, template: *Node };
pub const TemplateLiteralType = struct { head: []const u8, spans: []*Node };
pub const JsxSelfClosing = struct { tag: *Node, type_args: TypeList, attrs: []*Node };
pub const JsxOpening = struct { tag: *Node, type_args: TypeList, attrs: []*Node };
pub const JsxElement = struct { open: *Node, children: []*Node, close: *Node };

/// Field order is source order: forEachChild relies on it.
pub const Data = union(enum) {
    source_file: struct { stmts: []*Node },

    identifier: []const u8,
    private_name: []const u8,
    string_lit: []const u8,
    numeric_lit: []const u8,
    bigint_lit: []const u8,
    regex_lit: []const u8,
    no_subst_template: []const u8,
    this_expr,
    super_expr,
    null_lit,
    true_lit,
    false_lit,
    import_kw,
    omitted_expr,

    template_expr: *TemplateExpr,
    template_span: struct { expr: *Node, text: []const u8 },
    tagged_template: *TaggedTemplate,
    array_lit: struct { elems: []*Node },
    object_lit: struct { props: []*Node },
    property_assign: struct { name: *Node, value: *Node },
    shorthand_assign: struct { name: *Node, init: ?*Node },
    spread_assign: struct { expr: *Node },
    spread_elem: struct { expr: *Node },
    paren: struct { expr: *Node },
    prop_access: struct { expr: *Node, name: *Node, optional: bool },
    elem_access: struct { expr: *Node, index: *Node, optional: bool },
    call: *Call,
    new_expr: *NewExpr,
    prefix: struct { op: Tok, expr: *Node },
    postfix: struct { expr: *Node, op: Tok },
    typeof_expr: struct { expr: *Node },
    void_expr: struct { expr: *Node },
    delete_expr: struct { expr: *Node },
    await_expr: struct { expr: *Node },
    yield_expr: struct { expr: ?*Node, star: bool },
    binary: struct { left: *Node, op: Tok, right: *Node },
    conditional: struct { cond: *Node, then: *Node, els: *Node },
    as_expr: struct { expr: *Node, type: *Node },
    satisfies_expr: struct { expr: *Node, type: *Node },
    non_null: struct { expr: *Node },
    type_assertion: struct { type: *Node, expr: *Node },
    meta_property: struct { keyword: Tok, name: []const u8 },

    jsx_element: *JsxElement,
    jsx_self_closing: *JsxSelfClosing,
    jsx_fragment: struct { children: []*Node },
    jsx_opening: *JsxOpening,
    jsx_closing: struct { tag: *Node },
    jsx_attr: struct { name: *Node, value: ?*Node },
    jsx_spread_attr: struct { expr: *Node },
    jsx_expr: struct { expr: ?*Node },
    jsx_text: []const u8,

    block: struct { stmts: []*Node },
    /// A function's block left unparsed: most of a program is function bodies, and most of those
    /// matter to one checker only. The node's span finds the text and its `flow` is where the
    /// block starts. `specs` are the modules the block names, which must load with the program.
    lazy_body: struct { specs: []const *Node = &.{} },
    var_stmt: struct { list: *Node },
    var_list: struct { kind: VarKind, decls: []*Node },
    var_decl: *VarDecl,
    expr_stmt: struct { expr: *Node },
    if_stmt: struct { cond: *Node, then: *Node, els: ?*Node },
    do_stmt: struct { body: *Node, cond: *Node },
    while_stmt: struct { cond: *Node, body: *Node },
    for_stmt: *ForStmt,
    for_in: struct { init: *Node, expr: *Node, body: *Node },
    for_of: *ForOf,
    continue_stmt: struct { label: ?*Node },
    break_stmt: struct { label: ?*Node },
    return_stmt: struct { expr: ?*Node },
    with_stmt: struct { expr: *Node, body: *Node },
    switch_stmt: struct { expr: *Node, clauses: []*Node },
    case_clause: struct { expr: *Node, stmts: []*Node },
    default_clause: struct { stmts: []*Node },
    labeled: struct { label: *Node, stmt: *Node },
    throw_stmt: struct { expr: *Node },
    try_stmt: struct { block: *Node, catch_clause: ?*Node, finally: ?*Node },
    catch_clause: struct { decl: ?*Node, block: *Node },
    debugger_stmt,
    empty_stmt,

    func: *Func,
    class: *Class,
    interface: *Interface,
    type_alias: *TypeAlias,
    enum_decl: struct { name: *Node, members: []*Node },
    enum_member: struct { name: *Node, init: ?*Node },
    module_decl: struct { name: *Node, body: ?*Node, is_global: bool, is_namespace: bool },
    module_block: struct { stmts: []*Node },

    import_decl: struct { clause: ?*Node, specifier: *Node, attrs: ?*Node },
    import_clause: struct { name: ?*Node, bindings: ?*Node, type_only: bool },
    namespace_import: struct { name: *Node },
    named_imports: struct { elems: []*Node },
    import_spec: struct { prop_name: ?*Node, name: *Node, type_only: bool },
    export_decl: *ExportDecl,
    named_exports: struct { elems: []*Node },
    namespace_export: struct { name: *Node },
    export_spec: struct { prop_name: ?*Node, name: *Node, type_only: bool },
    export_assign: struct { expr: *Node, is_equals: bool },
    import_equals: struct { name: *Node, ref: *Node, type_only: bool },
    external_module_ref: struct { expr: *Node },
    namespace_export_decl: struct { name: *Node },

    object_pattern: struct { elems: []*Node },
    array_pattern: struct { elems: []*Node },
    binding_elem: *BindingElem,

    param: *Param,
    decorator: struct { expr: *Node },
    property_decl: *Property,
    index_sig: struct { params: []*Node, type: ?*Node },
    static_block: struct { body: *Node },
    semicolon_member,
    computed_name: struct { expr: *Node },

    kw_type: KwType,
    this_type,
    type_ref: *TypeRef,
    qualified_name: struct { left: *Node, right: *Node },
    type_query: *TypeQuery,
    type_literal: struct { members: []*Node },
    array_type: struct { elem: *Node },
    tuple_type: struct { elems: []*Node },
    named_tuple_member: struct { dotdotdot: bool, name: *Node, question: bool, type: *Node },
    optional_type: struct { type: *Node },
    rest_type: struct { type: *Node },
    union_type: struct { types: []*Node },
    intersection_type: struct { types: []*Node },
    conditional_type: *ConditionalType,
    infer_type: struct { tparam: *Node },
    paren_type: struct { type: *Node },
    type_operator: struct { op: Tok, type: *Node },
    indexed_access: struct { object: *Node, index: *Node },
    mapped_type: *Mapped,
    literal_type: struct { lit: *Node },
    template_literal_type: *TemplateLiteralType,
    template_type_span: struct { type: *Node, text: []const u8 },
    import_type: *ImportType,
    type_predicate: struct { asserts: bool, param: *Node, type: ?*Node },
    type_param: struct { name: *Node, constraint: ?*Node, default: ?*Node },
    property_sig: struct { name: *Node, question: bool, type: ?*Node },
    heritage_clause: struct { tok: Tok, types: []*Node },
    expr_with_type_args: *ExprWithTypeArgs,
};

pub const Kind = std.meta.Tag(Data);

/// For the few nodes that need more than one of what `Node` keeps in its link, functions mostly.
const LinkExtra = struct {
    symbol: ?*binder.Symbol = null,
    flow: ?*binder.FlowNode = null,
    locals: ?*binder.SymbolTable = null,
};

const LinkTag = enum(u3) { none, symbol, flow, locals, extra };

/// A declaration has a symbol, a reference has a flow and a scope has locals, so of VS Code's five
/// million nodes under a tenth of a percent want two of them. One 48-bit pointer with a tag takes
/// a node from 80 bytes to 56, and the bytes it leaves over hold `mods`.
pub const Node = struct {
    start: u32,
    end: u32,
    parent: ?*Node = null,
    link_low: u32 = 0,
    link_high: u16 = 0,
    mods: Mods = .{},
    data: Data,

    pub fn kind(n: *const Node) Kind {
        return std.meta.activeTag(n.data);
    }

    fn link(n: *const Node) usize {
        return @as(usize, n.link_high) << 32 | n.link_low;
    }

    fn setLink(n: *Node, v: usize) void {
        n.link_low = @truncate(v);
        n.link_high = @intCast(v >> 32);
    }

    fn linkTag(v: usize) LinkTag {
        return @enumFromInt(@as(u3, @truncate(v)));
    }

    fn extra(v: usize) *LinkExtra {
        return @ptrFromInt(v & ~@as(usize, 7));
    }

    fn get(n: *const Node, comptime field: LinkTag) @FieldType(LinkExtra, @tagName(field)) {
        const v = n.link();
        const tag = linkTag(v);
        if (tag == field) return @ptrFromInt(v & ~@as(usize, 7));
        return if (tag == .extra) @field(extra(v), @tagName(field)) else null;
    }

    fn put(n: *Node, a: std.mem.Allocator, comptime field: LinkTag, x: @FieldType(LinkExtra, @tagName(field))) void {
        const v = n.link();
        const tag = linkTag(v);
        const bits = if (x) |p| @intFromPtr(p) | @intFromEnum(field) else 0;
        if (tag == .none or tag == field) return n.setLink(bits);
        if (bits == 0 and tag != .extra) return;
        if (tag != .extra) {
            const e = a.create(LinkExtra) catch @panic("out of memory");
            e.* = .{};
            switch (tag) {
                inline .symbol, .flow, .locals => |t| @field(e, @tagName(t)) = @ptrFromInt(v & ~@as(usize, 7)),
                else => unreachable,
            }
            n.setLink(@intFromPtr(e) | @intFromEnum(LinkTag.extra));
        }
        @field(extra(n.link()), @tagName(field)) = x;
    }

    pub fn symbol(n: *const Node) ?*binder.Symbol {
        return n.get(.symbol);
    }

    pub fn flow(n: *const Node) ?*binder.FlowNode {
        return n.get(.flow);
    }

    pub fn locals(n: *const Node) ?*binder.SymbolTable {
        return n.get(.locals);
    }

    pub fn setSymbol(n: *Node, a: std.mem.Allocator, s: ?*binder.Symbol) void {
        n.put(a, .symbol, s);
    }

    pub fn setFlow(n: *Node, a: std.mem.Allocator, f: ?*binder.FlowNode) void {
        n.put(a, .flow, f);
    }

    pub fn setLocals(n: *Node, a: std.mem.Allocator, t: ?*binder.SymbolTable) void {
        n.put(a, .locals, t);
    }

    /// A node the checker makes for itself, which is read like a reference at `f`.
    pub fn atFlow(f: *binder.FlowNode, start: u32, end: u32, parent: *Node, data: Data) Node {
        var n: Node = .{ .start = start, .end = end, .parent = parent, .data = data };
        n.setLink(@intFromPtr(f) | @intFromEnum(LinkTag.flow));
        return n;
    }

    pub fn func(n: *const Node) ?*Func {
        return if (n.data == .func) n.data.func else null;
    }
};

fn visitValue(value: anytype, ctx: anytype, comptime visit: anytype) void {
    const T = @TypeOf(value);
    if (T == *Node) {
        visit(ctx, value);
    } else if (T == ?*Node) {
        if (value) |v| visit(ctx, v);
    } else if (T == []*Node) {
        for (value) |v| visit(ctx, v);
    } else switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| visitValue(@field(value, name), ctx, visit),
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .@"struct") visitValue(value.*, ctx, visit),
        else => {},
    }
}

/// Written once through reflection so a new node kind cannot be forgotten by a walker.
pub fn forEachChild(n: *Node, ctx: anytype, comptime visit: anytype) void {
    switch (n.data) {
        inline else => |payload| visitValue(payload, ctx, visit),
    }
}

/// Both kinds of function block, as opposed to the expression an arrow can return directly.
pub fn isBlockBody(n: *const Node) bool {
    return n.data == .block or n.data == .lazy_body;
}

pub const File = struct {
    path: []const u8,
    src: []const u8,
    root: *Node,
    diags: []lexer.Diag,
    /// TS-only modifier tokens, which leave no other trace in the AST for the emitter to erase.
    strip: []Span,
    directives: []lexer.Lexer.TsDirective,
    is_dts: bool,
    is_module: bool,
    references: []Reference,
    symbol: ?*binder.Symbol = null,
    bind_diags: []lexer.Diag = &.{},
    /// String literals naming other modules, in binding order.
    module_specs: []*Node = &.{},
    ambient_modules: []*binder.Symbol = &.{},
    augmentations: []*binder.Symbol = &.{},
    global_augs: []*binder.Symbol = &.{},
    umd_name: ?[]const u8 = null,
    /// A body had to be parsed while loading and has a syntax error.
    bad_body: bool = false,

    pub const Reference = struct { kind: enum { path, lib, types }, value: []const u8 };

    pub fn lineCol(f: *const File, pos: u32) struct { line: u32, col: u32 } {
        var line: u32 = 1;
        var last: u32 = 0;
        var i: u32 = 0;
        while (i < pos and i < f.src.len) : (i += 1) {
            if (f.src[i] == '\n') {
                line += 1;
                last = i + 1;
            }
        }
        return .{ .line = line, .col = pos - last + 1 };
    }
};

test "forEachChild visits in source order" {
    var a = Node{ .start = 0, .end = 1, .data = .{ .identifier = "a" } };
    var b = Node{ .start = 2, .end = 3, .data = .{ .identifier = "b" } };
    var bin = Node{ .start = 0, .end = 3, .data = .{ .binary = .{ .left = &a, .op = .plus, .right = &b } } };
    var seen: u32 = 0;
    forEachChild(&bin, &seen, struct {
        fn f(s: *u32, c: *Node) void {
            s.* = s.* * 10 + c.start + 1;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 13), seen);
}

/// The text of a member name in `a.b` or `a.#b`.
pub fn memberText(n: *const Node) []const u8 {
    return switch (n.data) {
        .identifier, .private_name => |v| v,
        else => "",
    };
}
