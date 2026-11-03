//! What a node's place in the tree makes it, which decides what its type and its symbol mean. The
//! checker never needs this: it walks from the statements down and knows what it is looking at. A
//! client holds a node from anywhere and has to ask, so these follow tsc's own answers.
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const Node = ast.Node;

/// A node written as a type. `void` in `void 0` is a `void_expr`, so a keyword is always a type.
pub fn isTypeNode(n: *const Node) bool {
    return switch (n.data) {
        .kw_type, .this_type, .type_ref, .type_query, .type_literal, .array_type, .tuple_type, .named_tuple_member, .optional_type, .rest_type, .union_type, .intersection_type, .conditional_type, .infer_type, .paren_type, .type_operator, .indexed_access, .mapped_type, .literal_type, .template_literal_type, .template_type_span, .import_type, .type_predicate => true,
        .func => |f| f.kind == .function_type or f.kind == .constructor_type,
        else => false,
    };
}

/// Whether `e`, a heritage entry, names a class to inherit from: a value as much as a type.
pub fn isClassExtends(e: *const Node) bool {
    const h = e.parent orelse return false;
    if (h.data != .heritage_clause or h.data.heritage_clause.tok != .kw_extends) return false;
    const owner = h.parent orelse return false;
    return owner.data == .class;
}

fn isTypeHeritage(e: *const Node) bool {
    const p = e.parent orelse return false;
    return p.data == .heritage_clause and !isClassExtends(e);
}

/// Whether `n` means a type where it stands, written as one or as a name inside one.
pub fn isPartOfTypeNode(n: *const Node) bool {
    if (isTypeNode(n)) return true;
    switch (n.data) {
        .expr_with_type_args => return isTypeHeritage(n),
        .type_param => {
            const p = n.parent orelse return false;
            return p.data == .infer_type;
        },
        .identifier, .qualified_name, .prop_access => {},
        else => return false,
    }
    var at = n;
    if (n.data == .identifier) if (n.parent) |p| switch (p.data) {
        .qualified_name => |x| {
            if (x.right == n) at = p;
        },
        .prop_access => |x| {
            if (x.name == n) at = p;
        },
        else => {},
    };
    const p = at.parent orelse return false;
    return switch (p.data) {
        .type_query => false,
        .import_type => |x| !x.is_typeof,
        .expr_with_type_args => isTypeHeritage(p),
        else => isTypeNode(p),
    };
}

/// `{ type: "json" }` in `with { type: "json" }`, which is written as an object but holds no values.
fn isImportAttributes(n: *const Node) bool {
    const owner = n.parent orelse return false;
    return switch (owner.data) {
        .import_decl => true,
        .export_decl => true,
        else => false,
    };
}

/// Whether `n` is the value of an import attribute.
pub fn isImportAttributeValue(n: *const Node) bool {
    const p = n.parent orelse return false;
    if (p.data != .property_assign or p.data.property_assign.value != n) return false;
    return isImportAttributes(p.parent orelse return false);
}

/// Whether a literal, a name or `this` stands where a value is read.
pub fn isInExpressionContext(n: *const Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .var_decl => |x| x.init == n,
        .param => |x| x.init == n,
        .property_decl => |x| x.init == n,
        .enum_member => |x| x.init == n,
        .property_assign => |x| x.value == n and !isImportAttributes(p.parent orelse return false),
        .binding_elem => |x| x.init == n,
        .expr_stmt => |x| x.expr == n,
        .if_stmt => |x| x.cond == n,
        .do_stmt => |x| x.cond == n,
        .while_stmt => |x| x.cond == n,
        .return_stmt => |x| x.expr == n,
        .with_stmt => |x| x.expr == n,
        .switch_stmt => |x| x.expr == n,
        .case_clause => |x| x.expr == n,
        .throw_stmt => |x| x.expr == n,
        .for_stmt => |x| (x.init == n and n.data != .var_list) or x.cond == n or x.update == n,
        .for_in => |x| (x.init == n and n.data != .var_list) or x.expr == n,
        .for_of => |x| (x.init == n and n.data != .var_list) or x.expr == n,
        .type_assertion => |x| x.expr == n,
        .as_expr => |x| x.expr == n,
        .satisfies_expr => |x| x.expr == n,
        .template_span => |x| x.expr == n,
        .computed_name => |x| x.expr == n,
        .decorator, .jsx_expr, .jsx_spread_attr, .spread_assign => true,
        .expr_with_type_args => |x| x.expr == n and !isPartOfTypeNode(p),
        .shorthand_assign => |x| x.init == n,
        else => isExpressionNode(p),
    };
}

