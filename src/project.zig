const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fspath = std.fs.path;
const json = std.json;
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const parser = @import("parser.zig");
const pool = @import("pool.zig");
const Bump = @import("bump.zig").Bump;
const emit = @import("emit.zig");
const Symbol = binder.Symbol;
const SymbolTable = binder.SymbolTable;
const F = binder.F;

fn oom() noreturn {
    @panic("out of memory");
}

/// Field names are the tsconfig keys: options load through reflection.
pub const Options = struct {
    strict: ?bool = null,
    noImplicitAny: ?bool = null,
    strictNullChecks: ?bool = null,
    strictFunctionTypes: ?bool = null,
    strictBindCallApply: ?bool = null,
    strictPropertyInitialization: ?bool = null,
    noImplicitThis: ?bool = null,
    useUnknownInCatchVariables: ?bool = null,
    noImplicitReturns: ?bool = null,
    noFallthroughCasesInSwitch: ?bool = null,
    noUncheckedIndexedAccess: ?bool = null,
    noUncheckedSideEffectImports: ?bool = null,
    exactOptionalPropertyTypes: ?bool = null,
    noPropertyAccessFromIndexSignature: ?bool = null,
    noImplicitOverride: ?bool = null,
    noUnusedLocals: ?bool = null,
    noUnusedParameters: ?bool = null,
    esModuleInterop: ?bool = null,
    allowSyntheticDefaultImports: ?bool = null,
    resolveJsonModule: ?bool = null,
    skipLibCheck: ?bool = null,
    skipDefaultLibCheck: ?bool = null,
    noEmit: ?bool = null,
    noLib: ?bool = null,
    verbatimModuleSyntax: ?bool = null,
    allowImportingTsExtensions: ?bool = null,
    rewriteRelativeImportExtensions: ?bool = null,
    allowJs: ?bool = null,
    checkJs: ?bool = null,
    noCheck: ?bool = null,
    allowUnreachableCode: ?bool = null,
    preserveConstEnums: ?bool = null,
    isolatedModules: ?bool = null,
    useDefineForClassFields: ?bool = null,
    target: ?[]const u8 = null,
    module: ?[]const u8 = null,
    moduleResolution: ?[]const u8 = null,
    moduleDetection: ?[]const u8 = null,
    jsx: ?[]const u8 = null,
    jsxFactory: ?[]const u8 = null,
    jsxFragmentFactory: ?[]const u8 = null,
    jsxImportSource: ?[]const u8 = null,
    experimentalDecorators: ?bool = null,
    reactNamespace: ?[]const u8 = null,
    outDir: ?[]const u8 = null,
    rootDir: ?[]const u8 = null,
    baseUrl: ?[]const u8 = null,
    lib: ?[]const []const u8 = null,
    types: ?[]const []const u8 = null,
    typeRoots: ?[]const []const u8 = null,

    pub fn flag(o: Options, comptime name: []const u8) bool {
        return @field(o, name) orelse o.strict orelse false;
    }

    /// tsc's `moduleDetection`: what makes a file a module with no import or export in it.
    /// Declaration files stay out, as `declare` globals rely on it.
    pub fn forcesModule(o: Options, path: []const u8) bool {
        const eql = std.ascii.eqlIgnoreCase;
        const kind = o.moduleDetection orelse blk: {
            const m = o.module orelse break :blk "auto";
            const node = eql(m, "node16") or eql(m, "node18") or eql(m, "node20") or eql(m, "nodenext");
            break :blk if (node) "force" else "auto";
        };
        if (eql(kind, "force")) return true;
        if (eql(kind, "legacy")) return false;
        for ([_][]const u8{ ".mts", ".cts", ".mjs", ".cjs" }) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
        return false;
    }

    /// The emit format `module` asks for, by what it means for resolving imports.
    pub fn moduleFormat(o: Options) enum { cjs, esm, node, preserve, other } {
        const eql = std.ascii.eqlIgnoreCase;
        const m = o.module orelse {
            const t = o.target orelse return .esm;
            return if (eql(t, "es3") or eql(t, "es5")) .cjs else .esm;
        };
        if (eql(m, "commonjs")) return .cjs;
        if (eql(m, "preserve")) return .preserve;
        if (eql(m, "node16") or eql(m, "node18") or eql(m, "node20") or eql(m, "nodenext")) return .node;
        if (eql(m, "amd") or eql(m, "umd") or eql(m, "system") or eql(m, "none")) return .other;
        return .esm;
    }

    /// tsc 7 dropped `node10` and `classic`: anything but Node's own modes resolves like a bundler.
    pub fn nodeResolution(o: Options) bool {
        const eql = std.ascii.eqlIgnoreCase;
        if (o.moduleResolution) |m| {
            if (eql(m, "node16") or eql(m, "nodenext")) return true;
            if (eql(m, "bundler")) return false;
        }
        return o.moduleFormat() == .node;
    }

    /// tsc's `canIncludeBindAndCheckDiagnostics`. A JavaScript file with neither `checkJs` nor a
    /// `@ts-check` comment is still checked, but keeps only the errors in `plain_js_errors`.
    pub fn semantics(o: Options, f: *const ast.File) Semantics {
        if (o.noCheck orelse false) return .none;
        const directive = checkDirective(f.src);
        if (directive == false) return .none;
        if (!isJs(f.path)) return .all;
        if (directive orelse o.checkJs) |on| return if (on) .all else .none;
        return .plain;
    }

    pub fn jsxMode(o: Options) emit.Jsx {
        const v = o.jsx orelse return .preserve;
        if (std.ascii.eqlIgnoreCase(v, "react")) return .react;
        if (std.ascii.eqlIgnoreCase(v, "react-jsx")) return .react_jsx;
        if (std.ascii.eqlIgnoreCase(v, "react-jsxdev")) return .react_jsxdev;
        return .preserve;
    }
};

pub const Semantics = enum { all, plain, none };

pub fn isJs(path: []const u8) bool {
    for ([_][]const u8{ ".js", ".jsx", ".mjs", ".cjs" }) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

/// The last `// @ts-check` or `// @ts-nocheck` among the comments before the first token, as
/// tsc reads pragmas.
fn checkDirective(src: []const u8) ?bool {
    var out: ?bool = null;
    var i: usize = if (std.mem.startsWith(u8, src, "\xef\xbb\xbf")) 3 else 0;
    if (std.mem.startsWith(u8, src[i..], "#!")) i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
    while (i < src.len) {
        switch (src[i]) {
            ' ', '\t', '\r', '\n', 0x0b, 0x0c => i += 1,
            '/' => {
                if (std.mem.startsWith(u8, src[i..], "//")) {
                    const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
                    var line = src[i + 2 .. end];
                    if (std.mem.startsWith(u8, line, "/")) line = line[1..];
                    line = std.mem.trimStart(u8, line, " \t");
                    if (std.mem.startsWith(u8, line, "@")) {
                        const name_end = std.mem.indexOfAny(u8, line, " \t\r:") orelse line.len;
                        const name = line[1..name_end];
                        if (std.ascii.eqlIgnoreCase(name, "ts-check")) out = true;
                        if (std.ascii.eqlIgnoreCase(name, "ts-nocheck")) out = false;
                    }
                    i = end;
                } else if (std.mem.startsWith(u8, src[i..], "/*")) {
                    i = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |e| e + 2 else src.len;
                } else return out;
            },
            else => return out,
        }
    }
    return out;
}

/// tsc's `plainJSErrors`: the binder and grammar errors it keeps for an unchecked JavaScript file.
pub fn plainJsError(code: u32) bool {
    return std.mem.indexOfScalar(u32, &plain_js_errors, code) != null;
}

const plain_js_errors = [_]u32{
    2451,  2528,  2753,  2752, 1262,  1214,  1359,  18012, 1102, 1210,  1215,  1100,  1344,  1101,  1105, 1116,
    1211,  1248,  1171,  1104, 1115,  1113,  1258,  18117, 1255, 1182,  1054,  2501,  2566,  1186,  2462, 1048,
    1014,  1013,  18041, 1053, 1049,  18111, 1474,  1193,  1473, 1191,  1162,  1325,  2803,  2492,  1197, 18036,
    1174,  18006, 1312,  1114, 1450,  18038, 17000, 17001, 18007, 2633, 1107,  1200,  1184,  18112, 1091, 1188,
    18114, 18016, 1451,  18013, 18115, 18113, 1358, 1106,  1189,  1190, 1009,  1123,  5076,  1005,  18061, 17012,
    1097,  1030,  1089,  1044, 1090,  1031,  1042,  1029, 1156,  1155,  1172,  2480,  1368,  1341,  1308, 2852,
    1111,  2839,  1206,
};

pub const PathMapping = struct { pattern: []const u8, targets: []const []const u8 };

pub const Config = struct {
    /// Directory of the tsconfig, or the scanned directory.
    root: []const u8,
    path: ?[]const u8 = null,
    options: Options = .{},
    files: ?[]const []const u8 = null,
    include: ?[]const []const u8 = null,
    exclude: ?[]const []const u8 = null,
    paths: []const PathMapping = &.{},
    paths_base: []const u8 = "",
};

pub const Ctx = struct {
    a: Allocator,
    io: Io,
};

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn readFile(a: Allocator, io: Io, path: []const u8) ![]u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    return readOpen(a, io, f, path, try f.length(io));
}

fn readOpen(a: Allocator, io: Io, f: Io.File, path: []const u8, size: u64) ![]u8 {
    // A pipe or a device says nothing about its size; a file is one read into a buffer that fits.
    if (size == 0) return Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    const buf = try a.alloc(u8, size);
    return buf[0..try f.readPositionalAll(io, buf, 0)];
}

/// Below this a file shares its pages with too little to be worth a mapping.
const least_mapped = 16 * 1024;

/// The file cache has these bytes already, and a mapping leaves one copy the kernel can drop where
/// a read makes a second it cannot. Most source bytes are in files this large.
fn readSource(a: Allocator, io: Io, path: []const u8) ![]u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const size = try f.length(io);
    if (size >= least_mapped) {
        if (f.createMemoryMap(io, .{ .len = size, .protection = .{ .read = true }, .populate = false })) |m| return m.memory else |_| {}
    }
    return readOpen(a, io, f, path, size);
}

