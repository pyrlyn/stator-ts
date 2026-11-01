const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tok = enum(u8) {
    eof,
    unknown,

    numeric,
    bigint,
    string,
    no_subst_template,
    template_head,
    template_middle,
    template_tail,
    regex,
    identifier,
    private_name,
    jsx_text,

    l_brace,
    r_brace,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    dot,
    dot3,
    semi,
    comma,
    lt,
    gt,
    lte,
    gte,
    eq2,
    neq,
    eq3,
    neq3,
    arrow,
    plus,
    minus,
    star,
    star2,
    slash,
    percent,
    plus2,
    minus2,
    shl,
    shr,
    ushr,
    amp,
    pipe,
    caret,
    bang,
    tilde,
    amp2,
    pipe2,
    qq,
    question,
    question_dot,
    colon,
    at,
    lt_slash,

    assign,
    plus_assign,
    minus_assign,
    star_assign,
    star2_assign,
    slash_assign,
    percent_assign,
    shl_assign,
    shr_assign,
    ushr_assign,
    amp_assign,
    pipe_assign,
    caret_assign,
    amp2_assign,
    pipe2_assign,
    qq_assign,

    // Reserved words. The enum order is relied on by isReserved and friends.
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_false,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_null,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_true,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,

    // Reserved in strict mode only.
    kw_implements,
    kw_interface,
    kw_let,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,
    kw_yield,

    // Contextual.
    kw_abstract,
    kw_accessor,
    kw_as,
    kw_asserts,
    kw_assert,
    kw_any,
    kw_async,
    kw_await,
    kw_boolean,
    kw_constructor,
    kw_declare,
    kw_get,
    kw_infer,
    kw_intrinsic,
    kw_is,
    kw_keyof,
    kw_module,
    kw_namespace,
    kw_never,
    kw_out,
    kw_readonly,
    kw_require,
    kw_number,
    kw_object,
    kw_satisfies,
    kw_set,
    kw_string,
    kw_symbol,
    kw_type,
    kw_undefined,
    kw_unique,
    kw_unknown,
    kw_using,
    kw_from,
    kw_global,
    kw_bigint,
    kw_override,
    kw_of,
    kw_defer,

    pub fn isKeyword(t: Tok) bool {
        return @intFromEnum(t) >= @intFromEnum(Tok.kw_break);
    }
    pub fn isReserved(t: Tok) bool {
        return @intFromEnum(t) >= @intFromEnum(Tok.kw_break) and @intFromEnum(t) <= @intFromEnum(Tok.kw_with);
    }
    pub fn isIdentifierLike(t: Tok) bool {
        return t == .identifier or @intFromEnum(t) >= @intFromEnum(Tok.kw_implements);
    }
    pub fn isAssignment(t: Tok) bool {
        return @intFromEnum(t) >= @intFromEnum(Tok.assign) and @intFromEnum(t) <= @intFromEnum(Tok.qq_assign);
    }
};

const keywords = std.StaticStringMap(Tok).initComptime(blk: {
    const info = @typeInfo(Tok).@"enum";
    var pairs: [info.field_names.len]struct { []const u8, Tok } = undefined;
    var n: usize = 0;
    for (info.field_names, info.field_values) |name, value| {
        if (std.mem.startsWith(u8, name, "kw_")) {
            pairs[n] = .{ name[3..], @enumFromInt(value) };
            n += 1;
        }
    }
    break :blk pairs[0..n].*;
});

pub fn tokenText(t: Tok) []const u8 {
    return switch (t) {
        .l_brace => "{",
        .r_brace => "}",
        .l_paren => "(",
        .r_paren => ")",
        .l_bracket => "[",
        .r_bracket => "]",
        .dot => ".",
        .dot3 => "...",
        .semi => ";",
        .comma => ",",
        .lt => "<",
        .gt => ">",
        .arrow => "=>",
        .colon => ":",
        .assign => "=",
        .question => "?",
        .star => "*",
        .at => "@",
        .lt_slash => "</",
        .slash => "/",
        else => if (t.isKeyword()) @tagName(t)[3..] else @tagName(t),
    };
}

