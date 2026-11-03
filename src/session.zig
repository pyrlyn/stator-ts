//! One checker over a whole project, for a compiler that walks the AST and asks for a type at each
//! node. `check` and `build` cut a project into short-lived checkers because they visit each file
//! once; a client asks in its own order, so here the checker lives as long as the session.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const api = @import("api.zig");
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const checker = @import("checker.zig");
const decls = @import("decls.zig");
const driver = @import("driver.zig");
const expr = @import("expr.zig");
const flow = @import("flow.zig");
const pool = @import("pool.zig");
const print = @import("print.zig");
const project = @import("project.zig");
const syntax = @import("syntax.zig");
const T = @import("types.zig");
const Node = ast.Node;
const Symbol = binder.Symbol;
const F = binder.F;
const Type = T.Type;
const Sig = T.Sig;
const Prop = T.Prop;
const Sym = api.Sym;

fn oom() noreturn {
    @panic("out of memory");
}

pub const Printed = driver.Printed;

pub const Options = struct {
    lib_dir: ?[]const u8 = null,
    lib_env: ?[]const u8 = null,
};

/// What tsc has a symbol for and the binder has no use for. A client sees them as any other symbol,
/// so each is made once and stays the same one.
const Synthetic = struct {
    a: Allocator,
    undefined_sym: *Symbol,
    arguments_sym: *Symbol,
    /// What a call to an untyped value resolves to: no parameters, and `any` back.
    any_sig: *Sig,
    made: std.AutoHashMapUnmanaged(*Node, *Symbol) = .empty,

    pub fn create(a: Allocator, c: *T.Checker) *Synthetic {
        const out = a.create(Synthetic) catch oom();
        const any_sig = a.create(Sig) catch oom();
        any_sig.* = .{ .ret = c.t_any };
        out.* = .{ .a = a, .undefined_sym = newSymbol(a, "undefined", F.property), .arguments_sym = newSymbol(a, "arguments", F.property), .any_sig = any_sig };
        return out;
    }

    fn of(y: *Synthetic, n: *Node, name: []const u8, flags: u32) *Symbol {
        const gop = y.made.getOrPut(y.a, n) catch oom();
        if (!gop.found_existing) {
            const k = newSymbol(y.a, name, flags);
            k.decls = y.a.dupe(*Node, &.{n}) catch oom();
            k.value_decl = n;
            gop.value_ptr.* = k;
        }
        return gop.value_ptr.*;
    }
};

fn newSymbol(a: Allocator, name: []const u8, flags: u32) *Symbol {
    const k = a.create(Symbol) catch oom();
    k.* = .{ .name = name, .flags = flags };
    return k;
}

