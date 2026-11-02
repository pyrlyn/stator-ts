//! Command-line entry point: parses the arguments, loads the project's tsconfig and dispatches
//! to `check`, `build`, `scan` or `test`. Exit codes: 0 on success, 1 on a usage or load error,
//! 2 when diagnostics were reported.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fspath = std.fs.path;
const ast = @import("ast.zig");
const project = @import("project.zig");
const pool = @import("pool.zig");
const emit = @import("emit.zig");
const testrun = @import("testrun.zig");
const parser = @import("parser.zig");

const usage =
    \\usage: stator-ts <command> [options]
    \\
    \\commands:
    \\  check               type-check the project
    \\  build               type-check and emit JavaScript
    \\  scan                parse the whole project in parallel, print stats
    \\  test [filter...]    compile and run *.test.ts files in parallel on Node or Bun
    \\
    \\options:
    \\  -p, --project <p>   tsconfig.json, or a directory to use as the project
    \\  -j, --jobs <n>      worker threads and test processes (default: CPU count)
    \\      --outDir <d>    output directory for build
    \\      --lib-dir <d>   directory holding lib.*.d.ts
    \\      --runtime <r>   node or bun, for test
    \\  -t, --test-name <re> run only tests whose name matches, for test
    \\
;

const Cli = struct {
    command: []const u8 = "",
    project: ?[]const u8 = null,
    jobs: usize = 0,
    out_dir: ?[]const u8 = null,
    lib_dir: ?[]const u8 = null,
    all_diagnostics: bool = false,
    runtime: []const u8 = "node",
    test_name: ?[]const u8 = null,
    rest: std.ArrayList([]const u8) = .empty,
};

fn parseCli(a: Allocator, args: []const []const u8) !Cli {
    var c = Cli{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        const value = struct {
            fn get(list: []const []const u8, at: *usize) ![]const u8 {
                at.* += 1;
                return if (at.* < list.len) list[at.*] else error.MissingValue;
            }
        };
        if (std.mem.eql(u8, x, "-p") or std.mem.eql(u8, x, "--project")) {
            c.project = try value.get(args, &i);
        } else if (std.mem.eql(u8, x, "-j") or std.mem.eql(u8, x, "--jobs")) {
            c.jobs = try std.fmt.parseInt(usize, try value.get(args, &i), 10);
        } else if (std.mem.eql(u8, x, "--outDir")) {
            c.out_dir = try value.get(args, &i);
        } else if (std.mem.eql(u8, x, "--lib-dir")) {
            c.lib_dir = try value.get(args, &i);
        } else if (std.mem.eql(u8, x, "--all-diagnostics")) {
            c.all_diagnostics = true;
        } else if (std.mem.eql(u8, x, "--runtime")) {
            c.runtime = try value.get(args, &i);
        } else if (std.mem.eql(u8, x, "-t") or std.mem.eql(u8, x, "--test-name")) {
            c.test_name = try value.get(args, &i);
        } else if (c.command.len == 0) {
            c.command = x;
        } else {
            c.rest.append(a, x) catch return error.OutOfMemory;
        }
    }
    return c;
}

fn loadConfig(a: Allocator, io: Io, cli: *const Cli) !*project.Config {
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const target = if (cli.project) |p| try fspath.resolve(a, &.{ cwd, p }) else cwd;
    const st = try Io.Dir.cwd().statFile(io, target, .{});
    const cfg_path = if (st.kind == .directory) try fspath.join(a, &.{ target, "tsconfig.json" }) else target;
    const cfg = try a.create(project.Config);
    if (Io.Dir.cwd().access(io, cfg_path, .{})) |_| {
        cfg.* = try project.loadConfig(.{ .a = a, .io = io }, cfg_path);
    } else |_| {
        cfg.* = .{ .root = target };
    }
    if (cli.out_dir) |d| cfg.options.outDir = try fspath.resolve(a, &.{ cwd, d });
    return cfg;
}

const Scan = struct {
    io: Io,
    files: []const []const u8,
    bytes: std.atomic.Value(u64) = .init(0),
    lines: std.atomic.Value(u64) = .init(0),
    nodes_err: std.atomic.Value(u64) = .init(0),
    unreadable: std.atomic.Value(u64) = .init(0),
    diags: [][]const u8,
};