pub const Diag = struct {
    start: u32,
    len: u32,
    code: u32,
    msg: []const u8,
};

/// For each first letter, the lengths of the keywords that start with it. Most identifiers are
/// not keywords and this tells without comparing them to anything.
const keyword_lengths = blk: {
    var t: [256]u16 = @splat(0);
    for (keywords.keys()) |k| t[k[0]] |= 1 << k.len;
    break :blk t;
};

fn keywordOf(text: []const u8) Tok {
    if (text.len >= 16 or keyword_lengths[text[0]] >> @intCast(text.len) & 1 == 0) return .identifier;
    return keywords.get(text) orelse .identifier;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '$' or c == '_' or c >= 0x80;
}
fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Byte length of the UTF-8 space or line terminator at `i`, or 0. Every other non-ASCII byte passes
/// for a letter, so identifier scans must stop at these as well as trivia skipping.
fn spaceLen(src: []const u8, i: usize) u8 {
    if (i + 1 >= src.len) return 0;
    const b1 = src[i + 1];
    if (src[i] == 0xc2) return if (b1 == 0xa0) 2 else 0;
    if (i + 2 >= src.len) return 0;
    const b2 = src[i + 2];
    const hit = switch (src[i]) {
        0xe1 => b1 == 0x9a and b2 == 0x80,
        0xe2 => (b1 == 0x80 and ((b2 >= 0x80 and b2 <= 0x8a) or b2 == 0xa8 or b2 == 0xa9 or b2 == 0xaf)) or (b1 == 0x81 and b2 == 0x9f),
        0xe3 => b1 == 0x80 and b2 == 0x80,
        0xef => b1 == 0xbb and b2 == 0xbf,
        else => false,
    };
    return if (hit) 3 else 0;
}

const ascii_ident_part = blk: {
    var t: [128]bool = undefined;
    for (&t, 0..) |*x, i| x.* = isIdentPart(i);
    break :blk t;
};

