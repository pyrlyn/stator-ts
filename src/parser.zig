const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const jsdoc = @import("jsdoc.zig");
const lexer = @import("lexer.zig");
const spelling = @import("spelling.zig");

/// Keywords longer than two letters, in tsc's table order, which breaks ties.
const suggested_keywords = [_][]const u8{
    "abstract", "accessor", "any",        "asserts",     "assert",    "bigint",  "boolean",   "break",     "case",      "catch",
    "class",    "continue", "const",      "constructor", "debugger",  "declare", "default",   "defer",     "delete",    "else",
    "enum",     "export",   "extends",    "false",       "finally",   "for",     "from",      "function",  "get",       "implements",
    "import",   "infer",    "instanceof", "interface",   "intrinsic", "keyof",   "let",       "module",    "namespace", "never",
    "new",      "null",     "number",     "object",      "package",   "private", "protected", "public",    "override",  "out",
    "readonly", "require",  "global",     "return",      "satisfies", "set",     "static",    "string",    "super",     "switch",
    "symbol",   "this",     "throw",      "true",        "try",       "type",    "typeof",    "undefined", "unique",    "unknown",
    "using",    "var",      "void",       "while",       "with",      "yield",   "async",     "await",
};
const Node = ast.Node;
const Tok = lexer.Tok;
const Lexer = lexer.Lexer;
const Data = ast.Data;
const Mods = ast.Mods;
const Span = ast.Span;

const NodeList = std.ArrayList(*Node);

fn oom() noreturn {
    @panic("out of memory");
}

pub fn parse(a: Allocator, path: []const u8, src: []const u8) *ast.File {
    return parseFile(a, path, src, false).?;
}

/// Like `parse`, except that function blocks stay unparsed for `parseBody` to fill in. JSX text is
/// not made of tokens, so a block holding some could not be skipped by looking at them.
pub fn parseLazily(a: Allocator, path: []const u8, src: []const u8) *ast.File {
    const lazy = for ([_][]const u8{ ".ts", ".mts", ".cts" }) |x| {
        if (std.mem.endsWith(u8, path, x)) break true;
    } else false;
    return parseFile(a, path, src, lazy) orelse parse(a, path, src);
}

pub const Body = struct {
    block: *Node,
    /// False when the block has a syntax error or ends elsewhere than the skip found, which also
    /// proves every skip that passes: this runs for each body of each file the program checks.
    ok: bool,
};

/// Parses the block `parseLazily` skipped for the function `n`.
pub fn parseBody(a: Allocator, file: *const ast.File, n: *Node) Body {
    const f = n.data.func;
    const skipped = f.body.?;
    var p = Parser{
        .a = a,
        .lx = .{ .src = file.src, .a = a, .pos = skipped.start },
        .tsx = false,
        .ambient = false,
        .in_async = n.mods.async,
        .in_gen = f.asterisk,
        .in_func = true,
    };
    _ = p.lx.next();
    const block = p.parseBlock();
    setParents(block);
    block.parent = n;
    return .{ .block = block, .ok = block.end == skipped.end and p.lx.diags.items.len == 0 };
}

/// Null when `lazy` could not skip a block; only then is there anything to do over.
fn parseFile(a: Allocator, path: []const u8, src: []const u8, lazy: bool) ?*ast.File {
    const is_dts = std.mem.endsWith(u8, path, ".d.ts") or std.mem.endsWith(u8, path, ".d.mts") or std.mem.endsWith(u8, path, ".d.cts") or std.mem.endsWith(u8, path, ".json");
    var p = Parser{
        .a = a,
        .lx = .{ .src = src, .a = a },
        .tsx = std.mem.endsWith(u8, path, ".tsx") or std.mem.endsWith(u8, path, ".jsx"),
        .ambient = is_dts,
        .lazy = lazy and !is_dts,
    };
    _ = p.lx.next();
    var stmts: NodeList = .empty;
    while (p.t() != .eof) {
        p.parseListStatement(&stmts);
    }
    if (p.skip_failed) return null;
    const root = p.mk(0, .{ .source_file = .{ .stmts = stmts.items } });
    root.end = @intCast(src.len);
    const jsdoc_names: []const ast.JsdocName = if (ast.isJsFile(path)) jsdoc.attach(a, src, root) else &.{};
    setParents(root);
    const pragmas = scanPragmas(a, src);
    const f = a.create(ast.File) catch oom();
    f.* = .{
        .path = path,
        .src = src,
        .root = root,
        .diags = p.lx.diags.items,
        .strip = p.strip.items,
        .directives = p.lx.ts_ignores.items,
        .is_dts = is_dts,
        .is_module = isExternalModule(stmts.items) or p.saw_import_meta,
        .references = pragmas.references,
        .check_directive = pragmas.check,
        .jsdoc_names = jsdoc_names,
    };
    return f;
}

pub const CommentType = struct { node: *Node, optional: bool };

/// Parses a JSDoc type, its braces taken off. Null when it is not one: a comment cannot be a
/// syntax error of the program, so nothing here is reported.
pub fn parseCommentType(a: Allocator, src: []const u8, start: u32, end: u32) ?CommentType {
    var p = Parser{ .a = a, .lx = .{ .src = withoutMargin(a, src, start, end), .a = a, .pos = start }, .tsx = false, .ambient = false, .jsdoc = true };
    _ = p.lx.next();
    const rest = p.eat(.dot3);
    const ty = p.parseType();
    const optional = p.eat(.assign);
    if (p.t() != .eof or p.lx.diags.items.len != 0) return null;
    return .{ .node = if (rest) p.mk(start, .{ .array_type = .{ .elem = ty } }) else ty, .optional = optional };
}

/// A type that spans lines has the comment's asterisks in it, which are not tokens. Offsets stay.
fn withoutMargin(a: Allocator, src: []const u8, start: u32, end: u32) []const u8 {
    if (std.mem.indexOfScalar(u8, src[start..end], '\n') == null) return src[0..end];
    const copy = a.dupe(u8, src[0..end]) catch oom();
    var i = start;
    while (std.mem.indexOfScalarPos(u8, copy, i, '\n')) |nl| {
        i = @intCast(nl + 1);
        while (i < end and (copy[i] == ' ' or copy[i] == '\t')) i += 1;
        if (i < end and copy[i] == '*') copy[i] = ' ';
    }
    return copy;
}

fn setParents(n: *Node) void {
    ast.forEachChild(n, n, struct {
        fn f(parent: *Node, c: *Node) void {
            c.parent = parent;
            setParents(c);
        }
    }.f);
}

fn isExternalModule(stmts: []*Node) bool {
    for (stmts) |s| {
        if (s.mods.@"export") return true;
        switch (s.data) {
            .import_decl, .export_decl, .export_assign => return true,
            .import_equals => |d| if (d.ref.data == .external_module_ref) return true,
            else => {},
        }
    }
    return false;
}

fn attrValue(line: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |i| {
        var j = i + name.len;
        from = j;
        // `lib` inside `no-default-lib` is not the attribute.
        if (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '-' or line[i - 1] == '_')) continue;
        while (j < line.len and line[j] == ' ') j += 1;
        if (j >= line.len or line[j] != '=') continue;
        j += 1;
        while (j < line.len and line[j] == ' ') j += 1;
        if (j >= line.len or (line[j] != '"' and line[j] != '\'')) continue;
        const end = std.mem.indexOfScalarPos(u8, line, j + 1, line[j]) orelse return null;
        return line[j + 1 .. end];
    }
    return null;
}

const Pragmas = struct { references: []ast.File.Reference, check: ?bool };