pub const Session = struct {
    prog: *project.Program,
    c: *T.Checker,
    synthetic: *Synthetic,
    /// A module's name is its absolute path, and a file is known by the path it was reached by.
    cwd: []const u8,

    pub fn open(a: Allocator, io: Io, tp: *pool.ThreadPool, cfg: *const project.Config, o: Options) Session {
        const fs = project.FsCache.create(a, io);
        const roots = project.projectFiles(a, fs, tp, cfg);
        const prog = project.loadProgram(a, io, tp, cfg, roots, .{ .fs = fs, .lib_dir_flag = o.lib_dir, .lib_dir_env = o.lib_env });
        const c = T.Checker.new(a, prog);
        decls.initGlobals(c);
        const cwd = Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch "";
        return .{ .prog = prog, .c = c, .synthetic = .create(a, c), .cwd = cwd };
    }

    /// Everything `check` reports for the project's own files. Call it at most once: it visits
    /// each file, and a second visit would report the same errors again.
    pub fn diagnostics(s: Session) []const T.Diag {
        for (s.prog.files.items) |sf| {
            if (sf.is_lib or sf.read_failed or sf.file.is_dts) continue;
            s.c.owned.put(s.c.a, sf.file, {}) catch oom();
            checker.checkFile(s.c, sf.file);
        }
        return s.c.diags.items;
    }

    /// `ts.getPreEmitDiagnostics`: syntax, binder, program and checker errors of the project's own
    /// files, sorted, without repeats, `@ts-ignore` applied. `check_js` is the option of that name.
    /// Like `diagnostics`, at most once.
    pub fn preEmitDiagnostics(s: Session, a: Allocator, check_js: bool) []const driver.Printed {
        const p = s.prog;
        var all: std.ArrayList(driver.Printed) = .empty;
        for (p.files.items) |sf| {
            if (sf.is_lib or sf.read_failed) continue;
            for (sf.file.diags) |d| all.append(a, .{ .file = sf.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg, .syntax = true }) catch oom();
            if (sf.file.is_dts or (!check_js and project.isJsFile(sf.file.path))) continue;
            for (sf.file.bind_diags) |d| all.append(a, .{ .file = sf.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg, .bind = true }) catch oom();
            s.c.owned.put(s.c.a, sf.file, {}) catch oom();
            checker.checkFile(s.c, sf.file);
        }
        for (p.diags.items) |d| if (!d.file.is_dts and (check_js or !project.isJsFile(d.file.path))) all.append(a, .{ .file = d.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg }) catch oom();
        for (s.c.diags.items) |d| all.append(a, .{ .file = d.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg }) catch oom();
        std.mem.sort(driver.Printed, all.items, {}, driver.lessDiag);
        var kept: std.ArrayList(driver.Printed) = .empty;
        var previous: ?driver.Printed = null;
        for (all.items) |d| {
            if (previous) |q| if (q.file == d.file and q.start == d.start and q.code == d.code and std.mem.eql(u8, q.msg, d.msg)) continue;
            previous = d;
            if (!driver.filteredByDirective(d)) kept.append(a, d) catch oom();
        }
        return kept.items;
    }

    /// `getTypeAtLocation`: the type of whatever `n` is, an expression, a type node, a declaration
    /// or a name. Asking reports nothing: errors come from `diagnostics`.
    pub fn typeAt(s: Session, n: *Node) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return s.typeOfNode(n);
    }

    /// `getSymbolAtLocation`: what a name, a declaration or a module specifier refers to. An import
    /// stays an alias, as in tsc: `aliasedSymbol` follows it.
    pub fn symbolAt(s: Session, n: *Node) ?Sym {
        const c = s.hushed();
        defer c.silent -= 1;
        return s.symbolOfNode(n);
    }

    /// `getTypeOfSymbol`: the declared type, with no narrowing.
    pub fn typeOfSym(s: Session, sym: Sym) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return switch (sym) {
            .symbol => |x| decls.typeOfSymbol(c, x),
            .prop => |x| decls.propType(c, x),
        };
    }

    /// `getTypeOfSymbolAtLocation`: the type `sym` has at `at`, narrowed by the flow up to there
    /// when `at` is a reference to it.
    pub fn typeOfSymAt(s: Session, sym: Sym, at: *Node) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        if (at.data == .identifier or at.data == .private_name) {
            const ref = if (syntax.isRightSideOfAccess(at)) at.parent.? else at;
            if (syntax.isExpressionNode(ref)) {
                const t = s.typeOfNode(ref);
                if (s.symbolOfNode(ref)) |here| if (here.same(sym)) return t;
            }
        }
        if (sym == .prop and syntax.isRightSideOfAccess(at) and expr.isAssignTarget(at.parent.?)) return decls.propWriteType(c, sym.prop);
        const t = s.typeOfSym(sym);
        return if (sym.flags().has(.optional)) decls.removeMissing(c, t) else t;
    }

    /// `getDeclaredTypeOfSymbol`: the type a class, interface, alias, enum or type parameter
    /// declares. An import answers for what it names.
    pub fn declaredTypeOf(s: Session, sym: Sym) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        const own = sym.binderSymbol() orelse return c.t_err;
        return decls.declaredType(c, decls.targetOf(c, own) orelse return c.t_err);
    }

    /// `getTypeFromTypeNode`.
    pub fn typeFromTypeNode(s: Session, n: *Node) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return s.typeOfTypeName(n);
    }

    /// `getPropertiesOfType`, in declaration order.
    pub fn propertiesOf(s: Session, t: *Type) []const *Prop {
        const c = s.hushed();
        defer c.silent -= 1;
        const props = decls.propsOf(c, decls.getApparent(c, t));
        return if (isClassValue(t)) prototypeFirst(c, props) else props;
    }

    /// `getPropertyOfType`. `name` is the key the binder uses: a well-known symbol is `__@iterator`.
    pub fn propertyOf(s: Session, t: *Type, name: []const u8) ?*Prop {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.getProp(c, t, name);
    }

    /// `getSignaturesOfType`.
    pub fn signaturesOf(s: Session, t: *Type, kind: api.SignatureKind) []*Sig {
        const c = s.hushed();
        defer c.silent -= 1;
        const ap = decls.getApparent(c, t);
        return switch (kind) {
            .call => decls.callSigs(c, ap),
            .construct => decls.ctorSigs(c, ap),
        };
    }

    /// `getIndexInfosOfType`.
    pub fn indexInfosOf(s: Session, t: *Type) []T.Index {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.indexesOf(c, decls.getApparent(c, t));
    }

    /// `getApparentType`: what property lookups see, `String` for `string`, a constraint for `T`.
    pub fn apparentTypeOf(s: Session, t: *Type) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return publicApparent(c, t);
    }

    /// `getBaseTypes` of the declaration behind `t`: what it extends, not instantiated for `t`.
    pub fn baseTypesOf(s: Session, t: *Type) []*Type {
        const c = s.hushed();
        defer c.silent -= 1;
        if (t.data != .obj) return &.{};
        const declared = t.data.obj.target orelse t;
        return if (declared.data == .obj) decls.basesOf(c, declared) else &.{};
    }

    /// `getTypeArguments`: of a reference, or a tuple's elements.
    pub fn typeArgumentsOf(_: Session, t: *Type) []const *Type {
        if (t.data != .obj) return &.{};
        const o = t.data.obj;
        return switch (o.kind) {
            .tuple => o.tuple.elems,
            .iface => o.tparams(),
            else => o.args orelse &.{},
        };
    }

    /// `aliasSymbol` and `aliasTypeArguments` of a type.
    pub fn aliasOf(_: Session, t: *Type) ?*T.Alias {
        return t.alias;
    }

    /// `type.symbol`: the declaration a type came from. A type written as a literal has none here,
    /// where tsc has a synthetic `__type` or `__object`.
    pub fn symbolOfType(s: Session, t: *Type) ?*Symbol {
        return switch (t.data) {
            .obj => |o| {
                // A mapped type keeps its key's symbol, which is not the symbol of the type.
                if (o.kind == .mapped) return null;
                if (o.sym orelse if (o.target) |x| x.data.obj.sym else null) |k| {
                    if (!std.mem.eql(u8, k.name, "__computed") or k.value_decl == null) return k;
                    return s.lateSymbol(k.value_decl.?) orelse k;
                }
                if (o.node) |n| if (methodOfLiteral(n)) |name| return s.synthetic.of(n, name, F.method);
                return if (o.literal) |n| s.synthetic.of(n, "__object", F.object_literal) else null;
            },
            .param => |p| p.sym orelse if (p.is_this) s.symbolOfType(p.constraint.?) else null,
            .enum_lit => |e| e.sym,
            .enum_ => |e| e,
            .union_ => t.enum_sym,
            .unique => |k| k,
            else => null,
        };
    }

    /// The method `decl` names through a constant: its key is known only to the checker.
    fn lateSymbol(s: Session, decl: *Node) ?*Symbol {
        const name = syntax.nameOfDeclaration(decl) orelse return null;
        if (name.data != .computed_name) return null;
        const c = s.hushed();
        defer c.silent -= 1;
        const t = expr.checkExpression(c, name.data.computed_name.expr);
        const key = decls.literalName(c, t.regular orelse t) orelse return null;
        return s.synthetic.of(decl, key, F.method);
    }

    /// `getResolvedSignature` of a call, `new`, or `super(...)`: the overload picked, instantiated.
    pub fn resolvedSignature(s: Session, n: *Node) ?*Sig {
        const c = s.hushed();
        defer c.silent -= 1;
        const sig = expr.resolvedSig(c, n) orelse return if (n.data == .call or n.data == .new_expr) s.synthetic.any_sig else null;
        if (n.data != .call or !(n.data.call.optional or flow.isOptionalChain(n.data.call.callee))) return sig;
        const callee = expr.checkSilent(c, n.data.call.callee);
        if (expr.nonNull(c, callee) == callee) return sig;
        // The call may not happen, which the signature of a call in a chain says for itself.
        const chained = c.a.create(Sig) catch oom();
        chained.* = sig.*;
        chained.ret = c.getUnion(&.{ decls.returnOf(c, sig), c.t_undefined });
        return chained;
    }

    /// `getSignatureFromDeclaration`.
    pub fn signatureOfDeclaration(s: Session, n: *Node) *Sig {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.sigOfDecl(c, n);
    }

    /// `getReturnTypeOfSignature`.
    pub fn returnTypeOf(s: Session, sig: *Sig) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.returnOf(c, sig);
    }

    /// The type of parameter `i`, which for a rest parameter is the type of the element at `i`.
    pub fn paramTypeOf(s: Session, sig: *Sig, i: usize) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.paramTypeAt(c, sig, i);
    }

    /// `getTypePredicateOfSignature`.
    pub fn predicateOf(s: Session, sig: *Sig) ?*T.Pred {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.predOf(c, sig);
    }

    /// `getContextualType`: what surrounds `n` asks it to be.
    pub fn contextualTypeOf(s: Session, n: *Node) ?*Type {
        const c = s.hushed();
        defer c.silent -= 1;
        const p = n.parent orelse return null;
        if (p.data == .call and p.data.call.callee.data == .import_kw) {
            const i = std.mem.indexOfScalar(*Node, p.data.call.args, n) orelse return null;
            return switch (i) {
                0 => c.t_string,
                1 => decls.globalType(c, "ImportCallOptions"),
                else => c.t_any,
            };
        }
        const known = expr.contextualType(c, n);
        if (patternAt(c, n)) |pat| return bindingPatternType(c, pat);
        if (known) |t| return t;
        switch (p.data) {
            .array_lit => return if (s.contextualTypeOf(p)) |t| (if (t.data == .any) t else null) else null,
            .call => |x| return if (std.mem.indexOfScalar(*Node, x.args, n) != null) c.t_any else null,
            .new_expr => |x| return if (std.mem.indexOfScalar(*Node, x.args, n) != null) c.t_any else null,
            .property_assign => {
                if (!syntax.isImportAttributeValue(n)) return null;
                const g = decls.globalType(c, "ImportAttributes") orelse return null;
                return decls.indexValue(c, g, c.t_string);
            },
            else => return null,
        }
    }

    /// `isArrayType`: `T[]` or `readonly T[]`.
    pub fn isArrayType(s: Session, t: *Type) bool {
        return s.c.isArrayType(t);
    }

    /// `isTupleType`.
    pub fn isTupleType(_: Session, t: *Type) bool {
        return T.isTupleType(t);
    }

    /// `getAliasedSymbol`: what an import names, past every re-export. Null when it leads nowhere.
    pub fn aliasedSymbol(s: Session, sym: Sym) ?Sym {
        const c = s.hushed();
        defer c.silent -= 1;
        const own = sym.binderSymbol() orelse return sym;
        return .{ .symbol = decls.targetOf(c, own) orelse return null };
    }

    /// `getImmediateAliasedSymbol`: one step of `aliasedSymbol`.
    pub fn immediateAliased(s: Session, sym: Sym) ?Sym {
        const own = sym.binderSymbol() orelse return null;
        if (own.flags & F.alias == 0) return null;
        const next = s.prog.aliasStep(own, 0) orelse return null;
        return .{ .symbol = next.resolve() };
    }

    /// `getFullyQualifiedName`: names from the outermost parent down, a module's quoted.
    pub fn fullyQualifiedName(s: Session, sym: Sym) []const u8 {
        const own = s.asWritten(sym);
        const parent = sym.parent() orelse {
            // A mapped property has a type it belongs to, but no symbol that holds it.
            if (sym == .prop and sym.prop.mapped != null) return own;
            const lit = literalOf(sym) orelse return own;
            const name = if (s.literalVariable(lit)) |v| v else "__object";
            return s.c.fmt("{s}.{s}", .{ name, own });
        };
        return s.c.fmt("{s}.{s}", .{ s.fullyQualifiedName(.{ .symbol = parent.resolve() }), own });
    }

    /// The source of `n`, when it has a file.
    fn sourceOf(s: Session, n: *Node) ?[]const u8 {
        const file = decls.fileOf(s.c, n) orelse return null;
        return file.src[n.start..n.end];
    }

    /// The variable a nameless declaration initializes.
    fn literalVariable(s: Session, n: *Node) ?[]const u8 {
        const p = n.parent orelse return null;
        return if (p.data == .var_decl) s.sourceOf(p.data.var_decl.name) else null;
    }

    /// tsc's `symbolToString`: a symbol is called what its declaration calls it, quotes and
    /// brackets included, and only then what it is keyed by.
    fn asWritten(s: Session, sym: Sym) []const u8 {
        const list = sym.declarations();
        for (list) |decl| if (syntax.nameOfDeclaration(decl)) |name| return s.sourceOf(name) orelse s.nameOf(sym);
        if (list.len == 0) return s.nameOf(sym);
        if (s.literalVariable(list[0])) |v| return v;
        return switch (list[0].data) {
            .class => |x| if (x.is_expr) "(Anonymous class)" else s.nameOf(sym),
            .func => |f| if (f.kind == .expr or f.kind == .arrow) "(Anonymous function)" else s.nameOf(sym),
            else => s.nameOf(sym),
        };
    }

    /// `symbol.name` as tsc spells it: a module is its quoted path, a well-known symbol `[Symbol.x]`.
    pub fn nameOf(s: Session, sym: Sym) []const u8 {
        const name = sym.name();
        if (sym == .symbol and sym.symbol.file != null and sym.symbol.flags & F.value_module != 0 and sym.symbol.decls.len == 0) {
            return moduleText(s.c, std.fs.path.resolve(s.c.a, &.{ s.cwd, name }) catch oom());
        }
        return symbolText(s.c, name);
    }

    /// `getExportsOfModule`, `export *` included.
    pub fn exportsOfModule(s: Session, m: *Symbol) []const *Symbol {
        return decls.exportsOf(s.c, m);
    }

    /// `resolveName`: what `name` means at `at`.
    pub fn resolveName(s: Session, at: *Node, name: []const u8, meaning: api.SymbolFlags) ?*Symbol {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.resolveName(c, at, name, api.binderMeaning(meaning));
    }

    /// The module symbol of a file, or null when the file is a script.
    pub fn moduleOf(_: Session, file: *const ast.File) ?*Symbol {
        if (!file.is_module) return null;
        return if (file.symbol) |m| m.resolve() else null;
    }

    /// `getBaseConstraintOfType`: what `T` is known to be, however many steps away.
    pub fn baseConstraintOf(s: Session, t: *Type) *Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.baseConstraint(c, t);
    }

    /// `getConstraintOfTypeParameter`.
    pub fn constraintOf(s: Session, t: *Type) ?*Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.constraintOf(c, t);
    }

    /// `getDefaultFromTypeParameter`.
    pub fn defaultOf(s: Session, t: *Type) ?*Type {
        const c = s.hushed();
        defer c.silent -= 1;
        return decls.defaultOf(c, t);
    }

    /// `type.flags`, in tsc's numbering.
    pub fn typeFlags(_: Session, t: *Type) api.TypeFlags {
        return api.typeFlags(t);
    }

    /// `type.objectFlags`, in tsc's numbering.
    pub fn objectFlags(s: Session, t: *Type) api.ObjectFlags {
        const f = api.objectFlags(t);
        if (t.data != .obj or t.data.obj.kind != .iface or f.has(.reference)) return f;
        const c = s.hushed();
        defer c.silent -= 1;
        return if (isThisless(c, t, max_base_depth)) f else f.with(.reference);
    }

    fn hushed(s: Session) *T.Checker {
        s.c.silent += 1;
        return s.c;
    }

    fn typeOfNode(s: Session, n: *Node) *Type {
        const c = s.c;
        if (n.data == .source_file) {
            const m = s.moduleOf(decls.fileOf(c, n) orelse return c.t_unresolved) orelse return c.t_unresolved;
            return decls.typeOfSymbol(c, m);
        }
        const class = if (syntax.classOfHeritage(n)) |k| k.symbol() else null;
        const declared = if (class) |k| decls.declaredType(c, k) else null;
        if (syntax.isPartOfTypeNode(n)) {
            const t = s.typeOfTypeName(n);
            return if (declared) |own| thisAs(c, t, own) else t;
        }
        if (n.parent) |p| if (p.data == .literal_type) return decls.typeFromNode(c, p);
        if (syntax.isExpressionNode(n)) {
            const e = if (syntax.isRightSideOfAccess(n)) n.parent.? else n;
            // tsc gives up on a target it refused to assign to, whatever the name would read as.
            if (expr.isAssignTarget(e) and expr.isReadonlyTarget(c, e)) return c.t_unresolved;
            const t = expr.checkExpression(c, e);
            // Only a literal loses its freshness here: an object written in place stays as written.
            return if (t.data == .obj and e.data == .object_lit) t else expr.regularize(c, t);
        }
        if (declared) |own| {
            const bases = if (own.data == .obj) decls.basesOf(c, own) else &.{};
            return if (bases.len > 0) thisAs(c, bases[0], own) else c.t_err;
        }
        if (syntax.isTypeDeclaration(n)) if (n.symbol()) |k| return decls.declaredType(c, k);
        if (n.data == .identifier) if (n.parent) |p| if (syntax.isTypeDeclaration(p) and syntax.isDeclarationName(n)) {
            if (p.symbol()) |k| return decls.declaredType(c, k);
        };
        if (indexParam(n)) |p| return decls.typeFromNode(c, p.data.param.type orelse return c.t_unresolved);
        if (syntax.isDeclaration(n)) {
            if (s.symbolOfDeclaration(n)) |k| return s.typeOfSym(k);
            return c.t_unresolved;
        }
        if (syntax.isDeclarationName(n) or syntax.isPropertyNameOfSpecifier(n)) {
            if (s.symbolOfNode(n)) |k| return s.typeOfSym(k);
            return c.t_unresolved;
        }
        if (n.data == .object_pattern or n.data == .array_pattern) if (n.parent) |p| {
            if (s.symbolOfDeclaration(p)) |k| return s.typeOfSym(k);
        };
        return c.t_unresolved;
    }

    /// A name in a type position, which `decls.typeFromNode` does not expect to meet on its own.
    fn typeOfTypeName(s: Session, n: *Node) *Type {
        const c = s.c;
        switch (n.data) {
            .identifier, .qualified_name, .prop_access => {
                const k = s.symbolOfNode(n) orelse return c.t_unresolved;
                const own = k.binderSymbol() orelse return c.t_unresolved;
                return decls.declaredType(c, decls.targetOf(c, own) orelse return c.t_unresolved);
            },
            else => return decls.typeFromNode(c, n),
        }
    }

    /// What a declaration declares. An object literal's members have no binder symbol.
    fn symbolOfDeclaration(s: Session, n: *Node) ?Sym {
        if (n.symbol()) |k| return .{ .symbol = k.resolve() };
        const p = n.parent orelse return null;
        if (n.data == .param and p.data == .func and decls.thisParam(p) == n) return .{ .symbol = s.synthetic.of(n, "this", F.func_var) };
        if (p.data == .index_sig and n.data == .param and n.data.param.name.data == .identifier) {
            return .{ .symbol = s.synthetic.of(n, n.data.param.name.data.identifier, F.func_var) };
        }
        if (p.data != .object_lit) return null;
        const name = syntax.nameOfDeclaration(n) orelse return null;
        const t = expr.checkExpression(s.c, p);
        return memberOf(s.c, t, name);
    }

    fn symbolOfNode(s: Session, n: *Node) ?Sym {
        const c = s.c;
        if (n.data == .source_file) {
            const m = s.moduleOf(decls.fileOf(c, n) orelse return null) orelse return null;
            return .{ .symbol = m };
        }
        const p = n.parent orelse return null;
        if (syntax.isPropertyNameOfSpecifier(n)) return s.immediateAliased(s.symbolOfDeclaration(p) orelse return null);
        if (syntax.isDeclarationName(n)) return s.symbolOfDeclaration(p);
        if (isLiteral(n) and p.data == .computed_name) if (p.parent) |owner| {
            if (syntax.nameOfDeclaration(owner) == p) return s.symbolOfDeclaration(owner);
        };
        switch (n.data) {
            .identifier => {
                if (p.data == .binding_elem and p.data.binding_elem.prop_name == n) if (p.parent) |pattern| {
                    if (pattern.data == .object_pattern) return memberOf(c, s.typeOfNode(pattern), n);
                };
                return s.nameSymbol(n);
            },
            .private_name, .prop_access, .qualified_name => return s.nameSymbol(n),
            .this_expr => {
                if (thisParam(n)) |k| return s.symbolOfDeclaration(k);
                return bare(s.symbolOfType(expr.checkExpression(c, n)));
            },
            .this_type => return bare(s.symbolOfType(decls.typeFromNode(c, n))),
            .super_expr, .meta_property => return bare(s.symbolOfType(expr.checkExpression(c, n))),
            .string_lit, .no_subst_template => {
                if (s.moduleNamedBy(n)) |m| return .{ .symbol = m };
                return s.keyedMember(n);
            },
            .numeric_lit => return s.keyedMember(n),
            .import_type => |x| {
                const lit = if (x.arg.data == .literal_type) x.arg.data.literal_type.lit else x.arg;
                return if (s.moduleNamedBy(lit)) |m| .{ .symbol = m } else null;
            },
            else => return null,
        }
    }

    /// `undefined`, and `arguments` in a function: names nothing declares.
    fn builtinValue(s: Session, n: *Node) ?*Symbol {
        const name = n.data.identifier;
        if (std.mem.eql(u8, name, "undefined")) return s.synthetic.undefined_sym;
        if (!std.mem.eql(u8, name, "arguments")) return null;
        var cur = n.parent;
        while (cur) |x| : (cur = x.parent) {
            if (x.data == .func and x.data.func.kind != .arrow) return s.synthetic.arguments_sym;
        }
        return null;
    }

    /// The module a string names, when it stands where a module is named.
    fn moduleNamedBy(s: Session, n: *Node) ?*Symbol {
        const c = s.c;
        const p = n.parent orelse return null;
        const named = switch (p.data) {
            .import_decl => |x| x.specifier == n,
            .export_decl => |x| x.specifier == n,
            .external_module_ref => true,
            .call => |x| x.callee.data == .import_kw and x.args.len > 0 and x.args[0] == n,
            .literal_type => if (p.parent) |g| g.data == .import_type else false,
            else => false,
        };
        if (!named or n.data != .string_lit and n.data != .no_subst_template) return null;
        const text = if (n.data == .string_lit) n.data.string_lit else n.data.no_subst_template;
        const sf = c.prog.sourceOf(decls.fileOf(c, n)) orelse return null;
        const m = c.prog.resolveModuleName(sf, text) orelse return null;
        return m.resolve();
    }

    /// The member a literal names: `o["k"]`, or `T["k"]` in a type.
    fn keyedMember(s: Session, n: *Node) ?Sym {
        const c = s.c;
        const p = n.parent orelse return null;
        const t = switch (p.data) {
            .elem_access => |x| if (x.index == n) expr.checkExpression(c, x.expr) else return null,
            .literal_type => blk: {
                const g = p.parent orelse return null;
                if (g.data != .indexed_access) return null;
                break :blk decls.typeFromNode(c, g.data.indexed_access.object);
            },
            else => return null,
        };
        return memberOf(c, t, n);
    }

    /// A name read as a whole: `b` in `a.b` means what `a.b` means.
    fn nameSymbol(s: Session, n0: *Node) ?Sym {
        const c = s.c;
        var n = n0;
        while (syntax.isRightSideOfAccess(n)) n = n.parent.?;
        const p = n.parent orelse return null;
        if (p.data == .export_assign) if (decls.entitySymbol(c, n, F.value | F.type | F.namespace | F.alias)) |k| return .{ .symbol = k };
        if (inHeritageName(n)) {
            var meaning: u32 = F.alias | (if (syntax.isPartOfTypeNode(n)) F.type else F.namespace);
            if (p.data == .expr_with_type_args and syntax.isClassExtends(p)) meaning |= F.value;
            if (decls.entitySymbol(c, n, meaning)) |k| return .{ .symbol = k };
        }
        if (syntax.isExpressionNode(n)) switch (n.data) {
            .identifier => return bare(expr.symbolOf(c, n) orelse s.builtinValue(n)),
            .private_name => return null,
            .prop_access => |x| {
                var left = expr.checkExpression(c, x.expr);
                left = expr.nonNull(c, left);
                return memberOf(c, left, x.name);
            },
            .qualified_name => |x| {
                if (decls.entitySymbol(c, n, F.value | F.alias)) |k| return .{ .symbol = k };
                return memberOf(c, s.typeOfNode(x.left), x.right);
            },
            else => return null,
        };
        if (isTypeReferenceName(n)) {
            const meaning = F.alias | (if (p.data == .type_ref) F.type else F.namespace);
            if (decls.entitySymbol(c, n, meaning)) |k| return .{ .symbol = k };
            return null;
        }
        if (p.data == .type_predicate and n.data == .identifier) return bare(decls.resolveName(c, n, n.data.identifier, F.variable));
        return null;
    }

    /// True when the checker gave up here: the type says nothing, and a compiler has to refuse the
    /// node rather than read it as a real `any`. A name reported as missing is not a surrender.
    pub fn degraded(s: Session, t: *Type) bool {
        return t.data == .err and !decls.isUnresolved(s.c, t);
    }

    pub fn typeName(s: Session, t: *Type) []const u8 {
        return print.fullTypeToString(s.c, t);
    }

    /// One line per expression, for comparing the checker against another one:
    /// `path<TAB>start<TAB>end<TAB>kind<TAB>degraded<TAB>type`. `with_api` adds, per `Dump.api`,
    /// what the rest of this API answers there.
    pub fn dumpTypes(s: Session, w: *Io.Writer, with_api: bool) Io.Writer.Error!void {
        for (s.prog.files.items) |sf| {
            if (sf.is_lib or sf.read_failed or sf.file.is_dts) continue;
            var d = Dump{ .s = s, .w = w, .path = sf.file.path, .with_api = with_api };
            ast.forEachChild(sf.file.root, &d, Dump.visit);
            if (d.failed) |e| return e;
        }
    }
};