/// tsconfig is JSON with comments and trailing commas; std.json takes neither.
pub fn stripJsonc(a: Allocator, src: []const u8) []const u8 {
    var out = a.alloc(u8, src.len) catch oom();
    var n: usize = 0;
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) {
        const c = src[i];
        if (in_str) {
            out[n] = c;
            n += 1;
            i += 1;
            if (c == '\\' and i < src.len) {
                out[n] = src[i];
                n += 1;
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i += 2;
            continue;
        } else if (c == ',') {
            var j = i + 1;
            while (j < src.len) {
                if (std.ascii.isWhitespace(src[j])) {
                    j += 1;
                } else if (src[j] == '/' and j + 1 < src.len and src[j + 1] == '/') {
                    while (j < src.len and src[j] != '\n') j += 1;
                } else if (src[j] == '/' and j + 1 < src.len and src[j + 1] == '*') {
                    j += 2;
                    while (j + 1 < src.len and !(src[j] == '*' and src[j + 1] == '/')) j += 1;
                    j += 2;
                } else break;
            }
            if (j < src.len and (src[j] == '}' or src[j] == ']')) {
                i += 1;
                continue;
            }
        }
        out[n] = c;
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn stringList(a: Allocator, v: json.Value) ?[]const []const u8 {
    if (v != .array) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |x| if (x == .string) out.append(a, x.string) catch oom();
    return out.items;
}

fn applyOptions(a: Allocator, cfg: *Config, base: []const u8, co: json.ObjectMap) void {
    const info = @typeInfo(Options).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (co.get(name)) |v| {
            if (T == ?bool) {
                if (v == .bool) @field(cfg.options, name) = v.bool;
            } else if (T == ?[]const u8) {
                if (v == .string) {
                    const is_path = comptime (std.mem.eql(u8, name, "outDir") or std.mem.eql(u8, name, "rootDir") or std.mem.eql(u8, name, "baseUrl"));
                    @field(cfg.options, name) = if (is_path) fspath.resolve(a, &.{ base, v.string }) catch oom() else v.string;
                }
            } else {
                if (stringList(a, v)) |l| @field(cfg.options, name) = l;
            }
        }
    }
    if (co.get("paths")) |p| if (p == .object) {
        var list: std.ArrayList(PathMapping) = .empty;
        var it = p.object.iterator();
        while (it.next()) |e| {
            list.append(a, .{ .pattern = e.key_ptr.*, .targets = stringList(a, e.value_ptr.*) orelse &.{} }) catch oom();
        }
        cfg.paths = list.items;
        cfg.paths_base = cfg.options.baseUrl orelse base;
    };
}

fn resolveExtends(c: Ctx, base: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, ".") or fspath.isAbsolute(name)) {
        const p = fspath.resolve(c.a, &.{ base, name }) catch oom();
        if (isFile(c.io, p)) return p;
        const q = std.mem.concat(c.a, u8, &.{ p, ".json" }) catch oom();
        return if (isFile(c.io, q)) q else null;
    }
    var dir: ?[]const u8 = base;
    while (dir) |d| : (dir = fspath.dirname(d)) {
        const p = fspath.join(c.a, &.{ d, "node_modules", name }) catch oom();
        if (isFile(c.io, p)) return p;
        const q = std.mem.concat(c.a, u8, &.{ p, ".json" }) catch oom();
        if (isFile(c.io, q)) return q;
        const r = fspath.join(c.a, &.{ p, "tsconfig.json" }) catch oom();
        if (isFile(c.io, r)) return r;
    }
    return null;
}

fn loadInto(c: Ctx, cfg: *Config, path: []const u8, depth: u32) anyerror!void {
    if (depth > 16) return error.ExtendsCycle;
    const base = fspath.dirname(path) orelse ".";
    const text = try readFile(c.a, c.io, path);
    const value = try json.parseFromSliceLeaky(json.Value, c.a, stripJsonc(c.a, text), .{});
    if (value != .object) return error.InvalidConfig;
    const obj = value.object;
    if (obj.get("extends")) |e| {
        if (e == .string) {
            if (resolveExtends(c, base, e.string)) |p| try loadInto(c, cfg, p, depth + 1);
        } else if (stringList(c.a, e)) |list| {
            for (list) |x| if (resolveExtends(c, base, x)) |p| try loadInto(c, cfg, p, depth + 1);
        }
    }
    if (obj.get("compilerOptions")) |co| if (co == .object) applyOptions(c.a, cfg, base, co.object);
    if (obj.get("files")) |v| cfg.files = absList(c.a, base, stringList(c.a, v) orelse &.{});
    if (obj.get("include")) |v| cfg.include = absList(c.a, base, stringList(c.a, v) orelse &.{});
    if (obj.get("exclude")) |v| cfg.exclude = absList(c.a, base, stringList(c.a, v) orelse &.{});
}

fn absList(a: Allocator, base: []const u8, list: []const []const u8) []const []const u8 {
    const out = a.alloc([]const u8, list.len) catch oom();
    for (list, 0..) |x, i| out[i] = fspath.resolve(a, &.{ base, x }) catch oom();
    return out;
}

pub fn loadConfig(c: Ctx, path: []const u8) !Config {
    var cfg = Config{ .root = fspath.dirname(path) orelse ".", .path = path };
    try loadInto(c, &cfg, path, 0);
    return cfg;
}

/// `*`, `?` and `**/`, as in tsconfig exclude patterns. Patterns are absolute.
pub fn globMatch(pat: []const u8, s: []const u8) bool {
    return matchGlob(pat, s, false, true);
}

/// tsc's include wildcards, unlike its excludes, skip a file or directory whose name starts with a dot.
pub fn includeMatch(pat: []const u8, s: []const u8) bool {
    return matchGlob(pat, s, true, true);
}

fn matchGlob(pat: []const u8, s: []const u8, hide_dots: bool, start: bool) bool {
    if (pat.len == 0) return s.len == 0;
    if (std.mem.startsWith(u8, pat, "**/")) {
        const rest = pat[3..];
        if (matchGlob(rest, s, hide_dots, true)) return true;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, s, i, '/')) |p| : (i = p + 1) {
            if (hide_dots and s[i] == '.') return false;
            if (matchGlob(rest, s[p + 1 ..], hide_dots, true)) return true;
        }
        return false;
    }
    const hidden = hide_dots and start and s.len > 0 and s[0] == '.';
    switch (pat[0]) {
        '*' => {
            if (hidden) return false;
            var i: usize = 0;
            while (true) : (i += 1) {
                if (matchGlob(pat[1..], s[i..], hide_dots, start and i == 0)) return true;
                if (i >= s.len or s[i] == '/') return false;
            }
        },
        '?' => return s.len > 0 and s[0] != '/' and !hidden and matchGlob(pat[1..], s[1..], hide_dots, false),
        else => return s.len > 0 and s[0] == pat[0] and matchGlob(pat[1..], s[1..], hide_dots, s[0] == '/'),
    }
}

fn hasWildcard(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

/// `src` in include means everything under it; the same rule makes exclude cover subtrees.
fn expandInclude(a: Allocator, p: []const u8) []const u8 {
    const base = fspath.basename(p);
    if (hasWildcard(base) or std.mem.indexOfScalar(u8, base, '.') != null) return p;
    return std.mem.concat(a, u8, &.{ p, "/**/*" }) catch oom();
}

fn walkRoot(pat: []const u8) []const u8 {
    const w = std.mem.indexOfAny(u8, pat, "*?") orelse return pat;
    const slash = std.mem.lastIndexOfScalar(u8, pat[0..w], '/') orelse return "/";
    return if (slash == 0) "/" else pat[0..slash];
}

pub fn isSourceFile(name: []const u8) bool {
    for ([_][]const u8{ ".ts", ".tsx", ".mts", ".cts" }) |e| if (std.mem.endsWith(u8, name, e)) return true;
    return false;
}

const WalkItem = struct { dirs: std.ArrayList([]const u8) = .empty, files: std.ArrayList([]const u8) = .empty, arena: std.heap.ArenaAllocator };

const Walk = struct {
    fs: *FsCache,
    level: []const []const u8,
    out: []WalkItem,
    excludes: []const []const u8 = &.{},
    js: bool = false,
};

fn walkOne(w: *const Walk, worker: usize, i: usize) void {
    const item = &w.out[worker];
    const a = item.arena.allocator();
    const path = w.level[i];
    const names = switch (w.fs.listing(path).*) {
        .names => |*x| x,
        else => return,
    };
    var it = names.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        // A symlink target may be a directory; tsc follows them, and pnpm stores rely on that.
        const kind = e.value_ptr.*;
        if (kind == .directory) {
            if (std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, "bower_components") or std.mem.eql(u8, name, "jspm_packages")) continue;
            const child = fspath.join(a, &.{ path, name }) catch oom();
            if (!excludedDir(w.excludes, child)) item.dirs.append(a, child) catch oom();
        } else if (kind == .file and (isSourceFile(name) or (w.js and isJs(name)))) {
            item.files.append(a, fspath.join(a, &.{ path, name }) catch oom()) catch oom();
        }
    }
}

/// Breadth-first, one parallel pass per directory level; no queue or lock needed.
pub fn walkDirs(a: Allocator, fs: *FsCache, tp: *pool.ThreadPool, roots: []const []const u8) []const []const u8 {
    return walkFiltered(a, fs, tp, roots, &.{}, false);
}

fn excludedDir(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |pattern| {
        const prefix = if (std.mem.endsWith(u8, pattern, "/**/*")) pattern[0..@max(1, pattern.len - 5)] else continue;
        var dir: ?[]const u8 = path;
        while (dir) |d| : (dir = fspath.dirname(d)) if (globMatch(prefix, d)) return true;
    }
    return false;
}

fn pathLessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn walkFiltered(a: Allocator, fs: *FsCache, tp: *pool.ThreadPool, roots: []const []const u8, excludes: []const []const u8, js: bool) []const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var level: std.ArrayList([]const u8) = .empty;
    level.appendSlice(a, roots) catch oom();
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    while (level.items.len > 0) {
        var count: usize = 0;
        for (level.items) |path| {
            if (excludedDir(excludes, path)) continue;
            // Lexical paths preserve diagnostics; canonical directory identity stops symlink cycles.
            const real = Io.Dir.cwd().realPathFileAlloc(fs.io, path, a) catch path;
            if ((visited.getOrPut(a, real) catch oom()).found_existing) continue;
            level.items[count] = path;
            count += 1;
        }
        level.items.len = count;
        if (count == 0) break;
        const items = a.alloc(WalkItem, tp.width()) catch oom();
        for (items) |*x| x.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
        const w = Walk{ .fs = fs, .level = level.items, .out = items, .excludes = excludes, .js = js };
        pool.parallelFor(tp, level.items.len, &w, walkOne);
        var next: std.ArrayList([]const u8) = .empty;
        for (items) |*x| {
            for (x.files.items) |f| files.append(a, a.dupe(u8, f) catch oom()) catch oom();
            for (x.dirs.items) |d| next.append(a, a.dupe(u8, d) catch oom()) catch oom();
            x.arena.deinit();
        }
        std.mem.sort([]const u8, next.items, {}, pathLessThan);
        level = next;
    }
    std.mem.sort([]const u8, files.items, {}, pathLessThan);
    return files.items;
}

/// Path containment on whole components: `src2` is a sibling of `src`, not inside it.
fn isWithin(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/' or (dir.len > 0 and dir[dir.len - 1] == '/');
}

test "isWithin needs a component boundary" {
    try std.testing.expect(isWithin("/p/src", "/p/src"));
    try std.testing.expect(isWithin("/p/src/a", "/p/src"));
    try std.testing.expect(!isWithin("/p/src2", "/p/src"));
    try std.testing.expect(isWithin("/p/src2", "/p/"));
}

test "project discovery prunes excluded subtrees and terminates directory cycles" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "generated/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "export const value = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "generated/nested/ignored.ts", .data = "export {};" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const excluded = try fspath.join(a, &.{ root, "generated" });
    const cfg = Config{ .root = root, .exclude = &.{excluded} };
    var tp = pool.ThreadPool.init(2);
    const fs = FsCache.create(a, io);
    const files = projectFiles(a, fs, &tp, &cfg);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expect(!fs.shardOf(excluded).dirs.contains(excluded));
    try std.testing.expect(excludedDir(&.{"/**/*"}, root));
    try std.testing.expect(excludedDir(&.{expandInclude(a, excluded)}, try fspath.join(a, &.{ excluded, "nested" })));
    if (@import("builtin").os.tag == .windows) return;
    try tmp.dir.symLink(io, ".", "loop", .{ .is_directory = true });
    const cyclic = projectFiles(a, FsCache.create(a, io), &tp, &cfg);
    try std.testing.expectEqual(@as(usize, 1), cyclic.len);
    try std.testing.expectEqualStrings(files[0], cyclic[0]);
}