fn identPartAt(src: []const u8, i: usize) bool {
    if (i >= src.len) return false;
    const c = src[i];
    return if (c < 0x80) ascii_ident_part[c] else spaceLen(src, i) == 0;
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub const Lexer = struct {
    src: []const u8,
    a: Allocator,
    diags: std.ArrayList(Diag) = .empty,

    pos: u32 = 0,
    tok: Tok = .eof,
    start: u32 = 0,
    nl_before: bool = false,
    /// Cooked text of the current string or template token; slices the source when no escape occurs.
    value: []const u8 = "",
    /// JSDoc is not part of the grammar here, but `@ts-ignore` directives are found while skipping trivia.
    ts_ignores: std.ArrayList(TsDirective) = .empty,
    /// Escape errors of the template token being scanned wait for the parser: a tag makes them legal
    /// (the cooked value is just undefined), so only an untagged template commits them.
    tpl_escapes: std.ArrayList(Diag) = .empty,
    in_template: bool = false,

    pub const TsDirective = struct { line_end: u32, expect_error: bool };

    pub const State = struct { pos: u32, tok: Tok, start: u32, nl_before: bool, value: []const u8, diags: usize, directives: usize };

    pub fn save(l: *const Lexer) State {
        return .{ .pos = l.pos, .tok = l.tok, .start = l.start, .nl_before = l.nl_before, .value = l.value, .diags = l.diags.items.len, .directives = l.ts_ignores.items.len };
    }
    pub fn restore(l: *Lexer, s: State) void {
        l.pos = s.pos;
        l.tok = s.tok;
        l.start = s.start;
        l.nl_before = s.nl_before;
        l.value = s.value;
        l.diags.items.len = s.diags;
        l.ts_ignores.items.len = s.directives;
    }

    pub fn err(l: *Lexer, start: u32, len: u32, code: u32, msg: []const u8) void {
        if (l.diags.items.len > 0 and l.diags.items[l.diags.items.len - 1].start == start) return;
        l.diags.append(l.a, .{ .start = start, .len = len, .code = code, .msg = msg }) catch @panic("out of memory");
    }

    fn escapeErr(l: *Lexer, start: u32, len: u32, code: u32, msg: []const u8) void {
        if (!l.in_template) return l.err(start, len, code, msg);
        l.tpl_escapes.append(l.a, .{ .start = start, .len = len, .code = code, .msg = msg }) catch @panic("out of memory");
    }

    pub fn commitTemplateEscapes(l: *Lexer) void {
        for (l.tpl_escapes.items) |d| l.err(d.start, d.len, d.code, d.msg);
        l.tpl_escapes.clearRetainingCapacity();
    }

    fn peek(l: *const Lexer, off: u32) u8 {
        const i = l.pos + off;
        return if (i < l.src.len) l.src[i] else 0;
    }

    pub fn text(l: *const Lexer) []const u8 {
        return l.src[l.start..l.pos];
    }

    /// Mirrors tsc's directive regexes: for a block comment `comment` is its last line, and any run of
    /// `/` and `*` may precede the `@`, so `/*** @ts-ignore */` and a trailing ` * @ts-ignore */` count.
    fn scanDirective(l: *Lexer, comment: []const u8, end: u32) void {
        const ws = " \t\r\n\x0b\x0c";
        var s = std.mem.trimStart(u8, std.mem.trimStart(u8, std.mem.trimStart(u8, comment, ws), "/*"), ws);
        if (!std.mem.startsWith(u8, s, "@ts-")) return;
        s = s[4..];
        const expect = std.mem.startsWith(u8, s, "expect-error");
        if (!expect and !std.mem.startsWith(u8, s, "ignore")) return;
        l.ts_ignores.append(l.a, .{ .line_end = end, .expect_error = expect }) catch @panic("out of memory");
    }

    fn skipTrivia(l: *Lexer) void {
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            switch (c) {
                ' ', '\t', 0x0b, 0x0c => l.pos += 1,
                '\n', '\r' => {
                    l.nl_before = true;
                    l.pos += 1;
                },
                '/' => {
                    const n = l.peek(1);
                    if (n == '/') {
                        const s = l.pos;
                        while (l.pos < l.src.len and l.src[l.pos] != '\n' and l.src[l.pos] != '\r') l.pos += 1;
                        l.scanDirective(l.src[s + 2 .. l.pos], l.pos);
                    } else if (n == '*') {
                        const s = l.pos;
                        l.pos += 2;
                        // Comments are a good part of a source file, so this jumps between stars.
                        const body = l.pos;
                        var star = std.mem.indexOfScalarPos(u8, l.src, body, '*');
                        while (star) |x| {
                            if (x + 1 < l.src.len and l.src[x + 1] == '/') break;
                            star = std.mem.indexOfScalarPos(u8, l.src, x + 1, '*');
                        }
                        const end = star orelse l.src.len;
                        var last_line = s;
                        if (std.mem.lastIndexOfAny(u8, l.src[body..end], "\n\r")) |i| {
                            l.nl_before = true;
                            last_line = body + @as(u32, @intCast(i)) + 1;
                        }
                        l.pos = @intCast(end);
                        if (star != null) l.pos += 2 else l.err(l.pos, 0, 1010, "'*/' expected.");
                        l.scanDirective(l.src[last_line..l.pos], l.pos);
                    } else return;
                },
                0xc2, 0xe1, 0xe2, 0xe3, 0xef => {
                    const n = spaceLen(l.src, l.pos);
                    if (n == 0) return;
                    // U+2028 and U+2029 are line terminators.
                    if (c == 0xe2 and l.peek(1) == 0x80 and (l.peek(2) == 0xa8 or l.peek(2) == 0xa9)) l.nl_before = true;
                    l.pos += n;
                },
                '#' => {
                    if (l.pos == 0 and l.peek(1) == '!') {
                        while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
                    } else return;
                },
                else => return,
            }
        }
    }

    fn single(l: *Lexer, n: u32, t: Tok) Tok {
        l.pos += n;
        return t;
    }

    pub fn next(l: *Lexer) Tok {
        l.nl_before = false;
        l.skipTrivia();
        l.start = l.pos;
        l.tok = l.scan();
        return l.tok;
    }

    fn scan(l: *Lexer) Tok {
        if (l.pos >= l.src.len) return .eof;
        const c = l.src[l.pos];
        const c1 = l.peek(1);
        const c2 = l.peek(2);
        switch (c) {
            '{' => return l.single(1, .l_brace),
            '}' => return l.single(1, .r_brace),
            '(' => return l.single(1, .l_paren),
            ')' => return l.single(1, .r_paren),
            '[' => return l.single(1, .l_bracket),
            ']' => return l.single(1, .r_bracket),
            ';' => return l.single(1, .semi),
            ',' => return l.single(1, .comma),
            ':' => return l.single(1, .colon),
            '~' => return l.single(1, .tilde),
            '@' => return l.single(1, .at),
            '.' => {
                if (isDigit(c1)) return l.scanNumber();
                if (c1 == '.' and c2 == '.') return l.single(3, .dot3);
                return l.single(1, .dot);
            },
            '<' => {
                if (c1 == '<') return if (c2 == '=') l.single(3, .shl_assign) else l.single(2, .shl);
                if (c1 == '=') return l.single(2, .lte);
                return l.single(1, .lt);
            },
            // `>` stays a single token: closing a type argument list must not merge into `>>`.
            // The parser calls rescanGreater in expression position.
            '>' => return l.single(1, .gt),
            '=' => {
                if (c1 == '=') return if (c2 == '=') l.single(3, .eq3) else l.single(2, .eq2);
                if (c1 == '>') return l.single(2, .arrow);
                return l.single(1, .assign);
            },
            '!' => {
                if (c1 == '=') return if (c2 == '=') l.single(3, .neq3) else l.single(2, .neq);
                return l.single(1, .bang);
            },
            '+' => {
                if (c1 == '+') return l.single(2, .plus2);
                if (c1 == '=') return l.single(2, .plus_assign);
                return l.single(1, .plus);
            },
            '-' => {
                if (c1 == '-') return l.single(2, .minus2);
                if (c1 == '=') return l.single(2, .minus_assign);
                return l.single(1, .minus);
            },
            '*' => {
                if (c1 == '*') return if (c2 == '=') l.single(3, .star2_assign) else l.single(2, .star2);
                if (c1 == '=') return l.single(2, .star_assign);
                return l.single(1, .star);
            },
            '/' => {
                if (c1 == '=') return l.single(2, .slash_assign);
                return l.single(1, .slash);
            },
            '%' => {
                if (c1 == '=') return l.single(2, .percent_assign);
                return l.single(1, .percent);
            },
            '&' => {
                if (c1 == '&') return if (c2 == '=') l.single(3, .amp2_assign) else l.single(2, .amp2);
                if (c1 == '=') return l.single(2, .amp_assign);
                return l.single(1, .amp);
            },
            '|' => {
                if (c1 == '|') return if (c2 == '=') l.single(3, .pipe2_assign) else l.single(2, .pipe2);
                if (c1 == '=') return l.single(2, .pipe_assign);
                return l.single(1, .pipe);
            },
            '^' => {
                if (c1 == '=') return l.single(2, .caret_assign);
                return l.single(1, .caret);
            },
            '?' => {
                if (c1 == '?') return if (c2 == '=') l.single(3, .qq_assign) else l.single(2, .qq);
                // `a?.5:b` is a conditional with a decimal, not optional chaining.
                if (c1 == '.' and !isDigit(c2)) return l.single(2, .question_dot);
                return l.single(1, .question);
            },
            '\'', '"' => return l.scanString(c),
            '`' => {
                l.pos += 1;
                return l.scanTemplate(true);
            },
            '0'...'9' => return l.scanNumber(),
            '#' => {
                if (isIdentStart(c1)) {
                    l.pos += 1;
                    while (identPartAt(l.src, l.pos)) l.pos += 1;
                    l.value = l.src[l.start..l.pos];
                    return .private_name;
                }
                l.err(l.pos, 1, 1127, "Invalid character.");
                l.pos += 1;
                return .unknown;
            },
            '\\' => {
                if (c1 == 'u') return l.scanEscapedIdentifier();
                // Consumes the byte: an empty identifier here would stall the parser for good.
                l.err(l.pos, 1, 1127, "Invalid character.");
                l.pos += 1;
                return .unknown;
            },
            else => {
                if (isIdentStart(c)) {
                    while (identPartAt(l.src, l.pos)) l.pos += 1;
                    if (l.pos < l.src.len and l.src[l.pos] == '\\') return l.scanEscapedIdentifier();
                    l.value = l.src[l.start..l.pos];
                    return keywordOf(l.value);
                }
                l.err(l.pos, 1, 1127, "Invalid character.");
                l.pos += 1;
                return .unknown;
            },
        }
    }

    fn scanEscapedIdentifier(l: *Lexer) Tok {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(l.a, l.src[l.start..l.pos]) catch @panic("out of memory");
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\\' and l.peek(1) == 'u') {
                l.pos += 2;
                l.cookUnicode(&buf);
            } else if (identPartAt(l.src, l.pos)) {
                buf.append(l.a, c) catch @panic("out of memory");
                l.pos += 1;
            } else break;
        }
        l.value = buf.items;
        return .identifier;
    }

    fn scanDigits(l: *Lexer, comptime pred: fn (u8) bool) void {
        while (l.pos < l.src.len and (pred(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
    }

    fn scanNumber(l: *Lexer) Tok {
        const c1 = l.peek(1);
        if (l.src[l.pos] == '0' and (c1 | 32 == 'x' or c1 | 32 == 'o' or c1 | 32 == 'b')) {
            l.pos += 2;
            if (c1 | 32 == 'x') l.scanDigits(std.ascii.isHex) else l.scanDigits(isDigit);
        } else {
            l.scanDigits(isDigit);
            if (l.pos < l.src.len and l.src[l.pos] == '.') {
                l.pos += 1;
                l.scanDigits(isDigit);
            }
            if (l.pos < l.src.len and l.src[l.pos] | 32 == 'e') {
                const n = l.peek(1);
                if (isDigit(n) or ((n == '+' or n == '-') and isDigit(l.peek(2)))) {
                    l.pos += 2;
                    l.scanDigits(isDigit);
                }
            }
        }
        if (l.pos < l.src.len and l.src[l.pos] == 'n') {
            l.pos += 1;
            l.value = l.src[l.start..l.pos];
            return .bigint;
        }
        l.value = l.src[l.start..l.pos];
        if (l.pos < l.src.len and isIdentStart(l.src[l.pos])) {
            l.err(l.pos, 1, 1351, "An identifier or keyword cannot immediately follow a numeric literal.");
        }
        return .numeric;
    }

    fn appendCodepoint(l: *Lexer, buf: *std.ArrayList(u8), cp: u21) void {
        var tmp: [4]u8 = undefined;
        // Lone surrogates are legal in JS strings; WTF-8 keeps them round-trippable.
        const n = std.unicode.wtf8Encode(cp, &tmp) catch 0;
        buf.appendSlice(l.a, tmp[0..n]) catch @panic("out of memory");
    }

    fn hexValue(l: *Lexer, digits: u32) ?u21 {
        var v: u21 = 0;
        var i: u32 = 0;
        while (i < digits) : (i += 1) {
            const d = std.fmt.charToDigit(l.peek(i), 16) catch return null;
            v = v * 16 + d;
        }
        l.pos += digits;
        return v;
    }

    /// Expects `pos` just past `\u`.
    fn cookUnicode(l: *Lexer, buf: *std.ArrayList(u8)) void {
        if (l.peek(0) == '{') {
            l.pos += 1;
            var v: u32 = 0;
            while (l.pos < l.src.len and l.src[l.pos] != '}') {
                const d = std.fmt.charToDigit(l.src[l.pos], 16) catch break;
                v = v *| 16 +| d;
                l.pos += 1;
            }
            if (l.peek(0) == '}') l.pos += 1;
            if (v > 0x10ffff) {
                l.escapeErr(l.pos, 0, 1198, "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.");
                return;
            }
            l.appendCodepoint(buf, @intCast(v));
            return;
        }
        const hi = l.hexValue(4) orelse {
            l.escapeErr(l.pos, 1, 1125, "Hexadecimal digit expected.");
            return;
        };
        if (hi >= 0xd800 and hi < 0xdc00 and l.peek(0) == '\\' and l.peek(1) == 'u') {
            const save_pos = l.pos;
            l.pos += 2;
            if (l.hexValue(4)) |lo| {
                if (lo >= 0xdc00 and lo < 0xe000) {
                    l.appendCodepoint(buf, 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00));
                    return;
                }
            }
            l.pos = save_pos;
        }
        l.appendCodepoint(buf, hi);
    }

    /// Expects `pos` on the backslash.
    fn cookEscape(l: *Lexer, buf: *std.ArrayList(u8)) void {
        l.pos += 1;
        // A backslash ending the file: the caller reports the unterminated literal.
        if (l.pos >= l.src.len) return;
        const e = l.src[l.pos];
        l.pos += 1;
        const out: ?u8 = switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            'v' => 11,
            '0' => if (isDigit(l.peek(0))) null else 0,
            '\n' => return,
            '\r' => {
                if (l.peek(0) == '\n') l.pos += 1;
                return;
            },
            'x' => {
                const v = l.hexValue(2) orelse {
                    l.escapeErr(l.pos, 1, 1125, "Hexadecimal digit expected.");
                    return;
                };
                l.appendCodepoint(buf, v);
                return;
            },
            'u' => {
                l.cookUnicode(buf);
                return;
            },
            else => e,
        };
        buf.append(l.a, out orelse e) catch @panic("out of memory");
    }

    fn scanString(l: *Lexer, q: u8) Tok {
        l.pos += 1;
        const body = l.pos;
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == q) {
                l.value = l.src[body..l.pos];
                l.pos += 1;
                return .string;
            }
            if (c == '\\' or c == '\n' or c == '\r') break;
            l.pos += 1;
        }
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(l.a, l.src[body..l.pos]) catch @panic("out of memory");
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == q) {
                l.pos += 1;
                l.value = buf.items;
                return .string;
            }
            if (c == '\n' or c == '\r') break;
            if (c == '\\') {
                l.cookEscape(&buf);
            } else {
                buf.append(l.a, c) catch @panic("out of memory");
                l.pos += 1;
            }
        }
        l.err(l.start, l.pos - l.start, 1002, "Unterminated string literal.");
        l.value = buf.items;
        return .string;
    }

    /// Continues from `pos`, just past a backtick or the `}` closing a substitution.
    fn scanTemplate(l: *Lexer, head: bool) Tok {
        var buf: std.ArrayList(u8) = .empty;
        l.tpl_escapes.clearRetainingCapacity();
        l.in_template = true;
        defer l.in_template = false;
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '`') {
                l.pos += 1;
                l.value = buf.items;
                return if (head) .no_subst_template else .template_tail;
            }
            if (c == '$' and l.peek(1) == '{') {
                l.pos += 2;
                l.value = buf.items;
                return if (head) .template_head else .template_middle;
            }
            if (c == '\\') {
                l.cookEscape(&buf);
            } else {
                buf.append(l.a, c) catch @panic("out of memory");
                l.pos += 1;
            }
        }
        l.err(l.pos, 0, 1160, "Unterminated template literal.");
        l.value = buf.items;
        return if (head) .no_subst_template else .template_tail;
    }

    pub fn rescanTemplate(l: *Lexer) Tok {
        l.pos = l.start + 1;
        l.tok = l.scanTemplate(false);
        return l.tok;
    }

    pub fn rescanGreater(l: *Lexer) Tok {
        if (l.tok != .gt) return l.tok;
        const c0 = l.peek(0);
        const c1 = l.peek(1);
        const c2 = l.peek(2);
        if (c0 == '>') {
            if (c1 == '>') {
                if (c2 == '=') {
                    l.pos += 3;
                    l.tok = .ushr_assign;
                } else {
                    l.pos += 2;
                    l.tok = .ushr;
                }
            } else if (c1 == '=') {
                l.pos += 2;
                l.tok = .shr_assign;
            } else {
                l.pos += 1;
                l.tok = .shr;
            }
        } else if (c0 == '=') {
            l.pos += 1;
            l.tok = .gte;
        }
        return l.tok;
    }

    /// A `<<` in type position opens two generic lists, e.g. `f<<T>(x: T) => T>()`.
    pub fn rescanLessThan(l: *Lexer) void {
        if (l.tok == .shl) {
            l.pos = l.start + 1;
            l.tok = .lt;
        }
    }

    pub fn rescanRegex(l: *Lexer) Tok {
        var p = l.start + 1;
        var in_class = false;
        while (true) : (p += 1) {
            if (p >= l.src.len or l.src[p] == '\n' or l.src[p] == '\r') {
                l.err(l.start, p - l.start, 1161, "Unterminated regular expression literal.");
                break;
            }
            const c = l.src[p];
            if (c == '\\') {
                // A backslash may not escape the end of the file or line; both are unterminated.
                if (p + 1 < l.src.len and l.src[p + 1] != '\n' and l.src[p + 1] != '\r') p += 1;
            } else if (c == '[') {
                in_class = true;
            } else if (c == ']') {
                in_class = false;
            } else if (c == '/' and !in_class) {
                p += 1;
                while (identPartAt(l.src, p)) p += 1;
                break;
            }
        }
        l.pos = p;
        l.tok = .regex;
        l.value = l.src[l.start..p];
        return .regex;
    }

    pub fn nextJsxChild(l: *Lexer) Tok {
        l.start = l.pos;
        l.nl_before = false;
        if (l.pos >= l.src.len) {
            l.tok = .eof;
            return .eof;
        }
        const c = l.src[l.pos];
        if (c == '<') {
            if (l.peek(1) == '/') {
                l.pos += 2;
                l.tok = .lt_slash;
            } else {
                l.pos += 1;
                l.tok = .lt;
            }
            return l.tok;
        }
        if (c == '{') {
            l.pos += 1;
            l.tok = .l_brace;
            return l.tok;
        }
        while (l.pos < l.src.len and l.src[l.pos] != '<' and l.src[l.pos] != '{') l.pos += 1;
        l.value = l.src[l.start..l.pos];
        l.tok = .jsx_text;
        return l.tok;
    }

    /// Extends an identifier over the `-` that JSX names allow.
    pub fn extendJsxIdentifier(l: *Lexer) void {
        if (!l.tok.isIdentifierLike() and !l.tok.isKeyword()) return;
        while (identPartAt(l.src, l.pos) or (l.pos < l.src.len and l.src[l.pos] == '-')) l.pos += 1;
        l.value = l.src[l.start..l.pos];
        l.tok = .identifier;
    }

    /// JSX attribute strings have no escape sequences.
    pub fn nextJsxAttrValue(l: *Lexer) Tok {
        l.nl_before = false;
        l.skipTrivia();
        l.start = l.pos;
        const q = if (l.pos < l.src.len) l.src[l.pos] else 0;
        if (q == '"' or q == '\'') {
            l.pos += 1;
            while (l.pos < l.src.len and l.src[l.pos] != q) l.pos += 1;
            l.value = l.src[l.start + 1 .. l.pos];
            if (l.pos < l.src.len) l.pos += 1 else l.err(l.start, l.pos - l.start, 1002, "Unterminated string literal.");
            l.tok = .string;
            return .string;
        }
        l.tok = l.scan();
        return l.tok;
    }
};