const ThisSearch = struct {
    found: bool = false,

    fn visit(x: *ThisSearch, n: *Node) void {
        if (n.data == .this_type) x.found = true;
        if (!x.found) ast.forEachChild(n, x, visit);
    }
};

/// A malformed chain of bases can be any length, and past this tsc's answer no longer matters.
const max_base_depth = 32;

/// tsc gives an interface a `this` type unless it can rule one out, and that makes it generic.
fn isThisless(c: *T.Checker, t: *Type, depth: u8) bool {
    if (t.data != .obj or depth == 0) return false;
    const o = t.data.obj;
    if (o.kind != .iface or o.is_class or o.tparams().len > 0) return false;
    const sym = o.sym orelse return true;
    for (sym.decls) |decl| {
        if (decl.data != .interface) continue;
        var search = ThisSearch{};
        ast.forEachChild(decl, &search, ThisSearch.visit);
        if (search.found) return false;
    }
    for (decls.basesOf(c, t)) |b| if (!isThisless(c, b, depth - 1)) return false;
    return true;
}

/// The pattern whose shape is all the context the initializer `n` has.
fn patternAt(c: *T.Checker, n: *Node) ?*Node {
    const p = n.parent orelse return null;
    const pat = switch (p.data) {
        .var_decl => |x| if (x.init == n and x.type == null) x.name else return null,
        .param => |x| if (x.init == n and x.type == null and !c.param_types.contains(p)) x.name else return null,
        .binding_elem => |x| if (x.init == n and expr.bindingDefaultContext(c, p) == null) x.name else return null,
        else => return null,
    };
    return switch (pat.data) {
        .object_pattern => |x| if (x.elems.len > 0) pat else null,
        .array_pattern => |x| if (x.elems.len > 0) pat else null,
        else => null,
    };
}