test "project discovery keeps the highest-priority extension per name" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.ts", "a.d.ts", "a.js", "b.d.ts", "b.js", "c.js", "d.mjs" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "export {};" });
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    var tp = pool.ThreadPool.init(2);
    const ts_only = projectFiles(a, FsCache.create(a, io), &tp, &Config{ .root = root });
    try std.testing.expectEqual(@as(usize, 2), ts_only.len);
    const cfg = Config{ .root = root, .options = .{ .allowJs = true } };
    const files = projectFiles(a, FsCache.create(a, io), &tp, &cfg);
    var names: std.ArrayList([]const u8) = .empty;
    for (files) |f| try names.append(a, fspath.basename(f));
    std.mem.sort([]const u8, names.items, {}, pathLessThan);
    try std.testing.expectEqual(@as(usize, 5), names.items.len);
    for ([_][]const u8{ "a.ts", "b.d.ts", "b.js", "c.js", "d.mjs" }, names.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

pub fn projectFiles(a: Allocator, fs: *FsCache, tp: *pool.ThreadPool, cfg: *const Config) []const []const u8 {
    const io = fs.io;
    var out: std.ArrayList([]const u8) = .empty;
    if (cfg.files) |listed| out.appendSlice(a, listed) catch oom();
    if (cfg.files != null and cfg.include == null) return out.items;

    const include = cfg.include orelse absList(a, cfg.root, &.{"**/*"});
    var patterns: std.ArrayList([]const u8) = .empty;
    var roots: std.ArrayList([]const u8) = .empty;
    for (include) |p| {
        const pat = expandInclude(a, p);
        patterns.append(a, pat) catch oom();
        const r = walkRoot(pat);
        var nested = false;
        for (roots.items) |x| if (isWithin(r, x)) {
            nested = true;
        };
        if (!nested and exists(io, r)) {
            if (isFile(io, r)) {
                out.append(a, r) catch oom();
            } else roots.append(a, r) catch oom();
        }
    }
    var excludes: std.ArrayList([]const u8) = .empty;
    if (cfg.exclude) |ex| {
        for (ex) |e| excludes.append(a, expandInclude(a, e)) catch oom();
    } else if (cfg.options.outDir) |d| excludes.append(a, expandInclude(a, d)) catch oom();

    const js = cfg.options.allowJs orelse false;
    const groups: []const []const []const u8 = if (js) &all_extension_groups else &ts_extension_groups;
    var literal: std.StringHashMapUnmanaged(void) = .empty;
    for (out.items) |f| literal.put(a, f, {}) catch oom();
    var wildcard: std.StringArrayHashMapUnmanaged(void) = .empty;
    next: for (walkFiltered(a, fs, tp, roots.items, excludes.items, js)) |f| {
        var hit = false;
        for (patterns.items) |p| {
            if (includeMatch(p, f)) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        for (excludes.items) |e| if (globMatch(e, f)) continue :next;
        if (hasHigherPriority(a, f, groups, &literal, &wildcard)) continue;
        removeLowerPriority(a, f, groups, &wildcard);
        if (!literal.contains(f)) wildcard.put(a, f, {}) catch oom();
    }
    out.appendSlice(a, wildcard.keys()) catch oom();
    return out.items;
}

/// tsc's extension priority: of `a.ts`, `a.tsx`, `a.d.ts`, `a.js` and `a.jsx` in one directory,
/// usually compiler output beside its source, only the first one present is a root.
const ts_extension_groups = [_][]const []const u8{ &.{ ".ts", ".tsx", ".d.ts" }, &.{ ".cts", ".d.cts" }, &.{ ".mts", ".d.mts" } };
const all_extension_groups = [_][]const []const u8{ &.{ ".ts", ".tsx", ".d.ts", ".js", ".jsx" }, &.{ ".cts", ".d.cts", ".cjs" }, &.{ ".mts", ".d.mts", ".mjs" } };

fn extensionGroup(a: Allocator, file: []const u8, groups: []const []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (groups) |g| for (g) |ext| if (std.mem.endsWith(u8, file, ext)) {
        out.appendSlice(a, g) catch oom();
        break;
    };
    return out.items;
}

fn withExtension(a: Allocator, file: []const u8, ext: []const u8) []const u8 {
    const known = [_][]const u8{ ".d.mts", ".d.cts", ".d.ts", ".tsx", ".jsx", ".mts", ".cts", ".mjs", ".cjs", ".ts", ".js" };
    const base = for (known) |k| {
        if (std.mem.endsWith(u8, file, k)) break file[0 .. file.len - k.len];
    } else file;
    return std.mem.concat(a, u8, &.{ base, ext }) catch oom();
}

fn hasHigherPriority(a: Allocator, file: []const u8, groups: []const []const []const u8, literal: *const std.StringHashMapUnmanaged(void), wildcard: *const std.StringArrayHashMapUnmanaged(void)) bool {
    for (extensionGroup(a, file, groups)) |ext| {
        // `a.d.ts` also ends in `.ts`, which must not count as its own extension.
        if (std.mem.endsWith(u8, file, ext) and !(std.mem.eql(u8, ext, ".ts") and std.mem.endsWith(u8, file, ".d.ts"))) return false;
        const other = withExtension(a, file, ext);
        if (!literal.contains(other) and !wildcard.contains(other)) continue;
        // tsc keeps a declaration file next to its JavaScript, a legacy quirk it does not break.
        if (std.mem.eql(u8, ext, ".d.ts") and (std.mem.endsWith(u8, file, ".js") or std.mem.endsWith(u8, file, ".jsx"))) continue;
        return true;
    }
    return false;
}

fn removeLowerPriority(a: Allocator, file: []const u8, groups: []const []const []const u8, wildcard: *std.StringArrayHashMapUnmanaged(void)) void {
    const group = extensionGroup(a, file, groups);
    var i = group.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.endsWith(u8, file, group[i])) return;
        _ = wildcard.orderedRemove(withExtension(a, file, group[i]));
    }
}

/// Every import probes up to a dozen names, nearly all missing, and each failed stat takes a
/// kernel lock the other workers want. Listing a directory once answers all of them from memory.
/// Entries live as long as the process, so they come straight from the thread-safe allocator.
/// Walking the project fills it too, or resolving imports would list all those directories again.
pub const FsCache = struct {
    io: Io,
    shards: [64]Shard = @splat(.{}),

    pub fn create(a: Allocator, io: Io) *FsCache {
        const f = a.create(FsCache) catch oom();
        f.* = .{ .io = io };
        return f;
    }

    const Listing = union(enum) {
        missing,
        /// Listing was refused, which says nothing about the entries: those still get a stat.
        unreadable,
        names: std.StringHashMapUnmanaged(Io.File.Kind),
    };

    const Shard = struct {
        mutex: Io.Mutex = .init,
        dirs: std.StringHashMapUnmanaged(*Listing) = .empty,
        bare: std.StringHashMapUnmanaged(?[]const u8) = .empty,
        packages: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    };

    fn shardOf(f: *FsCache, key: []const u8) *Shard {
        return &f.shards[std.hash.Wyhash.hash(0, key) % f.shards.len];
    }

    fn list(f: *FsCache, path: []const u8) *Listing {
        const a = std.heap.smp_allocator;
        const out = a.create(Listing) catch oom();
        var dir = Io.Dir.cwd().openDir(f.io, path, .{ .iterate = true }) catch |e| {
            out.* = if (e == error.FileNotFound or e == error.NotDir) .missing else .unreadable;
            return out;
        };
        defer dir.close(f.io);
        var names: std.StringHashMapUnmanaged(Io.File.Kind) = .empty;
        var it = dir.iterate();
        while (it.next(f.io) catch null) |e| {
            var kind = e.kind;
            if (kind == .sym_link) kind = (dir.statFile(f.io, e.name, .{}) catch continue).kind;
            names.put(a, a.dupe(u8, e.name) catch oom(), kind) catch oom();
        }
        out.* = .{ .names = names };
        return out;
    }

    fn listing(f: *FsCache, path: []const u8) *Listing {
        const shard = f.shardOf(path);
        shard.mutex.lockUncancelable(f.io);
        defer shard.mutex.unlock(f.io);
        if (shard.dirs.get(path)) |known| return known;
        // Concurrent misses must share one snapshot instead of retaining duplicate listings.
        const fresh = f.list(path);
        const key = std.heap.smp_allocator.dupe(u8, path) catch oom();
        shard.dirs.put(std.heap.smp_allocator, key, fresh) catch oom();
        return fresh;
    }

    fn kindOf(f: *FsCache, path: []const u8) ?Io.File.Kind {
        const parent = fspath.dirname(path) orelse {
            const st = Io.Dir.cwd().statFile(f.io, path, .{}) catch return null;
            return st.kind;
        };
        return f.kindInListing(path, f.listing(parent));
    }

    fn kindInListing(f: *FsCache, path: []const u8, listing_: *const Listing) ?Io.File.Kind {
        switch (listing_.*) {
            .missing => return null,
            .unreadable => {
                const st = Io.Dir.cwd().statFile(f.io, path, .{}) catch return null;
                return st.kind;
            },
            .names => |names| return names.get(fspath.basename(path)),
        }
    }

    fn isFile(f: *FsCache, path: []const u8) bool {
        return f.kindOf(path) == .file;
    }

    fn isDir(f: *FsCache, path: []const u8) bool {
        return f.kindOf(path) == .directory;
    }

    fn resolved(f: *FsCache, key: []const u8) ??[]const u8 {
        const shard = f.shardOf(key);
        shard.mutex.lockUncancelable(f.io);
        defer shard.mutex.unlock(f.io);
        return shard.bare.get(key);
    }

    /// Different subpath imports share a manifest even when their resolutions differ. Keep the
    /// bytes outside resolver scratch arenas; parsing still belongs to the individual resolver.
    fn readPackage(f: *FsCache, path: []const u8) ?[]const u8 {
        const shard = f.shardOf(path);
        shard.mutex.lockUncancelable(f.io);
        defer shard.mutex.unlock(f.io);
        if (shard.packages.get(path)) |known| return known;
        const a = std.heap.smp_allocator;
        const text = readFile(a, f.io, path) catch null;
        const key = a.dupe(u8, path) catch oom();
        shard.packages.put(a, key, text) catch oom();
        return text;
    }

    /// The strings come from a resolver's scratch arena, so the table keeps its own copies.
    fn remember(f: *FsCache, key: []const u8, path: ?[]const u8) void {
        const a = std.heap.smp_allocator;
        const shard = f.shardOf(key);
        shard.mutex.lockUncancelable(f.io);
        defer shard.mutex.unlock(f.io);
        const gop = shard.bare.getOrPut(a, key) catch oom();
        if (gop.found_existing) return;
        gop.key_ptr.* = a.dupe(u8, key) catch oom();
        gop.value_ptr.* = if (path) |p| a.dupe(u8, p) catch oom() else null;
    }
};