/// The comments before the first token: `/// <reference …/>` and `// @ts-check` or `// @ts-nocheck`.
fn scanPragmas(a: Allocator, src: []const u8) Pragmas {
    var out: std.ArrayList(ast.File.Reference) = .empty;
    var check: ?bool = null;
    var i: usize = 0;
    if (std.mem.startsWith(u8, src, "#!")) i = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    while (i < src.len) {
        if (std.ascii.isWhitespace(src[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse break;
            i = end + 2;
            continue;
        }
        if (!std.mem.startsWith(u8, src[i..], "//")) break;
        const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = src[i..end];
        i = end;
        if (checkPragma(line)) |on| check = on;
        if (!std.mem.startsWith(u8, line, "///") or std.mem.indexOf(u8, line, "<reference") == null) continue;
        if (attrValue(line, "lib")) |v| {
            out.append(a, .{ .kind = .lib, .value = v }) catch oom();
        } else if (attrValue(line, "path")) |v| {
            out.append(a, .{ .kind = .path, .value = v }) catch oom();
        } else if (attrValue(line, "types")) |v| {
            out.append(a, .{ .kind = .types, .value = v }) catch oom();
        }
    }
    return .{ .references = out.items, .check = check };
}

/// tsc reads the name after `@` as letters and dashes, in any case.
fn checkPragma(line: []const u8) ?bool {
    var i: usize = 2;
    if (i < line.len and line[i] == '/') i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or line[i] != '@') return null;
    const start = i + 1;
    i = start;
    while (i < line.len and (std.ascii.isAlphabetic(line[i]) or line[i] == '-')) i += 1;
    const name = line[start..i];
    if (std.ascii.eqlIgnoreCase(name, "ts-check")) return true;
    if (std.ascii.eqlIgnoreCase(name, "ts-nocheck")) return false;
    return null;
}

const Snapshot = struct { lx: Lexer.State, prev_end: u32, strip: usize };

const Parser = struct {
    a: Allocator,
    lx: Lexer,
    tsx: bool,
    ambient: bool,
    prev_end: u32 = 0,
    in_async: bool = false,
    in_gen: bool = false,
    no_in: bool = false,
    no_cond_type: bool = false,
    in_decorator: bool = false,
    in_func: bool = false,
    saw_import_meta: bool = false,
    no_arrow_ret: bool = false,
    not_arrow: std.AutoHashMapUnmanaged(u32, void) = .empty,
    strip: std.ArrayList(Span) = .empty,
    pending_new_args: ?ast.TypeList = null,
    lazy: bool = false,
    skip_failed: bool = false,
    /// In a JSDoc comment, where a type has a few spellings of its own.
    jsdoc: bool = false,

    fn t(p: *const Parser) Tok {
        return p.lx.tok;
    }

    fn next(p: *Parser) void {
        p.prev_end = p.lx.pos;
        _ = p.lx.next();
    }

    fn save(p: *const Parser) Snapshot {
        return .{ .lx = p.lx.save(), .prev_end = p.prev_end, .strip = p.strip.items.len };
    }

    fn restore(p: *Parser, s: Snapshot) void {
        p.lx.restore(s.lx);
        p.prev_end = s.prev_end;
        p.strip.items.len = s.strip;
    }

    fn mk(p: *Parser, start: u32, data: Data) *Node {
        const n = p.a.create(Node) catch oom();
        n.* = .{ .start = start, .end = p.prev_end, .data = data };
        return n;
    }

    /// `std.ArrayList` reserves 17 items on the first append, and a node list usually holds two.
    /// The list is kept in the tree as it stands, so what it reserves stays for the whole run.
    fn push(p: *Parser, list: *NodeList, n: *Node) void {
        if (list.items.len == list.capacity) list.ensureTotalCapacityPrecise(p.a, @max(1, list.capacity * 2)) catch oom();
        list.appendAssumeCapacity(n);
    }

    fn box(p: *Parser, value: anytype) *@TypeOf(value) {
        const b = p.a.create(@TypeOf(value)) catch oom();
        b.* = value;
        return b;
    }

    fn errHere(p: *Parser, code: u32, msg: []const u8) void {
        p.lx.err(p.lx.start, p.lx.pos - p.lx.start, code, msg);
    }

    fn skipBadToken(p: *Parser, code: u32, msg: []const u8) void {
        p.errHere(code, msg);
        p.next();
    }

    fn eat(p: *Parser, tok: Tok) bool {
        if (p.t() == tok) {
            p.next();
            return true;
        }
        return false;
    }

    fn expect(p: *Parser, tok: Tok) void {
        if (p.eat(tok)) return;
        const msg = std.fmt.allocPrint(p.a, "'{s}' expected.", .{lexer.tokenText(tok)}) catch oom();
        p.errHere(1005, msg);
    }

    fn semi(p: *Parser) void {
        if (p.eat(.semi)) return;
        if (p.t() == .r_brace or p.t() == .eof or p.lx.nl_before) return;
        p.errHere(1005, "';' expected.");
    }

    /// A word left standing with no semicolon is usually a misspelled keyword, or a declaration
    /// whose name did not parse.
    fn semiAfterWord(p: *Parser, e: *Node) void {
        if (p.eat(.semi) or p.canSemi()) return;
        const word = e.data.identifier;
        const eql = std.mem.eql;
        if (word.len == 0) return p.errHere(1005, "';' expected.");
        const span = e.end - e.start;
        if (eql(u8, word, "const") or eql(u8, word, "let") or eql(u8, word, "var")) {
            return p.lx.err(e.start, span, 1440, "Variable declaration not allowed at this location.");
        }
        if (eql(u8, word, "declare")) return;
        if (eql(u8, word, "interface")) return p.badName(.l_brace, 2427, "Interface name cannot be '{s}'.", 1438, "Interface must be given a name.");
        if (eql(u8, word, "module") or eql(u8, word, "namespace")) return p.badName(.l_brace, 2819, "Namespace name cannot be '{s}'.", 1437, "Namespace must be given a name.");
        if (eql(u8, word, "type")) return p.badName(.assign, 2457, "Type alias name cannot be '{s}'.", 1439, "Type alias must be given a name.");
        if (eql(u8, word, "is")) return p.lx.err(e.start, p.lx.start - e.start, 1228, "A type predicate is only allowed in return type position for functions and methods.");
        if (spelling.best(p.a, word, &suggested_keywords) orelse p.spaceSuggestion(word)) |s| {
            return p.lx.err(e.start, span, 1435, std.fmt.allocPrint(p.a, "Unknown keyword or identifier. Did you mean '{s}'?", .{s}) catch oom());
        }
        if (p.t() == .unknown) return;
        p.lx.err(e.start, span, 1434, "Unexpected keyword or identifier.");
    }

    fn badName(p: *Parser, blank: Tok, code: u32, comptime fmt: []const u8, blank_code: u32, blank_msg: []const u8) void {
        if (p.t() == blank) return p.errHere(blank_code, blank_msg);
        p.errHere(code, std.fmt.allocPrint(p.a, fmt, .{p.lx.src[p.lx.start..p.lx.pos]}) catch oom());
    }

    /// `functionfoo` for `function foo`.
    fn spaceSuggestion(p: *Parser, word: []const u8) ?[]const u8 {
        for (suggested_keywords) |k| {
            if (word.len > k.len + 2 and std.mem.startsWith(u8, word, k)) {
                return std.fmt.allocPrint(p.a, "{s} {s}", .{ k, word[k.len..] }) catch oom();
            }
        }
        return null;
    }

    fn canSemi(p: *const Parser) bool {
        return p.t() == .semi or p.t() == .r_brace or p.t() == .eof or p.lx.nl_before;
    }

    fn isIdent(p: *const Parser) bool {
        const tok = p.t();
        if (tok == .kw_yield and p.in_gen) return false;
        if (tok == .kw_await and p.in_async) return false;
        return tok.isIdentifierLike();
    }

    fn identNode(p: *Parser) *Node {
        const s = p.lx.start;
        const v = p.lx.value;
        const tok = p.t();
        p.next();
        const text = if (tok == .identifier) v else p.lx.src[s..p.prev_end];
        return p.mk(s, .{ .identifier = text });
    }

    fn missingIdent(p: *Parser) *Node {
        return p.mk(p.lx.start, .{ .identifier = "" });
    }

    fn parseIdent(p: *Parser) *Node {
        if (p.isIdent()) return p.identNode();
        p.errHere(if (p.t().isReserved()) 1359 else 1003, if (p.t().isReserved())
            "Identifier expected. Reserved word cannot be used here."
        else
            "Identifier expected.");
        return p.missingIdent();
    }

    /// Property names accept reserved words.
    fn parseIdentName(p: *Parser) *Node {
        if (p.t().isKeyword() or p.t() == .identifier) return p.identNode();
        p.errHere(1003, "Identifier expected.");
        return p.missingIdent();
    }

    fn isPropertyNameStart(p: *const Parser) bool {
        return switch (p.t()) {
            .identifier, .string, .numeric, .bigint, .l_bracket, .private_name => true,
            else => p.t().isKeyword(),
        };
    }

    fn parsePropertyName(p: *Parser) *Node {
        const s = p.lx.start;
        switch (p.t()) {
            .string => return p.stringNode(),
            .numeric => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .numeric_lit = v });
            },
            .bigint => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .bigint_lit = v });
            },
            .private_name => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .private_name = v });
            },
            .l_bracket => {
                p.next();
                const save_in = p.no_in;
                p.no_in = false;
                const e = p.parseAssignment();
                p.no_in = save_in;
                p.expect(.r_bracket);
                return p.mk(s, .{ .computed_name = .{ .expr = e } });
            },
            else => return p.parseIdentName(),
        }
    }

    fn stringNode(p: *Parser) *Node {
        const s = p.lx.start;
        const v = p.lx.value;
        p.next();
        return p.mk(s, .{ .string_lit = v });
    }

    // Statements

    /// A list skips what cannot start a statement, where an expression parse would call it a
    /// missing expression.
    fn parseListStatement(p: *Parser, list: *NodeList) void {
        if (!p.startsStatement()) return p.skipBadToken(1128, "Declaration or statement expected.");
        const before = p.lx.start;
        p.push(list, p.parseStatement());
        if (p.lx.start == before and p.t() != .eof) p.skipBadToken(1128, "Declaration or statement expected.");
    }

    fn startsStatement(p: *Parser) bool {
        return switch (p.t()) {
            .kw_accessor, .kw_public, .kw_private, .kw_protected, .kw_static, .kw_readonly => p.modifierStartsStatement(),
            .kw_export => p.isDeclarationStart(),
            .r_brace, .r_paren, .r_bracket, .dot, .dot3, .comma, .arrow, .question, .question_dot, .colon => false,
            .assign, .plus_assign, .minus_assign, .star_assign, .star2_assign, .slash_assign, .percent_assign => false,
            .shl_assign, .shr_assign, .ushr_assign, .amp_assign, .pipe_assign, .caret_assign, .amp2_assign => false,
            .pipe2_assign, .qq_assign, .kw_else, .kw_case, .kw_default, .kw_extends => false,
            else => true,
        };
    }

    /// `static x` outside a class is a misplaced member, not an expression statement.
    fn modifierStartsStatement(p: *Parser) bool {
        if (p.isDeclarationStart()) return true;
        const st = p.save();
        defer p.restore(st);
        return !(p.nextOnSameLine() and (p.t().isKeyword() or p.t() == .identifier));
    }

    fn parseStatementsUntil(p: *Parser, close: Tok) []*Node {
        var list: NodeList = .empty;
        while (p.t() != close and p.t() != .eof) {
            p.parseListStatement(&list);
        }
        return list.items;
    }

    fn parseBlock(p: *Parser) *Node {
        const s = p.lx.start;
        p.expect(.l_brace);
        const stmts = p.parseStatementsUntil(.r_brace);
        p.expect(.r_brace);
        return p.mk(s, .{ .block = .{ .stmts = stmts } });
    }

    fn parseStatement(p: *Parser) *Node {
        const s = p.lx.start;
        switch (p.t()) {
            .semi => {
                p.next();
                return p.mk(s, .empty_stmt);
            },
            .l_brace => return p.parseBlock(),
            .kw_var => return p.parseVarStmt(s, .{}),
            .kw_if => {
                p.next();
                const cond = p.parseParenCond();
                const then = p.parseStatement();
                const els = if (p.eat(.kw_else)) p.parseStatement() else null;
                return p.mk(s, .{ .if_stmt = .{ .cond = cond, .then = then, .els = els } });
            },
            .kw_do => {
                p.next();
                const body = p.parseStatement();
                p.expect(.kw_while);
                const cond = p.parseParenCond();
                _ = p.eat(.semi);
                return p.mk(s, .{ .do_stmt = .{ .body = body, .cond = cond } });
            },
            .kw_while => {
                p.next();
                const cond = p.parseParenCond();
                const body = p.parseStatement();
                return p.mk(s, .{ .while_stmt = .{ .cond = cond, .body = body } });
            },
            .kw_for => return p.parseFor(),
            .kw_continue, .kw_break => {
                const is_break = p.t() == .kw_break;
                p.next();
                const label = if (!p.canSemi() and p.isIdent()) p.identNode() else null;
                p.semi();
                return if (is_break) p.mk(s, .{ .break_stmt = .{ .label = label } }) else p.mk(s, .{ .continue_stmt = .{ .label = label } });
            },
            .kw_return => {
                p.next();
                const e = if (p.canSemi()) null else p.parseExpression();
                p.semi();
                return p.mk(s, .{ .return_stmt = .{ .expr = e } });
            },
            .kw_with => {
                p.next();
                const e = p.parseParenCond();
                const body = p.parseStatement();
                return p.mk(s, .{ .with_stmt = .{ .expr = e, .body = body } });
            },
            .kw_switch => return p.parseSwitch(),
            .kw_throw => {
                p.next();
                if (p.lx.nl_before) p.errHere(1142, "Line break not permitted here.");
                const e = p.parseExpression();
                p.semi();
                return p.mk(s, .{ .throw_stmt = .{ .expr = e } });
            },
            .kw_try => return p.parseTry(),
            .kw_debugger => {
                p.next();
                p.semi();
                return p.mk(s, .debugger_stmt);
            },
            else => {},
        }
        if (p.isDeclarationStart()) return p.parseDeclaration();
        const e = p.parseExpression();
        if (e.data == .identifier and p.t() == .colon) {
            p.next();
            const stmt = p.parseStatement();
            return p.mk(s, .{ .labeled = .{ .label = e, .stmt = stmt } });
        }
        if (e.end == s and p.lx.start == s) {
            // Nothing was consumed: let the caller recover instead of looping.
            return p.mk(s, .empty_stmt);
        }
        if (e.data == .identifier) p.semiAfterWord(e) else p.semi();
        return p.mk(s, .{ .expr_stmt = .{ .expr = e } });
    }

    fn parseParenCond(p: *Parser) *Node {
        p.expect(.l_paren);
        const e = p.parseExpressionAllowIn();
        p.expect(.r_paren);
        return e;
    }

    fn parseExpressionAllowIn(p: *Parser) *Node {
        const save_in = p.no_in;
        p.no_in = false;
        defer p.no_in = save_in;
        return p.parseExpression();
    }

    fn parseSwitch(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        const e = p.parseParenCond();
        p.expect(.l_brace);
        var clauses: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const cs = p.lx.start;
            if (p.eat(.kw_case)) {
                const test_expr = p.parseExpressionAllowIn();
                p.expect(.colon);
                const stmts = p.parseClauseStatements();
                p.push(&clauses, p.mk(cs, .{ .case_clause = .{ .expr = test_expr, .stmts = stmts } }));
            } else if (p.eat(.kw_default)) {
                p.expect(.colon);
                const stmts = p.parseClauseStatements();
                p.push(&clauses, p.mk(cs, .{ .default_clause = .{ .stmts = stmts } }));
            } else {
                p.skipBadToken(1130, "'case' or 'default' expected.");
            }
        }
        p.expect(.r_brace);
        return p.mk(s, .{ .switch_stmt = .{ .expr = e, .clauses = clauses.items } });
    }

    fn parseClauseStatements(p: *Parser) []*Node {
        var list: NodeList = .empty;
        while (p.t() != .kw_case and p.t() != .kw_default and p.t() != .r_brace and p.t() != .eof) {
            p.parseListStatement(&list);
        }
        return list.items;
    }

    fn parseTry(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        const block = p.parseBlock();
        var catch_clause: ?*Node = null;
        if (p.t() == .kw_catch) {
            const cs = p.lx.start;
            p.next();
            var decl: ?*Node = null;
            if (p.eat(.l_paren)) {
                const ds = p.lx.start;
                const name = p.parseBindingName();
                var ann: Span = .{};
                var ty: ?*Node = null;
                if (p.t() == .colon) {
                    ann.start = p.lx.start;
                    p.next();
                    ty = p.parseType();
                    ann.end = p.prev_end;
                }
                decl = p.mk(ds, .{ .var_decl = p.box(ast.VarDecl{ .name = name, .ann_span = ann, .type = ty }) });
                p.expect(.r_paren);
            }
            const body = p.parseBlock();
            catch_clause = p.mk(cs, .{ .catch_clause = .{ .decl = decl, .block = body } });
        }
        const finally = if (p.eat(.kw_finally)) p.parseBlock() else null;
        if (catch_clause == null and finally == null) p.errHere(1472, "'catch' or 'finally' expected.");
        return p.mk(s, .{ .try_stmt = .{ .block = block, .catch_clause = catch_clause, .finally = finally } });
    }

    fn parseFor(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        const is_await = p.eat(.kw_await);
        p.expect(.l_paren);
        var init_node: ?*Node = null;
        const save_in = p.no_in;
        p.no_in = true;
        if (p.t() != .semi) {
            if (p.t() == .kw_var or p.t() == .kw_const or (p.t() == .kw_let and p.isLetDecl()) or p.isUsingDecl()) {
                init_node = p.parseVarList();
            } else {
                init_node = p.parseExpression();
            }
        }
        p.no_in = save_in;
        if (init_node != null and p.t() == .kw_of) {
            p.next();
            const e = p.parseAssignment();
            p.expect(.r_paren);
            const body = p.parseStatement();
            return p.mk(s, .{ .for_of = p.box(ast.ForOf{ .is_await = is_await, .init = init_node.?, .expr = e, .body = body }) });
        }
        if (init_node != null and p.t() == .kw_in) {
            p.next();
            const e = p.parseExpressionAllowIn();
            p.expect(.r_paren);
            const body = p.parseStatement();
            return p.mk(s, .{ .for_in = .{ .init = init_node.?, .expr = e, .body = body } });
        }
        p.expect(.semi);
        const cond = if (p.t() != .semi) p.parseExpressionAllowIn() else null;
        p.expect(.semi);
        const update = if (p.t() != .r_paren) p.parseExpressionAllowIn() else null;
        p.expect(.r_paren);
        const body = p.parseStatement();
        return p.mk(s, .{ .for_stmt = p.box(ast.ForStmt{ .init = init_node, .cond = cond, .update = update, .body = body }) });
    }

    fn isLetDecl(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.isIdent() or p.t() == .l_bracket or p.t() == .l_brace;
    }

    fn isUsingDecl(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        if (p.t() == .kw_await) {
            p.next();
            if (p.t() != .kw_using or p.lx.nl_before) return false;
        } else if (p.t() != .kw_using) return false;
        p.next();
        return p.isIdent() and !p.lx.nl_before and p.t() != .kw_of;
    }

    fn parseVarStmt(p: *Parser, s: u32, mods: Mods) *Node {
        const list = p.parseVarList();
        p.semi();
        const n = p.mk(s, .{ .var_stmt = .{ .list = list } });
        n.mods = mods;
        return n;
    }

    fn parseVarList(p: *Parser) *Node {
        const s = p.lx.start;
        var kind: ast.VarKind = .@"var";
        switch (p.t()) {
            .kw_var => {},
            .kw_let => kind = .let,
            .kw_const => kind = .@"const",
            .kw_using => kind = .using,
            .kw_await => {
                kind = .await_using;
                p.next();
            },
            else => {},
        }
        p.next();
        var decls: NodeList = .empty;
        while (true) {
            if (p.startsBinding()) {
                p.push(&decls, p.parseVarDecl());
                if (p.eat(.comma)) continue;
                if (p.endsVarList()) break;
                p.expect(.comma);
                continue;
            }
            if (p.endsVarList()) break;
            p.errHere(1134, "Variable declaration expected.");
            if (p.t() == .eof or p.t() == .r_brace or p.startsStatement()) break;
            p.next();
        }
        if (decls.items.len == 0 and p.lx.diags.items.len == 0) {
            p.lx.err(p.prev_end, 0, 1123, "Variable declaration list cannot be empty.");
        }
        return p.mk(s, .{ .var_list = .{ .kind = kind, .decls = decls.items } });
    }

    fn startsBinding(p: *const Parser) bool {
        return p.t() == .l_brace or p.t() == .l_bracket or p.t() == .private_name or p.isIdent();
    }

    fn endsVarList(p: *const Parser) bool {
        return p.canSemi() or p.t() == .kw_in or p.t() == .kw_of or p.t() == .arrow;
    }

    fn parseVarDecl(p: *Parser) *Node {
        const s = p.lx.start;
        const name = if (p.t() == .private_name) blk: {
            p.skipBadToken(18029, "Private identifiers are not allowed in variable declarations.");
            break :blk p.mk(s, .{ .identifier = "" });
        } else p.parseBindingName();
        var d = ast.VarDecl{ .name = name };
        d.ann_span.start = p.lx.start;
        if (p.t() == .bang and !p.lx.nl_before) {
            p.next();
            d.excl = true;
            d.ann_span.end = p.prev_end;
        }
        if (p.t() == .colon) {
            if (!d.excl) d.ann_span.start = p.lx.start;
            p.next();
            d.type = p.parseType();
            d.ann_span.end = p.prev_end;
        }
        if (p.eat(.assign)) d.init = p.parseAssignment();
        return p.mk(s, .{ .var_decl = p.box(d) });
    }

    fn parseBindingName(p: *Parser) *Node {
        return switch (p.t()) {
            .l_brace => p.parseObjectPattern(),
            .l_bracket => p.parseArrayPattern(),
            else => p.parseIdent(),
        };
    }

    fn parseObjectPattern(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        var elems: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const es = p.lx.start;
            const dots = p.eat(.dot3);
            var prop: ?*Node = null;
            var name: *Node = undefined;
            if (dots) {
                name = p.parseIdent();
            } else {
                const key = p.parsePropertyName();
                if (p.eat(.colon)) {
                    prop = key;
                    name = p.parseBindingName();
                } else {
                    if (key.data != .identifier) p.errHere(1005, "':' expected.");
                    name = key;
                }
            }
            const in = if (p.eat(.assign)) p.parseAssignmentAllowIn() else null;
            p.push(&elems, p.mk(es, .{ .binding_elem = p.box(ast.BindingElem{ .prop_name = prop, .dotdotdot = dots, .name = name, .init = in }) }));
            if (!p.eat(.comma)) break;
        }
        p.expect(.r_brace);
        return p.mk(s, .{ .object_pattern = .{ .elems = elems.items } });
    }

    fn parseArrayPattern(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        var elems: NodeList = .empty;
        while (p.t() != .r_bracket and p.t() != .eof) {
            const es = p.lx.start;
            if (p.t() == .comma) {
                p.next();
                p.push(&elems, p.mk(es, .omitted_expr));
                continue;
            }
            const dots = p.eat(.dot3);
            const name = p.parseBindingName();
            const in = if (p.eat(.assign)) p.parseAssignmentAllowIn() else null;
            p.push(&elems, p.mk(es, .{ .binding_elem = p.box(ast.BindingElem{ .prop_name = null, .dotdotdot = dots, .name = name, .init = in }) }));
            if (p.lx.start == es) break;
            if (p.t() != .r_bracket) p.expect(.comma);
        }
        p.expect(.r_bracket);
        return p.mk(s, .{ .array_pattern = .{ .elems = elems.items } });
    }

    fn parseAssignmentAllowIn(p: *Parser) *Node {
        const save_in = p.no_in;
        p.no_in = false;
        defer p.no_in = save_in;
        return p.parseAssignment();
    }

    // Declarations

    fn nextOnSameLine(p: *Parser) bool {
        p.next();
        return !p.lx.nl_before;
    }

    fn isDeclarationStart(p: *Parser) bool {
        switch (p.t()) {
            .kw_function, .kw_class, .kw_enum, .at, .kw_const => return true,
            .kw_let => return p.isLetDecl(),
            .kw_using, .kw_await => return p.isUsingDecl(),
            else => {},
        }
        const st = p.save();
        defer p.restore(st);
        while (true) {
            switch (p.t()) {
                .kw_var, .kw_const, .kw_function, .kw_class, .kw_enum, .at => return true,
                .kw_let => return p.isLetDecl(),
                .kw_interface, .kw_type => return p.nextOnSameLine() and p.isIdent(),
                .kw_module, .kw_namespace => {
                    if (!p.nextOnSameLine()) return false;
                    return p.isIdent() or p.t() == .string;
                },
                .kw_abstract, .kw_accessor, .kw_async, .kw_declare, .kw_private, .kw_protected, .kw_public, .kw_readonly, .kw_static, .kw_override => {
                    if (!p.nextOnSameLine()) return false;
                },
                .kw_global => {
                    p.next();
                    return p.t() == .l_brace or p.t() == .kw_export or p.isIdent();
                },
                .kw_import => {
                    p.next();
                    return p.t() == .string or p.t() == .star or p.t() == .l_brace or p.isIdent();
                },
                .kw_export => {
                    p.next();
                    switch (p.tokenAfterType()) {
                        .assign, .star, .l_brace, .kw_default, .kw_as, .at => return true,
                        else => {},
                    }
                },
                else => return false,
            }
        }
    }

    fn tokenAfterType(p: *Parser) Tok {
        if (p.t() != .kw_type) return p.t();
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t();
    }

    fn isTsOnlyModifier(tok: Tok) bool {
        return switch (tok) {
            .kw_declare, .kw_abstract, .kw_public, .kw_private, .kw_protected, .kw_readonly, .kw_override => true,
            else => false,
        };
    }

    fn canFollowModifier(p: *const Parser) bool {
        return switch (p.t()) {
            .l_bracket, .l_brace, .star, .dot3, .private_name, .string, .numeric, .bigint => true,
            else => p.t().isKeyword() or p.t() == .identifier,
        };
    }

    fn modifierApplies(p: *Parser, tok: Tok) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        switch (tok) {
            .kw_export => {
                if (p.t() == .star or p.t() == .kw_as or p.t() == .l_brace or p.t() == .assign or p.t() == .kw_import) return false;
                if (p.t() == .kw_default) {
                    p.next();
                    return p.defaultStartsDeclaration();
                }
                if (p.t() == .kw_type) {
                    p.next();
                    return p.t() != .l_brace and p.t() != .star;
                }
                return p.t() == .at or p.canFollowModifier();
            },
            .kw_default => return p.defaultStartsDeclaration(),
            .kw_const => return p.t() == .kw_enum,
            else => return !p.lx.nl_before and p.canFollowModifier(),
        }
    }

    fn defaultStartsDeclaration(p: *Parser) bool {
        return p.t() == .kw_class or p.t() == .kw_function or p.t() == .kw_interface or
            (p.t() == .kw_abstract and p.nextIsClass()) or (p.t() == .kw_async and p.nextIsFunction());
    }

    fn nextIsClass(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .kw_class;
    }

    fn nextIsFunction(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .kw_function and !p.lx.nl_before;
    }

    fn parseModifiers(p: *Parser) Mods {
        var m = Mods{};
        while (true) {
            const tok = p.t();
            switch (tok) {
                .kw_export, .kw_default, .kw_declare, .kw_abstract, .kw_public, .kw_private, .kw_protected, .kw_static, .kw_readonly, .kw_override, .kw_async, .kw_const, .kw_accessor, .kw_in, .kw_out => {},
                else => break,
            }
            if (!p.modifierApplies(tok)) break;
            switch (tok) {
                .kw_export => m.@"export" = true,
                .kw_default => m.default = true,
                .kw_declare => m.declare = true,
                .kw_abstract => m.abstract = true,
                .kw_public => m.public = true,
                .kw_private => m.private = true,
                .kw_protected => m.protected = true,
                .kw_static => m.static = true,
                .kw_readonly => m.readonly = true,
                .kw_override => m.override = true,
                .kw_async => m.async = true,
                .kw_const => m.@"const" = true,
                .kw_accessor => m.accessor = true,
                .kw_in => m.in = true,
                .kw_out => m.out = true,
                else => unreachable,
            }
            if (isTsOnlyModifier(tok)) p.strip.append(p.a, .{ .start = p.lx.start, .end = p.lx.pos }) catch oom();
            p.next();
        }
        return m;
    }

    fn parseDecorators(p: *Parser) []*Node {
        if (p.t() != .at) return &.{};
        var list: NodeList = .empty;
        while (p.t() == .at) {
            const s = p.lx.start;
            p.next();
            const save_dec = p.in_decorator;
            p.in_decorator = true;
            const e = p.parseLeftHandSide();
            p.in_decorator = save_dec;
            p.push(&list, p.mk(s, .{ .decorator = .{ .expr = e } }));
        }
        return list.items;
    }

    fn parseDeclaration(p: *Parser) *Node {
        const s = p.lx.start;
        const decorators = p.parseDecorators();
        const mods = p.parseModifiers();
        const save_ambient = p.ambient;
        if (mods.declare) p.ambient = true;
        defer p.ambient = save_ambient;
        const n: *Node = switch (p.t()) {
            .kw_var, .kw_let, .kw_const => p.parseVarStmt(s, mods),
            .kw_using, .kw_await => p.parseVarStmt(s, mods),
            .kw_function => p.parseFunction(s, .decl, decorators, mods),
            .kw_class => p.parseClass(s, false, decorators),
            .kw_interface => p.parseInterface(s),
            .kw_type => p.parseTypeAlias(s),
            .kw_enum => p.parseEnum(s),
            .kw_module, .kw_namespace, .kw_global => p.parseModule(s),
            .kw_import => p.parseImport(s),
            .kw_export => p.parseExport(s),
            else => blk: {
                p.errHere(1146, "Declaration expected.");
                break :blk p.mk(s, .empty_stmt);
            },
        };
        n.start = s;
        n.mods = @bitCast(@as(u16, @bitCast(n.mods)) | @as(u16, @bitCast(mods)));
        return n;
    }

    fn parseFunction(p: *Parser, s: u32, kind: ast.FuncKind, decorators: []*Node, mods: Mods) *Node {
        p.next();
        var f = ast.Func{ .kind = kind, .decorators = decorators };
        f.asterisk = p.eat(.star);
        if (kind == .decl or p.t() != .l_paren) {
            if (p.isIdent() or p.t().isIdentifierLike()) {
                f.name = p.identNode();
            } else if (kind == .decl and !mods.default) {
                p.errHere(1003, "Identifier expected.");
            }
        }
        p.parseSignature(&f, mods.async);
        p.parseFunctionBody(&f, mods.async);
        return p.mk(s, .{ .func = p.box(f) });
    }

    fn parseSignature(p: *Parser, f: *ast.Func, is_async: bool) void {
        const save_a = p.in_async;
        const save_g = p.in_gen;
        p.in_async = is_async;
        p.in_gen = f.asterisk;
        f.type_params = p.parseTypeParams();
        f.params = p.parseParams();
        p.in_async = save_a;
        p.in_gen = save_g;
        p.parseReturnAnnotation(f, .colon);
    }

    fn parseReturnAnnotation(p: *Parser, f: *ast.Func, tok: Tok) void {
        if (p.t() == tok) {
            f.ret_span.start = p.lx.start;
            p.next();
            f.ret = p.parseTypeOrPredicate();
            f.ret_span.end = p.prev_end;
        }
    }

    fn parseFunctionBody(p: *Parser, f: *ast.Func, is_async: bool) void {
        if (p.t() != .l_brace) {
            if (p.t() == .semi or p.canSemi()) {
                _ = p.eat(.semi);
                return;
            }
            p.errHere(1144, "'{' or ';' expected.");
            return;
        }
        const save_a = p.in_async;
        const save_g = p.in_gen;
        const save_f = p.in_func;
        const save_in = p.no_in;
        p.in_async = is_async;
        p.in_gen = f.asterisk;
        p.in_func = true;
        p.no_in = false;
        f.body = p.parseFunctionBlock();
        p.in_async = save_a;
        p.in_gen = save_g;
        p.in_func = save_f;
        p.no_in = save_in;
    }

    fn parseFunctionBlock(p: *Parser) *Node {
        return if (p.lazy and !p.ambient and p.t() == .l_brace) p.skipBlock() else p.parseBlock();
    }

    /// Finds where a block ends from its tokens, far cheaper than parsing what is in it. The one
    /// thing tokens leave open is whether a `/` starts a regex; a wrong guess can only matter if
    /// that regex holds quotes or braces, and then lexing fails here or `parseBody` sees it.
    fn skipBlock(p: *Parser) *Node {
        const s = p.lx.start;
        const errors = p.lx.diags.items.len;
        var specs: NodeList = .empty;
        var depth: u32 = 0;
        // The brace depth at which each open template substitution started.
        var subst: [32]u32 = undefined;
        var open: usize = 0;
        var prev: Tok = .semi;
        var tok = p.t();
        while (true) {
            switch (tok) {
                .eof => {
                    p.skip_failed = true;
                    break;
                },
                .l_brace => depth += 1,
                .r_brace => {
                    if (open > 0 and subst[open - 1] == depth) {
                        tok = p.lx.rescanTemplate();
                        if (tok == .template_tail) open -= 1;
                    } else {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                },
                .template_head => {
                    if (open == subst.len) {
                        p.skip_failed = true;
                        break;
                    }
                    subst[open] = depth;
                    open += 1;
                },
                .slash, .slash_assign => if (regexCanFollow(prev)) {
                    tok = p.lx.rescanRegex();
                },
                .kw_import => {
                    const member = prev == .dot or prev == .question_dot;
                    prev = tok;
                    tok = p.lx.next();
                    if (member) continue;
                    if (tok == .dot) {
                        prev = tok;
                        tok = p.lx.next();
                        if (tok == .identifier and std.mem.eql(u8, p.lx.text(), "meta")) p.saw_import_meta = true;
                    } else if (tok == .l_paren) {
                        prev = tok;
                        tok = p.lx.next();
                        if (tok == .string) {
                            const spec = p.mk(p.lx.start, .{ .string_lit = p.lx.value });
                            spec.end = p.lx.pos;
                            p.push(&specs, spec);
                        }
                    } else {
                        p.skip_failed = true;
                    }
                    continue;
                },
                // Whatever these start reaches past the block, so the file has to see it.
                .kw_export, .kw_declare => p.skip_failed = true,
                else => {},
            }
            prev = tok;
            tok = p.lx.next();
        }
        p.next();
        if (p.lx.diags.items.len != errors) p.skip_failed = true;
        return p.mk(s, .{ .lazy_body = .{ .specs = specs.items } });
    }

    fn regexCanFollow(prev: Tok) bool {
        return switch (prev) {
            .numeric, .bigint, .string, .no_subst_template, .template_tail, .regex, .private_name => false,
            .r_paren, .r_bracket, .plus2, .minus2, .kw_this, .kw_super, .kw_null, .kw_true, .kw_false => false,
            else => !prev.isIdentifierLike(),
        };
    }

    fn parseParams(p: *Parser) []*Node {
        p.expect(.l_paren);
        var list: NodeList = .empty;
        const save_in = p.no_in;
        p.no_in = false;
        while (p.t() != .r_paren and p.t() != .eof) {
            const before = p.lx.start;
            p.push(&list, p.parseParam());
            if (p.t() != .r_paren) {
                if (!p.eat(.comma)) {
                    p.expect(.comma);
                    if (p.lx.start == before) break;
                    if (p.t() != .identifier) break;
                }
            }
        }
        p.no_in = save_in;
        p.expect(.r_paren);
        return list.items;
    }

    fn parseParam(p: *Parser) *Node {
        const s = p.lx.start;
        const decorators = p.parseDecorators();
        const mods = p.parseModifiers();
        var d = ast.Param{ .decorators = decorators, .name = undefined };
        d.dotdotdot = p.eat(.dot3);
        d.name = if (p.t() == .kw_this) p.identNode() else p.parseBindingName();
        d.ann_span.start = p.lx.start;
        d.ann_span.end = p.lx.start;
        if (p.t() == .question) {
            p.next();
            d.question = true;
            d.ann_span.end = p.prev_end;
        }
        if (p.t() == .colon) {
            p.next();
            d.type = p.parseType();
            d.ann_span.end = p.prev_end;
        }
        if (p.eat(.assign)) d.init = p.parseAssignment();
        const n = p.mk(s, .{ .param = p.box(d) });
        n.mods = mods;
        return n;
    }

    fn parseHeritage(p: *Parser) []*Node {
        var list: NodeList = .empty;
        while (p.t() == .kw_extends or p.t() == .kw_implements) {
            const s = p.lx.start;
            const tok = p.t();
            p.next();
            var types: NodeList = .empty;
            while (true) {
                const es = p.lx.start;
                const e = p.parseLeftHandSideNoTypeArgs();
                const ta = p.parseOptionalTypeArgs();
                p.push(&types, p.mk(es, .{ .expr_with_type_args = p.box(ast.ExprWithTypeArgs{ .expr = e, .type_args = ta }) }));
                if (!p.eat(.comma)) break;
            }
            p.push(&list, p.mk(s, .{ .heritage_clause = .{ .tok = tok, .types = types.items } }));
        }
        return list.items;
    }

    fn parseLeftHandSideNoTypeArgs(p: *Parser) *Node {
        const s = p.lx.start;
        var e = p.parsePrimary();
        while (true) {
            if (p.t() == .dot) {
                p.next();
                const name = p.parseMemberName();
                e = p.mk(s, .{ .prop_access = .{ .expr = e, .name = name, .optional = false } });
            } else if (p.t() == .l_paren) {
                // Mixin bases: `class A extends Mixin(B) {}`.
                const args = p.parseArgs();
                e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = .{}, .args = args, .optional = false }) });
            } else if (p.t() == .lt) {
                // `class A extends mock<B>() {}`; a plain `extends B<T>` is left to the caller.
                const st = p.save();
                const tl = p.tryTypeArgsInExpr() orelse break;
                if (p.t() != .l_paren) {
                    p.restore(st);
                    break;
                }
                const args = p.parseArgs();
                e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = tl, .args = args, .optional = false }) });
            } else break;
        }
        return e;
    }

    fn parseOptionalTypeArgs(p: *Parser) ast.TypeList {
        p.lx.rescanLessThan();
        if (p.t() != .lt) return .{};
        return p.parseTypeArgs();
    }

    fn parseClass(p: *Parser, s: u32, is_expr: bool, decorators: []*Node) *Node {
        p.next();
        var c = ast.Class{ .is_expr = is_expr, .decorators = decorators };
        if (p.isIdent() and p.t() != .kw_implements and p.t() != .kw_extends) c.name = p.identNode();
        c.type_params = p.parseTypeParams();
        c.heritage = p.parseHeritage();
        p.expect(.l_brace);
        var members: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const before = p.lx.start;
            p.push(&members, p.parseClassMember());
            if (p.lx.start == before) p.skipBadToken(1068, "Unexpected token. A constructor, method, accessor, or property was expected.");
        }
        p.expect(.r_brace);
        c.members = members.items;
        return p.mk(s, .{ .class = p.box(c) });
    }

    fn isIndexSignature(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.t() == .dot3 or p.t() == .r_bracket) return true;
        if (Parser.isTsOnlyModifier(p.t())) {
            p.next();
            return p.isIdent();
        }
        if (!p.isIdent()) return false;
        p.next();
        if (p.t() == .colon or p.t() == .comma) return true;
        if (p.t() != .question) return false;
        p.next();
        return p.t() == .colon or p.t() == .comma or p.t() == .r_bracket;
    }

    fn parseIndexSig(p: *Parser, s: u32, mods: Mods) *Node {
        p.next();
        var params: NodeList = .empty;
        while (p.t() != .r_bracket and p.t() != .eof) {
            p.push(&params, p.parseParam());
            if (!p.eat(.comma)) break;
        }
        p.expect(.r_bracket);
        var ty: ?*Node = null;
        if (p.eat(.colon)) ty = p.parseType();
        p.typeMemberEnd();
        const n = p.mk(s, .{ .index_sig = .{ .params = params.items, .type = ty } });
        n.mods = mods;
        return n;
    }

    fn typeMemberEnd(p: *Parser) void {
        if (p.eat(.semi) or p.eat(.comma)) return;
        if (p.t() == .r_brace or p.t() == .eof or p.lx.nl_before) return;
        p.errHere(1005, "';' expected.");
    }

    fn isAccessorStart(p: *Parser) bool {
        if (p.t() != .kw_get and p.t() != .kw_set) return false;
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.isPropertyNameStart();
    }

    fn parseClassMember(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.eat(.semi)) return p.mk(s, .semicolon_member);
        const decorators = p.parseDecorators();
        const mods = p.parseModifiers();
        const n = p.parseClassMemberRest(s, decorators, mods);
        n.mods = mods;
        n.start = s;
        return n;
    }

    fn isCtorStart(p: *Parser) bool {
        const is_ctor = p.t() == .kw_constructor or (p.t() == .string and std.mem.eql(u8, p.lx.value, "constructor"));
        if (!is_ctor) return false;
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .l_paren or p.t() == .lt;
    }

    fn parseClassMemberRest(p: *Parser, s: u32, decorators: []*Node, mods: Mods) *Node {
        if (mods.static and p.t() == .l_brace) {
            const save_f = p.in_func;
            p.in_func = true;
            const body = p.parseBlock();
            p.in_func = save_f;
            return p.mk(s, .{ .static_block = .{ .body = body } });
        }
        if (p.isAccessorStart()) {
            const kind: ast.FuncKind = if (p.t() == .kw_get) .getter else .setter;
            p.next();
            var f = ast.Func{ .kind = kind, .decorators = decorators };
            f.name = p.parsePropertyName();
            p.parseSignature(&f, false);
            p.parseFunctionBody(&f, false);
            return p.mk(s, .{ .func = p.box(f) });
        }
        if (p.isCtorStart()) {
            var f = ast.Func{ .kind = .ctor, .decorators = decorators };
            p.next();
            p.parseSignature(&f, false);
            p.parseFunctionBody(&f, false);
            return p.mk(s, .{ .func = p.box(f) });
        }
        if (p.t() == .l_bracket and p.isIndexSignature()) return p.parseIndexSig(s, mods);
        const asterisk = p.eat(.star);
        if (!asterisk and !p.isPropertyNameStart()) {
            p.errHere(1068, "Unexpected token. A constructor, method, accessor, or property was expected.");
            return p.mk(s, .semicolon_member);
        }
        const name = p.parsePropertyName();
        const q_pos = p.lx.start;
        const question = p.eat(.question);
        if (asterisk or p.t() == .l_paren or p.t() == .lt) {
            var f = ast.Func{ .kind = .method, .decorators = decorators, .name = name, .asterisk = asterisk, .question = question, .q_pos = q_pos };
            p.parseSignature(&f, mods.async);
            p.parseFunctionBody(&f, mods.async);
            return p.mk(s, .{ .func = p.box(f) });
        }
        var d = ast.Property{ .decorators = decorators, .name = name, .question = question };
        d.ann_span = .{ .start = q_pos, .end = q_pos };
        if (question) d.ann_span.end = p.prev_end;
        if (!question and p.t() == .bang and !p.lx.nl_before) {
            p.next();
            d.excl = true;
            d.ann_span.end = p.prev_end;
        }
        if (p.t() == .colon) {
            p.next();
            d.type = p.parseType();
            d.ann_span.end = p.prev_end;
        }
        if (p.t() == .assign) {
            p.next();
            const save_f = p.in_func;
            p.in_func = true;
            d.init = p.parseAssignmentAllowIn();
            p.in_func = save_f;
        }
        p.semi();
        return p.mk(s, .{ .property_decl = p.box(d) });
    }

    fn parseInterface(p: *Parser, s: u32) *Node {
        p.next();
        var d = ast.Interface{ .name = undefined };
        d.name = p.parseIdent();
        d.type_params = p.parseTypeParams();
        d.heritage = p.parseHeritage();
        d.members = p.parseTypeMembers();
        return p.mk(s, .{ .interface = p.box(d) });
    }

    fn parseTypeAlias(p: *Parser, s: u32) *Node {
        p.next();
        const name = p.parseIdent();
        const tp = p.parseTypeParams();
        p.expect(.assign);
        const ty = if (p.t() == .kw_intrinsic and p.isIntrinsicAlias()) blk: {
            const is = p.lx.start;
            p.next();
            break :blk p.mk(is, .{ .kw_type = .intrinsic });
        } else p.parseType();
        p.semi();
        return p.mk(s, .{ .type_alias = p.box(ast.TypeAlias{ .name = name, .type_params = tp, .type = ty }) });
    }

    fn isIntrinsicAlias(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() != .dot;
    }

    fn parseEnum(p: *Parser, s: u32) *Node {
        p.next();
        const name = p.parseIdent();
        p.expect(.l_brace);
        var members: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const ms = p.lx.start;
            const mn = p.parsePropertyName();
            if (mn.data == .computed_name) p.lx.err(mn.start, mn.end - mn.start, 1164, "Computed property names are not allowed in enums.");
            const in = if (p.eat(.assign)) p.parseAssignmentAllowIn() else null;
            p.push(&members, p.mk(ms, .{ .enum_member = .{ .name = mn, .init = in } }));
            if (!p.eat(.comma)) break;
        }
        p.expect(.r_brace);
        return p.mk(s, .{ .enum_decl = .{ .name = name, .members = members.items } });
    }

    fn parseModule(p: *Parser, s: u32) *Node {
        if (p.t() == .kw_global) {
            const name = p.identNode();
            const body = p.parseModuleBlock();
            return p.mk(s, .{ .module_decl = .{ .name = name, .body = body, .is_global = true, .is_namespace = false } });
        }
        const is_ns = p.t() == .kw_namespace;
        p.next();
        if (p.t() == .string) {
            const name = p.stringNode();
            var body: ?*Node = null;
            if (p.t() == .l_brace) body = p.parseModuleBlock() else p.semi();
            return p.mk(s, .{ .module_decl = .{ .name = name, .body = body, .is_global = false, .is_namespace = false } });
        }
        return p.parseNamespaceRest(s, is_ns);
    }

    /// `namespace A.B {}` nests one module per segment, as tsc does.
    fn parseNamespaceRest(p: *Parser, s: u32, is_ns: bool) *Node {
        const name = p.parseIdent();
        const body = if (p.t() == .dot) blk: {
            p.next();
            break :blk p.parseNamespaceRest(p.lx.start, is_ns);
        } else p.parseModuleBlock();
        return p.mk(s, .{ .module_decl = .{ .name = name, .body = body, .is_global = false, .is_namespace = is_ns } });
    }

    fn parseModuleBlock(p: *Parser) *Node {
        const s = p.lx.start;
        p.expect(.l_brace);
        const stmts = p.parseStatementsUntil(.r_brace);
        p.expect(.r_brace);
        return p.mk(s, .{ .module_block = .{ .stmts = stmts } });
    }

    fn parseAttrs(p: *Parser) ?*Node {
        if ((p.t() == .kw_with or p.t() == .kw_assert) and !p.lx.nl_before) {
            p.next();
            return p.parseObjectLiteral();
        }
        return null;
    }

    fn parseModuleSpecifier(p: *Parser) *Node {
        if (p.t() == .string) return p.stringNode();
        p.errHere(1141, "String literal expected.");
        return p.mk(p.lx.start, .{ .string_lit = "" });
    }

    fn isTypeOnlyImportStart(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.t() == .l_brace or p.t() == .star) return true;
        if (p.t() == .kw_from) {
            p.next();
            return p.t() == .kw_from or p.t() == .assign;
        }
        return p.isIdent();
    }

    fn parseImport(p: *Parser, s: u32) *Node {
        p.next();
        if (p.t() == .string) {
            const spec = p.stringNode();
            const attrs = p.parseAttrs();
            p.semi();
            return p.mk(s, .{ .import_decl = .{ .clause = null, .specifier = spec, .attrs = attrs } });
        }
        const cs = p.lx.start;
        var type_only = false;
        if (p.t() == .kw_type and p.isTypeOnlyImportStart()) {
            type_only = true;
            p.next();
        }
        var name: ?*Node = null;
        if (p.isIdent()) {
            name = p.identNode();
            if (p.t() == .assign) return p.parseImportEquals(s, name.?, type_only);
        }
        var bindings: ?*Node = null;
        if (name == null or p.eat(.comma)) {
            if (p.t() == .star) {
                const ns = p.lx.start;
                p.next();
                p.expect(.kw_as);
                const local = p.parseIdent();
                bindings = p.mk(ns, .{ .namespace_import = .{ .name = local } });
            } else if (p.t() == .l_brace) {
                const ns = p.lx.start;
                p.next();
                const elems = p.parseSpecifiers(true);
                bindings = p.mk(ns, .{ .named_imports = .{ .elems = elems } });
            } else {
                p.errHere(1003, "Identifier expected.");
            }
        }
        const clause = p.mk(cs, .{ .import_clause = .{ .name = name, .bindings = bindings, .type_only = type_only } });
        p.expect(.kw_from);
        const spec = p.parseModuleSpecifier();
        const attrs = p.parseAttrs();
        p.semi();
        return p.mk(s, .{ .import_decl = .{ .clause = clause, .specifier = spec, .attrs = attrs } });
    }

    fn parseImportEquals(p: *Parser, s: u32, name: *Node, type_only: bool) *Node {
        p.next();
        const rs = p.lx.start;
        var ref: *Node = undefined;
        if (p.t() == .kw_require and p.nextIsParen()) {
            p.next();
            p.next();
            const e = p.parseModuleSpecifier();
            p.expect(.r_paren);
            ref = p.mk(rs, .{ .external_module_ref = .{ .expr = e } });
        } else {
            ref = p.parseEntityName();
        }
        p.semi();
        return p.mk(s, .{ .import_equals = .{ .name = name, .ref = ref, .type_only = type_only } });
    }

    fn nextIsParen(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .l_paren;
    }

    fn parseModuleExportName(p: *Parser) *Node {
        return if (p.t() == .string) p.stringNode() else p.parseIdentName();
    }

    fn parseSpecifiers(p: *Parser, is_import: bool) []*Node {
        var list: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const s = p.lx.start;
            var type_only = false;
            if (p.t() == .kw_type and p.isTypeOnlySpecifier()) {
                type_only = true;
                p.next();
            }
            var first = p.parseModuleExportName();
            var prop: ?*Node = null;
            if (p.eat(.kw_as)) {
                prop = first;
                first = p.parseModuleExportName();
            }
            const d: Data = if (is_import)
                .{ .import_spec = .{ .prop_name = prop, .name = first, .type_only = type_only } }
            else
                .{ .export_spec = .{ .prop_name = prop, .name = first, .type_only = type_only } };
            p.push(&list, p.mk(s, d));
            if (!p.eat(.comma)) break;
        }
        p.expect(.r_brace);
        return list.items;
    }

    /// `{ type }`, `{ type as x }` and `{ type as as x }` all differ; only the token after `type` tells.
    fn isTypeOnlySpecifier(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.t() == .comma or p.t() == .r_brace) return false;
        if (p.t() == .kw_as) {
            p.next();
            if (p.t() == .comma or p.t() == .r_brace) return true;
            if (p.t() != .kw_as) return false;
            p.next();
            return p.t() == .comma or p.t() == .r_brace;
        }
        return true;
    }

    fn parseExport(p: *Parser, s: u32) *Node {
        p.next();
        var type_only = false;
        switch (p.t()) {
            .assign => {
                p.next();
                const e = p.parseAssignment();
                p.semi();
                return p.mk(s, .{ .export_assign = .{ .expr = e, .is_equals = true } });
            },
            .kw_default => {
                p.next();
                const e = p.parseAssignment();
                p.semi();
                return p.mk(s, .{ .export_assign = .{ .expr = e, .is_equals = false } });
            },
            .kw_as => {
                p.next();
                p.expect(.kw_namespace);
                const name = p.parseIdent();
                p.semi();
                return p.mk(s, .{ .namespace_export_decl = .{ .name = name } });
            },
            .kw_import => {
                const inner = p.parseImport(s);
                inner.mods.@"export" = true;
                return inner;
            },
            .kw_type => {
                type_only = true;
                p.next();
            },
            else => {},
        }
        const cs = p.lx.start;
        var clause: ?*Node = null;
        if (p.t() == .star) {
            p.next();
            if (p.eat(.kw_as)) {
                const name = p.parseModuleExportName();
                clause = p.mk(cs, .{ .namespace_export = .{ .name = name } });
            }
        } else {
            p.expect(.l_brace);
            const elems = p.parseSpecifiers(false);
            clause = p.mk(cs, .{ .named_exports = .{ .elems = elems } });
        }
        var spec: ?*Node = null;
        var attrs: ?*Node = null;
        if (p.eat(.kw_from)) {
            spec = p.parseModuleSpecifier();
            attrs = p.parseAttrs();
        }
        p.semi();
        return p.mk(s, .{ .export_decl = p.box(ast.ExportDecl{ .clause = clause, .specifier = spec, .type_only = type_only, .attrs = attrs }) });
    }

    // Expressions

    pub fn parseExpression(p: *Parser) *Node {
        const s = p.lx.start;
        var e = p.parseAssignment();
        while (p.t() == .comma) {
            p.next();
            const r = p.parseAssignment();
            e = p.mk(s, .{ .binary = .{ .left = e, .op = .comma, .right = r } });
        }
        return e;
    }

    fn parseAssignment(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.t() == .kw_yield and p.in_gen) return p.parseYield();
        if (p.t() == .l_paren or p.t() == .lt or p.t() == .kw_async) {
            if (p.tryParseArrow()) |arrow| return arrow;
        }
        if (p.isIdent() and p.t() != .kw_async) {
            if (p.simpleArrowFollows()) return p.parseSimpleArrow(s, false);
        }
        const e = p.parseBinary(0);
        const tok = p.lx.rescanGreater();
        if (tok.isAssignment() and isLeftHandSide(e)) {
            p.next();
            const r = p.parseAssignment();
            return p.mk(s, .{ .binary = .{ .left = e, .op = tok, .right = r } });
        }
        if (tok == .question) {
            p.next();
            const save_in = p.no_in;
            const save_no_ret = p.no_arrow_ret;
            p.no_in = false;
            p.no_arrow_ret = true;
            const then = p.parseAssignment();
            p.no_in = save_in;
            p.no_arrow_ret = save_no_ret;
            p.expect(.colon);
            const els = p.parseAssignment();
            return p.mk(s, .{ .conditional = .{ .cond = e, .then = then, .els = els } });
        }
        return e;
    }

    fn isLeftHandSide(e: *const Node) bool {
        return switch (e.data) {
            .identifier, .prop_access, .elem_access, .array_lit, .object_lit, .non_null, .paren, .as_expr, .satisfies_expr, .type_assertion, .call, .this_expr, .super_expr => true,
            else => false,
        };
    }

    fn parseYield(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        var star = false;
        var e: ?*Node = null;
        if (!p.lx.nl_before) {
            star = p.eat(.star);
            if (star or p.isStartOfExpression()) e = p.parseAssignment();
        }
        return p.mk(s, .{ .yield_expr = .{ .expr = e, .star = star } });
    }

    fn isStartOfExpression(p: *const Parser) bool {
        return switch (p.t()) {
            .r_paren, .r_bracket, .r_brace, .colon, .semi, .comma, .eof, .kw_in, .kw_of => false,
            else => true,
        };
    }

    fn simpleArrowFollows(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .arrow and !p.lx.nl_before;
    }

    fn parseSimpleArrow(p: *Parser, s: u32, is_async: bool) *Node {
        const ps = p.lx.start;
        const name = p.identNode();
        const param = p.mk(ps, .{ .param = p.box(ast.Param{ .name = name, .ann_span = .{ .start = name.end, .end = name.end } }) });
        param.parent = null;
        const params = p.a.alloc(*Node, 1) catch oom();
        params[0] = param;
        var f = ast.Func{ .kind = .arrow, .params = params };
        p.expect(.arrow);
        p.parseArrowBody(&f, is_async);
        const n = p.mk(s, .{ .func = p.box(f) });
        n.mods.async = is_async;
        return n;
    }

    fn parseArrowBody(p: *Parser, f: *ast.Func, is_async: bool) void {
        const save_a = p.in_async;
        const save_g = p.in_gen;
        const save_f = p.in_func;
        p.in_async = is_async;
        p.in_gen = false;
        p.in_func = true;
        // A statement that no expression can start means the `{` went missing.
        if (p.t() == .l_brace or p.startsPlainStatement()) {
            const save_in = p.no_in;
            p.no_in = false;
            f.body = p.parseFunctionBlock();
            p.no_in = save_in;
        } else {
            f.body = p.parseAssignment();
        }
        p.in_async = save_a;
        p.in_gen = save_g;
        p.in_func = save_f;
    }

    fn startsPlainStatement(p: *const Parser) bool {
        return switch (p.t()) {
            .kw_var, .kw_const, .kw_if, .kw_do, .kw_while, .kw_for, .kw_continue, .kw_break, .kw_return => true,
            .kw_with, .kw_switch, .kw_throw, .kw_try, .kw_debugger, .kw_catch, .kw_finally => true,
            else => false,
        };
    }

    /// False rules an arrow out; true means it can only be one; null means parse to find out.
    fn arrowLookahead(p: *Parser) ?bool {
        const st = p.save();
        defer p.restore(st);
        if (p.t() == .kw_async) {
            p.next();
            if (p.lx.nl_before) return false;
            if (p.t() != .l_paren and p.t() != .lt) return false;
        }
        if (p.t() == .lt) {
            if (!p.tsx) return null;
            p.next();
            if (p.t() == .kw_const) return true;
            if (!p.isIdent()) return false;
            p.next();
            if (p.t() == .kw_extends) {
                p.next();
                return switch (p.t()) {
                    .assign, .gt, .slash => false,
                    else => true,
                };
            }
            return p.t() == .comma or p.t() == .assign;
        }
        p.next();
        switch (p.t()) {
            .r_paren => {
                p.next();
                return p.t() == .arrow or p.t() == .colon or p.t() == .l_brace;
            },
            .l_bracket, .l_brace => return null,
            .dot3 => return true,
            else => {},
        }
        if (p.t() == .at) return null;
        if (isTsOnlyModifier(p.t())) {
            const m = p.save();
            p.next();
            const is_param = p.isIdent();
            p.restore(m);
            if (is_param) return true;
        }
        if (!p.isIdent() and p.t() != .kw_this) return false;
        p.next();
        switch (p.t()) {
            .colon => return true,
            .question => {
                p.next();
                return if (p.t() == .colon or p.t() == .comma or p.t() == .assign or p.t() == .r_paren) true else false;
            },
            .comma, .assign, .r_paren => return null,
            else => return false,
        }
    }

    fn tryParseArrow(p: *Parser) ?*Node {
        const s = p.lx.start;
        if (p.t() == .kw_async) {
            const st = p.save();
            p.next();
            if (!p.lx.nl_before and p.isIdent() and p.t() != .kw_async and p.simpleArrowFollows()) {
                return p.parseSimpleArrow(s, true);
            }
            p.restore(st);
        }
        const verdict = p.arrowLookahead();
        if (verdict != null and !verdict.?) return null;
        if (p.not_arrow.contains(s)) return null;
        const st = p.save();
        const diags = p.lx.diags.items.len;
        const is_async = p.t() == .kw_async;
        if (is_async) p.next();
        var f = ast.Func{ .kind = .arrow };
        const save_a = p.in_async;
        p.in_async = is_async;
        f.type_params = p.parseTypeParams();
        f.params = p.parseParams();
        p.in_async = save_a;
        p.parseReturnAnnotation(&f, .colon);
        if (p.t() != .arrow or p.lx.nl_before or p.lx.diags.items.len != diags) {
            if (verdict == null or p.t() != .arrow) {
                p.not_arrow.put(p.a, s, {}) catch oom();
                p.restore(st);
                return null;
            }
        }
        p.next();
        p.parseArrowBody(&f, is_async);
        // Inside `a ? (b): c => d : e` the `: c` belongs to the conditional unless a `:` still follows.
        if (p.no_arrow_ret and f.ret != null and p.t() != .colon) {
            p.not_arrow.put(p.a, s, {}) catch oom();
            p.restore(st);
            return null;
        }
        const n = p.mk(s, .{ .func = p.box(f) });
        n.mods.async = is_async;
        return n;
    }

    fn binaryPrec(p: *Parser, tok: Tok) u8 {
        return switch (tok) {
            .qq => 1,
            .pipe2 => 2,
            .amp2 => 3,
            .pipe => 4,
            .caret => 5,
            .amp => 6,
            .eq2, .neq, .eq3, .neq3 => 7,
            .lt, .gt, .lte, .gte, .kw_instanceof, .kw_as, .kw_satisfies => 8,
            .kw_in => if (p.no_in) 0 else 8,
            .shl, .shr, .ushr => 9,
            .plus, .minus => 10,
            .star, .slash, .percent => 11,
            .star2 => 12,
            else => 0,
        };
    }

    fn parseBinary(p: *Parser, min: u8) *Node {
        const s = p.lx.start;
        var left = p.parseUnary();
        while (true) {
            const tok = p.lx.rescanGreater();
            const prec = p.binaryPrec(tok);
            if (prec == 0 or prec <= min) break;
            if (tok == .kw_as or tok == .kw_satisfies) {
                if (p.lx.nl_before) break;
                p.next();
                const ty = p.parseType();
                left = if (tok == .kw_as)
                    p.mk(s, .{ .as_expr = .{ .expr = left, .type = ty } })
                else
                    p.mk(s, .{ .satisfies_expr = .{ .expr = left, .type = ty } });
                continue;
            }
            p.next();
            const right = p.parseBinary(if (tok == .star2) prec - 1 else prec);
            left = p.mk(s, .{ .binary = .{ .left = left, .op = tok, .right = right } });
        }
        return left;
    }

    fn parseUnary(p: *Parser) *Node {
        const s = p.lx.start;
        switch (p.t()) {
            .plus, .minus, .tilde, .bang, .plus2, .minus2 => {
                const op = p.t();
                p.next();
                const e = p.parseUnary();
                return p.mk(s, .{ .prefix = .{ .op = op, .expr = e } });
            },
            .kw_typeof => {
                p.next();
                const e = p.parseUnary();
                return p.mk(s, .{ .typeof_expr = .{ .expr = e } });
            },
            .kw_void => {
                p.next();
                const e = p.parseUnary();
                return p.mk(s, .{ .void_expr = .{ .expr = e } });
            },
            .kw_delete => {
                p.next();
                const e = p.parseUnary();
                return p.mk(s, .{ .delete_expr = .{ .expr = e } });
            },
            .kw_await => if (p.isAwaitExpr()) {
                p.next();
                const e = p.parseUnary();
                return p.mk(s, .{ .await_expr = .{ .expr = e } });
            },
            .lt => {
                if (!p.tsx) {
                    p.next();
                    const ty = p.parseType();
                    p.expect(.gt);
                    const e = p.parseUnary();
                    return p.mk(s, .{ .type_assertion = .{ .type = ty, .expr = e } });
                }
                return p.parseJsx(false);
            },
            else => {},
        }
        var e = p.parseLeftHandSide();
        if ((p.t() == .plus2 or p.t() == .minus2) and !p.lx.nl_before) {
            const op = p.t();
            p.next();
            e = p.mk(s, .{ .postfix = .{ .expr = e, .op = op } });
        }
        return e;
    }

    fn isAwaitExpr(p: *Parser) bool {
        if (p.in_async) return true;
        // Top-level await: outside any function, `await` followed by an expression start is the operator.
        if (p.in_func) return false;
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.lx.nl_before) return false;
        return switch (p.t()) {
            .identifier, .kw_new, .kw_this, .string, .numeric, .l_paren, .l_bracket, .kw_import, .no_subst_template, .template_head, .kw_await => true,
            else => p.t().isIdentifierLike(),
        };
    }

    fn parseMemberName(p: *Parser) *Node {
        if (p.t() == .private_name) {
            const s = p.lx.start;
            const v = p.lx.value;
            p.next();
            return p.mk(s, .{ .private_name = v });
        }
        return p.parseIdentName();
    }

    fn parseLeftHandSide(p: *Parser) *Node {
        const s = p.lx.start;
        const base = if (p.t() == .kw_new) p.parseNew() else p.parsePrimary();
        return p.parseCallChain(s, base, true);
    }

    fn canFollowTypeArgs(p: *const Parser) bool {
        return switch (p.t()) {
            .l_paren, .no_subst_template, .template_head => true,
            .lt, .gt, .plus, .minus => false,
            else => p.lx.nl_before or p.binaryPrec2() > 0 or !p.isStartOfExpression() or p.isBinaryKeyword(),
        };
    }

    fn isBinaryKeyword(p: *const Parser) bool {
        return p.t() == .kw_as or p.t() == .kw_satisfies or p.t() == .kw_in or p.t() == .kw_instanceof;
    }

    fn binaryPrec2(p: *const Parser) u8 {
        return switch (p.t()) {
            .qq, .pipe2, .amp2, .pipe, .caret, .amp, .eq2, .neq, .eq3, .neq3, .lte, .gte, .shl, .shr, .ushr, .star, .slash, .percent, .star2 => 1,
            else => if (p.t().isAssignment()) 1 else 0,
        };
    }

    fn tryTypeArgsInExpr(p: *Parser) ?ast.TypeList {
        const st = p.save();
        const diags = p.lx.diags.items.len;
        p.lx.rescanLessThan();
        const tl = p.parseTypeArgs();
        if (p.lx.diags.items.len != diags or !p.canFollowTypeArgs()) {
            p.restore(st);
            return null;
        }
        return tl;
    }

    fn parseCallChain(p: *Parser, s: u32, base: *Node, allow_call: bool) *Node {
        var e = base;
        while (true) {
            switch (p.t()) {
                .dot, .question_dot => {
                    const optional = p.t() == .question_dot;
                    p.next();
                    if (optional and p.t() == .l_paren) {
                        const args = p.parseArgs();
                        e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = .{}, .args = args, .optional = true }) });
                    } else if (optional and p.t() == .l_bracket) {
                        p.next();
                        const idx = p.parseExpressionAllowIn();
                        p.expect(.r_bracket);
                        e = p.mk(s, .{ .elem_access = .{ .expr = e, .index = idx, .optional = true } });
                    } else if (optional and (p.t() == .lt or p.t() == .shl)) {
                        const tl = p.tryTypeArgsInExpr() orelse return e;
                        const args = p.parseArgs();
                        e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = tl, .args = args, .optional = true }) });
                    } else {
                        const name = p.parseMemberName();
                        e = p.mk(s, .{ .prop_access = .{ .expr = e, .name = name, .optional = optional } });
                    }
                },
                .l_bracket => {
                    if (p.in_decorator) return e;
                    p.next();
                    var idx: *Node = undefined;
                    if (p.t() == .r_bracket) {
                        p.errHere(1011, "An element access expression should take an argument.");
                        idx = p.mk(p.lx.start, .{ .identifier = "" });
                    } else idx = p.parseExpressionAllowIn();
                    p.expect(.r_bracket);
                    e = p.mk(s, .{ .elem_access = .{ .expr = e, .index = idx, .optional = false } });
                },
                .bang => {
                    if (p.lx.nl_before) return e;
                    p.next();
                    e = p.mk(s, .{ .non_null = .{ .expr = e } });
                },
                .no_subst_template, .template_head => {
                    const tpl = p.parseTemplate(true);
                    e = p.mk(s, .{ .tagged_template = p.box(ast.TaggedTemplate{ .tag = e, .type_args = .{}, .template = tpl }) });
                },
                .l_paren => {
                    if (!allow_call) return e;
                    const args = p.parseArgs();
                    e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = .{}, .args = args, .optional = false }) });
                },
                .lt, .shl => {
                    const tl = p.tryTypeArgsInExpr() orelse return e;
                    if (p.t() == .l_paren and allow_call) {
                        const args = p.parseArgs();
                        e = p.mk(s, .{ .call = p.box(ast.Call{ .callee = e, .type_args = tl, .args = args, .optional = false }) });
                    } else if (p.t() == .no_subst_template or p.t() == .template_head) {
                        const tpl = p.parseTemplate(true);
                        e = p.mk(s, .{ .tagged_template = p.box(ast.TaggedTemplate{ .tag = e, .type_args = tl, .template = tpl }) });
                    } else if (p.t() == .l_paren) {
                        // `new Foo<T>(x)`: the caller consumes the arguments.
                        p.pending_new_args = tl;
                        return e;
                    } else {
                        // Instantiation expression `f<T>`; at run time it is just `f`.
                        e = p.mk(s, .{ .expr_with_type_args = p.box(ast.ExprWithTypeArgs{ .expr = e, .type_args = tl }) });
                    }
                },
                else => return e,
            }
        }
    }

    fn parseNew(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        if (p.t() == .dot) {
            p.next();
            const name = p.parseIdentName();
            return p.mk(s, .{ .meta_property = .{ .keyword = .kw_new, .name = name.data.identifier } });
        }
        const cs = p.lx.start;
        const base = if (p.t() == .kw_new) p.parseNew() else p.parsePrimary();
        const callee = p.parseCallChain(cs, base, false);
        var ta: ast.TypeList = .{};
        if (p.pending_new_args) |tl| {
            ta = tl;
            p.pending_new_args = null;
        }
        const args: []*Node = if (p.t() == .l_paren) p.parseArgs() else &.{};
        return p.mk(s, .{ .new_expr = p.box(ast.NewExpr{ .callee = callee, .type_args = ta, .args = args }) });
    }

    fn parseArgs(p: *Parser) []*Node {
        p.expect(.l_paren);
        const save_in = p.no_in;
        const save_dec = p.in_decorator;
        const save_no_ret = p.no_arrow_ret;
        p.no_in = false;
        p.in_decorator = false;
        p.no_arrow_ret = false;
        var list: NodeList = .empty;
        while (p.t() != .r_paren and p.t() != .eof) {
            const s = p.lx.start;
            if (p.eat(.dot3)) {
                const e = p.parseAssignment();
                p.push(&list, p.mk(s, .{ .spread_elem = .{ .expr = e } }));
            } else {
                p.push(&list, p.parseAssignment());
            }
            if (p.t() != .r_paren and !p.eat(.comma)) {
                p.expect(.r_paren);
                p.no_in = save_in;
                p.in_decorator = save_dec;
                p.no_arrow_ret = save_no_ret;
                return list.items;
            }
        }
        p.no_in = save_in;
        p.in_decorator = save_dec;
        p.no_arrow_ret = save_no_ret;
        p.expect(.r_paren);
        return list.items;
    }

    fn parseTemplate(p: *Parser, tagged: bool) *Node {
        const s = p.lx.start;
        if (!tagged) p.lx.commitTemplateEscapes();
        if (p.t() == .no_subst_template) {
            const v = p.lx.value;
            p.next();
            return p.mk(s, .{ .no_subst_template = v });
        }
        const head = p.lx.value;
        p.next();
        var spans: NodeList = .empty;
        while (true) {
            const ss = p.lx.start;
            const e = p.parseExpressionAllowIn();
            if (p.t() != .r_brace) {
                p.errHere(1005, "'}' expected.");
                break;
            }
            const tok = p.lx.rescanTemplate();
            if (!tagged) p.lx.commitTemplateEscapes();
            const text = p.lx.value;
            p.next();
            p.push(&spans, p.mk(ss, .{ .template_span = .{ .expr = e, .text = text } }));
            if (tok != .template_middle) break;
        }
        return p.mk(s, .{ .template_expr = p.box(ast.TemplateExpr{ .head = head, .spans = spans.items }) });
    }

    fn parsePrimary(p: *Parser) *Node {
        // Brackets of any kind end the `a ? (b): c => d` ambiguity for what is inside them.
        const save_no_ret = p.no_arrow_ret;
        defer p.no_arrow_ret = save_no_ret;
        p.no_arrow_ret = false;
        const s = p.lx.start;
        switch (p.t()) {
            .numeric => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .numeric_lit = v });
            },
            .bigint => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .bigint_lit = v });
            },
            .string => return p.stringNode(),
            .no_subst_template, .template_head => return p.parseTemplate(false),
            .kw_this => {
                p.next();
                return p.mk(s, .this_expr);
            },
            .kw_super => {
                p.next();
                return p.mk(s, .super_expr);
            },
            .kw_null => {
                p.next();
                return p.mk(s, .null_lit);
            },
            .kw_true => {
                p.next();
                return p.mk(s, .true_lit);
            },
            .kw_false => {
                p.next();
                return p.mk(s, .false_lit);
            },
            .kw_import => {
                p.next();
                if (p.t() == .dot) {
                    p.next();
                    const name = p.parseIdentName();
                    p.saw_import_meta = true;
                    return p.mk(s, .{ .meta_property = .{ .keyword = .kw_import, .name = name.data.identifier } });
                }
                return p.mk(s, .import_kw);
            },
            .l_paren => {
                p.next();
                const e = p.parseExpressionAllowIn();
                p.expect(.r_paren);
                return p.mk(s, .{ .paren = .{ .expr = e } });
            },
            .l_bracket => return p.parseArrayLiteral(),
            .l_brace => return p.parseObjectLiteral(),
            .kw_function => return p.parseFunctionExpr(s, false),
            .kw_class => return p.parseClass(s, true, &.{}),
            .at => {
                const d = p.parseDecorators();
                return p.parseClass(s, true, d);
            },
            .kw_async => {
                if (p.nextIsFunction()) {
                    p.next();
                    return p.parseFunctionExpr(s, true);
                }
                return p.identNode();
            },
            .slash, .slash_assign => {
                _ = p.lx.rescanRegex();
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .regex_lit = v });
            },
            .private_name => {
                const v = p.lx.value;
                p.next();
                return p.mk(s, .{ .private_name = v });
            },
            else => {},
        }
        if (p.isIdent()) return p.identNode();
        p.errHere(1109, "Expression expected.");
        return p.mk(s, .{ .identifier = "" });
    }

    fn parseFunctionExpr(p: *Parser, s: u32, is_async: bool) *Node {
        var mods = Mods{};
        mods.async = is_async;
        const n = p.parseFunction(s, .expr, &.{}, mods);
        n.mods = mods;
        return n;
    }

    fn parseArrayLiteral(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        const save_in = p.no_in;
        p.no_in = false;
        var list: NodeList = .empty;
        while (p.t() != .r_bracket and p.t() != .eof) {
            const es = p.lx.start;
            if (p.t() == .comma) {
                p.next();
                p.push(&list, p.mk(es, .omitted_expr));
                continue;
            }
            if (p.eat(.dot3)) {
                const e = p.parseAssignment();
                p.push(&list, p.mk(es, .{ .spread_elem = .{ .expr = e } }));
            } else {
                p.push(&list, p.parseAssignment());
            }
            if (p.t() != .r_bracket and !p.eat(.comma)) break;
        }
        p.no_in = save_in;
        p.expect(.r_bracket);
        return p.mk(s, .{ .array_lit = .{ .elems = list.items } });
    }

    fn parseObjectLiteral(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        const save_in = p.no_in;
        p.no_in = false;
        var list: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const before = p.lx.start;
            p.push(&list, p.parseObjectMember());
            if (p.t() != .r_brace and !p.eat(.comma)) {
                if (p.lx.start == before) p.next();
                p.errHere(1005, "',' expected.");
                break;
            }
        }
        p.no_in = save_in;
        p.expect(.r_brace);
        return p.mk(s, .{ .object_lit = .{ .props = list.items } });
    }

    fn parseObjectMember(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.eat(.dot3)) {
            const e = p.parseAssignment();
            return p.mk(s, .{ .spread_assign = .{ .expr = e } });
        }
        const decorators = p.parseDecorators();
        const mods = p.parseModifiers();
        if (p.isAccessorStart()) {
            const kind: ast.FuncKind = if (p.t() == .kw_get) .getter else .setter;
            p.next();
            var f = ast.Func{ .kind = kind, .decorators = decorators };
            f.name = p.parsePropertyName();
            p.parseSignature(&f, false);
            p.parseFunctionBody(&f, false);
            return p.mk(s, .{ .func = p.box(f) });
        }
        const asterisk = p.eat(.star);
        const name_tok = p.t();
        const name = p.parsePropertyName();
        const q_pos = p.lx.start;
        const question = p.eat(.question);
        if (asterisk or p.t() == .l_paren or p.t() == .lt) {
            var f = ast.Func{ .kind = .method, .name = name, .asterisk = asterisk, .question = question, .q_pos = q_pos };
            p.parseSignature(&f, mods.async);
            p.parseFunctionBody(&f, mods.async);
            const n = p.mk(s, .{ .func = p.box(f) });
            n.mods = mods;
            return n;
        }
        if (p.eat(.colon)) {
            const value = p.parseAssignment();
            return p.mk(s, .{ .property_assign = .{ .name = name, .value = value } });
        }
        if (!name_tok.isIdentifierLike()) {
            p.errHere(1005, "':' expected.");
        }
        const in = if (p.eat(.assign)) p.parseAssignment() else null;
        return p.mk(s, .{ .shorthand_assign = .{ .name = name, .init = in } });
    }

    // JSX

    fn parseJsxTagName(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.t() == .kw_this) {
            p.next();
            return p.mk(s, .this_expr);
        }
        p.lx.extendJsxIdentifier();
        var e = p.parseIdentName();
        if (p.t() == .colon) {
            p.next();
            p.lx.extendJsxIdentifier();
            const local = p.parseIdentName();
            e = p.mk(s, .{ .identifier = p.lx.src[e.start..local.end] });
        }
        while (p.t() == .dot) {
            p.next();
            const name = p.parseIdentName();
            e = p.mk(s, .{ .prop_access = .{ .expr = e, .name = name, .optional = false } });
        }
        return e;
    }

    fn parseJsxAttrs(p: *Parser) []*Node {
        var list: NodeList = .empty;
        while (p.t() != .gt and p.t() != .slash and p.t() != .eof) {
            const s = p.lx.start;
            if (p.t() == .l_brace) {
                p.next();
                p.expect(.dot3);
                const e = p.parseAssignment();
                p.expect(.r_brace);
                p.push(&list, p.mk(s, .{ .jsx_spread_attr = .{ .expr = e } }));
                continue;
            }
            // Anything else cannot start an attribute and would hold the loop on this token.
            if (!p.t().isKeyword() and p.t() != .identifier) {
                p.skipBadToken(1003, "Identifier expected.");
                continue;
            }
            p.lx.extendJsxIdentifier();
            const name = p.parseJsxAttrName();
            var value: ?*Node = null;
            if (p.t() == .assign) {
                _ = p.lx.nextJsxAttrValue();
                switch (p.t()) {
                    .string => value = p.stringNode(),
                    .l_brace => value = p.parseJsxExprContainer(false),
                    .lt => value = p.parseJsx(false),
                    else => p.errHere(1145, "'{' or JSX element expected."),
                }
            }
            p.push(&list, p.mk(s, .{ .jsx_attr = .{ .name = name, .value = value } }));
        }
        return list.items;
    }

    fn parseJsxAttrName(p: *Parser) *Node {
        const s = p.lx.start;
        const e = p.parseIdentName();
        if (p.t() == .colon) {
            p.next();
            p.lx.extendJsxIdentifier();
            const local = p.parseIdentName();
            return p.mk(s, .{ .identifier = p.lx.src[e.start..local.end] });
        }
        return e;
    }

    fn parseJsxExprContainer(p: *Parser, in_children: bool) *Node {
        const s = p.lx.start;
        p.next();
        var e: ?*Node = null;
        if (p.t() != .r_brace) {
            const save_in = p.no_in;
            p.no_in = false;
            if (p.t() == .dot3) {
                const ss = p.lx.start;
                p.next();
                const inner = p.parseAssignment();
                e = p.mk(ss, .{ .spread_elem = .{ .expr = inner } });
            } else {
                e = p.parseExpression();
            }
            p.no_in = save_in;
        }
        if (p.t() != .r_brace) p.errHere(1005, "'}' expected.");
        p.closeJsx(in_children);
        return p.mk(s, .{ .jsx_expr = .{ .expr = e } });
    }

    /// The token after a closing `>` or `}` lexes as JSX text when still inside children.
    fn closeJsx(p: *Parser, in_children: bool) void {
        p.prev_end = p.lx.pos;
        if (in_children) _ = p.lx.nextJsxChild() else _ = p.lx.next();
    }

    fn parseJsx(p: *Parser, in_children: bool) *Node {
        const s = p.lx.start;
        var e = p.parseJsxElement(in_children);
        if (in_children) return e;
        // Sibling elements with no parent parse as a comma expression, one error for the whole run.
        var last = e;
        while (p.t() == .lt) {
            last = p.parseJsxElement(false);
            e = p.mk(s, .{ .binary = .{ .left = e, .op = .comma, .right = last } });
        }
        if (last != e) p.lx.err(s, last.end - s, 2657, "JSX expressions must have one parent element.");
        return e;
    }

    fn parseJsxElement(p: *Parser, in_children: bool) *Node {
        const s = p.lx.start;
        p.next();
        if (p.t() == .gt) {
            p.prev_end = p.lx.pos;
            _ = p.lx.nextJsxChild();
            const children = p.parseJsxChildren();
            p.next();
            if (p.t() != .gt) p.errHere(1005, "'>' expected.");
            p.closeJsx(in_children);
            return p.mk(s, .{ .jsx_fragment = .{ .children = children } });
        }
        const tag = p.parseJsxTagName();
        const ta = p.parseOptionalTypeArgs();
        const attrs = p.parseJsxAttrs();
        if (p.t() == .slash) {
            p.next();
            if (p.t() != .gt) p.errHere(1005, "'>' expected.");
            p.closeJsx(in_children);
            return p.mk(s, .{ .jsx_self_closing = p.box(ast.JsxSelfClosing{ .tag = tag, .type_args = ta, .attrs = attrs }) });
        }
        if (p.t() != .gt) p.errHere(1005, "'>' expected.");
        p.prev_end = p.lx.pos;
        const open = p.mk(s, .{ .jsx_opening = p.box(ast.JsxOpening{ .tag = tag, .type_args = ta, .attrs = attrs }) });
        _ = p.lx.nextJsxChild();
        const children = p.parseJsxChildren();
        const cs = p.lx.start;
        p.next();
        const close_tag = p.parseJsxTagName();
        if (p.t() != .gt) p.errHere(1005, "'>' expected.");
        p.closeJsx(in_children);
        const close = p.mk(cs, .{ .jsx_closing = .{ .tag = close_tag } });
        return p.mk(s, .{ .jsx_element = p.box(ast.JsxElement{ .open = open, .children = children, .close = close }) });
    }

    fn parseJsxChildren(p: *Parser) []*Node {
        var list: NodeList = .empty;
        while (true) {
            switch (p.t()) {
                .jsx_text => {
                    const s = p.lx.start;
                    const v = p.lx.value;
                    p.prev_end = p.lx.pos;
                    _ = p.lx.nextJsxChild();
                    p.push(&list, p.mk(s, .{ .jsx_text = v }));
                },
                .l_brace => p.push(&list, p.parseJsxExprContainer(true)),
                .lt => p.push(&list, p.parseJsx(true)),
                .lt_slash => return list.items,
                else => {
                    p.errHere(17008, "JSX element has no corresponding closing tag.");
                    return list.items;
                },
            }
        }
    }

    // Types

    fn parseTypeParams(p: *Parser) ast.TypeList {
        p.lx.rescanLessThan();
        if (p.t() != .lt) return .{};
        const s = p.lx.start;
        p.next();
        var list: NodeList = .empty;
        while (p.t() != .gt and p.t() != .eof) {
            const ts = p.lx.start;
            const mods = p.parseTypeParamModifiers();
            const name = p.parseIdent();
            const constraint = if (p.eat(.kw_extends)) p.parseType() else null;
            const default = if (p.eat(.assign)) p.parseType() else null;
            const n = p.mk(ts, .{ .type_param = .{ .name = name, .constraint = constraint, .default = default } });
            n.mods = mods;
            p.push(&list, n);
            if (!p.eat(.comma)) break;
        }
        p.expect(.gt);
        return .{ .items = list.items, .span = .{ .start = s, .end = p.prev_end } };
    }

    fn parseTypeParamModifiers(p: *Parser) Mods {
        var m = Mods{};
        while (p.t() == .kw_const or p.t() == .kw_in or p.t() == .kw_out) {
            const st = p.save();
            const tok = p.t();
            p.next();
            if (!p.isIdent() and p.t() != .kw_in and p.t() != .kw_const) {
                p.restore(st);
                break;
            }
            if (tok == .kw_const) m.@"const" = true else if (tok == .kw_in) m.in = true else m.out = true;
        }
        return m;
    }

    fn parseTypeArgs(p: *Parser) ast.TypeList {
        const s = p.lx.start;
        p.next();
        var list: NodeList = .empty;
        while (p.t() != .gt and p.t() != .eof) {
            p.push(&list, p.parseType());
            if (!p.eat(.comma)) break;
        }
        p.expect(.gt);
        return .{ .items = list.items, .span = .{ .start = s, .end = p.prev_end } };
    }

    fn parseEntityName(p: *Parser) *Node {
        const s = p.lx.start;
        var e = p.parseIdent();
        while (p.t() == .dot) {
            p.next();
            const r = p.parseIdentName();
            e = p.mk(s, .{ .qualified_name = .{ .left = e, .right = r } });
        }
        return e;
    }

    fn isStartOfFunctionType(p: *Parser) bool {
        if (p.t() == .lt) return true;
        if (p.t() != .l_paren) return false;
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.t() == .r_paren or p.t() == .dot3) return true;
        if (!p.skipParamStart()) return false;
        switch (p.t()) {
            .colon, .comma, .question, .assign => return true,
            .r_paren => {
                p.next();
                return p.t() == .arrow;
            },
            else => return false,
        }
    }

    fn skipParamStart(p: *Parser) bool {
        if (isTsOnlyModifier(p.t())) p.next();
        if (p.isIdent() or p.t() == .kw_this) {
            p.next();
            return true;
        }
        if (p.t() == .l_bracket or p.t() == .l_brace) {
            const diags = p.lx.diags.items.len;
            _ = p.parseBindingName();
            return p.lx.diags.items.len == diags;
        }
        return false;
    }

    fn isStartOfConstructorType(p: *Parser) bool {
        if (p.t() == .kw_new) return true;
        if (p.t() != .kw_abstract) return false;
        const st = p.save();
        defer p.restore(st);
        p.next();
        return p.t() == .kw_new;
    }

    pub fn parseType(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.isStartOfFunctionType()) return p.parseFunctionType(s, .function_type);
        if (p.isStartOfConstructorType()) return p.parseFunctionType(s, .constructor_type);
        const ty = p.parseUnionType();
        if (!p.no_cond_type and p.t() == .kw_extends and !p.lx.nl_before) {
            p.next();
            const save_cond = p.no_cond_type;
            p.no_cond_type = true;
            const ext = p.parseType();
            p.no_cond_type = false;
            p.expect(.question);
            const then = p.parseType();
            p.expect(.colon);
            const els = p.parseType();
            p.no_cond_type = save_cond;
            return p.mk(s, .{ .conditional_type = p.box(ast.ConditionalType{ .check = ty, .extends = ext, .then = then, .els = els }) });
        }
        return ty;
    }

    fn parseFunctionType(p: *Parser, s: u32, kind: ast.FuncKind) *Node {
        var mods = Mods{};
        if (p.t() == .kw_abstract) {
            mods.abstract = true;
            p.next();
        }
        if (kind == .constructor_type) p.next();
        var f = ast.Func{ .kind = kind };
        f.type_params = p.parseTypeParams();
        f.params = p.parseParams();
        // Past the `=>` a conditional type is unambiguous even inside an `extends` clause.
        const save_cond = p.no_cond_type;
        p.no_cond_type = false;
        p.parseReturnAnnotation(&f, .arrow);
        p.no_cond_type = save_cond;
        if (f.ret == null) {
            p.errHere(1005, "'=>' expected.");
            f.ret = p.mk(p.lx.start, .{ .kw_type = .any });
        }
        const n = p.mk(s, .{ .func = p.box(f) });
        n.mods = mods;
        return n;
    }

    fn parseTypeOrPredicate(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.t() == .kw_asserts) {
            const st = p.save();
            p.next();
            if (!p.lx.nl_before and (p.isIdent() or p.t() == .kw_this)) {
                const param = if (p.t() == .kw_this) p.thisType() else p.identNode();
                var ty: ?*Node = null;
                if (p.t() == .kw_is and !p.lx.nl_before) {
                    p.next();
                    ty = p.parseType();
                }
                return p.mk(s, .{ .type_predicate = .{ .asserts = true, .param = param, .type = ty } });
            }
            p.restore(st);
        }
        if (p.isIdent() or p.t() == .kw_this) {
            const st = p.save();
            const param = if (p.t() == .kw_this) p.thisType() else p.identNode();
            if (p.t() == .kw_is and !p.lx.nl_before) {
                p.next();
                const ty = p.parseType();
                return p.mk(s, .{ .type_predicate = .{ .asserts = false, .param = param, .type = ty } });
            }
            p.restore(st);
        }
        return p.parseType();
    }

    fn thisType(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        return p.mk(s, .this_type);
    }

    fn parseUnionType(p: *Parser) *Node {
        return p.parseTypeList(.pipe);
    }

    fn parseTypeList(p: *Parser, op: Tok) *Node {
        const s = p.lx.start;
        _ = p.eat(op);
        const first = p.parseConstituent(op);
        if (p.t() != op) return first;
        var list: NodeList = .empty;
        p.push(&list, first);
        while (p.eat(op)) p.push(&list, p.parseConstituent(op));
        if (op == .pipe) return p.mk(s, .{ .union_type = .{ .types = list.items } });
        return p.mk(s, .{ .intersection_type = .{ .types = list.items } });
    }

    fn parseConstituent(p: *Parser, op: Tok) *Node {
        const s = p.lx.start;
        if (p.isStartOfFunctionType()) return p.parseFunctionType(s, .function_type);
        if (p.isStartOfConstructorType()) return p.parseFunctionType(s, .constructor_type);
        return if (op == .pipe) p.parseTypeList(.amp) else p.parseTypeOperator();
    }

    fn parseTypeOperator(p: *Parser) *Node {
        const s = p.lx.start;
        switch (p.t()) {
            .kw_keyof, .kw_unique, .kw_readonly => {
                const op = p.t();
                p.next();
                const inner = p.parseTypeOperator();
                return p.mk(s, .{ .type_operator = .{ .op = op, .type = inner } });
            },
            .kw_infer => {
                const st = p.save();
                p.next();
                if (p.isIdent()) {
                    const ts = p.lx.start;
                    const name = p.identNode();
                    var constraint: ?*Node = null;
                    if (p.t() == .kw_extends) {
                        // `infer U extends X ? a : b` must not swallow the conditional's `?`.
                        const c = p.save();
                        p.next();
                        const save_cond = p.no_cond_type;
                        p.no_cond_type = true;
                        const ty = p.parseType();
                        p.no_cond_type = save_cond;
                        if (save_cond or p.t() != .question) constraint = ty else p.restore(c);
                    }
                    const tparam = p.mk(ts, .{ .type_param = .{ .name = name, .constraint = constraint, .default = null } });
                    return p.mk(s, .{ .infer_type = .{ .tparam = tparam } });
                }
                p.restore(st);
            },
            else => {},
        }
        // Only the operand of `extends` is ambiguous: inside any bracket a conditional is back on.
        const save_cond = p.no_cond_type;
        p.no_cond_type = false;
        defer p.no_cond_type = save_cond;
        return p.parsePostfixType();
    }

    fn parsePostfixType(p: *Parser) *Node {
        const s = p.lx.start;
        var ty = p.parseNonArrayType();
        while (!p.lx.nl_before) {
            switch (p.t()) {
                .bang => p.next(),
                .question => {
                    // A `?` here is JSDoc nullable unless a conditional is being parsed; tsc rejects it too.
                    return ty;
                },
                .l_bracket => {
                    p.next();
                    if (p.eat(.r_bracket)) {
                        ty = p.mk(s, .{ .array_type = .{ .elem = ty } });
                    } else {
                        const idx = p.parseType();
                        p.expect(.r_bracket);
                        ty = p.mk(s, .{ .indexed_access = .{ .object = ty, .index = idx } });
                    }
                },
                else => return ty,
            }
        }
        return ty;
    }

    fn kwType(p: *Parser, k: ast.KwType) ?*Node {
        const s = p.lx.start;
        const st = p.save();
        p.next();
        if (p.t() == .dot) {
            p.restore(st);
            return null;
        }
        return p.mk(s, .{ .kw_type = k });
    }

    /// `?T`, `!T`, `*` and `function(T): U`, or null when the type is one TypeScript spells too.
    fn parseJsdocType(p: *Parser) ?*Node {
        const s = p.lx.start;
        switch (p.t()) {
            .star => {
                p.next();
                return p.mk(s, .{ .kw_type = .any });
            },
            .bang => {
                p.next();
                return p.parsePostfixType();
            },
            .question => {
                p.next();
                if (p.t() == .eof or p.t() == .comma or p.t() == .r_paren) return p.mk(s, .{ .kw_type = .any });
                const types = p.a.alloc(*Node, 2) catch oom();
                types[0] = p.parsePostfixType();
                types[1] = p.mk(s, .{ .kw_type = .null });
                return p.mk(s, .{ .union_type = .{ .types = types } });
            },
            .kw_function => {
                p.next();
                p.expect(.l_paren);
                var params: NodeList = .empty;
                while (p.t() != .r_paren and p.t() != .eof) {
                    const ps = p.lx.start;
                    const rest = p.eat(.dot3);
                    const elem = p.parseType();
                    const name = p.mk(ps, .{ .identifier = std.fmt.allocPrint(p.a, "arg{d}", .{params.items.len}) catch oom() });
                    const ty = if (rest) p.mk(ps, .{ .array_type = .{ .elem = elem } }) else elem;
                    p.push(&params, p.mk(ps, .{ .param = p.box(ast.Param{ .name = name, .dotdotdot = rest, .type = ty, .question = p.eat(.assign) }) }));
                    if (!p.eat(.comma)) break;
                }
                p.expect(.r_paren);
                const ret = if (p.eat(.colon)) p.parseType() else p.mk(s, .{ .kw_type = .any });
                return p.mk(s, .{ .func = p.box(ast.Func{ .kind = .function_type, .params = params.items, .ret = ret }) });
            },
            else => return null,
        }
    }

    fn parseNonArrayType(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.jsdoc) if (p.parseJsdocType()) |n| return n;
        switch (p.t()) {
            .kw_any => if (p.kwType(.any)) |n| return n,
            .kw_unknown => if (p.kwType(.unknown)) |n| return n,
            .kw_never => if (p.kwType(.never)) |n| return n,
            .kw_void => if (p.kwType(.void)) |n| return n,
            .kw_number => if (p.kwType(.number)) |n| return n,
            .kw_string => if (p.kwType(.string)) |n| return n,
            .kw_boolean => if (p.kwType(.boolean)) |n| return n,
            .kw_bigint => if (p.kwType(.bigint)) |n| return n,
            .kw_symbol => if (p.kwType(.symbol)) |n| return n,
            .kw_object => if (p.kwType(.object)) |n| return n,
            .kw_undefined => if (p.kwType(.undefined)) |n| return n,
            .kw_null => if (p.kwType(.null)) |n| return n,
            .string, .numeric, .bigint, .kw_true, .kw_false => {
                const lit = p.parsePrimary();
                return p.mk(s, .{ .literal_type = .{ .lit = lit } });
            },
            .minus => {
                p.next();
                const inner = p.parsePrimary();
                const lit = p.mk(s, .{ .prefix = .{ .op = .minus, .expr = inner } });
                return p.mk(s, .{ .literal_type = .{ .lit = lit } });
            },
            .no_subst_template => {
                const lit = p.parseTemplate(false);
                return p.mk(s, .{ .literal_type = .{ .lit = lit } });
            },
            .template_head => return p.parseTemplateType(),
            .kw_this => {
                const th = p.thisType();
                if (p.t() == .kw_is and !p.lx.nl_before) {
                    p.next();
                    const ty = p.parseType();
                    return p.mk(s, .{ .type_predicate = .{ .asserts = false, .param = th, .type = ty } });
                }
                return th;
            },
            .kw_typeof => {
                p.next();
                if (p.t() == .kw_import) return p.parseImportType(s, true);
                const name = p.parseEntityNameInQuery();
                const ta = if (!p.lx.nl_before) p.parseOptionalTypeArgs() else ast.TypeList{};
                return p.mk(s, .{ .type_query = p.box(ast.TypeQuery{ .name = name, .type_args = ta }) });
            },
            .kw_import => return p.parseImportType(s, false),
            .l_brace => return if (p.isMappedType()) p.parseMappedType() else blk: {
                const members = p.parseTypeMembers();
                break :blk p.mk(s, .{ .type_literal = .{ .members = members } });
            },
            .l_bracket => return p.parseTupleType(),
            .l_paren => {
                p.next();
                const ty = p.parseType();
                p.expect(.r_paren);
                return p.mk(s, .{ .paren_type = .{ .type = ty } });
            },
            .kw_const => {
                // `x as const`
                const name = p.identNode();
                return p.mk(s, .{ .type_ref = p.box(ast.TypeRef{ .name = name, .type_args = .{} }) });
            },
            else => {},
        }
        if (p.isIdent()) {
            const name = p.parseEntityName();
            const ta = if (!p.lx.nl_before) p.parseOptionalTypeArgs() else ast.TypeList{};
            return p.mk(s, .{ .type_ref = p.box(ast.TypeRef{ .name = name, .type_args = ta }) });
        }
        p.errHere(1110, "Type expected.");
        return p.mk(s, .{ .kw_type = .any });
    }

    fn parseEntityNameInQuery(p: *Parser) *Node {
        const s = p.lx.start;
        var e = if (p.t() == .kw_this) p.identNode() else p.parseIdent();
        while (p.t() == .dot) {
            p.next();
            const private = p.t() == .private_name;
            const r = if (private) p.parseMemberName() else p.parseIdentName();
            if (private) p.errHere(1003, "Identifier expected.");
            e = p.mk(s, .{ .qualified_name = .{ .left = e, .right = r } });
        }
        return e;
    }

    fn parseImportType(p: *Parser, s: u32, is_typeof: bool) *Node {
        p.next();
        p.expect(.l_paren);
        const arg = p.parseType();
        if (p.eat(.comma)) {
            if (p.t() == .l_brace) _ = p.parseObjectLiteral();
            _ = p.eat(.comma);
        }
        p.expect(.r_paren);
        var qualifier: ?*Node = null;
        if (p.eat(.dot)) {
            // Unlike a plain entity name this may start with a keyword: `import('x').default`.
            const qs = p.lx.start;
            var q = p.parseIdentName();
            while (p.eat(.dot)) q = p.mk(qs, .{ .qualified_name = .{ .left = q, .right = p.parseIdentName() } });
            qualifier = q;
        }
        const ta = p.parseOptionalTypeArgs();
        return p.mk(s, .{ .import_type = p.box(ast.ImportType{ .is_typeof = is_typeof, .arg = arg, .qualifier = qualifier, .type_args = ta }) });
    }

    fn parseTemplateType(p: *Parser) *Node {
        const s = p.lx.start;
        p.lx.commitTemplateEscapes();
        const head = p.lx.value;
        p.next();
        var spans: NodeList = .empty;
        while (true) {
            const ss = p.lx.start;
            const ty = p.parseType();
            if (p.t() != .r_brace) {
                p.errHere(1005, "'}' expected.");
                break;
            }
            const tok = p.lx.rescanTemplate();
            p.lx.commitTemplateEscapes();
            const text = p.lx.value;
            p.next();
            p.push(&spans, p.mk(ss, .{ .template_type_span = .{ .type = ty, .text = text } }));
            if (tok != .template_middle) break;
        }
        return p.mk(s, .{ .template_literal_type = p.box(ast.TemplateLiteralType{ .head = head, .spans = spans.items }) });
    }

    fn isMappedType(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        p.next();
        if (p.t() == .plus or p.t() == .minus) {
            p.next();
            return p.t() == .kw_readonly;
        }
        if (p.t() == .kw_readonly) p.next();
        if (p.t() != .l_bracket) return false;
        p.next();
        if (!p.isIdent()) return false;
        p.next();
        return p.t() == .kw_in;
    }

    fn parseMappedType(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        var m = ast.Mapped{ .tparam_name = undefined, .constraint = undefined };
        if (p.t() == .plus or p.t() == .minus) {
            m.readonly_mod = p.t();
            p.next();
            p.expect(.kw_readonly);
        } else if (p.eat(.kw_readonly)) {
            m.readonly_mod = .kw_readonly;
        }
        p.expect(.l_bracket);
        m.tparam_name = p.parseIdent();
        p.expect(.kw_in);
        m.constraint = p.parseType();
        if (p.eat(.kw_as)) m.name_type = p.parseType();
        p.expect(.r_bracket);
        if (p.t() == .plus or p.t() == .minus) {
            m.question_mod = p.t();
            p.next();
            p.expect(.question);
        } else if (p.eat(.question)) {
            m.question_mod = .question;
        }
        if (p.eat(.colon)) m.type = p.parseType();
        _ = p.eat(.semi);
        _ = p.eat(.comma);
        p.expect(.r_brace);
        return p.mk(s, .{ .mapped_type = p.box(m) });
    }

    fn parseTupleType(p: *Parser) *Node {
        const s = p.lx.start;
        p.next();
        var list: NodeList = .empty;
        while (p.t() != .r_bracket and p.t() != .eof) {
            p.push(&list, p.parseTupleElement());
            if (!p.eat(.comma)) break;
        }
        p.expect(.r_bracket);
        return p.mk(s, .{ .tuple_type = .{ .elems = list.items } });
    }

    fn isNamedTupleMember(p: *Parser) bool {
        const st = p.save();
        defer p.restore(st);
        if (p.t() == .dot3) p.next();
        if (!p.t().isKeyword() and p.t() != .identifier) return false;
        p.next();
        if (p.t() == .colon) return true;
        if (p.t() != .question) return false;
        p.next();
        return p.t() == .colon;
    }

    fn parseTupleElement(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.isNamedTupleMember()) {
            const dots = p.eat(.dot3);
            const name = p.parseIdentName();
            const q = p.eat(.question);
            p.expect(.colon);
            const ty = p.parseType();
            return p.mk(s, .{ .named_tuple_member = .{ .dotdotdot = dots, .name = name, .question = q, .type = ty } });
        }
        if (p.eat(.dot3)) {
            const ty = p.parseType();
            return p.mk(s, .{ .rest_type = .{ .type = ty } });
        }
        const ty = p.parseType();
        if (p.eat(.question)) return p.mk(s, .{ .optional_type = .{ .type = ty } });
        return ty;
    }

    fn parseTypeMembers(p: *Parser) []*Node {
        p.expect(.l_brace);
        var list: NodeList = .empty;
        while (p.t() != .r_brace and p.t() != .eof) {
            const before = p.lx.start;
            p.push(&list, p.parseTypeMember());
            if (p.lx.start == before) p.skipBadToken(1131, "Property or signature expected.");
        }
        p.expect(.r_brace);
        return list.items;
    }

    fn parseTypeMember(p: *Parser) *Node {
        const s = p.lx.start;
        if (p.t() == .l_paren or p.t() == .lt) return p.parseSigMember(s, .call_sig, null, false, 0);
        if (p.t() == .kw_new) {
            const st = p.save();
            p.next();
            if (p.t() == .l_paren or p.t() == .lt) return p.parseSigMember(s, .construct_sig, null, false, 0);
            p.restore(st);
        }
        const mods = p.parseModifiers();
        if (p.t() == .l_bracket and p.isIndexSignature()) return p.parseIndexSig(s, mods);
        if (p.isAccessorStart()) {
            const kind: ast.FuncKind = if (p.t() == .kw_get) .getter_sig else .setter_sig;
            p.next();
            const name = p.parsePropertyName();
            const n = p.parseSigMember(s, kind, name, false, 0);
            n.mods = mods;
            return n;
        }
        if (!p.isPropertyNameStart()) {
            p.errHere(1131, "Property or signature expected.");
            return p.mk(s, .semicolon_member);
        }
        const name = p.parsePropertyName();
        const q_pos = p.lx.start;
        const question = p.eat(.question);
        if (p.t() == .l_paren or p.t() == .lt) {
            const n = p.parseSigMember(s, .method_sig, name, question, q_pos);
            n.mods = mods;
            return n;
        }
        const ty = if (p.eat(.colon)) p.parseType() else null;
        p.typeMemberEnd();
        const n = p.mk(s, .{ .property_sig = .{ .name = name, .question = question, .type = ty } });
        n.mods = mods;
        return n;
    }

    fn parseSigMember(p: *Parser, s: u32, kind: ast.FuncKind, name: ?*Node, question: bool, q_pos: u32) *Node {
        var f = ast.Func{ .kind = kind, .name = name, .question = question, .q_pos = q_pos };
        f.type_params = p.parseTypeParams();
        f.params = p.parseParams();
        p.parseReturnAnnotation(&f, .colon);
        p.typeMemberEnd();
        return p.mk(s, .{ .func = p.box(f) });
    }
};

