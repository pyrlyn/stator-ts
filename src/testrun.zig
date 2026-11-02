//! The `test` command: finds `*.test.*`, `*.spec.*` and `*_test.*` files, compiles them and runs
//! them in parallel on Node or Bun through the embedded `harness.mjs`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fspath = std.fs.path;
const ast = @import("ast.zig");
const project = @import("project.zig");
const pool = @import("pool.zig");
const emit = @import("emit.zig");
const driver = @import("driver.zig");

fn oom() noreturn {
    @panic("out of memory");
}

/// What `run` runs: `filters` are path substrings, `name_filter` a test-name regex.
pub const Options = struct {
    cfg: *const project.Config,
    tp: *pool.ThreadPool,
    runtime: []const u8,
    filters: []const []const u8 = &.{},
    name_filter: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
    /// Whole-process limit, so a test that never exits cannot hang the run.
    timeout_seconds: i64 = 120,
};

const harness = @embedFile("harness.mjs");

/// True for a non-declaration file whose name contains `.test.`, `.spec.` or `_test.`.
pub fn isTestFile(path: []const u8) bool {
    const base = fspath.basename(path);
    if (std.mem.endsWith(u8, base, ".d.ts")) return false;
    for ([_][]const u8{ ".test.", ".spec.", "_test." }) |m| if (std.mem.indexOf(u8, base, m) != null) return true;
    return false;
}

fn matches(path: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| if (std.mem.indexOf(u8, path, f) != null) return true;
    return false;
}

test "filters see the path inside the project" {
    const f: []const []const u8 = &.{"tools"};
    try std.testing.expect(!matches(relativeTo("/home/tools/app/a.test.ts", "/home/tools/app"), f));
    try std.testing.expect(matches(relativeTo("/home/tools/app/tools/a.test.ts", "/home/tools/app"), f));
}

fn relativeTo(path: []const u8, root: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, path, root)) return path;
    return std.mem.trimStart(u8, path[root.len..], "/");
}

const Counts = struct { passed: u64 = 0, failed: u64 = 0, skipped: u64 = 0 };

const Outcome = struct {
    ok: bool = false,
    ms: i64 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    failure: []const u8 = "",
    counts: Counts = .{},
};

const Pool = struct {
    io: Io,
    environ: *const std.process.Environ.Map,
    runtime: []const u8,
    root: []const u8,
    harness_path: []const u8,
    timeout_seconds: i64,
    tests: []const []const u8,
    outcomes: []Outcome,
};

const marker = "@@stator-ts ";

/// What the test printed around the harness's line, which is for us and not for the reader.
fn aroundMarker(stdout: []const u8) [2][]const u8 {
    const at = std.mem.lastIndexOf(u8, stdout, marker) orelse return .{ stdout, "" };
    const end = std.mem.indexOfScalarPos(u8, stdout, at, '\n') orelse return .{ stdout[0..at], "" };
    return .{ stdout[0..at], stdout[end + 1 ..] };
}

test "the harness line is left out of what a failed file printed" {
    const parts = aroundMarker("one\n@@stator-ts {}\ntwo\n");
    try std.testing.expectEqualStrings("one\n", parts[0]);
    try std.testing.expectEqualStrings("two\n", parts[1]);
}

/// Only the last marker counts: a test may print anything, but the harness prints last.
fn parseCounts(stdout: []const u8) Counts {
    const at = std.mem.lastIndexOf(u8, stdout, marker) orelse return .{};
    const rest = stdout[at + marker.len ..];
    const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    const parsed = std.json.parseFromSlice(Counts, std.heap.smp_allocator, line, .{}) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

fn describeExit(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |c| std.fmt.allocPrint(std.heap.smp_allocator, "exit code {d}\n", .{c}) catch "",
        .signal => |c| std.fmt.allocPrint(std.heap.smp_allocator, "crashed: signal {d}\n", .{@intFromEnum(c)}) catch "",
        else => "crashed\n",
    };
}