/// `getTypeFromBindingPattern`, which the checker's own context stops short of for an object
/// pattern: it has what it needs from the names being bound.
fn bindingPatternType(c: *T.Checker, pat: *Node) *Type {
    if (pat.data == .array_pattern) return arrayPatternType(c, pat.data.array_pattern.elems);
    const m = c.emptyMembers();
    for (pat.data.object_pattern.elems) |e| {
        const x = e.data.binding_elem;
        if (x.dotdotdot) {
            m.indexes = c.dupe(T.Index, &.{.{ .key = c.t_string, .ty = c.t_any }});
            continue;
        }
        const name = expr.propNameOf(c, x.prop_name orelse x.name) orelse continue;
        m.props.put(c.a, name, c.create(Prop, .{ .name = name, .ty = bindingElementType(c, e), .optional = x.init != null })) catch oom();
    }
    return c.newObj(.{ .kind = .anon, .members = m });
}

fn arrayPatternType(c: *T.Checker, elems: []const *Node) *Type {
    const isRest = struct {
        fn at(e: *const Node) bool {
            return e.data == .binding_elem and e.data.binding_elem.dotdotdot;
        }
    }.at;
    if (elems.len == 0 or (elems.len == 1 and isRest(elems[0]))) return decls.generic(c, "Iterable", &.{ c.t_any, c.t_void, c.t_undefined });
    var min: usize = 0;
    for (elems, 0..) |e, i| {
        if (e.data == .binding_elem and !isRest(e) and e.data.binding_elem.init == null) min = i + 1;
    }
    const types = c.a.alloc(*Type, elems.len) catch oom();
    const flags = c.a.alloc(T.ElemFlag, elems.len) catch oom();
    for (elems, types, flags, 0..) |e, *t, *f, i| {
        t.* = if (e.data == .binding_elem) bindingElementType(c, e) else c.t_any;
        f.* = if (isRest(e)) .rest else if (i >= min) .optional else .required;
    }
    return c.makeTuple(types, flags, false, &.{});
}