fn scanOne(s: *Scan, _: usize, i: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = s.files[i];
    const src = project.readFile(a, s.io, path) catch {
        _ = s.unreadable.fetchAdd(1, .monotonic);
        s.diags[i] = std.fmt.allocPrint(std.heap.smp_allocator, "error TS6053: File '{s}' not found.\n", .{path}) catch "";
        return;
    };
    const f = parser.parse(a, path, src);
    _ = s.bytes.fetchAdd(src.len, .monotonic);
    _ = s.lines.fetchAdd(std.mem.count(u8, src, "\n") + 1, .monotonic);
    if (f.diags.len == 0) return;
    _ = s.nodes_err.fetchAdd(f.diags.len, .monotonic);
    var buf: std.ArrayList(u8) = .empty;
    for (f.diags) |d| {
        const lc = f.lineCol(d.start);
        buf.print(std.heap.smp_allocator, "{s}({d},{d}): error TS{d}: {s}\n", .{ path, lc.line, lc.col, d.code, d.msg }) catch return;
    }
    s.diags[i] = buf.items;
}

fn cmdScan(a: Allocator, io: Io, tp: *pool.ThreadPool, cfg: *const project.Config, w: *Io.Writer) !u8 {
    const t0 = Io.Clock.awake.now(io);
    const files = project.projectFiles(a, project.FsCache.create(a, io), tp, cfg);
    const t1 = Io.Clock.awake.now(io);
    const diags = try a.alloc([]const u8, files.len);
    @memset(diags, "");
    var s = Scan{ .io = io, .files = files, .diags = diags };
    pool.parallelFor(tp, files.len, &s, scanOne);
    const t2 = Io.Clock.awake.now(io);
    for (diags) |d| try w.writeAll(d);
    const walk_ms = t0.durationTo(t1).toMilliseconds();
    const parse_ms = t1.durationTo(t2).toMilliseconds();
    try w.print("files: {d}\nlines: {d}\nbytes: {d}\nsyntax errors: {d}\nthreads: {d}\nwalk: {d} ms\nparse: {d} ms\n", .{
        files.len, s.lines.load(.monotonic), s.bytes.load(.monotonic), s.nodes_err.load(.monotonic), tp.width(), walk_ms, parse_ms,
    });
    return if (s.nodes_err.load(.monotonic) > 0 or s.unreadable.load(.monotonic) > 0) 2 else 0;
}

/// Runs one command and returns the process exit code.
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    var out_buf: [65536]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const argv = try init.minimal.args.toSlice(a);
    const owned = try a.alloc([]const u8, argv.len -| 1);
    for (argv[1..], 0..) |x, i| owned[i] = x;
    const cli = parseCli(a, owned) catch {
        try w.writeAll(usage);
        return 1;
    };
    if (cli.command.len == 0 or std.mem.eql(u8, cli.command, "help")) {
        try w.writeAll(usage);
        return if (cli.command.len == 0) 1 else 0;
    }
    const cfg = loadConfig(a, io, &cli) catch |e| {
        try w.print("error: cannot load project: {s}\n", .{@errorName(e)});
        return 1;
    };
    var workers = pool.ThreadPool.init(pool.jobCount(cli.jobs));
    const tp = &workers;
    if (std.mem.eql(u8, cli.command, "scan")) return cmdScan(a, io, tp, cfg, w);
    if (std.mem.eql(u8, cli.command, "test")) {
        return testrun.run(a, io, init.environ_map, .{ .cfg = cfg, .tp = tp, .runtime = cli.runtime, .filters = cli.rest.items, .name_filter = cli.test_name, .lib_dir = cli.lib_dir }, w);
    }
    if (std.mem.eql(u8, cli.command, "check") or std.mem.eql(u8, cli.command, "build")) {
        return @import("driver.zig").run(a, io, .{
            .cfg = cfg,
            .tp = tp,
            .emit = std.mem.eql(u8, cli.command, "build"),
            .all_diagnostics = cli.all_diagnostics,
            .lib_dir = cli.lib_dir,
            .lib_env = init.environ_map.get("STATOR_TS_LIB"),
        }, w);
    }
    try w.print("error: unknown command '{s}'\n\n{s}", .{ cli.command, usage });
    return 1;
}

test {
    _ = @import("lexer.zig");
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("binder.zig");
    _ = @import("bump.zig");
    _ = @import("emit.zig");
    _ = @import("pool.zig");
    _ = @import("project.zig");
    _ = @import("driver.zig");
    _ = @import("testrun.zig");
    _ = @import("spelling.zig");
}