const Resolver = struct {
    io: Io,
    a: Allocator,
    fs: *FsCache,
    cfg: *const Config,
    mode: ast.ResolutionMode = .import,
    /// tsc's second pass for a module TypeScript cannot type: a JavaScript file makes it `any`.
    js: bool = false,

    fn jsonModules(r: Resolver) bool {
        const bundler = if (r.cfg.options.moduleResolution) |m| std.ascii.eqlIgnoreCase(m, "bundler") else false;
        return r.cfg.options.resolveJsonModule orelse bundler;
    }

    /// tsc's `loadModuleFromFile`: a known extension is swapped for the ones that may stand for
    /// it, then the whole name gets each extension added.
    fn tryFile(r: Resolver, base: []const u8) ?[]const u8 {
        // All extension candidates share one directory snapshot and its synchronization cost.
        const dir_only = base.len > 0 and fspath.isSep(base[base.len - 1]);
        const dir = if (dir_only) base else fspath.dirname(base) orelse ".";
        const listing = r.fs.listing(dir);
        if (listing.* == .missing) return null;
        const name = fspath.basename(base);
        if (!dir_only and std.mem.indexOfScalar(u8, name, '.') != null) {
            const ext = knownExtension(name) orelse name[std.mem.lastIndexOfScalar(u8, name, '.').?..];
            if (r.tryAddingExtensions(base[0 .. base.len - ext.len], ext, listing)) |p| return p;
        }
        return r.tryAddingExtensions(base, "", listing);
    }

    /// tsc's `tryAddingExtensions`, for the extensions this program reads.
    fn tryAddingExtensions(r: Resolver, stem: []const u8, ext: []const u8, listing: *const FsCache.Listing) ?[]const u8 {
        const js = r.js or r.cfg.options.allowJs orelse false;
        const eql = std.mem.eql;
        const candidates: []const []const u8 = if (eql(u8, ext, ".mjs") or eql(u8, ext, ".mts") or eql(u8, ext, ".d.mts"))
            if (js) &.{ ".mts", ".d.mts", ".mjs" } else &.{ ".mts", ".d.mts" }
        else if (eql(u8, ext, ".cjs") or eql(u8, ext, ".cts") or eql(u8, ext, ".d.cts"))
            if (js) &.{ ".cts", ".d.cts", ".cjs" } else &.{ ".cts", ".d.cts" }
        else if (eql(u8, ext, ".json"))
            if (r.jsonModules()) &.{ ".d.json.ts", ".json" } else &.{".d.json.ts"}
        else if (eql(u8, ext, ".tsx") or eql(u8, ext, ".jsx"))
            if (js) &.{ ".tsx", ".ts", ".d.ts", ".jsx", ".js" } else &.{ ".tsx", ".ts", ".d.ts" }
        else if (ext.len == 0 or eql(u8, ext, ".ts") or eql(u8, ext, ".d.ts") or eql(u8, ext, ".js"))
            if (js) &.{ ".ts", ".tsx", ".d.ts", ".js", ".jsx" } else &.{ ".ts", ".tsx", ".d.ts" }
        else {
            // `./styles.css` finds `./styles.d.css.ts`.
            const p = std.mem.concat(r.a, u8, &.{ stem, ".d", ext, ".ts" }) catch oom();
            return if (r.fs.kindInListing(p, listing) == .file) p else null;
        };
        for (candidates) |x| {
            const p = std.mem.concat(r.a, u8, &.{ stem, x }) catch oom();
            if (r.fs.kindInListing(p, listing) == .file) return p;
        }
        return null;
    }

    fn knownExtension(name: []const u8) ?[]const u8 {
        const exts = [_][]const u8{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json" };
        for (exts) |x| if (std.mem.endsWith(u8, name, x) and name.len > x.len) return x;
        return null;
    }

    fn tryIndex(r: Resolver, dir: []const u8) ?[]const u8 {
        const listing = r.fs.listing(dir);
        if (listing.* == .missing) return null;
        const index = fspath.join(r.a, &.{ dir, "index" }) catch oom();
        return r.tryAddingExtensions(index, "", listing);
    }

    fn tryPath(r: Resolver, base: []const u8) ?[]const u8 {
        if (r.tryFile(base)) |p| return p;
        if (r.fs.isDir(base)) {
            if (r.tryPackageDir(base, "")) |p| return p;
            return r.tryIndex(base);
        }
        return null;
    }

    /// `types: ["node"]` names a package under `typeRoots`, or else under `@types` looked up from
    /// the project outwards.
    fn tryTypeRoot(r: Resolver, from: []const u8, name: []const u8) ?[]const u8 {
        if (r.cfg.options.typeRoots) |roots| for (roots) |root| {
            const pkg = fspath.resolve(r.a, &.{ r.cfg.root, root, name }) catch oom();
            if (r.tryPackageDir(pkg, "")) |p| return p;
        };
        var dir: ?[]const u8 = from;
        while (dir) |x| : (dir = fspath.dirname(x)) {
            const pkg = fspath.join(r.a, &.{ x, "node_modules", "@types", name }) catch oom();
            if (r.tryPackageDir(pkg, "")) |p| return p;
        }
        return null;
    }

    /// Conditions are tried in the map's own order. A target whose file is missing falls
    /// through to the next condition, which `"types": "./*.d.ts", "import": "./*"` relies on.
    fn tryTarget(r: Resolver, dir: []const u8, v: json.Value, stem: ?[]const u8) ?[]const u8 {
        switch (v) {
            .string => |s| {
                const t = if (stem) |x| std.mem.replaceOwned(u8, r.a, s, "*", x) catch oom() else s;
                return r.tryExportFile(dir, t);
            },
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    if (!r.conditionMatches(e.key_ptr.*)) continue;
                    if (r.tryTarget(dir, e.value_ptr.*, stem)) |p| return p;
                }
                return null;
            },
            .array => |l| {
                for (l.items) |x| if (r.tryTarget(dir, x, stem)) |p| return p;
                return null;
            },
            else => return null,
        }
    }

    fn conditionMatches(r: Resolver, key: []const u8) bool {
        const eql = std.mem.eql;
        if (eql(u8, key, "default") or eql(u8, key, "types") or eql(u8, key, @tagName(r.mode))) return true;
        return eql(u8, key, "node") and r.cfg.options.nodeResolution();
    }

    /// tsc's `getImpliedNodeFormatForEmit`: the format the file's extension or package.json
    /// settles, or null when only `module` can.
    fn impliedMode(r: Resolver, path: []const u8) ?ast.ResolutionMode {
        const ends = std.mem.endsWith;
        if (ends(u8, path, ".mts") or ends(u8, path, ".mjs")) return .import;
        if (ends(u8, path, ".cts") or ends(u8, path, ".cjs")) return .require;
        const ty = if (r.packageScope(fspath.dirname(path) orelse ".")) |scope| scope[1].get("type") else null;
        const module = ty != null and ty.? == .string and std.mem.eql(u8, ty.?.string, "module");
        if (r.cfg.options.moduleFormat() == .node) return if (module) .import else .require;
        if (module) return .import;
        if (ty != null and ty.? == .string and std.mem.eql(u8, ty.?.string, "commonjs")) return .require;
        return null;
    }

    /// Without a format of its own, a file resolves the way tsc does with no mode at all.
    fn defaultMode(r: Resolver) ast.ResolutionMode {
        return if (r.cfg.options.nodeResolution()) .require else .import;
    }

    /// tsc's `getModeForUsageLocation`: `require` forms always resolve as require, `import()`
    /// as import unless the file's format turns it into a require, the rest as the file's format.
    fn usageMode(r: Resolver, path: []const u8, spec: *ast.Node) ast.ResolutionMode {
        const format = r.cfg.options.moduleFormat();
        const emitted: ?ast.ResolutionMode = r.impliedMode(path) orelse switch (format) {
            .cjs => .require,
            .esm, .preserve => .import,
            .node, .other => null,
        };
        if (spec.parent) |p| switch (p.data) {
            .external_module_ref => return .require,
            .call => return if (format == .node or format == .preserve) .import else emitted orelse .require,
            else => {},
        };
        return emitted orelse r.defaultMode();
    }

    fn tryExports(r: Resolver, dir: []const u8, exp: json.Value, sub: []const u8) ?[]const u8 {
        const key = std.mem.concat(r.a, u8, &.{ ".", sub }) catch oom();
        if (exp == .string or exp == .array) return if (sub.len == 0) r.tryTarget(dir, exp, null) else null;
        if (exp != .object) return null;
        var has_sub = false;
        var it0 = exp.object.iterator();
        while (it0.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, ".")) {
            has_sub = true;
        };
        if (!has_sub) return if (sub.len == 0) r.tryTarget(dir, exp, null) else null;
        return r.tryMapKey(dir, exp.object, key);
    }

    /// An exact key wins; otherwise the `*` pattern with the longest prefix, as in Node.
    fn tryMapKey(r: Resolver, dir: []const u8, map: json.ObjectMap, key: []const u8) ?[]const u8 {
        if (map.get(key)) |v| return r.tryTarget(dir, v, null);
        var best: ?json.Value = null;
        var best_pre: usize = 0;
        var stem: []const u8 = "";
        var it = map.iterator();
        while (it.next()) |e| {
            const star = std.mem.indexOfScalar(u8, e.key_ptr.*, '*') orelse continue;
            const pre = e.key_ptr.*[0..star];
            const post = e.key_ptr.*[star + 1 ..];
            if (key.len < pre.len + post.len or !std.mem.startsWith(u8, key, pre) or !std.mem.endsWith(u8, key, post)) continue;
            if (best != null and pre.len <= best_pre) continue;
            best = e.value_ptr.*;
            best_pre = pre.len;
            stem = key[pre.len .. key.len - post.len];
        }
        return if (best) |v| r.tryTarget(dir, v, stem) else null;
    }

    fn tryExportFile(r: Resolver, dir: []const u8, rel: []const u8) ?[]const u8 {
        const p = fspath.resolve(r.a, &.{ dir, rel }) catch oom();
        return r.tryFile(p);
    }

    fn tryPackageDir(r: Resolver, dir: []const u8, sub: []const u8) ?[]const u8 {
        const pkg = fspath.join(r.a, &.{ dir, "package.json" }) catch oom();
        if (r.fs.isFile(pkg)) blk: {
            const text = r.fs.readPackage(pkg) orelse break :blk;
            const v = json.parseFromSliceLeaky(json.Value, r.a, text, .{}) catch break :blk;
            if (v != .object) break :blk;
            if (v.object.get("exports")) |e| {
                if (r.tryExports(dir, e, sub)) |p| return p;
                // A package with an exports map hides every other path.
                if (e == .object or e == .string) break :blk;
            }
            if (sub.len == 0) for ([_][]const u8{ "types", "typings", "main" }) |k| {
                if (v.object.get(k)) |x| if (x == .string) {
                    const p = fspath.resolve(r.a, &.{ dir, x.string }) catch oom();
                    if (r.tryFile(p)) |q| return q;
                    if (r.fs.isDir(p)) if (r.tryIndex(p)) |q| return q;
                };
            };
        }
        if (sub.len == 0) return r.tryIndex(dir);
        const p = std.mem.concat(r.a, u8, &.{ dir, sub }) catch oom();
        return r.tryPath(p);
    }

    fn packageName(spec: []const u8) struct { []const u8, []const u8 } {
        var end = std.mem.indexOfScalar(u8, spec, '/') orelse spec.len;
        if (spec[0] == '@' and end < spec.len) {
            end = std.mem.indexOfScalarPos(u8, spec, end + 1, '/') orelse spec.len;
        }
        return .{ spec[0..end], spec[end..] };
    }

    fn atTypesName(r: Resolver, name: []const u8) []const u8 {
        if (name[0] == '@') {
            const m = std.mem.replaceOwned(u8, r.a, name[1..], "/", "__") catch oom();
            return std.mem.concat(r.a, u8, &.{ "@types/", m }) catch oom();
        }
        return std.mem.concat(r.a, u8, &.{ "@types/", name }) catch oom();
    }

    /// The nearest package.json above `from`, with the directory that holds it.
    fn packageScope(r: Resolver, from: []const u8) ?struct { []const u8, json.ObjectMap } {
        var dir: ?[]const u8 = from;
        const scope = while (dir) |d| : (dir = fspath.dirname(d)) {
            const pkg = fspath.join(r.a, &.{ d, "package.json" }) catch oom();
            if (r.fs.isFile(pkg)) break pkg;
        } else return null;
        const text = r.fs.readPackage(scope) orelse return null;
        const v = json.parseFromSliceLeaky(json.Value, r.a, text, .{}) catch return null;
        if (v != .object) return null;
        return .{ dir.?, v.object };
    }

    /// `#name` goes through the `imports` map of the package the importing file belongs to.
    fn tryImports(r: Resolver, from: []const u8, spec: []const u8) ?[]const u8 {
        // tsc rejects `#` and `#/…` before looking.
        if (spec.len < 2 or spec[1] == '/') return null;
        const dir, const pkg = r.packageScope(from) orelse return null;
        const imports = pkg.get("imports") orelse return null;
        if (imports != .object) return null;
        return r.tryMapKey(dir, imports.object, spec);
    }

    /// A package can import itself by name, and only through its own exports map.
    fn trySelfName(r: Resolver, from: []const u8, spec: []const u8) ?[]const u8 {
        const dir, const v = r.packageScope(from) orelse return null;
        const exports = v.get("exports") orelse return null;
        const name = v.get("name") orelse return null;
        if (name != .string or !std.mem.startsWith(u8, spec, name.string)) return null;
        const sub = spec[name.string.len..];
        if (sub.len > 0 and sub[0] != '/') return null;
        return r.tryExports(dir, exports, sub);
    }

    fn tryNodeModules(r: Resolver, from: []const u8, spec: []const u8) ?[]const u8 {
        const parts = packageName(spec);
        var dir: ?[]const u8 = from;
        while (dir) |d| : (dir = fspath.dirname(d)) {
            if (std.mem.eql(u8, fspath.basename(d), "node_modules")) continue;
            const nm = fspath.join(r.a, &.{ d, "node_modules" }) catch oom();
            if (!r.fs.isDir(nm)) continue;
            const pkg = fspath.join(r.a, &.{ nm, parts[0] }) catch oom();
            if (r.fs.isDir(pkg)) {
                if (r.tryPackageDir(pkg, parts[1])) |p| return p;
            } else if (r.tryPath(fspath.join(r.a, &.{ nm, spec }) catch oom())) |p| return p;
            const ty = fspath.join(r.a, &.{ nm, r.atTypesName(parts[0]) }) catch oom();
            if (r.fs.isDir(ty)) if (r.tryPackageDir(ty, parts[1])) |p| return p;
        }
        return null;
    }

    fn tryPaths(r: Resolver, spec: []const u8) ?[]const u8 {
        for (r.cfg.paths) |m| {
            const star = std.mem.indexOfScalar(u8, m.pattern, '*');
            var stem: []const u8 = "";
            if (star) |s| {
                const pre = m.pattern[0..s];
                const post = m.pattern[s + 1 ..];
                if (spec.len < pre.len + post.len or !std.mem.startsWith(u8, spec, pre) or !std.mem.endsWith(u8, spec, post)) continue;
                stem = spec[pre.len .. spec.len - post.len];
            } else if (!std.mem.eql(u8, m.pattern, spec)) continue;
            for (m.targets) |t| {
                const filled = std.mem.replaceOwned(u8, r.a, t, "*", stem) catch oom();
                const base = fspath.resolve(r.a, &.{ r.cfg.paths_base, filled }) catch oom();
                if (r.tryPath(base)) |p| return p;
            }
        }
        return null;
    }

    pub fn resolve(r: Resolver, from_file: []const u8, spec: []const u8) ?[]const u8 {
        if (spec.len == 0) return null;
        const dir = fspath.dirname(from_file) orelse ".";
        if (spec[0] == '.' or spec[0] == '/') {
            return r.tryPath(fspath.resolve(r.a, &.{ dir, spec }) catch oom());
        }
        // A package is imported from thousands of files, and each probe rereads its package.json.
        const key = std.mem.concat(r.a, u8, &.{ dir, "\x00", @tagName(r.mode), if (r.js) "\x00js\x00" else "\x00", spec }) catch oom();
        if (r.fs.resolved(key)) |known| return known;
        const found = r.resolveBare(dir, spec);
        r.fs.remember(key, found);
        return found;
    }

    fn resolveBare(r: Resolver, dir: []const u8, spec: []const u8) ?[]const u8 {
        if (spec[0] == '#') return r.tryImports(dir, spec);
        if (std.mem.startsWith(u8, spec, "node:")) return r.tryNodeModules(dir, spec[5..]) orelse r.tryNodeModules(dir, spec);
        if (r.tryPaths(spec)) |p| return p;
        if (r.cfg.options.baseUrl) |b| {
            if (r.tryPath(fspath.resolve(r.a, &.{ b, spec }) catch oom())) |p| return p;
        }
        return r.trySelfName(dir, spec) orelse r.tryNodeModules(dir, spec);
    }
};