fn bindingElementType(c: *T.Checker, e: *Node) *Type {
    const x = e.data.binding_elem;
    if (x.init) |i| {
        const t = expr.widenInit(c, i, expr.checkSilent(c, i), isConstPattern(e));
        return c.getUnion(&.{ t, c.t_undefined });
    }
    return switch (x.name.data) {
        .object_pattern, .array_pattern => bindingPatternType(c, x.name),
        else => c.t_any,
    };
}

fn isConstPattern(e: *Node) bool {
    var at = e;
    while (at.parent) |p| : (at = p) {
        if (p.data == .var_list) return p.data.var_list.kind == .@"const";
    }
    return false;
}

/// `typeof C`, whose members start with the `prototype` the binder gave it first.
fn isClassValue(t: *Type) bool {
    if (t.data != .obj or t.data.obj.kind != .anon) return false;
    const k = t.data.obj.sym orelse return false;
    return k.flags & F.class != 0;
}

fn prototypeFirst(c: *T.Checker, props: []const *Prop) []const *Prop {
    for (props, 0..) |p, i| {
        if (!std.mem.eql(u8, p.name, "prototype")) continue;
        const out = c.a.alloc(*Prop, props.len) catch oom();
        out[0] = p;
        @memcpy(out[1 .. i + 1], props[0..i]);
        @memcpy(out[i + 1 ..], props[i + 1 ..]);
        return out;
    }
    return props;
}