fn runOne(p: *Pool, _: usize, i: usize) void {
    const gpa = std.heap.smp_allocator;
    const path = p.tests[i];
    const bun = std.mem.eql(u8, p.runtime, "bun");
    const argv: []const []const u8 = if (bun)
        &.{ "bun", "run", "--preload", p.harness_path, path }
    else
        &.{ "node", "--import", p.harness_path, path };
    const t0 = Io.Clock.awake.now(p.io);
    const r = std.process.run(gpa, p.io, .{
        .argv = argv,
        .cwd = .{ .path = p.root },
        .environ_map = p.environ,
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(p.timeout_seconds), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) {
            p.outcomes[i] = .{ .failure = std.fmt.allocPrint(gpa, "timed out after {d} s\n", .{p.timeout_seconds}) catch "" };
            return;
        }
        p.outcomes[i] = .{ .failure = std.fmt.allocPrint(gpa, "cannot start {s}: {s}\n", .{ p.runtime, @errorName(e) }) catch "" };
        return;
    };
    const ok = r.term == .exited and r.term.exited == 0;
    p.outcomes[i] = .{
        .ok = ok,
        .ms = t0.durationTo(Io.Clock.awake.now(p.io)).toMilliseconds(),
        .stdout = r.stdout,
        .stderr = r.stderr,
        .failure = if (ok) "" else describeExit(r.term),
        .counts = parseCounts(r.stdout),
    };
}

/// Imports may omit extensions or use tsconfig paths; emitted files need real relative paths.
const SpecMap = struct {
    prog: *project.Program,
    base: []const u8,
    out: []const u8,
    jsx: emit.Jsx,

    fn map(ctx: *anyopaque, a: Allocator, f: *ast.File, spec: []const u8) ?[]const u8 {
        const m: *SpecMap = @ptrCast(@alignCast(ctx));
        const sf = m.prog.by_file.get(f) orelse return null;
        for (f.module_specs, 0..) |n, i| {
            if (!std.mem.eql(u8, n.data.string_lit, spec)) continue;
            const t = sf.resolved[i] orelse return null;
            if (t.file.is_dts or std.mem.indexOf(u8, t.file.path, "/node_modules/") != null) return null;
            const from = fspath.dirname(f.path) orelse ".";
            const rel = fspath.relative(a, "/", null, from, emit.outputPath(a, t.file.path, m.jsx)) catch return null;
            if (std.mem.startsWith(u8, rel, "../")) return rel;
            return std.mem.concat(a, u8, &.{ "./", rel }) catch oom();
        }
        return null;
    }
};

fn copyAssets(a: Allocator, io: Io, prog: *project.Program, base: []const u8, out: []const u8) void {
    for (driver.emittable(a, prog, false)) |sf| {
        for (sf.file.module_specs, 0..) |n, i| {
            const spec = n.data.string_lit;
            if (sf.resolved[i] != null or spec.len == 0 or spec[0] != '.') continue;
            const src = fspath.resolve(a, &.{ fspath.dirname(sf.file.path) orelse ".", spec }) catch oom();
            const data = project.readFile(a, io, src) catch continue;
            const rel = fspath.relative(a, "/", null, base, src) catch continue;
            const target = fspath.join(a, &.{ out, rel }) catch oom();
            if (fspath.dirname(target)) |d| Io.Dir.cwd().createDirPath(io, d) catch continue;
            Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = data }) catch {};
        }
    }
}

