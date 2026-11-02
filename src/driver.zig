const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fspath = std.fs.path;
const ast = @import("ast.zig");
const binder = @import("binder.zig");
const project = @import("project.zig");
const pool = @import("pool.zig");
const emit = @import("emit.zig");
const checker = @import("checker.zig");
const Symbol = binder.Symbol;
const Program = project.Program;
const SourceFile = project.SourceFile;

fn oom() noreturn {
    @panic("out of memory");
}

pub const Options = struct {
    cfg: *const project.Config,
    tp: *pool.ThreadPool,
    emit: bool,
    /// Semantic diagnostics even after a syntax error, which the tsc command line holds back and
    /// its test harness does not.
    all_diagnostics: bool = false,
    lib_dir: ?[]const u8 = null,
    lib_env: ?[]const u8 = null,
};

fn isTypeAlias(ctx: *anyopaque, s: *Symbol) bool {
    const p: *Program = @ptrCast(@alignCast(ctx));
    const t = p.resolveAlias(s, 0) orelse return false;
    return t.flags & binder.F.value == 0;
}

pub fn emitOptions(p: *Program) emit.Options {
    const o = p.cfg.options;
    return .{
        .jsx = o.jsxMode(),
        .jsx_factory = o.jsxFactory orelse "React.createElement",
        .jsx_fragment = o.jsxFragmentFactory orelse "React.Fragment",
        .jsx_import_source = o.jsxImportSource orelse "react",
        .rewrite_ts_ext = o.rewriteRelativeImportExtensions orelse false,
        .verbatim_module_syntax = o.verbatimModuleSyntax orelse false,
        .is_type_alias = isTypeAlias,
        .ctx = p,
    };
}

pub fn commonDir(a: Allocator, paths: []const []const u8) []const u8 {
    if (paths.len == 0) return ".";
    var common: []const u8 = fspath.dirname(paths[0]) orelse ".";
    for (paths[1..]) |x| {
        while (!(std.mem.startsWith(u8, x, common) and (x.len == common.len or x[common.len] == '/'))) {
            common = fspath.dirname(common) orelse return a.dupe(u8, "/") catch oom();
        }
    }
    return common;
}

pub const EmitJob = struct {
    io: Io,
    prog: *Program,
    files: []const *SourceFile,
    base: []const u8,
    out_dir: ?[]const u8,
    opts: emit.Options,
    outs: [][]const u8 = &.{},
    failed: std.atomic.Value(u32) = .init(0),
};

fn outputOf(a: Allocator, j: *const EmitJob, f: *ast.File) []const u8 {
    const rel = fspath.relative(a, "/", null, j.base, f.path) catch oom();
    const target = if (j.out_dir) |d| fspath.join(a, &.{ d, rel }) catch oom() else f.path;
    return emit.outputPath(a, target, j.opts.jsx);
}

fn emitOne(j: *EmitJob, _: usize, i: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const text = emit.emit(arena.allocator(), j.files[i].file, j.opts);
    Io.Dir.cwd().writeFile(j.io, .{ .sub_path = j.outs[i], .data = text }) catch {
        _ = j.failed.fetchAdd(1, .monotonic);
    };
}

/// Files in one directory would all retry `mkdir -p` on it, so directories are made once up front.
/// A directory that cannot be made is reported through the writes that then fail.
pub fn emitFiles(a: Allocator, j: *EmitJob) void {
    j.outs = a.alloc([]const u8, j.files.len) catch oom();
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (j.files, j.outs) |sf, *o| {
        o.* = outputOf(a, j, sf.file);
        if (fspath.dirname(o.*)) |d| dirs.put(a, d, {}) catch oom();
    }
    for (dirs.keys()) |d| Io.Dir.cwd().createDirPath(j.io, d) catch {};
    pool.parallelFor(j.prog.tp, j.files.len, j, emitOne);
}

pub fn emittable(a: Allocator, p: *Program, only_roots: bool) []const *SourceFile {
    var out: std.ArrayList(*SourceFile) = .empty;
    for (p.files.items) |sf| {
        if (sf.is_lib or sf.file.is_dts) continue;
        if (only_roots and !sf.is_root) continue;
        if (std.mem.indexOf(u8, sf.file.path, "/node_modules/") != null) continue;
        out.append(a, sf) catch oom();
    }
    return out.items;
}

const Printed = struct {
    file: *ast.File,
    start: u32,
    len: u32,
    code: u32,
    msg: []const u8,
    /// From the parser. tsc applies `@ts-ignore` to semantic diagnostics only, whatever their code.
    syntax: bool = false,
};

fn lessDiag(_: void, l: Printed, r: Printed) bool {
    const o = std.mem.order(u8, l.file.path, r.file.path);
    if (o != .eq) return o == .lt;
    if (l.start != r.start) return l.start < r.start;
    if (l.len != r.len) return l.len < r.len;
    if (l.code != r.code) return l.code < r.code;
    return std.mem.lessThan(u8, l.msg, r.msg);
}

pub fn run(a: Allocator, io: Io, o: Options, w: *Io.Writer) !u8 {
    const fs = project.FsCache.create(a, io);
    const roots = project.projectFiles(a, fs, o.tp, o.cfg);
    // The emitter walks every body, so only a run that writes nothing can leave them unparsed.
    if (!o.emit or (o.cfg.options.noEmit orelse false)) {
        const p = load(a, fs, o, roots, true);
        if (!p.hasSyntaxErrors() and p.missing_roots.items.len == 0) if (try report(a, io, o, p, w)) |code| return code;
    }
    // tsc lists every syntax error at once and then stops, so the checker cannot be what finds them.
    return (try report(a, io, o, load(a, fs, o, roots, false), w)).?;
}