/// tsc's `isShorthandAmbientModuleSymbol`: `declare module "x";` with no body.
pub fn isShorthandAmbient(s: *const Symbol) bool {
    const d = s.value_decl orelse if (s.decls.len > 0) s.decls[0] else return false;
    return d.data == .module_decl and d.data.module_decl.body == null and d.data.module_decl.name.data == .string_lit;
}

pub const SourceFile = struct {
    file: *ast.File,
    /// Parallel to `file.module_specs`.
    resolved: []?*SourceFile = &.{},
    /// Paths found this round, before the owning file exists.
    pending: []?[]const u8 = &.{},
    is_lib: bool = false,
    is_root: bool = false,
    /// `/// <reference>` targets and lib names, resolved to paths.
    extra: []const []const u8 = &.{},
    extra_files: []*SourceFile = &.{},
    /// Specifiers that found only JavaScript, which is not read: tsc types them as `any`.
    untyped: []const Untyped = &.{},
    read_failed: bool = false,

    pub const Untyped = struct { spec: []const u8, path: []const u8 };

    pub fn resolvedFile(sf: *const SourceFile, spec: []const u8) ?*SourceFile {
        for (sf.file.module_specs, 0..) |n, i| if (std.mem.eql(u8, n.data.string_lit, spec)) return sf.resolved[i];
        return null;
    }

    pub fn untypedPath(sf: *const SourceFile, spec: []const u8) ?[]const u8 {
        for (sf.untyped) |u| if (std.mem.eql(u8, u.spec, spec)) return u.path;
        return null;
    }
};

const Loading = struct {
    io: Io,
    fs: *FsCache,
    cfg: *const Config,
    list: []*SourceFile,
    lib_dir: ?[]const u8,
    lazy_bodies: bool,
    /// Per worker: what a file keeps lasts as long as the program, and one arena a file wastes its tail.
    keeps: []Bump,
    scratch: []Bump,
};

fn libFile(a: Allocator, io: Io, dir: []const u8, name: []const u8) []const u8 {
    const lower = std.ascii.allocLowerString(a, name) catch oom();
    const mapped = if (std.mem.eql(u8, lower, "es6")) "es2015" else if (std.mem.eql(u8, lower, "es7")) "es2016" else lower;
    const file = std.fmt.allocPrint(a, "lib.{s}.d.ts", .{mapped}) catch oom();
    const path = fspath.join(a, &.{ dir, file }) catch oom();
    // A feature that ships in a yearly lib leaves `esnext.x` as a name for `es20xx.x`.
    if (std.mem.startsWith(u8, mapped, "esnext.") and !isFile(io, path)) {
        for ([_][]const u8{ "es2025", "es2024", "es2023", "es2022", "es2021", "es2020", "es2019", "es2018" }) |y| {
            const f = std.fmt.allocPrint(a, "lib.{s}{s}.d.ts", .{ y, mapped["esnext".len..] }) catch oom();
            const q = fspath.join(a, &.{ dir, f }) catch oom();
            if (isFile(io, q)) return q;
        }
    }
    return path;
}

/// tsc's `libs` table: merge order inside the default library follows it, not the references.
const lib_order = [_][]const u8{
    "es5",            "es6",                     "es2015",               "es7",             "es2016",                  "es2017",             "es2018",                  "es2019",              "es2020",         "es2021",              "es2022",             "es2023",                  "es2024",               "es2025",            "esnext",
    "dom",            "dom.iterable",            "dom.asynciterable",    "webworker",       "webworker.importscripts", "webworker.iterable", "webworker.asynciterable", "scripthost",          "es2015.core",    "es2015.collection",   "es2015.generator",   "es2015.iterable",         "es2015.promise",       "es2015.proxy",      "es2015.reflect",
    "es2015.symbol",  "es2015.symbol.wellknown", "es2016.array.include", "es2016.intl",     "es2017.arraybuffer",      "es2017.date",        "es2017.object",           "es2017.sharedmemory", "es2017.string",  "es2017.intl",         "es2017.typedarrays", "es2018.asyncgenerator",   "es2018.asynciterable", "es2018.intl",       "es2018.promise",
    "es2018.regexp",  "es2019.array",            "es2019.object",        "es2019.string",   "es2019.symbol",           "es2019.intl",        "es2020.bigint",           "es2020.date",         "es2020.promise", "es2020.sharedmemory", "es2020.string",      "es2020.symbol.wellknown", "es2020.intl",          "es2020.number",     "es2021.promise",
    "es2021.string",  "es2021.weakref",          "es2021.intl",          "es2022.array",    "es2022.error",            "es2022.intl",        "es2022.object",           "es2022.string",       "es2022.regexp",  "es2023.array",        "es2023.collection",  "es2023.intl",             "es2024.arraybuffer",   "es2024.collection", "es2024.object",
    "es2024.promise", "es2024.regexp",           "es2024.sharedmemory",  "es2024.string",   "es2025.collection",       "es2025.float16",     "es2025.intl",             "es2025.iterator",     "es2025.promise", "es2025.regexp",       "esnext.array",       "esnext.collection",       "esnext.date",          "esnext.decorators", "esnext.disposable",
    "esnext.error",   "esnext.intl",             "esnext.sharedmemory",  "esnext.temporal", "esnext.typedarrays",      "decorators",         "decorators.legacy",
};

fn libRank(path: []const u8) usize {
    const base = fspath.basename(path);
    if (std.mem.eql(u8, base, "lib.d.ts") or std.mem.eql(u8, base, "lib.es6.d.ts")) return 0;
    if (!std.mem.startsWith(u8, base, "lib.") or !std.mem.endsWith(u8, base, ".d.ts")) return lib_order.len + 2;
    const name = base[4 .. base.len - 5];
    for (lib_order, 1..) |x, i| if (std.mem.eql(u8, x, name)) return i;
    return lib_order.len + 2;
}