/// Runs the matching test files and returns the process exit code. Rejects runtimes other than
/// `node` and `bun`.
pub fn run(a: Allocator, io: Io, base_env: *const std.process.Environ.Map, o: Options, w: *Io.Writer) !u8 {
    if (!std.mem.eql(u8, o.runtime, "node") and !std.mem.eql(u8, o.runtime, "bun")) {
        try w.print("error: unknown runtime '{s}'; use node or bun\n", .{o.runtime});
        return 1;
    }
    var found: std.ArrayList([]const u8) = .empty;
    const fs = project.FsCache.create(a, io);
    for (project.walkDirs(a, fs, o.tp, &.{o.cfg.root})) |f| {
        if (isTestFile(f) and matches(relativeTo(f, o.cfg.root), o.filters)) found.append(a, f) catch oom();
    }
    if (found.items.len == 0) {
        try w.writeAll("no test files found\n");
        return 1;
    }
    const prog = project.loadProgram(a, io, o.tp, o.cfg, found.items, .{ .fs = fs, .lib_dir_flag = o.lib_dir, .want_libs = false });
    var syntax: u32 = 0;
    for (prog.files.items) |sf| {
        for (sf.file.diags) |d| {
            const lc = sf.file.lineCol(d.start);
            try w.print("{s}({d},{d}): error TS{d}: {s}\n", .{ sf.file.path, lc.line, lc.col, d.code, d.msg });
            syntax += 1;
        }
    }
    if (syntax > 0) return 1;

    const files = driver.emittable(a, prog, false);
    var paths: std.ArrayList([]const u8) = .empty;
    for (files) |sf| paths.append(a, sf.file.path) catch oom();
    const base = driver.commonDir(a, paths.items);
    // Inside the project's node_modules, so bare imports resolve the way they do from the sources.
    const out = fspath.join(a, &.{ o.cfg.root, "node_modules", ".cache", "stator-ts", "test" }) catch oom();
    Io.Dir.cwd().deleteTree(io, out) catch {};
    Io.Dir.cwd().createDirPath(io, out) catch {
        try w.print("error: cannot create {s}\n", .{out});
        return 1;
    };
    const pkg = fspath.join(a, &.{ out, "package.json" }) catch oom();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pkg, .data = "{\"type\":\"module\"}\n" });

    const harness_path = fspath.join(a, &.{ out, "__harness.mjs" }) catch oom();
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = harness_path, .data = harness });

    var env = try base_env.clone(a);
    if (o.name_filter) |n| try env.put("STATOR_TS_TEST_NAME", n);

    var opts = driver.emitOptions(prog);
    var spec_map = SpecMap{ .prog = prog, .base = base, .out = out, .jsx = opts.jsx };
    opts.map_spec = SpecMap.map;
    opts.map_ctx = &spec_map;
    var job = driver.EmitJob{ .io = io, .prog = prog, .files = files, .base = base, .out_dir = out, .opts = opts };
    driver.emitFiles(a, &job);
    if (job.failed.load(.monotonic) > 0) {
        try w.print("error: could not write {d} output file(s)\n", .{job.failed.load(.monotonic)});
        return 1;
    }
    copyAssets(a, io, prog, base, out);

    var tests: std.ArrayList([]const u8) = .empty;
    for (found.items) |t| {
        const rel = fspath.relative(a, "/", null, base, t) catch oom();
        tests.append(a, emit.outputPath(a, fspath.join(a, &.{ out, rel }) catch oom(), opts.jsx)) catch oom();
    }
    const outcomes = a.alloc(Outcome, tests.items.len) catch oom();
    @memset(outcomes, .{});
    var p = Pool{
        .io = io,
        .environ = &env,
        .runtime = o.runtime,
        .root = o.cfg.root,
        .harness_path = harness_path,
        .timeout_seconds = o.timeout_seconds,
        .tests = tests.items,
        .outcomes = outcomes,
    };
    pool.parallelForEach(o.tp, tests.items.len, &p, runOne);

    var failed: u32 = 0;
    var total = Counts{};
    for (outcomes, found.items) |r, t| {
        total.passed += r.counts.passed;
        total.failed += r.counts.failed;
        total.skipped += r.counts.skipped;
        const shown = fspath.relative(a, "/", null, o.cfg.root, t) catch t;
        if (r.ok) {
            try w.print("PASS {s} ({d} ms)\n", .{ shown, r.ms });
        } else {
            failed += 1;
            const printed = aroundMarker(r.stdout);
            try w.print("FAIL {s}\n{s}{s}{s}{s}", .{ shown, r.failure, printed[0], printed[1], r.stderr });
        }
    }
    try w.print("\nfiles: {d} passed, {d} failed, {d} total\n", .{ outcomes.len - failed, failed, outcomes.len });
    try w.print("tests: {d} passed, {d} failed, {d} skipped\n", .{ total.passed, total.failed, total.skipped });
    return if (failed > 0) 1 else 0;
}

test "isTestFile" {
    try std.testing.expect(isTestFile("/a/b.test.ts"));
    try std.testing.expect(isTestFile("/a/b.spec.tsx"));
    try std.testing.expect(!isTestFile("/a/b.ts"));
    try std.testing.expect(!isTestFile("/a/b.test.d.ts"));
}