fn testParse(src: []const u8, path: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = parse(arena.allocator(), path, src);
    return f.diags.len;
}

test "syntax covers the awkward corners" {
    const src =
        \\abstract class A<in out T> extends B<T> implements C { private readonly x?: number = 1; constructor(public y: string) { super(); } get z(): T { return this.w!; } static { foo(); } declare q: string; abstract m(): void; [k: string]: any; }
        \\const f = async <T,>(x: T): Promise<T> => x;
        \\const g = a ? (b) : c => d;
        \\type M<T> = { readonly [K in keyof T as `get${K & string}`]-?: T[K] extends (infer U extends string)[] ? U : never };
        \\function over(a: string): void; function over(a: any) {}
        \\enum E { A = 1, B = A << 2, "c" }
        \\declare module "x" { export default function f(): void; }
        \\namespace N.M { export const v = 1; }
        \\import type { X } from "./x"; import y = require("y"); export = y;
        \\let t: [a: string, b?: number, ...c: boolean[]] = x as const;
        \\for await (const v of w) ;
        \\let r = /[/]/g.test(s) ? 1 >> 2 : a < b > c;
        \\let i = f<string>(`a${b}c`) satisfies Z;
        \\function assertIsString(v: unknown): asserts v is string {}
        \\type Fn = abstract new <T>(...args: T[]) => void;
    ;
    try std.testing.expectEqual(@as(usize, 0), try testParse(src, "a.ts"));
}