/// Whether `n` is a value expression, which is what `Session.typeAt` runs the checker on.
pub fn isExpressionNode(n: *const Node) bool {
    return switch (n.data) {
        .object_lit => !isImportAttributes(n),
        .super_expr, .null_lit, .true_lit, .false_lit, .regex_lit, .array_lit, .prop_access, .elem_access, .call, .new_expr, .tagged_template, .as_expr, .type_assertion, .satisfies_expr, .non_null, .paren, .void_expr, .delete_expr, .typeof_expr, .prefix, .postfix, .binary, .conditional, .spread_elem, .template_expr, .omitted_expr, .jsx_element, .jsx_self_closing, .jsx_fragment, .yield_expr, .await_expr, .meta_property => true,
        .func => |f| f.kind == .expr or f.kind == .arrow,
        .class => |x| x.is_expr,
        .expr_with_type_args => if (n.parent) |p| p.data != .heritage_clause else false,
        .qualified_name => blk: {
            var at = n;
            while (at.parent) |p| : (at = p) {
                if (p.data != .qualified_name) break :blk p.data == .type_query;
            }
            break :blk false;
        },
        .private_name => if (n.parent) |p| p.data == .binary and p.data.binary.left == n and p.data.binary.op == .kw_in else false,
        .identifier => if (n.parent) |p| p.data == .type_query or isInExpressionContext(n) else false,
        .numeric_lit, .bigint_lit, .string_lit, .no_subst_template, .this_expr => isInExpressionContext(n),
        else => false,
    };
}

/// `b` in `a.b`, or in the type name `a.b`: a name that only the whole expression gives a meaning to.
pub fn isRightSideOfAccess(n: *const Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .prop_access => |x| x.name == n,
        .qualified_name => |x| x.right == n,
        else => false,
    };
}

/// A declaration that gives a name a type rather than a value.
pub fn isTypeDeclaration(n: *const Node) bool {
    return switch (n.data) {
        .type_param, .interface, .type_alias, .enum_decl => true,
        .class => |x| !x.is_expr,
        else => false,
    };
}

/// Whether the node is a declaration, the thing a symbol has in its `decls`.
pub fn isDeclaration(n: *const Node) bool {
    return switch (n.data) {
        .binding_elem, .class, .static_block, .enum_decl, .enum_member, .export_spec, .func, .import_clause, .import_equals, .import_spec, .interface, .jsx_attr, .module_decl, .named_tuple_member, .namespace_export, .namespace_export_decl, .namespace_import, .param, .property_assign, .property_decl, .property_sig, .shorthand_assign, .spread_assign, .source_file, .type_alias, .type_param, .var_decl => true,
        else => false,
    };
}

/// The name a declaration is written with, for the declarations `binder.nameNode` leaves out
/// because the binder gives them no symbol.
pub fn nameOfDeclaration(n: *Node) ?*Node {
    return switch (n.data) {
        .property_assign => |x| x.name,
        .shorthand_assign => |x| x.name,
        .named_tuple_member => |x| x.name,
        .namespace_export => |x| x.name,
        .namespace_export_decl => |x| x.name,
        .jsx_attr => |x| x.name,
        else => binder.nameNode(n),
    };
}

/// Whether `n` is the name of the declaration above it.
pub fn isDeclarationName(n: *Node) bool {
    const p = n.parent orelse return false;
    if (n.data == .object_pattern or n.data == .array_pattern) return false;
    if (!isDeclaration(p)) return false;
    const name = nameOfDeclaration(p) orelse return false;
    return name == n;
}

/// The name an import or export specifier takes from the other side: `a` in `{ a as b }`.
pub fn isPropertyNameOfSpecifier(n: *const Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .import_spec => |x| x.prop_name == n,
        .export_spec => |x| x.prop_name == n,
        else => false,
    };
}

/// The class a heritage entry belongs to.
pub fn classOfHeritage(n: *const Node) ?*Node {
    if (n.data != .expr_with_type_args) return null;
    const h = n.parent orelse return null;
    if (h.data != .heritage_clause) return null;
    const owner = h.parent orelse return null;
    return if (owner.data == .class) owner else null;
}