/// `getApparentType`. `decls.getApparent` answers what a member access needs, where a type with
/// nothing known about it can pass for `{}` and `boolean` is its two literals.
fn publicApparent(c: *T.Checker, t: *Type) *Type {
    switch (t.data) {
        .unknown => return if (c.strict_null) t else c.t_empty,
        .param, .access, .cond, .keyof, .tmpl, .strmap, .noinfer => {
            const k = decls.baseConstraint(c, t);
            if (k == t or k.data == .unknown) return publicApparent(c, c.t_unknown);
        },
        .union_ => if (t.is_boolean) return decls.globalType(c, "Boolean") orelse c.t_err,
        .inter => |x| {
            const out = c.a.alloc(*Type, x.len) catch oom();
            for (x, 0..) |y, i| out[i] = publicApparent(c, y);
            if (std.mem.eql(*Type, out, x)) return t;
            return c.getIntersection(out);
        },
        else => {},
    }
    return decls.getApparent(c, t);
}

fn bare(k: ?*Symbol) ?Sym {
    return if (k) |x| .{ .symbol = x.resolve() } else null;
}

fn memberOf(c: *T.Checker, t: *Type, name: *Node) ?Sym {
    const key = expr.propNameOf(c, name) orelse ast.memberText(name);
    return .{ .prop = decls.getProp(c, t, key) orelse return null };
}

/// A base type with `this` standing for the class that inherits from it.
fn thisAs(c: *T.Checker, t: *Type, class: *Type) *Type {
    const own = if (class.data == .obj) class.data.obj.thisType() else null;
    return if (own) |x| decls.withThis(c, t, x) else t;
}

/// The parameter of an index signature, or its name: the binder gives neither a symbol.
fn indexParam(n: *Node) ?*Node {
    const p = if (n.data == .param) n else if (n.parent) |up| if (up.data == .param and syntax.isDeclarationName(n)) up else return null else return null;
    const owner = p.parent orelse return null;
    if (owner.data == .index_sig) return p;
    const name = p.data.param.name;
    return if (name.data == .identifier and std.mem.eql(u8, name.data.identifier, "this")) p else null;
}

fn isLiteral(n: *const Node) bool {
    return n.data == .string_lit or n.data == .numeric_lit or n.data == .no_subst_template;
}