test "tsx distinguishes elements from generics" {
    const src =
        \\const a = <T,>(x: T) => x;
        \\const b = <div className="x" {...p} data-a={1}>text {v} <b>bold</b><></></div>;
    ;
    try std.testing.expectEqual(@as(usize, 0), try testParse(src, "a.tsx"));
}

test "reports syntax errors" {
    try std.testing.expect((try testParse("let = ;", "a.ts")) > 0);
    try std.testing.expect((try testParse("function (", "a.ts")) > 0);
}

test "tagged templates accept invalid escapes, untagged ones do not" {
    try std.testing.expectEqual(@as(usize, 0), try testParse("const p = String.raw`C:\\users\\me`;", "a.ts"));
    try std.testing.expectEqual(@as(usize, 0), try testParse("const q = tag`\\xZZ${1}\\u00G0${2}\\u{110000}`;", "a.ts"));
    try std.testing.expectEqual(@as(usize, 0), try testParse("const r = tag<number>`\\x`;", "a.ts"));
    try std.testing.expect((try testParse("const s = `\\xZZ`;", "a.ts")) > 0);
    try std.testing.expect((try testParse("const t = `a${1}\\u00G0`;", "a.ts")) > 0);
    try std.testing.expect((try testParse("type U = `a${string}\\xZZ`;", "a.ts")) > 0);
}