fn loadOne(l: *const Loading, worker: usize, i: usize) void {
    const sf = l.list[i];
    const a = l.keeps[worker].allocator();
    const path = sf.file.path;
    var src = readSource(a, l.io, path) catch {
        sf.read_failed = true;
        return;
    };
    // tsc types a JSON module as `export =` of its one value.
    if (std.mem.endsWith(u8, path, ".json")) src = std.mem.concat(a, u8, &.{ "export = ", src, ";" }) catch oom();
    const f = if (l.lazy_bodies) parser.parseLazily(a, path, src) else parser.parse(a, path, src);
    if (!f.is_dts and l.cfg.options.forcesModule(path)) f.is_module = true;
    binder.bindFile(a, f);
    sf.file = f;
    sf.pending = a.alloc(?[]const u8, f.module_specs.len) catch oom();
    // Every path tried and package.json read goes here: resolving keeps only what it found.
    const scratch = &l.scratch[worker];
    defer scratch.reset();
    const r = Resolver{ .io = l.io, .a = scratch.allocator(), .fs = l.fs, .cfg = l.cfg };
    f.implied_cjs = l.cfg.options.moduleFormat() == .node and r.impliedMode(path) == .require;
    var untyped: std.ArrayList(SourceFile.Untyped) = .empty;
    for (f.module_specs, 0..) |s, n| {
        var by_mode = r;
        by_mode.mode = r.usageMode(path, s);
        sf.pending[n] = if (by_mode.resolve(path, s.data.string_lit)) |p| a.dupe(u8, p) catch oom() else null;
        if (sf.pending[n] != null or (l.cfg.options.allowJs orelse false)) continue;
        by_mode.js = true;
        if (by_mode.resolve(path, s.data.string_lit)) |p| untyped.append(a, .{ .spec = s.data.string_lit, .path = a.dupe(u8, p) catch oom() }) catch oom();
    }
    sf.untyped = untyped.items;
    var extra: std.ArrayList([]const u8) = .empty;
    for (f.references) |ref| switch (ref.kind) {
        .path => extra.append(a, fspath.resolve(a, &.{ fspath.dirname(path) orelse ".", ref.value }) catch oom()) catch oom(),
        .lib => if (l.lib_dir) |d| extra.append(a, libFile(a, l.io, d, ref.value)) catch oom(),
        // Type roots of the project win over whatever a package nests next to itself.
        .types => {
            var by_mode = r;
            by_mode.mode = ref.mode orelse r.impliedMode(path) orelse r.defaultMode();
            if (by_mode.tryTypeRoot(l.cfg.root, ref.value) orelse by_mode.tryNodeModules(fspath.dirname(path) orelse ".", ref.value)) |p| extra.append(a, a.dupe(u8, p) catch oom()) catch oom();
        },
    };
    sf.extra = extra.items;
}