/// The `this` parameter a function declares for itself, the one thing `this` can be the name of.
fn thisParam(n: *Node) ?*Node {
    var cur = n.parent;
    while (cur) |x| : (cur = x.parent) switch (x.data) {
        .func => |f| {
            if (f.kind == .arrow) continue;
            return decls.thisParam(x);
        },
        .class, .module_decl, .source_file => return null,
        else => {},
    };
    return null;
}

/// Whether `n` is the name, or part of the name, of an `extends` or `implements` entry.
fn inHeritageName(n0: *Node) bool {
    var n = n0;
    while (n.parent) |p| : (n = p) {
        if (p.data == .expr_with_type_args) return p.data.expr_with_type_args.expr == n;
        if (p.data != .prop_access) return false;
    }
    return false;
}

fn isTypeReferenceName(n0: *const Node) bool {
    if (n0.data != .identifier and n0.data != .qualified_name) return false;
    var n = n0;
    while (n.parent) |p| : (n = p) {
        if (p.data == .type_ref) return true;
        if (p.data != .qualified_name) return false;
    }
    return false;
}

/// How tsc spells a symbol's name: a module's file without its extension and in quotes, a well-known
/// symbol's key as it is written.
fn symbolText(c: *T.Checker, name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "__@")) return c.fmt("[Symbol.{s}]", .{name["__@".len..]});
    if (name.len > 0 and name[0] == '"') return name;
    if (!std.fs.path.isAbsolute(name)) return name;
    return moduleText(c, name);
}

fn moduleText(c: *T.Checker, path: []const u8) []const u8 {
    for ([_][]const u8{ ".d.ts", ".tsx", ".ts", ".jsx", ".js" }) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return c.fmt("\"{s}\"", .{path[0 .. path.len - ext.len]});
    }
    return c.fmt("\"{s}\"", .{path});
}

/// The object literal a member was written in. Such a member is a property of the literal's type
/// and has no symbol above it, however the literal gets its name.
fn literalOf(sym: Sym) ?*Node {
    const decl = sym.valueDeclaration() orelse return null;
    const p = decl.parent orelse return null;
    return if (p.data == .object_lit) p else null;
}

/// The name of a method written in an object literal, whose type has no symbol of its own here.
fn methodOfLiteral(n: *Node) ?[]const u8 {
    if (n.data != .func or n.data.func.kind != .method) return null;
    const p = n.parent orelse return null;
    if (p.data != .object_lit) return null;
    const name = syntax.nameOfDeclaration(n) orelse return null;
    return if (name.data == .identifier) name.data.identifier else null;
}

/// An identifier is an expression only in these places. The rest are names: of a property, a
/// label, a type, an import.
fn isValueIdentifier(n: *const Node) bool {
    const p = n.parent orelse return false;
    return switch (p.data) {
        .prop_access => |x| x.expr == n,
        .property_assign => |x| x.value == n,
        .var_decl => |x| x.init == n or x.name == n,
        .param => |x| x.init == n or x.name == n,
        .binding_elem => |x| x.init == n or x.name == n,
        .call, .new_expr, .binary, .conditional, .prefix, .postfix, .paren, .array_lit, .elem_access, .template_span, .as_expr, .satisfies_expr, .non_null, .spread_elem, .spread_assign, .await_expr, .typeof_expr, .void_expr, .return_stmt, .expr_stmt, .if_stmt, .while_stmt, .do_stmt, .for_stmt, .switch_stmt, .throw_stmt => true,
        else => false,
    };
}

fn isDumped(n: *const Node) bool {
    return switch (n.data) {
        .identifier => isValueIdentifier(n),
        .object_lit => syntax.isExpressionNode(n),
        .prop_access, .elem_access, .call, .new_expr, .binary, .conditional, .prefix, .postfix, .array_lit, .paren, .as_expr, .satisfies_expr, .non_null, .await_expr, .template_expr, .this_expr, .typeof_expr, .void_expr, .numeric_lit, .string_lit => true,
        else => false,
    };
}

const Dump = struct {
    s: Session,
    w: *Io.Writer,
    path: []const u8,
    with_api: bool,
    failed: ?Io.Writer.Error = null,

    fn visit(d: *Dump, n: *Node) void {
        if (d.failed == null and isDumped(n)) d.line(n) catch |e| {
            d.failed = e;
        };
        ast.forEachChild(n, d, visit);
    }

    fn line(d: *Dump, n: *Node) Io.Writer.Error!void {
        const t = d.s.typeAt(n);
        try d.w.print("{s}\t{d}\t{d}\t{t}\t{d}\t", .{ d.path, n.start, n.end, n.kind(), @intFromBool(d.s.degraded(t)) });
        try d.field(d.s.typeName(t));
        if (d.with_api) try d.api(n, t);
        try d.w.writeByte('\n');
    }

    fn field(d: *Dump, text: []const u8) Io.Writer.Error!void {
        for (text) |b| try d.w.writeByte(if (b == '\n' or b == '\t') ' ' else b);
    }

    fn types(d: *Dump, list: []const *Type) Io.Writer.Error!void {
        try d.w.writeByte('\t');
        for (list, 0..) |t, i| {
            if (i > 0) try d.w.writeAll("; ");
            try d.field(d.s.typeName(t));
        }
    }

    fn optionalType(d: *Dump, t: ?*Type) Io.Writer.Error!void {
        try d.w.writeByte('\t');
        if (t) |x| try d.field(d.s.typeName(x));
    }

    /// Columns after `type`, each from one method: type flags, object flags, symbol name, symbol
    /// flags, qualified name, type's symbol, alias, property names, call and construct signature
    /// counts, type arguments, apparent type, base types, contextual type, resolved signature,
    /// type of the symbol here, index signatures.
    fn api(d: *Dump, n: *Node, t: *Type) Io.Writer.Error!void {
        const s = d.s;
        try d.w.print("\t{d}\t{d}\t", .{ s.typeFlags(t).bits, s.objectFlags(t).bits });
        const sym = s.symbolAt(n);
        if (sym) |k| {
            try d.field(s.nameOf(k));
            try d.w.print("\t{d}\t", .{k.flags().bits});
            try d.field(s.fullyQualifiedName(k));
        } else try d.w.writeAll("\t\t");
        try d.w.writeByte('\t');
        if (s.symbolOfType(t)) |k| try d.field(if (k.flags & F.value_module != 0) s.nameOf(.{ .symbol = k }) else k.name);
        try d.w.writeByte('\t');
        if (s.aliasOf(t)) |x| {
            try d.field(x.sym.name);
            try d.w.print("/{d}", .{x.args.len});
        }
        try d.w.writeByte('\t');
        for (s.propertiesOf(t), 0..) |p, i| {
            if (i > 0) try d.w.writeByte(',');
            try d.field(p.name);
        }
        try d.w.print("\t{d}/{d}", .{ s.signaturesOf(t, .call).len, s.signaturesOf(t, .construct).len });
        try d.types(s.typeArgumentsOf(t));
        try d.optionalType(s.apparentTypeOf(t));
        try d.types(s.baseTypesOf(t));
        try d.optionalType(s.contextualTypeOf(n));
        try d.w.writeByte('\t');
        if (n.data == .call or n.data == .new_expr) if (s.resolvedSignature(n)) |sig| {
            try d.w.print("{d}:", .{sig.params.len});
            try d.field(s.typeName(s.returnTypeOf(sig)));
        };
        try d.optionalType(if (sym) |k| s.typeOfSymAt(k, n) else null);
        try d.w.writeByte('\t');
        for (s.indexInfosOf(t), 0..) |x, i| {
            if (i > 0) try d.w.writeAll("; ");
            try d.field(s.typeName(x.key));
            try d.w.writeByte(':');
            try d.field(s.typeName(x.ty));
        }
    }
};