test "keywords and greater-than splitting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer{ .src = "interface x >>= `a${", .a = arena.allocator() };
    try std.testing.expectEqual(Tok.kw_interface, l.next());
    try std.testing.expectEqual(Tok.identifier, l.next());
    try std.testing.expectEqual(Tok.gt, l.next());
    try std.testing.expectEqual(Tok.shr_assign, l.rescanGreater());
    try std.testing.expectEqual(Tok.template_head, l.next());
    try std.testing.expectEqualStrings("a", l.value);
}

test "string escapes are cooked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer{ .src = "'a\\n\\u{1F600}\\x41'", .a = arena.allocator() };
    _ = l.next();
    try std.testing.expectEqualStrings("a\n\u{1F600}A", l.value);
}

test "a trailing backslash does not run past the end of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "\"\\", "`\\", "'ab\\" }) |src| {
        var l = Lexer{ .src = src, .a = arena.allocator() };
        _ = l.next();
        try std.testing.expect(l.pos <= l.src.len);
        try std.testing.expect(l.diags.items.len > 0);
        try std.testing.expectEqual(Tok.eof, l.next());
    }
    var l = Lexer{ .src = "x = /\\", .a = arena.allocator() };
    _ = l.next();
    _ = l.next();
    try std.testing.expectEqual(Tok.slash, l.next());
    try std.testing.expectEqual(Tok.regex, l.rescanRegex());
    try std.testing.expectEqual(@as(usize, 1), l.diags.items.len);
    try std.testing.expectEqual(@as(u32, 1161), l.diags.items[0].code);
    try std.testing.expectEqual(Tok.eof, l.next());
}