test "reference attributes need a name boundary" {
    try std.testing.expectEqual(@as(?[]const u8, null), attrValue("/// <reference no-default-lib=\"true\"/>", "lib"));
    try std.testing.expectEqualStrings("es2015", attrValue("/// <reference lib=\"es2015\" />", "lib").?);
    try std.testing.expectEqualStrings("./a.ts", attrValue("/// <reference path='./a.ts' lib=\"dom\" />", "path").?);
}

fn bodyOfFirst(f: *const ast.File) *Node {
    return f.root.data.source_file.stmts[0].data.func.body.?;
}

test "a skipped body ends where parsing it does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        "{ return 1 / 2 / 3; }",
        "{ i++ / 2; (a) / b / c; [a][0] / b / c; }",
        "{ const a = /[/}'\"`]/.test('}'); }",
        "{ return x ? y / 2 : /}/; }",
        "{ return `a${`b${1}c${{ a: 1 }.a}`}d}`; }",
        "{ return `}${\"}\"}{`; }",
        "{ // }\n /* } */ }",
        "{ if (a) { b(); } else { c({ d: {} }); } }",
    };
    for (bodies) |body| {
        const src = std.fmt.allocPrint(a, "function f() {s}\nconst after = 1;", .{body}) catch unreachable;
        const f = parseLazily(a, "t.ts", src);
        try std.testing.expectEqual(@as(usize, 0), f.diags.len);
        try std.testing.expectEqual(@as(usize, 2), f.root.data.source_file.stmts.len);
        try std.testing.expect(bodyOfFirst(f).data == .lazy_body);
        try std.testing.expect(parseBody(a, f, f.root.data.source_file.stmts[0]).ok);
    }
}