fn load(a: Allocator, fs: *project.FsCache, o: Options, roots: []const []const u8, lazy_bodies: bool) *Program {
    return project.loadProgram(a, fs.io, o.tp, o.cfg, roots, .{ .fs = fs, .lib_dir_flag = o.lib_dir, .lib_dir_env = o.lib_env, .lazy_bodies = lazy_bodies });
}

/// Null, with nothing written, when a body left for later turned out to have a syntax error.
fn report(a: Allocator, io: Io, o: Options, p: *Program, w: *Io.Writer) !?u8 {
    if (p.lib_dir == null and !(o.cfg.options.noLib orelse false)) {
        try w.writeAll("error: cannot find lib.d.ts; pass --lib-dir, set STATOR_TS_LIB, or install typescript in the project\n");
        return 1;
    }

    // tsc reports a missing root as a config-level error and, like a syntax error, holds back
    // the semantic diagnostics while one exists.
    var count: u32 = @intCast(p.missing_roots.items.len);

    var all: std.ArrayList(Printed) = .empty;
    for (p.files.items) |sf| {
        if (sf.is_lib) continue;
        for (sf.file.diags) |d| all.append(a, .{ .file = sf.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg, .syntax = true }) catch oom();
    }
    const syntax_only = (all.items.len > 0 or count > 0) and !o.all_diagnostics;
    if (!syntax_only) {
        const skip_lib = o.cfg.options.skipLibCheck orelse false;
        const opts = o.cfg.options;
        for (p.files.items) |sf| {
            if (sf.is_lib or (sf.file.is_dts and skip_lib)) continue;
            for (sf.file.bind_diags) |d| if (keepSemantic(opts, sf.file, d.code)) all.append(a, .{ .file = sf.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg }) catch oom();
        }
        const skip_default = o.cfg.options.skipDefaultLibCheck orelse false;
        for (p.diags.items) |d| if (!(d.file.is_dts and skip_lib) and !(skip_default and p.sourceOf(d.file).?.is_lib) and keepSemantic(opts, d.file, d.code)) all.append(a, .{ .file = d.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg }) catch oom();
        for (checker.checkProgram(a, p)) |d| if (keepSemantic(opts, d.file, d.code)) all.append(a, .{ .file = d.file, .start = d.start, .len = d.len, .code = d.code, .msg = d.msg }) catch oom();
        if (p.body_failed.load(.monotonic)) return null;
    }

    for (p.missing_roots.items) |path| try w.print("error TS6053: File '{s}' not found.\n", .{path});
    std.mem.sort(Printed, all.items, {}, lessDiag);
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    var prev: ?Printed = null;
    for (all.items) |d| {
        if (prev) |q| if (q.file == d.file and q.start == d.start and q.code == d.code and std.mem.eql(u8, q.msg, d.msg)) continue;
        prev = d;
        if (filteredByDirective(d)) continue;
        count += 1;
        const lc = d.file.lineCol(d.start);
        const shown = fspath.relative(a, "/", null, cwd, d.file.path) catch d.file.path;
        try w.print("{s}({d},{d}): error TS{d}: {s}\n", .{ shown, lc.line, lc.col, d.code, d.msg });
    }

    if (o.emit and !(o.cfg.options.noEmit orelse false)) {
        // tsc writes every program file, including those only reached through imports.
        const files = emittable(a, p, false);
        var paths: std.ArrayList([]const u8) = .empty;
        for (files) |sf| paths.append(a, sf.file.path) catch oom();
        const base = o.cfg.options.rootDir orelse commonDir(a, paths.items);
        var job = EmitJob{ .io = io, .prog = p, .files = files, .base = base, .out_dir = o.cfg.options.outDir, .opts = emitOptions(p) };
        emitFiles(a, &job);
        if (job.failed.load(.monotonic) > 0) {
            try w.print("error: could not write {d} output file(s)\n", .{job.failed.load(.monotonic)});
            return 1;
        }
    }
    return if (count > 0) 2 else 0;
}

/// `@ts-ignore` silences the next line; `@ts-expect-error` does too.
fn keepSemantic(o: project.Options, f: *const ast.File, code: u32) bool {
    return switch (o.semantics(f)) {
        .all => true,
        .plain => project.plainJsError(code),
        .none => false,
    };
}

fn filteredByDirective(d: Printed) bool {
    if (d.syntax) return false;
    const src = d.file.src;
    var line_start: u32 = @min(d.start, @as(u32, @intCast(src.len)));
    while (line_start > 0 and src[line_start - 1] != '\n') line_start -= 1;
    if (line_start == 0) return false;
    for (d.file.directives) |t| {
        // A directive applies to the first line after it that is neither blank nor a comment.
        var p = t.line_end;
        while (p < line_start) {
            const nl = std.mem.indexOfScalarPos(u8, src, p, '\n') orelse break;
            const line = std.mem.trim(u8, src[p..nl], " \t\r");
            if (line.len != 0 and !std.mem.startsWith(u8, line, "//")) break;
            p = @intCast(nl + 1);
        }
        if (p == line_start) return true;
    }
    return false;
}
