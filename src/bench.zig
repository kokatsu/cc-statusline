//! cc-statusline benchmark harness.
//!
//! Generates synthetic JSONL transcripts in a temp directory, then measures:
//!   - end-to-end (spawn binary with stdin)
//!   - fullScan (direct call into scan.zig)
//!   - parseJsonlContent (JSONL parser only)
//!
//! Run with: `zig build bench` (also accepts -- --save / --baseline).

const std = @import("std");
const Io = std.Io;
const json = std.json;
const scan = @import("scan.zig");
const time = @import("time.zig");
const ju = @import("json_util.zig");

// ─── Configuration ────────────────────────────────────────────────────────

const FixtureSize = struct { name: []const u8, files: u32, lines: u32 };

const all_sizes = [_]FixtureSize{
    .{ .name = "small", .files = 3, .lines = 500 },
    .{ .name = "medium", .files = 10, .lines = 2000 },
    .{ .name = "large", .files = 20, .lines = 5000 },
};

const default_iters: u32 = 10;
const warmup_iters: u32 = 3;

const bench_root = "/tmp/cc-statusline-bench";
const cache_backup = "/tmp/cc-statusline-cache.bin.bench-bak";

// ─── Stats ─────────────────────────────────────────────────────────────────

const Stats = struct {
    iters: u32,
    min_ns: u64,
    median_ns: u64,
    p99_ns: u64,
};

fn computeStats(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, comptime std.sort.asc(u64));
    const n = samples.len;
    const median = samples[n / 2];
    // Nearest-rank percentile, clamped to last index.
    const p99_idx = @min(n - 1, (n * 99 + 99) / 100);
    return .{
        .iters = @intCast(n),
        .min_ns = samples[0],
        .median_ns = median,
        .p99_ns = samples[p99_idx],
    };
}

// ─── Fixture generation ───────────────────────────────────────────────────