test "a skip hands back what tokens cannot settle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        "{ if (x) /'/.test(y); }",
        "{ export const a = 1; }",
        "{ import a = require('a'); }",
        "{ declare const a: number; }",
    };
    for (bodies) |body| {
        const src = std.fmt.allocPrint(a, "function f() {s}", .{body}) catch unreachable;
        try std.testing.expect(bodyOfFirst(parseLazily(a, "t.ts", src)).data == .block);
    }
}

test "only a body that parses to the same end is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "function f() { return 1 +; }", "function f() { const = 2; }" }) |src| {
        const f = parseLazily(a, "t.ts", src);
        try std.testing.expectEqual(@as(usize, 0), f.diags.len);
        try std.testing.expect(!parseBody(a, f, f.root.data.source_file.stmts[0]).ok);
    }
}

test "bodies stay in code that needs them whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(bodyOfFirst(parseLazily(a, "t.tsx", "function f() { return <a>{'}'}</a>; }")).data == .block);
    try std.testing.expect(bodyOfFirst(parseLazily(a, "t.js", "function f() {}")).data == .block);
    try std.testing.expect(bodyOfFirst(parse(a, "t.ts", "function f() {}")).data == .block);
}

test "a skipped body still shows what the file needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = parseLazily(a, "t.ts", "function f() { import.meta.url; x.import('./c'); y?.import('./d'); }");
    try std.testing.expect(f.is_module);
    try std.testing.expectEqual(@as(usize, 0), bodyOfFirst(f).data.lazy_body.specs.len);
    const specs = bodyOfFirst(parseLazily(a, "t.ts", "function f() { import('./a'); let b: typeof import('./b'); }")).data.lazy_body.specs;
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expectEqualStrings("./a", specs[0].data.string_lit);
    try std.testing.expectEqualStrings("./b", specs[1].data.string_lit);
}