test "a session names types and tells a surrender from a missing name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const path = try Io.Dir.cwd().realPathFileAlloc(io, "tests/fixtures/session-types/tsconfig.json", a);
    var cfg = try project.loadConfig(.{ .a = a, .io = io }, path);
    cfg.options.noLib = true;
    var tp = pool.ThreadPool.init(1);
    const s = Session.open(a, io, &tp, &cfg, .{});

    var out: Io.Writer.Allocating = .init(a);
    try s.dumpTypes(&out.writer, false);
    const dump = out.written();
    try std.testing.expect(std.mem.indexOf(u8, dump, "\t6\t7\tidentifier\t0\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "\t17\t21\tidentifier\t0\tstring\n") != null);
    // `missing` is an error the checker reported, so a compiler may stop on that instead.
    try std.testing.expect(std.mem.indexOf(u8, dump, "\t42\t49\tidentifier\t0\t") != null);

    try std.testing.expect(s.degraded(s.c.t_err));
    try std.testing.expect(!s.degraded(s.c.t_unresolved));
    try std.testing.expect(!s.degraded(s.c.t_any));
}

fn typeOfConst(s: Session, name: []const u8) !*Type {
    for (s.prog.files.items) |sf| {
        if (sf.is_lib) continue;
        for (sf.file.root.data.source_file.stmts) |st| {
            if (st.data != .var_stmt) continue;
            for (st.data.var_stmt.list.data.var_list.decls) |decl| {
                const id = decl.data.var_decl.name;
                if (std.mem.eql(u8, id.data.identifier, name)) return s.typeAt(id);
            }
        }
    }
    return error.TestUnexpectedResult;
}

test "a session answers what tsc answers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const path = try Io.Dir.cwd().realPathFileAlloc(io, "tests/fixtures/session-api/tsconfig.json", a);
    var cfg = try project.loadConfig(.{ .a = a, .io = io }, path);
    cfg.options.noLib = true;
    var tp = pool.ThreadPool.init(1);
    const s = Session.open(a, io, &tp, &cfg, .{});

    // Each of these is what `checker.typeToString` printed for the same file under the same options.
    const printed = [_][2][]const u8{
        .{ "t1", "Named" },
        .{ "t2", "Box<\"a\">" },
        .{ "t3", "(a: number, rest_0: string, rest_1?: boolean | undefined) => void" },
        .{ "t4", "<T extends string>(x: T) => T" },
        .{ "t5", "() => typeof recurse" },
        .{ "t6", "{ c: number; b: number; a: number; }" },
        .{ "t7", "\"n\"" },
        .{ "t8", "\"k\"" },
        .{ "t9", "any" },
        .{ "t10", "\"n\"" },
        .{ "t11", "readonly [1, \"a\"]" },
    };
    for (printed) |want| try std.testing.expectEqualStrings(want[1], s.typeName(try typeOfConst(s, want[0])));

    const named = try typeOfConst(s, "t1");
    const props = s.propertiesOf(named);
    try std.testing.expectEqual(3, props.len);
    for (props, [_][]const u8{ "name", "value", "get" }) |p, want| try std.testing.expectEqualStrings(want, p.name);
    try std.testing.expectEqualStrings("() => \"n\"", s.typeName(s.typeOfSym(.{ .prop = s.propertyOf(named, "get").? })));
    try std.testing.expectEqual(1, s.baseTypesOf(named).len);
    try std.testing.expectEqualStrings("Box<\"n\">", s.typeName(s.baseTypesOf(named)[0]));
    try std.testing.expect(s.typeFlags(named).has(.object));
    try std.testing.expect(s.objectFlags(named).has(.interface));

    const box = try typeOfConst(s, "t2");
    try std.testing.expectEqual(1, s.typeArgumentsOf(box).len);
    try std.testing.expectEqualStrings("\"a\"", s.typeName(s.typeArgumentsOf(box)[0]));

    const sigs = s.signaturesOf(try typeOfConst(s, "t4"), .call);
    try std.testing.expectEqual(1, sigs.len);
    try std.testing.expectEqual(0, s.signaturesOf(named, .call).len);
    try std.testing.expectEqualStrings("T", s.typeName(s.returnTypeOf(sigs[0])));
    try std.testing.expect(s.typeFlags(s.returnTypeOf(sigs[0])).has(.type_parameter));
    try std.testing.expect(s.typeFlags(try typeOfConst(s, "t7")).has(.string_like));

    // A name that resolves to nothing is the error tsc reported, not a surrender.
    try std.testing.expect(!s.degraded(try typeOfConst(s, "t9")));

    const literal = try typeOfConst(s, "t12");
    try std.testing.expectEqualStrings("t12", s.fullyQualifiedName(.{ .symbol = s.symbolOfType(literal).? }));
    try std.testing.expectEqualStrings("t12.\"a-b\"", s.fullyQualifiedName(.{ .prop = s.propertiesOf(literal)[0] }));
    const class = try typeOfConst(s, "t13");
    try std.testing.expectEqualStrings("t13", s.fullyQualifiedName(.{ .symbol = s.symbolOfType(class).? }));
}
