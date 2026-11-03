//! The public names of the checker's answers. The checker works in its own terms: a tagged union of
//! types and binder flags in its own numbering. A client that speaks tsc's vocabulary gets tsc's
//! flag values here, which stay put however the inside changes.
const std = @import("std");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const T = @import("types.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Type = T.Type;
const Prop = T.Prop;

/// `ts.TypeFlags`, with the same values. The groups are tags too: `flags.has(.string_like)`.
pub const TypeFlag = enum(u32) {
    any = 1 << 0,
    unknown = 1 << 1,
    undefined = 1 << 2,
    null = 1 << 3,
    void = 1 << 4,
    string = 1 << 5,
    number = 1 << 6,
    bigint = 1 << 7,
    boolean = 1 << 8,
    es_symbol = 1 << 9,
    string_literal = 1 << 10,
    number_literal = 1 << 11,
    bigint_literal = 1 << 12,
    boolean_literal = 1 << 13,
    unique_es_symbol = 1 << 14,
    enum_literal = 1 << 15,
    @"enum" = 1 << 16,
    non_primitive = 1 << 17,
    never = 1 << 18,
    type_parameter = 1 << 19,
    object = 1 << 20,
    index = 1 << 21,
    template_literal = 1 << 22,
    string_mapping = 1 << 23,
    substitution = 1 << 24,
    indexed_access = 1 << 25,
    conditional = 1 << 26,
    @"union" = 1 << 27,
    intersection = 1 << 28,

    any_or_unknown = 3,
    nullable = 12,
    literal = 15360,
    unit = 97292,
    string_like = 12583968,
    number_like = 67648,
    bigint_like = 4224,
    boolean_like = 8448,
    enum_like = 98304,
    es_symbol_like = 16896,
    void_like = 20,
    union_or_intersection = 402653184,
    structured_type = 403701760,
    type_variable = 34078720,
    instantiable_non_primitive = 117964800,
    instantiable_primitive = 14680064,
    instantiable = 132644864,
};

/// `ts.ObjectFlags`, with the same values, for the flags that say what kind of object a type is.
pub const ObjectFlag = enum(u32) {
    class = 1 << 0,
    interface = 1 << 1,
    reference = 1 << 2,
    tuple = 1 << 3,
    anonymous = 1 << 4,
    mapped = 1 << 5,
    instantiated = 1 << 6,
    object_literal = 1 << 7,
    fresh_literal = 1 << 13,
    class_or_interface = 3,
};

/// `ts.SymbolFlags`, with the same values.
pub const SymbolFlag = enum(u32) {
    function_scoped_variable = 1 << 0,
    block_scoped_variable = 1 << 1,
    property = 1 << 2,
    enum_member = 1 << 3,
    function = 1 << 4,
    class = 1 << 5,
    interface = 1 << 6,
    const_enum = 1 << 7,
    regular_enum = 1 << 8,
    value_module = 1 << 9,
    namespace_module = 1 << 10,
    type_literal = 1 << 11,
    object_literal = 1 << 12,
    method = 1 << 13,
    constructor = 1 << 14,
    get_accessor = 1 << 15,
    set_accessor = 1 << 16,
    signature = 1 << 17,
    type_parameter = 1 << 18,
    type_alias = 1 << 19,
    alias = 1 << 21,
    optional = 1 << 24,
    assignment = 1 << 26,

    variable = 3,
    @"enum" = 384,
    module = 1536,
    accessor = 98304,
    namespace = 1920,
    value = 111551,
    type = 788968,
};

pub fn Flags(comptime E: type) type {
    return struct {
        bits: u32,

        const Self = @This();

        pub fn of(e: E) Self {
            return .{ .bits = @intFromEnum(e) };
        }

        /// Whether any bit of `e` is set, which for a group means "is one of these".
        pub fn has(f: Self, e: E) bool {
            return f.bits & @intFromEnum(e) != 0;
        }

        pub fn with(f: Self, e: E) Self {
            return .{ .bits = f.bits | @intFromEnum(e) };
        }
    };
}

pub const TypeFlags = Flags(TypeFlag);
pub const ObjectFlags = Flags(ObjectFlag);
pub const SymbolFlags = Flags(SymbolFlag);

pub const SignatureKind = enum { call, construct };

/// Bits 0 to 19 number alike on both sides, and tsc's table has no room for the binder's others.
const shared_symbol_bits: u32 = (1 << 20) - 1;

fn publicSymbolFlags(f: u32) SymbolFlags {
    var bits = f & shared_symbol_bits;
    if (f & F.alias != 0) bits |= @intFromEnum(SymbolFlag.alias);
    if (f & F.optional != 0) bits |= @intFromEnum(SymbolFlag.optional);
    if (f & F.assignment != 0) bits |= @intFromEnum(SymbolFlag.assignment);
    return .{ .bits = bits };
}

/// The binder's bits for a public `meaning`.
pub fn binderMeaning(m: SymbolFlags) u32 {
    var bits = m.bits & shared_symbol_bits;
    if (m.has(.alias)) bits |= F.alias;
    return bits;
}

/// What tsc calls a symbol. A property is not always a binder symbol: an instantiated, mapped or
/// union property, a tuple element and an object literal's member are `Prop`s, and a `Prop` is the
/// one that knows its type once instantiated.
pub const Sym = union(enum) {
    symbol: *Symbol,
    prop: *Prop,

    pub fn name(s: Sym) []const u8 {
        return switch (s) {
            .symbol => |x| x.name,
            .prop => |x| x.name,
        };
    }

    pub fn flags(s: Sym) SymbolFlags {
        switch (s) {
            .symbol => |x| return publicSymbolFlags(x.flags),
            .prop => |x| {
                var f: SymbolFlags = if (x.sym) |own| publicSymbolFlags(own.flags) else .of(if (x.method) .method else .property);
                if (x.optional) f = f.with(.optional);
                // An object literal's type has properties of its own, which a method is as well.
                if (f.has(.method) and s.valueDeclaration() != null) {
                    const up = s.valueDeclaration().?.parent;
                    if (up != null and up.?.data == .object_lit) f = f.with(.property);
                }
                return f;
            },
        }
    }

    /// Every declaration, in binding order. A merged symbol has several, a synthetic property none.
    pub fn declarations(s: Sym) []const *Node {
        switch (s) {
            .symbol => |x| return x.decls,
            .prop => |x| {
                if (x.sym) |own| return own.decls;
                if (x.decl) |*one| return @as(*const [1]*Node, one);
                return &.{};
            },
        }
    }

    pub fn valueDeclaration(s: Sym) ?*Node {
        return switch (s) {
            .symbol => |x| x.value_decl,
            .prop => |x| if (x.sym) |own| own.value_decl else x.decl,
        };
    }

    /// The binder symbol behind this one, when it has one.
    pub fn binderSymbol(s: Sym) ?*Symbol {
        return switch (s) {
            .symbol => |x| x.resolve(),
            .prop => |x| if (x.sym) |own| own.resolve() else null,
        };
    }

    pub fn parent(s: Sym) ?*Symbol {
        const own = s.binderSymbol() orelse return null;
        return own.parent;
    }

    /// Whether both are one thing: two instantiations of a member are one member, as a name is.
    pub fn same(a: Sym, b: Sym) bool {
        if (a.binderSymbol()) |x| if (b.binderSymbol()) |y| return x == y;
        if (a == .prop and b == .prop) return a.prop == b.prop or (a.prop.origin != null and a.prop.origin == b.prop.origin);
        return false;
    }
};

/// What the types' own shape says their `ts.Type.flags` are.
pub fn typeFlags(t: *Type) TypeFlags {
    return .of(switch (t.data) {
        .any, .err => .any,
        .unknown => .unknown,
        .never => .never,
        .void => .void,
        .undefined => .undefined,
        .null => .null,
        .string => .string,
        .number => .number,
        .bigint => .bigint,
        .symbol => .es_symbol,
        .nonprim => .non_primitive,
        .str_lit => .string_literal,
        .num_lit => .number_literal,
        .big_lit => .bigint_literal,
        .bool_lit => .boolean_literal,
        .unique => .unique_es_symbol,
        .enum_lit => |e| return TypeFlags.of(.enum_literal).with(switch (e.value) {
            .str => .string_literal,
            .num => .number_literal,
            .none => .enum_literal,
        }),
        .enum_ => .@"enum",
        .union_ => {
            var f = TypeFlags.of(.@"union");
            if (t.is_boolean) f = f.with(.boolean);
            if (t.enum_sym != null) f = f.with(.enum_literal);
            return f;
        },
        .inter => .intersection,
        .obj => .object,
        .param => .type_parameter,
        .keyof => .index,
        .access => .indexed_access,
        .cond => .conditional,
        .tmpl => .template_literal,
        .noinfer => .substitution,
        .strmap => .string_mapping,
    });
}

/// `ts.ObjectType.objectFlags`, or none for a type that is not an object.
pub fn objectFlags(t: *Type) ObjectFlags {
    if (t.data != .obj) return .{ .bits = 0 };
    const o = t.data.obj;
    var f: ObjectFlags = switch (o.kind) {
        .iface => blk: {
            const kind: ObjectFlags = .of(if (o.is_class) .class else .interface);
            // Generic ones are references to themselves, and so is every class, for its `this`.
            break :blk if (o.tparams().len > 0 or o.is_class) kind.with(.reference) else kind;
        },
        .ref => .of(.reference),
        .tuple => .of(.reference),
        .anon => .of(.anonymous),
        .mapped => .of(.mapped),
    };
    // What mentions no outer parameter stays one type however often it is instantiated.
    if (o.target != null and o.target.?.vars and (o.kind == .anon or o.kind == .mapped)) f = f.with(.instantiated);
    if (o.lit) f = f.with(.object_literal).with(.fresh_literal);
    return f;
}

test "public flags keep tsc's numbers" {
    try std.testing.expectEqual(@as(u32, 134217728), @intFromEnum(TypeFlag.@"union"));
    try std.testing.expectEqual(@as(u32, 1048576), @intFromEnum(TypeFlag.object));
    try std.testing.expectEqual(@as(u32, 8192), @intFromEnum(ObjectFlag.fresh_literal));
    try std.testing.expectEqual(@as(u32, 2097152), @intFromEnum(SymbolFlag.alias));
    try std.testing.expect(publicSymbolFlags(F.alias | F.optional).has(.alias));
    try std.testing.expect(publicSymbolFlags(F.alias | F.optional).has(.optional));
    try std.testing.expectEqual(F.value, binderMeaning(.of(.value)));
}