test "an extended unicode escape with too many digits is out of range, not wrapped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer{ .src = "\"\\u{FFFFFFFFF}\"", .a = arena.allocator() };
    try std.testing.expectEqual(Tok.string, l.next());
    try std.testing.expectEqual(@as(usize, 1), l.diags.items.len);
    try std.testing.expectEqual(@as(u32, 1198), l.diags.items[0].code);
}

test "template escape errors wait for the parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer{ .src = "`\\xZZ` `ok`", .a = arena.allocator() };
    try std.testing.expectEqual(Tok.no_subst_template, l.next());
    try std.testing.expectEqual(@as(usize, 0), l.diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), l.tpl_escapes.items.len);
    l.commitTemplateEscapes();
    try std.testing.expectEqual(@as(usize, 1), l.diags.items.len);
    try std.testing.expectEqual(@as(u32, 1125), l.diags.items[0].code);
    try std.testing.expectEqual(Tok.no_subst_template, l.next());
    try std.testing.expectEqual(@as(usize, 0), l.tpl_escapes.items.len);
}

test "ts directives in block comments follow tsc's last-line rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const honoured = [_][]const u8{ "/*** @ts-ignore */ x", "/*\n   * @ts-expect-error */ x", "// @ts-ignore\nx", "/* @ts-ignore */ x" };
    for (honoured) |src| {
        var l = Lexer{ .src = src, .a = arena.allocator() };
        try std.testing.expectEqual(Tok.identifier, l.next());
        try std.testing.expectEqual(@as(usize, 1), l.ts_ignores.items.len);
        try std.testing.expectEqual(@as(u32, @intCast(src.len - 2)), l.ts_ignores.items[0].line_end);
    }
    const ignored = [_][]const u8{ "/*\n  @ts-ignore\n*/ x", "/**\n * @ts-ignore\n */ x", "/* x @ts-ignore */ x" };
    for (ignored) |src| {
        var l = Lexer{ .src = src, .a = arena.allocator() };
        try std.testing.expectEqual(Tok.identifier, l.next());
        try std.testing.expectEqual(@as(usize, 0), l.ts_ignores.items.len);
    }
}

test "unicode spaces are trivia, not identifier parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "\u{1680}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{00A0}", "\u{2003}" }) |sp| {
        const src = try std.mem.concat(arena.allocator(), u8, &.{ "a", sp, "= 1" });
        var l = Lexer{ .src = src, .a = arena.allocator() };
        try std.testing.expectEqual(Tok.identifier, l.next());
        try std.testing.expectEqualStrings("a", l.text());
        try std.testing.expectEqual(Tok.assign, l.next());
        try std.testing.expectEqual(Tok.numeric, l.next());
        try std.testing.expectEqual(Tok.eof, l.next());
    }
}