/// Writes one synthetic JSONL line with all fields parseJsonlContent reads.
/// Each line gets a unique msg_id:req_id so dedup keeps every entry.
fn writeFixtureLine(w: *Io.Writer, file_idx: u32, line_idx: u32, ts_ms: i64) !void {
    var date_buf: [32]u8 = undefined;
    const ts = formatIsoUtc(&date_buf, ts_ms);
    try w.print(
        \\{{"timestamp":"{s}","requestId":"req-f{d}-l{d}","message":{{"id":"msg-f{d}-l{d}","model":"claude-sonnet-4-5-20250929","usage":{{"input_tokens":150,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}
        \\
    , .{ ts, file_idx, line_idx, file_idx, line_idx });
}

/// Format ms-since-epoch as ISO 8601 UTC ("YYYY-MM-DDTHH:MM:SS.sssZ").
fn formatIsoUtc(buf: *[32]u8, ms: i64) []const u8 {
    const c = time.epochToCivil(@divFloor(ms, 1000));
    const ms_part: u64 = @intCast(@mod(ms, 1000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second, ms_part,
    }) catch unreachable;
}

/// Build a fixture tree at `bench_root/projects/proj-bench/file-N.jsonl`.
/// Returns total bytes written. Existing tree is wiped first.
fn writeFixtures(io: Io, files: u32, lines: u32, now_ms: i64) !u64 {
    var tmp = try Io.Dir.openDirAbsolute(io, "/tmp", .{ .iterate = false });
    defer tmp.close(io);
    tmp.deleteTree(io, "cc-statusline-bench") catch {};

    try tmp.createDirPath(io, "cc-statusline-bench/projects/proj-bench");

    // Spread timestamps over the last 24h so all entries fall in the scan window
    // and exercise per-day cost accumulation.
    const window_ms: i64 = 24 * 60 * 60 * 1000;
    const total_lines: u64 = @as(u64, files) * @as(u64, lines);
    const step_ms: i64 = if (total_lines > 1) @divFloor(window_ms, @as(i64, @intCast(total_lines - 1))) else 0;

    var total_bytes: u64 = 0;
    var path_buf: [256]u8 = undefined;
    var line_buf: [4096]u8 = undefined;
    var global_idx: u64 = 0;

    var fi: u32 = 0;
    while (fi < files) : (fi += 1) {
        const rel = try std.fmt.bufPrint(&path_buf, "cc-statusline-bench/projects/proj-bench/file-{d}.jsonl", .{fi});
        var f = try tmp.createFile(io, rel, .{});
        defer f.close(io);
        var fbuf: [16 * 1024]u8 = undefined;
        var w = f.writerStreaming(io, &fbuf);

        var li: u32 = 0;
        while (li < lines) : (li += 1) {
            const ts = now_ms - window_ms + @as(i64, @intCast(global_idx)) * step_ms;
            global_idx += 1;
            // Format into a stack buffer first so we know the byte count.
            var stream: Io.Writer = .fixed(&line_buf);
            try writeFixtureLine(&stream, fi, li, ts);
            const bytes = stream.buffered();
            try w.interface.writeAll(bytes);
            total_bytes += bytes.len;
        }
        try w.interface.flush();
    }
    return total_bytes;
}

/// Read the entire contents of one fixture file (used by parseJsonlContent micro).
fn loadFirstFixture(io: Io, allocator: std.mem.Allocator) ![]u8 {
    const path = bench_root ++ "/projects/proj-bench/file-0.jsonl";
    var f = try Io.Dir.openFileAbsolute(io, path, .{});
    defer f.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var r = f.readerStreaming(io, &rbuf);
    return try r.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
}

// ─── Cache isolation ──────────────────────────────────────────────────────

/// Move the user's cache aside so benches run cold without clobbering real data.
/// Returns whether a stash actually happened; `restoreCache` keys off this so it
/// never renames a missing backup over a live cache it failed to stash.
/// Deletes any stale backup from a prior interrupted run first — otherwise the
/// rename would fail with PathAlreadyExists and leave the live cache exposed.
fn stashCache(io: Io) bool {
    Io.Dir.deleteFileAbsolute(io, cache_backup) catch {};
    Io.Dir.renameAbsolute(scan.cache_path, cache_backup, io) catch return false;
    return true;
}

fn restoreCache(io: Io, stashed: bool) void {
    Io.Dir.deleteFileAbsolute(io, scan.cache_path) catch {};
    if (stashed) {
        Io.Dir.renameAbsolute(cache_backup, scan.cache_path, io) catch {};
    }
}

fn dropCache(io: Io) void {
    Io.Dir.deleteFileAbsolute(io, scan.cache_path) catch {};
}

// ─── Macro bench: spawn cc-statusline ─────────────────────────────────────

const stdin_payload =
    \\{"model":{"id":"claude-sonnet-4-5-20250929","display_name":"Sonnet 4.5"},"cwd":"/tmp"}
;

fn buildEnvMap(allocator: std.mem.Allocator, parent: *const std.process.Environ.Map, config_dir: []const u8) !std.process.Environ.Map {
    var map = try parent.clone(allocator);
    try map.put("CLAUDE_CONFIG_DIR", config_dir);
    return map;
}

fn runOnce(io: Io, allocator: std.mem.Allocator, exe_path: []const u8, env: *const std.process.Environ.Map) !u64 {
    const start_ts = Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{exe_path},
        .environ_map = env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    if (child.stdin) |*stdin_file| {
        var sbuf: [256]u8 = undefined;
        var w = stdin_file.writerStreaming(io, &sbuf);
        w.interface.writeAll(stdin_payload) catch {};
        w.interface.flush() catch {};
        stdin_file.close(io);
        child.stdin = null;
    }
    // Drain stdout/stderr so the child doesn't block on a full pipe.
    if (child.stdout) |*f| drainPipe(io, allocator, f);
    if (child.stderr) |*f| drainPipe(io, allocator, f);

    _ = try child.wait(io);
    return @intCast(start_ts.untilNow(io, .awake).nanoseconds);
}

fn drainPipe(io: Io, allocator: std.mem.Allocator, file: *Io.File) void {
    var buf: [4096]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    _ = r.interface.allocRemaining(allocator, .limited(64 * 1024)) catch {};
}

const RunMode = enum { cold, warm };

fn benchEndToEnd(allocator: std.mem.Allocator, io: Io, exe_path: []const u8, env: *const std.process.Environ.Map, mode: RunMode, iters: u32) !Stats {
    if (mode == .warm) {
        // Prime the cache once before warm runs.
        dropCache(io);
        _ = try runOnce(io, allocator, exe_path, env);
    }

    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    var i: u32 = 0;
    while (i < warmup_iters) : (i += 1) {
        if (mode == .cold) dropCache(io);
        _ = try runOnce(io, allocator, exe_path, env);
    }
    i = 0;
    while (i < iters) : (i += 1) {
        if (mode == .cold) dropCache(io);
        samples[i] = try runOnce(io, allocator, exe_path, env);
    }
    return computeStats(samples);
}

// ─── Micro bench: scan.benchFullScan ──────────────────────────────────────

fn benchFullScan(allocator: std.mem.Allocator, io: Io, projects_path: []const u8, now_ms: i64, day_start_ms: i64, iters: u32) !Stats {
    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    // Each iteration uses a fresh arena so allocations don't accumulate.
    var i: u32 = 0;
    while (i < warmup_iters) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        _ = scan.benchFullScan(io, arena.allocator(), projects_path, now_ms, day_start_ms);
    }
    i = 0;
    while (i < iters) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const start_ts = Io.Clock.awake.now(io);
        _ = scan.benchFullScan(io, arena.allocator(), projects_path, now_ms, day_start_ms);
        samples[i] = @intCast(start_ts.untilNow(io, .awake).nanoseconds);
    }
    return computeStats(samples);
}

// ─── Micro bench: parseJsonlContent on one file ───────────────────────────

fn benchParseJsonl(allocator: std.mem.Allocator, io: Io, content: []const u8, iters: u32) !Stats {
    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    var i: u32 = 0;
    while (i < warmup_iters) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var entries: std.ArrayList(scan.TranscriptEntry) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        scan.parseJsonlContent(arena.allocator(), arena.allocator(), content, &entries, &seen);
    }
    i = 0;
    while (i < iters) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var entries: std.ArrayList(scan.TranscriptEntry) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        const start_ts = Io.Clock.awake.now(io);
        scan.parseJsonlContent(arena.allocator(), arena.allocator(), content, &entries, &seen);
        samples[i] = @intCast(start_ts.untilNow(io, .awake).nanoseconds);
    }
    return computeStats(samples);
}

// ─── Output ───────────────────────────────────────────────────────────────

const Result = struct {
    size: []const u8,
    fixture_files: u32,
    fixture_lines: u32,
    fixture_bytes: u64,
    e2e_cold: Stats,
    e2e_warm: Stats,
    full_scan: Stats,
    parse_jsonl: Stats,

    fn toBaseline(self: Result) BaselineEntry {
        return .{
            .e2e_cold = self.e2e_cold.median_ns,
            .e2e_warm = self.e2e_warm.median_ns,
            .full_scan = self.full_scan.median_ns,
            .parse_jsonl = self.parse_jsonl.median_ns,
        };
    }
};

fn fmtNs(buf: []u8, ns: u64) []const u8 {
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    if (ms >= 1.0) return std.fmt.bufPrint(buf, "{d:.2} ms", .{ms}) catch buf[0..0];
    const us = @as(f64, @floatFromInt(ns)) / 1_000.0;
    return std.fmt.bufPrint(buf, "{d:.1} us", .{us}) catch buf[0..0];
}

fn fmtBytes(buf: []u8, n: u64) []const u8 {
    const f = @as(f64, @floatFromInt(n));
    if (n >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MiB", .{f / (1024.0 * 1024.0)}) catch buf[0..0];
    if (n >= 1024) return std.fmt.bufPrint(buf, "{d:.1} KiB", .{f / 1024.0}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf[0..0];
}

fn diffPct(now: u64, base: ?u64) ?f64 {
    const b = base orelse return null;
    if (b == 0) return null;
    return (@as(f64, @floatFromInt(@as(i128, now) - @as(i128, b))) / @as(f64, @floatFromInt(b))) * 100.0;
}

inline fn pickBaseline(base: ?BaselineEntry, comptime field: []const u8) ?u64 {
    return if (base) |b| @field(b, field) else null;
}

fn writeRow(w: *Io.Writer, label: []const u8, s: Stats, base_median: ?u64) !void {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    try w.print("    {s: <22}{s: >12}  {s: >12}  {s: >12}", .{
        label,
        fmtNs(&b1, s.median_ns),
        fmtNs(&b2, s.min_ns),
        fmtNs(&b3, s.p99_ns),
    });
    if (diffPct(s.median_ns, base_median)) |p| {
        const sign = if (p >= 0) "+" else "";
        try w.print("   [{s}{d:.1}% vs baseline]", .{ sign, p });
    }
    try w.writeAll("\n");
}

fn printResults(w: *Io.Writer, results: []const Result, baseline: ?BaselineMap) !void {
    try w.print("\n  cc-statusline benchmark — zig 0.16.0\n", .{});
    try w.print("  iters: {d} measured (+{d} warmup)\n\n", .{ default_iters, warmup_iters });

    for (results) |r| {
        var fb: [32]u8 = undefined;
        try w.print("  fixture: {s} ({d} files × {d} lines, {s})\n", .{
            r.size, r.fixture_files, r.fixture_lines, fmtBytes(&fb, r.fixture_bytes),
        });
        try w.writeAll("    scenario               median           min           p99\n");
        try w.writeAll("    ────────────────────────────────────────────────────────────\n");

        const base = if (baseline) |bl| bl.find(r.size) else null;
        try writeRow(w, "end-to-end (cold)", r.e2e_cold, pickBaseline(base, "e2e_cold"));
        try writeRow(w, "end-to-end (warm)", r.e2e_warm, pickBaseline(base, "e2e_warm"));
        try writeRow(w, "fullScan", r.full_scan, pickBaseline(base, "full_scan"));
        try writeRow(w, "parseJsonlContent", r.parse_jsonl, pickBaseline(base, "parse_jsonl"));
        try w.writeAll("\n");
    }
}

// ─── Baseline JSON ────────────────────────────────────────────────────────

const baseline_path = "bench/baseline.json";

const BaselineEntry = struct {
    e2e_cold: u64,
    e2e_warm: u64,
    full_scan: u64,
    parse_jsonl: u64,
};

const BaselineMap = struct {
    entries: std.StringArrayHashMapUnmanaged(BaselineEntry),

    fn find(self: BaselineMap, size: []const u8) ?BaselineEntry {
        return self.entries.get(size);
    }
};

fn readBaseline(io: Io, allocator: std.mem.Allocator) ?BaselineMap {
    var f = Io.Dir.cwd().openFile(io, baseline_path, .{}) catch return null;
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = f.readerStreaming(io, &rbuf);
    const data = r.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024)) catch return null;
    const parsed = json.parseFromSlice(json.Value, allocator, data, .{}) catch return null;
    const root = if (parsed.value == .object) parsed.value.object else return null;

    var map: std.StringArrayHashMapUnmanaged(BaselineEntry) = .empty;
    var it = root.iterator();
    while (it.next()) |e| {
        const obj = if (e.value_ptr.* == .object) e.value_ptr.*.object else continue;
        const entry = BaselineEntry{
            .e2e_cold = readNs(obj, "e2e_cold"),
            .e2e_warm = readNs(obj, "e2e_warm"),
            .full_scan = readNs(obj, "full_scan"),
            .parse_jsonl = readNs(obj, "parse_jsonl"),
        };
        map.put(allocator, e.key_ptr.*, entry) catch continue;
    }
    return .{ .entries = map };
}

fn readNs(obj: json.ObjectMap, key: []const u8) u64 {
    return @intCast(@max(ju.getI64Field(obj, key), 0));
}

fn findResult(results: []const Result, size: []const u8) ?BaselineEntry {
    for (results) |r| {
        if (std.mem.eql(u8, r.size, size)) return r.toBaseline();
    }
    return null;
}

fn writeBaseline(io: Io, results: []const Result, existing: ?BaselineMap) !void {
    // Merge `existing` so a filtered --save (e.g. --size=medium, or a typoed
    // --size=foo with zero matches) does not silently delete entries for sizes
    // that were skipped this run.
    Io.Dir.cwd().createDirPath(io, "bench") catch {};
    var f = try Io.Dir.cwd().createFile(io, baseline_path, .{});
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = f.writerStreaming(io, &wbuf);
    try w.interface.writeAll("{\n");

    var first = true;
    for (all_sizes) |sz| {
        const entry = findResult(results, sz.name) orelse
            (if (existing) |b| b.find(sz.name) else null) orelse continue;

        if (!first) try w.interface.writeAll(",\n");
        first = false;
        try w.interface.print(
            \\  "{s}": {{ "e2e_cold": {d}, "e2e_warm": {d}, "full_scan": {d}, "parse_jsonl": {d} }}
        , .{ sz.name, entry.e2e_cold, entry.e2e_warm, entry.full_scan, entry.parse_jsonl });
    }
    try w.interface.writeAll("\n}\n");
    try w.interface.flush();
}

// ─── Entry point ──────────────────────────────────────────────────────────

const ParsedArgs = struct {
    exe_path: []const u8,
    save: bool,
    only_size: ?[]const u8,
};

const size_flag = "--size=";

/// argv[0] is the bench binary, argv[1] is the cc-statusline path (required),
/// the rest are flags.
fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !ParsedArgs {
    const argv = try args.toSlice(allocator);
    if (argv.len < 2) return error.MissingExePath;
    var out: ParsedArgs = .{ .exe_path = argv[1], .save = false, .only_size = null };
    for (argv[2..]) |a| {
        if (std.mem.eql(u8, a, "--save")) {
            out.save = true;
        } else if (std.mem.startsWith(u8, a, size_flag)) {
            out.only_size = a[size_flag.len..];
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = parseArgs(allocator, init.minimal.args) catch {
        var stderr_buf: [256]u8 = undefined;
        var w = Io.File.stderr().writerStreaming(io, &stderr_buf);
        try w.interface.writeAll("usage: cc-statusline-bench <exe-path> [--save] [--size=small|medium|large]\n");
        try w.interface.flush();
        return;
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    const stashed = stashCache(io);
    defer restoreCache(io, stashed);

    const baseline = readBaseline(io, allocator);

    // env_map is allocated from the arena, so no explicit deinit is needed.
    const env_map = try buildEnvMap(allocator, init.environ_map, bench_root);

    const projects_path = bench_root ++ "/projects";
    const now_ms: i64 = std.Io.Clock.real.now(io).toMilliseconds();
    const day_start_ms = now_ms - 12 * 60 * 60 * 1000; // 12h ago — covers all fixture entries

    var results: std.ArrayList(Result) = .empty;

    for (all_sizes) |sz| {
        if (args.only_size) |want| {
            if (!std.mem.eql(u8, want, sz.name)) continue;
        }
        try out.print("  generating fixture: {s} ({d} files × {d} lines)...\n", .{ sz.name, sz.files, sz.lines });
        try out.flush();

        const bytes = try writeFixtures(io, sz.files, sz.lines, now_ms);
        const content = try loadFirstFixture(io, allocator);

        const e2e_cold = try benchEndToEnd(allocator, io, args.exe_path, &env_map, .cold, default_iters);
        const e2e_warm = try benchEndToEnd(allocator, io, args.exe_path, &env_map, .warm, default_iters);
        const fs_stats = try benchFullScan(allocator, io, projects_path, now_ms, day_start_ms, default_iters);
        const pj_stats = try benchParseJsonl(allocator, io, content, default_iters);

        try results.append(allocator, .{
            .size = sz.name,
            .fixture_files = sz.files,
            .fixture_lines = sz.lines,
            .fixture_bytes = bytes,
            .e2e_cold = e2e_cold,
            .e2e_warm = e2e_warm,
            .full_scan = fs_stats,
            .parse_jsonl = pj_stats,
        });
    }

    try printResults(out, results.items, baseline);
    try out.flush();

    if (args.save) {
        try writeBaseline(io, results.items, baseline);
        try out.print("  saved baseline → {s}\n", .{baseline_path});
        try out.flush();
    }

    // Cleanup fixtures.
    var tmp = try Io.Dir.openDirAbsolute(io, "/tmp", .{ .iterate = false });
    defer tmp.close(io);
    tmp.deleteTree(io, "cc-statusline-bench") catch {};
}