pub const Program = struct {
    a: Allocator,
    io: Io,
    cfg: *const Config,
    tp: *pool.ThreadPool,
    files: std.ArrayList(*SourceFile) = .empty,
    fs: *FsCache,
    by_path: std.StringHashMapUnmanaged(*SourceFile) = .empty,
    /// Paths as imports spelled them; one file is reached through many imports.
    by_import: std.StringHashMapUnmanaged(*SourceFile) = .empty,
    by_package: std.StringHashMapUnmanaged(*SourceFile) = .empty,
    package_ids: std.StringHashMapUnmanaged([]const u8) = .empty,
    by_file: std.AutoHashMapUnmanaged(*ast.File, *SourceFile) = .empty,
    by_root: std.AutoHashMapUnmanaged(*ast.Node, *ast.File) = .empty,
    globals: *SymbolTable,
    // In declaration order, so the first of two equally specific `*` patterns wins, as in tsc.
    ambient: std.StringArrayHashMapUnmanaged(*Symbol) = .empty,
    lib_dir: ?[]const u8 = null,
    /// `lib_dir` with symlinks resolved, as file paths are; constant for the run.
    lib_dir_real: ?[]const u8 = null,
    diags: std.ArrayList(ProgramDiag) = .empty,
    /// Roots that could not be read: tsc's TS6053, which has no position and is reported by the caller.
    missing_roots: std.ArrayList([]const u8) = .empty,
    lazy_bodies: bool = false,
    /// A body left for later has a syntax error, which needs every other one reported with it.
    body_failed: std.atomic.Value(bool) = .init(false),

    pub fn hasSyntaxErrors(p: *const Program) bool {
        for (p.files.items) |sf| if (!sf.is_lib and (sf.file.diags.len > 0 or sf.file.bad_body)) return true;
        return false;
    }

    pub const ProgramDiag = struct { file: *ast.File, start: u32, len: u32, code: u32, msg: []const u8 };

    fn isLibPath(p: *Program, path: []const u8) bool {
        const d = p.lib_dir_real orelse return false;
        const base = fspath.basename(path);
        if (!std.mem.startsWith(u8, base, "lib.") or !std.mem.endsWith(u8, base, ".d.ts")) return false;
        return std.mem.eql(u8, fspath.dirname(path) orelse "", d);
    }

    /// `name@version/rel` for a file inside a package, like tsc's package id.
    fn packageKey(p: *Program, path: []const u8) ?[]const u8 {
        const nm = "/node_modules/";
        const at = std.mem.lastIndexOf(u8, path, nm) orelse return null;
        const start = at + nm.len;
        var end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse return null;
        if (path[start] == '@') end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse return null;
        const dir = path[0..end];
        const id = p.package_ids.get(dir) orelse blk: {
            const v = p.readPackageId(dir);
            p.package_ids.put(p.a, dir, v) catch oom();
            break :blk v;
        };
        if (id.len == 0) return null;
        return std.mem.concat(p.a, u8, &.{ id, path[end..] }) catch oom();
    }

    fn readPackageId(p: *Program, dir: []const u8) []const u8 {
        const file = fspath.join(p.a, &.{ dir, "package.json" }) catch oom();
        const text = readFile(p.a, p.io, file) catch return "";
        const v = json.parseFromSliceLeaky(json.Value, p.a, text, .{}) catch return "";
        if (v != .object) return "";
        const name = v.object.get("name") orelse return "";
        const version = v.object.get("version") orelse return "";
        if (name != .string or version != .string) return "";
        return std.mem.concat(p.a, u8, &.{ name.string, "@", version.string }) catch oom();
    }

    fn add(p: *Program, path: []const u8, next: *std.ArrayList(*SourceFile), is_lib: bool, is_root: bool) *SourceFile {
        const known = p.by_import.getOrPut(p.a, path) catch oom();
        if (known.found_existing) return known.value_ptr.*;
        known.value_ptr.* = p.addNew(path, next, is_lib, is_root);
        return known.value_ptr.*;
    }

    fn addNew(p: *Program, path: []const u8, next: *std.ArrayList(*SourceFile), is_lib: bool, is_root: bool) *SourceFile {
        // Like tsc, only package paths are made real: that is where symlinks are the norm.
        const in_package = std.mem.indexOf(u8, path, "/node_modules/") != null;
        const real = if (in_package) Io.Dir.cwd().realPathFileAlloc(p.io, path, p.a) catch null else null;
        const key: []const u8 = if (real) |r| r else path;
        if (p.by_path.get(key)) |sf| return sf;
        // tsc redirects another copy of one package version to the first, so that nested
        // `@types/node` does not declare every global a second time.
        const pkg = p.packageKey(key);
        if (pkg) |k| if (p.by_package.get(k)) |sf| {
            p.by_path.put(p.a, key, sf) catch oom();
            return sf;
        };
        const sf = p.a.create(SourceFile) catch oom();
        // Replaced once the file is parsed; until then only the path is meaningful.
        sf.* = .{ .file = parser.parse(p.a, key, ""), .is_lib = is_lib or p.isLibPath(key), .is_root = is_root };
        p.by_path.put(p.a, key, sf) catch oom();
        if (pkg) |k| p.by_package.put(p.a, k, sf) catch oom();
        next.append(p.a, sf) catch oom();
        return sf;
    }

    /// Loads level by level so each round parses and binds in parallel; new files only join between rounds.
    fn load(p: *Program, roots: []const []const u8, libs: []const []const u8) void {
        const keeps = p.a.alloc(Bump, p.tp.width()) catch oom();
        for (keeps) |*x| x.* = .init(std.heap.smp_allocator);
        const scratch = p.a.alloc(Bump, p.tp.width()) catch oom();
        for (scratch) |*x| x.* = .init(std.heap.smp_allocator);
        defer for (scratch) |*x| x.deinit();
        var level: std.ArrayList(*SourceFile) = .empty;
        for (libs) |l| _ = p.add(l, &level, true, false);
        for (roots) |r| _ = p.add(r, &level, false, true);
        p.addTypeRoots(&level);
        while (level.items.len > 0) {
            const l = Loading{ .io = p.io, .fs = p.fs, .cfg = p.cfg, .list = level.items, .lib_dir = p.lib_dir, .lazy_bodies = p.lazy_bodies, .keeps = keeps, .scratch = scratch };
            pool.parallelFor(p.tp, level.items.len, &l, loadOne);
            var next: std.ArrayList(*SourceFile) = .empty;
            for (level.items) |sf| {
                if (sf.read_failed) {
                    if (sf.is_root) p.missing_roots.append(p.a, sf.file.path) catch oom();
                    continue;
                }
                p.files.append(p.a, sf) catch oom();
                p.by_file.put(p.a, sf.file, sf) catch oom();
                p.by_root.put(p.a, sf.file.root, sf.file) catch oom();
                sf.resolved = p.a.alloc(?*SourceFile, sf.pending.len) catch oom();
                for (sf.pending, 0..) |rp, i| {
                    sf.resolved[i] = if (rp) |path| p.add(path, &next, sf.is_lib, false) else null;
                }
                sf.extra_files = p.a.alloc(*SourceFile, sf.extra.len) catch oom();
                for (sf.extra, 0..) |x, i| sf.extra_files[i] = p.add(x, &next, sf.is_lib, false);
            }
            level = next;
        }
        p.orderFiles();
    }

    /// Merge order decides overload order, but rounds load files breadth first. tsc walks
    /// references and imports depth first, puts a file after what it pulls in, and libs first.
    fn orderFiles(p: *Program) void {
        var seen: std.AutoHashMapUnmanaged(*SourceFile, void) = .empty;
        var libs: std.ArrayList(*SourceFile) = .empty;
        var rest: std.ArrayList(*SourceFile) = .empty;
        const Post = struct {
            fn visit(pr: *Program, sf: *SourceFile, s: *std.AutoHashMapUnmanaged(*SourceFile, void), l: *std.ArrayList(*SourceFile), o: *std.ArrayList(*SourceFile)) void {
                if (sf.read_failed) return;
                if ((s.getOrPut(pr.a, sf) catch oom()).found_existing) return;
                for (sf.extra_files) |x| visit(pr, x, s, l, o);
                for (sf.resolved) |x| if (x) |y| visit(pr, y, s, l, o);
                (if (sf.is_lib) l else o).append(pr.a, sf) catch oom();
            }
        };
        for (p.files.items) |sf| Post.visit(p, sf, &seen, &libs, &rest);
        std.mem.sort(*SourceFile, libs.items, {}, struct {
            fn less(_: void, x: *SourceFile, y: *SourceFile) bool {
                return libRank(x.file.path) < libRank(y.file.path);
            }
        }.less);
        libs.appendSlice(p.a, rest.items) catch oom();
        p.files = libs;
    }

    /// Since TS 6 `@types` packages are opt-in: a project gets what `types` names, and `"*"` asks
    /// for every package it can see.
    fn addTypeRoots(p: *Program, level: *std.ArrayList(*SourceFile)) void {
        const names = p.cfg.options.types orelse return;
        var r = Resolver{ .io = p.io, .a = p.a, .fs = p.fs, .cfg = p.cfg };
        r.mode = r.defaultMode();
        for (names) |n| {
            if (std.mem.eql(u8, n, "*")) {
                p.addEveryTypePackage(r, level);
                continue;
            }
            if (r.tryTypeRoot(p.cfg.root, n)) |path| {
                _ = p.add(path, level, false, false);
                continue;
            }
            const from = fspath.join(p.a, &.{ p.cfg.root, "_" }) catch oom();
            if (r.resolve(from, n)) |path| _ = p.add(path, level, false, false);
        }
    }

    fn addEveryTypePackage(p: *Program, r: Resolver, level: *std.ArrayList(*SourceFile)) void {
        if (p.cfg.options.typeRoots) |roots| {
            for (roots) |root| p.addPackagesIn(r, fspath.resolve(p.a, &.{ p.cfg.root, root }) catch oom(), level);
            return;
        }
        var dir: ?[]const u8 = p.cfg.root;
        while (dir) |d| : (dir = fspath.dirname(d)) {
            p.addPackagesIn(r, fspath.join(p.a, &.{ d, "node_modules", "@types" }) catch oom(), level);
        }
    }

    fn addPackagesIn(p: *Program, r: Resolver, root: []const u8, level: *std.ArrayList(*SourceFile)) void {
        var h = Io.Dir.cwd().openDir(p.io, root, .{ .iterate = true }) catch return;
        defer h.close(p.io);
        var it = h.iterate();
        while (it.next(p.io) catch null) |e| {
            if (e.name[0] == '.') continue;
            const pkg = fspath.join(p.a, &.{ root, e.name }) catch oom();
            if (r.tryPackageDir(pkg, "")) |path| _ = p.add(path, level, false, false);
        }
    }

    fn table(p: *Program) *SymbolTable {
        const t = p.a.create(SymbolTable) catch oom();
        t.* = .{};
        return t;
    }

    fn compatible(t: *Symbol, s: *Symbol) bool {
        const excl: u32 = if (t.flags & F.block_var != 0) F.block_var_ex else if (t.flags & F.func_var != 0) F.func_var_ex else if (t.flags & F.function != 0) F.function_ex else if (t.flags & F.class != 0) F.class_ex else if (t.flags & F.interface != 0) F.interface_ex else if (t.flags & F.regular_enum != 0) F.regular_enum_ex else if (t.flags & F.const_enum != 0) F.const_enum_ex else if (t.flags & F.value_module != 0) F.value_module_ex else if (t.flags & F.type_alias != 0) F.type_alias_ex else if (t.flags & F.alias != 0) F.alias_ex else 0;
        return s.flags & excl == 0;
    }

    fn mergeTable(p: *Program, dst: *SymbolTable, src: *SymbolTable) void {
        var it = src.map.keyIterator();
        while (it.next()) |e| p.mergeInto(dst, e.*.name, e.*);
    }

    fn mergeInto(p: *Program, dst: *SymbolTable, name: []const u8, sym: *Symbol) void {
        const entry = dst.slot(p.a, name);
        if (!entry.found_existing) {
            entry.symbol.* = sym;
            return;
        }
        const t = entry.symbol.*.resolve();
        const s = sym.resolve();
        if (t == s) return;
        p.mergeSymbol(t, s);
    }

    pub fn mergeSymbol(p: *Program, t: *Symbol, s: *Symbol) void {
        if (!compatible(t, s)) {
            p.reportConflict(t, s);
            return;
        }
        t.flags |= s.flags;
        t.decls = std.mem.concat(p.a, *ast.Node, &.{ t.decls, s.decls }) catch oom();
        if (s.rare) |from| {
            const into = t.rareParts(p.a);
            into.stars = std.mem.concat(p.a, *ast.Node, &.{ into.stars, from.stars }) catch oom();
            into.late_members = std.mem.concat(p.a, *Symbol, &.{ into.late_members, from.late_members }) catch oom();
            into.late_statics = std.mem.concat(p.a, *Symbol, &.{ into.late_statics, from.late_statics }) catch oom();
        }
        if (t.value_decl == null) t.value_decl = s.value_decl;
        if (s.members) |m| {
            if (t.members == null) t.members = p.table();
            p.mergeTable(t.members.?, m);
        }
        if (s.exports) |m| {
            if (t.exports == null) t.exports = p.table();
            p.mergeTable(t.exports.?, m);
        }
        s.merged = t;
    }

    fn reportConflict(p: *Program, t: *Symbol, s: *Symbol) void {
        const block = (t.flags | s.flags) & F.block_var != 0;
        const code: u32 = if (block) 2451 else 2300;
        const msg = if (block)
            std.fmt.allocPrint(p.a, "Cannot redeclare block-scoped variable '{s}'.", .{s.name}) catch oom()
        else
            std.fmt.allocPrint(p.a, "Duplicate identifier '{s}'.", .{s.name}) catch oom();
        for ([_]*Symbol{ t, s }) |x| for (x.decls) |d| {
            // What lib files merged lies in many files, whatever `x.file` says.
            var root = d;
            while (root.parent) |up| root = up;
            const f = p.by_root.get(root) orelse continue;
            const n = binder.nameNode(d) orelse d;
            p.diags.append(p.a, .{ .file = f, .start = n.start, .len = n.end - n.start, .code = code, .msg = msg }) catch oom();
        };
    }

    pub fn sourceOf(p: *const Program, f: ?*ast.File) ?*SourceFile {
        return p.by_file.get(f orelse return null);
    }

    /// What an import or export alias finally names; null when it leads nowhere.
    pub fn resolveAlias(p: *const Program, s: *Symbol, depth: u32) ?*Symbol {
        if (s.flags & F.alias == 0) return s;
        if (depth > 32 or s.decls.len == 0) return null;
        const d = s.decls[0];
        const sf = p.sourceOf(s.file) orelse return null;
        const next: ?*Symbol = switch (d.data) {
            .import_clause => blk: {
                const m = p.moduleOfDecl(sf, d) orelse break :blk null;
                break :blk p.exportOf(m, "default") orelse p.exportOf(m, "export=") orelse m;
            },
            .namespace_import, .namespace_export => blk: {
                const m = p.moduleOfDecl(sf, d) orelse break :blk null;
                break :blk p.exportOf(m, "export=") orelse m;
            },
            .import_spec => |x| blk: {
                const m = p.moduleOfDecl(sf, d) orelse break :blk null;
                break :blk p.exportOf(m, binder.specName(x.prop_name orelse x.name));
            },
            .export_spec => |x| blk: {
                const name = binder.specName(x.prop_name orelse x.name);
                if (p.moduleOfDecl(sf, d)) |m| break :blk p.exportOf(m, name);
                if (d.parent.?.parent.?.data.export_decl.specifier != null) break :blk null;
                break :blk binder.lookupLocal(d, name, F.value | F.type | F.namespace) orelse p.globals.get(name);
            },
            .import_equals => |x| blk: {
                if (x.ref.data == .external_module_ref) {
                    const e = x.ref.data.external_module_ref.expr;
                    if (e.data != .string_lit) break :blk null;
                    const m = p.resolveModuleName(sf, e.data.string_lit) orelse break :blk null;
                    break :blk p.exportOf(m, "export=") orelse m;
                }
                break :blk p.resolveEntity(x.ref, depth);
            },
            .export_assign => |x| p.resolveEntity(binder.stripParens(x.expr), depth),
            else => null,
        };
        const t = next orelse return null;
        return p.resolveAlias(t.resolve(), depth + 1);
    }

    fn resolveEntity(p: *const Program, n: *ast.Node, depth: u32) ?*Symbol {
        switch (n.data) {
            .identifier => |name| return binder.lookupLocal(n, name, F.value | F.type | F.namespace) orelse p.globals.get(name),
            .qualified_name => |x| return p.memberOf(p.resolveEntity(x.left, depth), x.right.data.identifier, depth),
            .prop_access => |x| return p.memberOf(p.resolveEntity(x.expr, depth), x.name.data.identifier, depth),
            else => return null,
        }
    }

    fn memberOf(p: *const Program, base: ?*Symbol, name: []const u8, depth: u32) ?*Symbol {
        const b = p.resolveAlias(base orelse return null, depth + 1) orelse return null;
        return if (b.exports) |e| e.get(name) else null;
    }

    pub fn moduleOfDecl(p: *const Program, sf: *const SourceFile, d: *ast.Node) ?*Symbol {
        var c: ?*ast.Node = d;
        while (c) |n| : (c = n.parent) {
            switch (n.data) {
                .import_decl => |x| return p.resolveModuleName(sf, x.specifier.data.string_lit),
                .export_decl => |x| return if (x.specifier) |sp| p.resolveModuleName(sf, sp.data.string_lit) else null,
                else => {},
            }
        }
        return null;
    }

    /// Looks through `export *`, which tsc flattens lazily and so do we.
    pub fn exportOf(p: *const Program, m: *Symbol, name: []const u8) ?*Symbol {
        var seen: [64]*Symbol = undefined;
        return p.exportOfRec(m.resolve(), name, &seen, 0);
    }

    fn exportOfRec(p: *const Program, m: *Symbol, name: []const u8, seen: *[64]*Symbol, depth: usize) ?*Symbol {
        // `declare module "x";` promises everything: each name it is asked for is the module, typed `any`.
        if (isShorthandAmbient(m)) return m;
        if (m.exports) |e| {
            if (e.get(name)) |s| return s;
            // Members of the namespace behind `export =` can be imported by name.
            if (e.get("export=")) |eq| if (p.resolveAlias(eq.resolve(), 0)) |t| if (t != m) if (t.exports) |te| if (te.get(name)) |s| return s;
        }
        if (std.mem.eql(u8, name, "default") or depth >= seen.len) return null;
        for (seen[0..depth]) |x| if (x == m) return null;
        seen[depth] = m;
        const sf = p.sourceOf(m.file) orelse return null;
        for (m.stars()) |star| {
            const spec = star.data.export_decl.specifier orelse continue;
            const t = p.resolveModuleName(sf, spec.data.string_lit) orelse continue;
            if (p.exportOfRec(t.resolve(), name, seen, depth + 1)) |x| return x;
        }
        return null;
    }

    /// Everything global folds into one table here, single-threaded, before any checker runs.
    fn mergeGlobals(p: *Program) void {
        for (p.files.items) |sf| {
            const f = sf.file;
            if (f.is_module) continue;
            if (f.root.locals()) |l| p.mergeTable(p.globals, l);
        }
        for (p.files.items) |sf| {
            for (sf.file.global_augs) |s| if (s.exports) |e| p.mergeTable(p.globals, e);
            if (sf.file.umd_name) |n| if (sf.file.symbol) |s| {
                if (!p.globals.contains(n)) p.globals.put(p.a, n, s);
            };
        }
        const global_this = p.a.create(Symbol) catch oom();
        global_this.* = .{ .name = "globalThis", .flags = F.value_module, .exports = p.globals };
        p.globals.put(p.a, "globalThis", global_this);
        for (p.files.items) |sf| for (sf.file.ambient_modules) |s| {
            const gop = p.ambient.getOrPut(p.a, s.name) catch oom();
            if (gop.found_existing) p.mergeSymbol(gop.value_ptr.*.resolve(), s) else gop.value_ptr.* = s;
        };
        for (p.files.items) |sf| for (sf.file.augmentations) |s| {
            const target = p.resolveModuleName(sf, s.name) orelse continue;
            const e = s.exports orelse continue;
            if (target.exports == null) target.exports = p.table();
            // An interface re-exported is extended where it lives; a copy here would shadow it
            // with only the augmented members.
            var it = e.map.keyIterator();
            while (it.next()) |kv| {
                const own = target.exports.?.get(kv.*.name);
                if (own orelse p.exportOf(target, kv.*.name)) |x| {
                    const named = x.resolve();
                    const real = p.resolveAlias(named, 0) orelse named;
                    if (own == null or real != named) {
                        p.mergeSymbol(real, kv.*);
                        continue;
                    }
                }
                p.mergeInto(target.exports.?, kv.*.name, kv.*);
            }
        };
    }

    /// The module symbol for a specifier written in `sf`; ambient declarations win, as in tsc.
    pub fn resolveModuleName(p: *const Program, sf: *const SourceFile, spec: []const u8) ?*Symbol {
        if (p.ambient.get(spec)) |s| return s.resolve();
        if (sf.resolvedFile(spec)) |t| return t.file.symbol;
        return p.patternAmbient(spec);
    }

    /// tsc's `findBestPatternMatch` over `declare module "pre*post"`: a real file wins, then the
    /// pattern with the longest prefix. A name with two stars is no pattern.
    fn patternAmbient(p: *const Program, spec: []const u8) ?*Symbol {
        var best: ?*Symbol = null;
        var best_len: usize = 0;
        var it = p.ambient.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const star = std.mem.indexOfScalar(u8, name, '*') orelse continue;
            if (std.mem.indexOfScalarPos(u8, name, star + 1, '*') != null) continue;
            const pre = name[0..star];
            const post = name[star + 1 ..];
            if (spec.len < pre.len + post.len or !std.mem.startsWith(u8, spec, pre) or !std.mem.endsWith(u8, spec, post)) continue;
            if (best != null and pre.len <= best_len) continue;
            best = e.value_ptr.*;
            best_len = pre.len;
        }
        return if (best) |s| s.resolve() else null;
    }
};

pub const LoadOptions = struct { fs: ?*FsCache = null, lib_dir_flag: ?[]const u8 = null, lib_dir_env: ?[]const u8 = null, want_libs: bool = true, lazy_bodies: bool = false };

fn findLibDir(a: Allocator, io: Io, root: []const u8, o: LoadOptions) ?[]const u8 {
    if (o.lib_dir_flag) |d| return d;
    if (o.lib_dir_env) |d| return d;
    var dir: ?[]const u8 = root;
    while (dir) |d| : (dir = fspath.dirname(d)) {
        const js = fspath.join(a, &.{ d, "node_modules", "typescript", "lib" }) catch oom();
        // TypeScript 7 keeps the libs beside its binary, in a package per platform. `..` is taken
        // after the symlink, so pnpm's layout finds it next to `typescript` too.
        const native = fspath.join(a, &.{ d, "node_modules", "typescript", "..", "@typescript", "typescript-" ++ node_platform, "lib" }) catch oom();
        for ([_][]const u8{ js, native }) |p| {
            const probe = fspath.join(a, &.{ p, "lib.d.ts" }) catch oom();
            if (isFile(io, probe)) return p;
        }
    }
    return null;
}

/// This machine as Node's `process.platform` and `process.arch` spell it.
const node_platform = switch (builtin.os.tag) {
    .macos => "darwin",
    .windows => "win32",
    else => @tagName(builtin.os.tag),
} ++ "-" ++ switch (builtin.cpu.arch) {
    .aarch64 => "arm64",
    .x86_64 => "x64",
    else => @tagName(builtin.cpu.arch),
};

fn defaultLib(target: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    const t = std.ascii.lowerString(&buf, target[0..@min(target.len, 32)]);
    if (std.mem.eql(u8, t, "es3") or std.mem.eql(u8, t, "es5")) return "lib.d.ts";
    if (std.mem.eql(u8, t, "es6") or std.mem.eql(u8, t, "es2015")) return "lib.es6.d.ts";
    if (std.mem.eql(u8, t, "esnext")) return "esnext.full";
    if (std.mem.startsWith(u8, t, "es20")) {
        return std.fmt.allocPrint(std.heap.smp_allocator, "{s}.full", .{t}) catch oom();
    }
    return "esnext.full";
}

pub fn loadProgram(a: Allocator, io: Io, tp: *pool.ThreadPool, cfg: *const Config, roots: []const []const u8, o: LoadOptions) *Program {
    const p = a.create(Program) catch oom();
    const g = a.create(SymbolTable) catch oom();
    g.* = .{};
    p.* = .{ .a = a, .io = io, .fs = o.fs orelse FsCache.create(a, io), .cfg = cfg, .tp = tp, .globals = g, .lazy_bodies = o.lazy_bodies };
    p.lib_dir = findLibDir(a, io, cfg.root, o);
    if (p.lib_dir) |d| p.lib_dir_real = Io.Dir.cwd().realPathFileAlloc(io, d, a) catch d;
    var libs: std.ArrayList([]const u8) = .empty;
    if (p.lib_dir != null and o.want_libs and !(cfg.options.noLib orelse false)) {
        if (cfg.options.lib) |names| {
            for (names) |n| libs.append(a, libFile(a, io, p.lib_dir.?, n)) catch oom();
        } else {
            const name = defaultLib(cfg.options.target orelse "es2023");
            // `lib.d.ts` and `lib.es6.d.ts` include the DOM, unlike the `lib` option's `es5` and `es6`.
            const full = if (std.mem.endsWith(u8, name, ".d.ts"))
                fspath.join(a, &.{ p.lib_dir.?, name }) catch oom()
            else
                libFile(a, io, p.lib_dir.?, name);
            libs.append(a, full) catch oom();
        }
    }
    p.load(roots, libs.items);
    p.mergeGlobals();
    return p;
}

test "a root that cannot be read is reported, not dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tp = pool.ThreadPool.init(1);
    const cfg = Config{ .root = "/nonexistent-stator-ts-test" };
    const p = loadProgram(a, std.testing.io, &tp, &cfg, &.{"/nonexistent-stator-ts-test/missing.ts"}, .{ .want_libs = false });
    try std.testing.expectEqual(@as(usize, 1), p.missing_roots.items.len);
    try std.testing.expectEqualStrings("/nonexistent-stator-ts-test/missing.ts", p.missing_roots.items[0]);
    try std.testing.expectEqual(@as(usize, 0), p.files.items.len);
}

test "filesystem snapshots share package bytes and concurrent directory reads" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try fspath.join(a, &.{ dir, "package.json" });
    defer a.free(path);
    const first = "{\"types\":\"first.d.ts\"}";
    const second = "{\"types\":\"second.d.ts\"}";
    var missing = FsCache{ .io = io };
    try std.testing.expect(missing.readPackage(path) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = first });
    try std.testing.expect(missing.readPackage(path) == null);
    var cache = FsCache{ .io = io };
    const saved = cache.readPackage(path).?;
    try std.testing.expectEqualStrings(first, saved);
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = second });
    try std.testing.expectEqual(saved.ptr, cache.readPackage(path).?.ptr);
    try std.testing.expectEqualStrings(first, cache.readPackage(path).?);
    var fresh = FsCache{ .io = io };
    try std.testing.expectEqualStrings(second, fresh.readPackage(path).?);

    const workers = 8;
    const Readers = struct {
        cache: *FsCache,
        path: []const u8,
        ready: std.atomic.Value(usize) = .init(0),
        listings: [workers]*FsCache.Listing = undefined,

        fn read(r: *@This(), _: usize, i: usize) void {
            _ = r.ready.fetchAdd(1, .acq_rel);
            while (r.ready.load(.acquire) < workers) std.atomic.spinLoopHint();
            r.listings[i] = r.cache.listing(r.path);
        }
    };
    var readers = Readers{ .cache = &fresh, .path = dir };
    var tp = pool.ThreadPool.init(workers);
    pool.parallelForEach(&tp, workers, &readers, Readers.read);
    for (readers.listings) |listing| try std.testing.expectEqual(readers.listings[0], listing);
}

test "resolver probes preserve extension order and unreadable-directory fallback" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    for ([_][]const u8{ "item.ts", "item.tsx", "mapped.ts", "view.tsx", "mod.mts", "common.cts", "data.json", "folder.tsx", "index.ts", "index.tsx" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    try tmp.dir.createDir(io, "folder.ts", .default_dir);
    try tmp.dir.createDir(io, "trailing", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "trailing/.ts", .data = "" });
    var fs = FsCache{ .io = io };
    const cfg = Config{ .root = dir, .options = .{ .resolveJsonModule = true } };
    const r = Resolver{ .io = io, .a = a, .fs = &fs, .cfg = &cfg };
    for ([_][2][]const u8{
        .{ "item", "item.ts" }, .{ "item.tsx", "item.tsx" },
        .{ "mapped.js", "mapped.ts" }, .{ "view.jsx", "view.tsx" },
        .{ "mod.mjs", "mod.mts" }, .{ "common.cjs", "common.cts" },
        .{ "data.json", "data.json" }, .{ "folder", "folder.tsx" },
        .{ "trailing/", "trailing/.ts" },
    }) |pair| {
        const base = try std.mem.concat(a, u8, &.{ dir, fspath.sep_str, pair[0] });
        const expected = try fspath.join(a, &.{ dir, pair[1] });
        try std.testing.expectEqualStrings(expected, r.tryFile(base).?);
    }
    try std.testing.expectEqualStrings(try fspath.join(a, &.{ dir, "index.ts" }), r.tryIndex(dir).?);
    for ([_][]const u8{ "decl.d.ts", "styles.d.css.ts", "plain.js" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    // The first cache keeps its listing from before these files existed.
    var js_fs = FsCache{ .io = io };
    const js_cfg = Config{ .root = dir, .options = .{ .allowJs = true } };
    const js = Resolver{ .io = io, .a = a, .fs = &js_fs, .cfg = &js_cfg };
    for ([_][2][]const u8{ .{ "decl.ts", "decl.d.ts" }, .{ "styles.css", "styles.d.css.ts" }, .{ "plain", "plain.js" } }) |pair| {
        const base = try std.mem.concat(a, u8, &.{ dir, fspath.sep_str, pair[0] });
        try std.testing.expectEqualStrings(try fspath.join(a, &.{ dir, pair[1] }), js.tryFile(base).?);
    }
    const ts_cfg = Config{ .root = dir };
    const ts = Resolver{ .io = io, .a = a, .fs = &js_fs, .cfg = &ts_cfg };
    try std.testing.expect(ts.tryFile(try fspath.join(a, &.{ dir, "plain" })) == null);
    const missing = try fspath.join(a, &.{ dir, "absent", "item" });
    try std.testing.expect(r.tryFile(missing) == null);
    try std.testing.expect(r.tryIndex(missing) == null);
    const unreadable: FsCache.Listing = .unreadable;
    const file = try fspath.join(a, &.{ dir, "item.ts" });
    try std.testing.expectEqual(Io.File.Kind.file, fs.kindInListing(file, &unreadable).?);
    try std.testing.expect(fs.kindInListing(missing, &unreadable) == null);
}

test "stripJsonc removes comments and trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = stripJsonc(arena.allocator(), "{ // c\n \"a\": [1, 2,], /* x */ \"b\": \"//no\", }");
    const v = try json.parseFromSliceLeaky(json.Value, arena.allocator(), out, .{});
    try std.testing.expectEqualStrings("//no", v.object.get("b").?.string);
}

test "globMatch" {
    try std.testing.expect(globMatch("/a/**/*", "/a/b/c.ts"));
    try std.testing.expect(globMatch("/a/**/*", "/a/c.ts"));
    try std.testing.expect(globMatch("/a/*.ts", "/a/c.ts"));
    try std.testing.expect(!globMatch("/a/*.ts", "/a/b/c.ts"));
    try std.testing.expect(globMatch("/a/**/x?.ts", "/a/b/xy.ts"));
    try std.testing.expect(globMatch("/a/**/*", "/a/.lib/c.ts"));
    try std.testing.expect(!includeMatch("/a/**/*", "/a/.lib/c.ts"));
    try std.testing.expect(!includeMatch("/a/**/*", "/a/b/.c.ts"));
    try std.testing.expect(!includeMatch("/a/?lib/c.ts", "/a/.lib/c.ts"));
    try std.testing.expect(includeMatch("/a/.lib/*.ts", "/a/.lib/c.ts"));
    try std.testing.expect(includeMatch("/a/**/*", "/a/b.c/d.ts"));
}
