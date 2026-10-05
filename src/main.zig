const std = @import("std");
const json = std.json;
const mem = std.mem;
const Io = std.Io;
const output = @import("output.zig");
const scan = @import("scan.zig");
const time = @import("time.zig");
const types = @import("types.zig");
const ju = @import("json_util.zig");
const TestTree = @import("test_tree.zig").TestTree;

const StdinInfo = types.StdinInfo;
const RateLimitWindow = types.RateLimitWindow;
const PromptCache = types.PromptCache;

const getObj = ju.getObj;
const getObjField = ju.getObjField;
const getStr = ju.getStr;
const getF64 = ju.getF64;
const getI64 = ju.getI64;
const getI64Field = ju.getI64Field;
const getEpochMs = ju.getEpochMs;

// ============================================================
// Stdin Parsing
// ============================================================

fn parseRateLimitWindow(obj: json.ObjectMap) ?RateLimitWindow {
    const pct_val = obj.get("used_percentage") orelse return null;
    const pct = getF64(pct_val) orelse return null;
    var window = RateLimitWindow{ .used_percentage = pct };
    if (obj.get("resets_at")) |ra| {
        // Claude Code sends resets_at as Unix epoch seconds (number)
        window.resets_at_ms = getEpochMs(ra) orelse
            if (getStr(ra)) |s| time.parseIso8601ToMs(s) else null;
    }
    return window;
}

/// Unlike `parseRateLimitWindow`, there is no field whose absence makes the
/// object meaningless, so this always builds a struct and lets each segment
/// gate on its own data.
fn parsePromptCache(obj: json.ObjectMap) PromptCache {
    var pc = PromptCache{};
    if (obj.get("warm")) |v| {
        if (v == .bool) pc.warm = v.bool;
    }
    if (obj.get("caching_observed")) |v| {
        if (v == .bool) pc.caching_observed = v.bool;
    }
    if (obj.get("ttl")) |v| {
        if (getStr(v)) |s| {
            if (mem.eql(u8, s, "1h")) pc.ttl = .one_hour;
            if (mem.eql(u8, s, "5m")) pc.ttl = .five_min;
        }
    }
    // Claude Code sends expires_at as Unix epoch seconds (number)
    if (obj.get("expires_at")) |v| pc.expires_at_ms = getEpochMs(v);
    if (obj.get("hit_ratio")) |v| {
        if (getF64(v)) |ratio| pc.hit_percentage = ratio * 100.0;
    }
    // getI64, not getI64Field: absent and 0 must stay distinguishable.
    if (obj.get("recache_tokens_if_cold")) |v| pc.recache_tokens_if_cold = getI64(v);
    return pc;
}

fn parseStdin(allocator: std.mem.Allocator, data: []const u8) StdinInfo {
    var info = StdinInfo{};
    if (data.len == 0) {
        info.stdin_absent = true;
        return info;
    }
    const parsed = json.parseFromSlice(json.Value, allocator, data, .{}) catch return info;
    const root = getObj(parsed.value) orelse return info;

    if (getObjField(root, "model")) |model| {
        if (model.get("id")) |id| info.model_id = getStr(id);
        if (model.get("display_name")) |name| info.model_name = getStr(name);
    }
    if (getObjField(root, "cost")) |cost| {
        if (cost.get("total_cost_usd")) |usd| info.session_cost = getF64(usd);
    }
    if (getObjField(root, "context_window")) |ctx| {
        if (ctx.get("used_percentage")) |pct| info.context_pct = getF64(pct);
        if (ctx.get("context_window_size")) |sz| info.context_window_size = getI64(sz);
        if (getObjField(ctx, "current_usage")) |usage| {
            // Saturating: three i64 token counts can overflow a plain sum, and
            // clamping costs no branch.
            info.context_tokens = getI64Field(usage, "input_tokens") +|
                getI64Field(usage, "cache_creation_input_tokens") +|
                getI64Field(usage, "cache_read_input_tokens");
        } else if (ctx.get("total_input_tokens")) |t| {
            // Same input-only sum as current_usage per the statusline docs
            info.context_tokens = getI64(t);
        }
    }
    if (root.get("session_id")) |v| info.session_id = getStr(v);
    if (root.get("session_name")) |v| info.session_name = getStr(v);
    if (root.get("transcript_path")) |v| info.transcript_path = getStr(v);
    if (root.get("cwd")) |v| info.cwd = getStr(v);

    // Parse rate_limits (added in Claude Code v2.1.80)
    if (getObjField(root, "rate_limits")) |rl| {
        if (getObjField(rl, "five_hour")) |fh| info.rate_limit_5h = parseRateLimitWindow(fh);
        if (getObjField(rl, "seven_day")) |sd| info.rate_limit_7d = parseRateLimitWindow(sd);
        // spend_limit added in Claude Code v2.1.251 (apps gateway only)
        if (getObjField(rl, "spend_limit")) |sl| info.rate_limit_spend = parseRateLimitWindow(sl);
    }

    // Parse prompt_cache (added in Claude Code v2.1.251)
    if (getObjField(root, "prompt_cache")) |pc| info.prompt_cache = parsePromptCache(pc);

    if (getObjField(root, "agent")) |agent| {
        if (agent.get("name")) |n| info.agent_name = getStr(n);
    }
    if (getObjField(root, "effort")) |effort| {
        if (effort.get("level")) |l| info.effort_level = getStr(l);
    }
    if (root.get("exceeds_200k_tokens")) |v| {
        if (v == .bool) info.exceeds_200k_tokens = v.bool;
    }

    return info;
}

// ============================================================
// Git Branch Detection
// ============================================================

fn getGitBranch(io: std.Io, buf: *[256]u8, cwd: []const u8) ?[]const u8 {
    // Walk up from cwd looking for a .git directory or pointer file
    var dir = cwd;
    while (true) {
        if (readBranchAt(io, buf, dir)) |branch| return branch;

        // Move to parent directory
        const sep = mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        if (sep == 0) return readBranchAt(io, buf, "");
        dir = dir[0..sep];
    }
}

/// Branch for the repository rooted at `dir`. A linked worktree (`git
/// worktree add`) has a `.git` *file* holding `gitdir: <path>` instead of a
/// directory, so when `<dir>/.git/HEAD` cannot be read the pointer is
/// followed to `<gitdir>/HEAD`.
fn readBranchAt(io: std.Io, buf: *[256]u8, dir: []const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const head_path = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir}) catch return null;
    if (readGitHead(io, buf, head_path)) |branch| return branch;

    const dotgit_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{dir}) catch return null;
    var pointer_buf: [4096]u8 = undefined;
    const pointer = readSmallFile(io, &pointer_buf, dotgit_path) orelse return null;
    const gitdir = parseGitdirPointer(pointer) orelse return null;
    // `worktree.useRelativePaths` (and submodules) write the pointer relative
    // to the directory holding the `.git` file.
    const wt_head_path = if (gitdir[0] == '/')
        std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{gitdir}) catch return null
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}/HEAD", .{ dir, gitdir }) catch return null;
    return readGitHead(io, buf, wt_head_path);
}

/// Whole file into `buf`, or null when it cannot be read or does not fit.
/// A truncated ref would render as a wrong branch rather than none, so an
/// exact fit is accepted only once a further read confirms EOF.
fn readSmallFile(io: std.Io, buf: []u8, path: []const u8) ?[]const u8 {
    var f = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var reader = f.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch return null;
    if (n == buf.len) {
        var extra: [1]u8 = undefined;
        const more = reader.interface.readSliceShort(&extra) catch return null;
        if (more != 0) return null;
    }
    return buf[0..n];
}

fn readGitHead(io: std.Io, buf: *[256]u8, path: []const u8) ?[]const u8 {
    const data = readSmallFile(io, buf, path) orelse return null;
    return parseGitHead(data);
}

/// Target of a `.git` pointer file (`gitdir: <path>`), absolute or relative.
fn parseGitdirPointer(raw: []const u8) ?[]const u8 {
    const prefix = "gitdir: ";
    if (!mem.startsWith(u8, raw, prefix)) return null;
    var path = raw[prefix.len..];
    if (path.len > 0 and path[path.len - 1] == '\n') path = path[0 .. path.len - 1];
    if (path.len == 0) return null;
    return path;
}

fn parseGitHead(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;

    // Trim trailing newline
    const content = if (raw[raw.len - 1] == '\n') raw[0 .. raw.len - 1] else raw;
    if (content.len == 0) return null;

    // "ref: refs/heads/<branch>"
    const prefix = "ref: refs/heads/";
    if (mem.startsWith(u8, content, prefix)) {
        return content[prefix.len..];
    }

    // Detached HEAD: show short hash (first 7 chars)
    if (content.len >= 7) return content[0..7];
    return content;
}

// ============================================================
// Main
// ============================================================

pub fn main(init: std.process.Init) void {
    const io = init.io;
    mainImpl(init) catch {
        var buf: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io, &buf);
        output.printFallback(&writer.interface);
        writer.interface.flush() catch {};
    };
}

fn mainImpl(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const theme = output.initTheme(init.environ_map);

    // Read stdin
    var stdin_buf: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const stdin_data = stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch &.{};

    // Parse stdin JSON
    const stdin_info = parseStdin(allocator, stdin_data);

    const now_ms: i64 = std.Io.Clock.real.now(io).toMilliseconds();
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const utc_offset_s = time.getUtcOffsetSeconds(io, init.environ_map, allocator, now_s);
    const day_start_ms = time.computeLocalDayStartMs(now_ms, utc_offset_s);

    // Scan transcripts (or use cache)
    const resets_at_ms: ?i64 = if (stdin_info.rate_limit_5h) |rl| rl.resets_at_ms else null;
    const scan_output = scan.scanTranscripts(io, init.environ_map, allocator, now_ms, day_start_ms, resets_at_ms, &.{});
    const scan_result: ?types.ScanResult = if (scan_output) |o| o.scan else null;

    // Resolve git branch
    var branch_buf: [256]u8 = undefined;
    const git_branch: ?[]const u8 = if (stdin_info.cwd) |cwd| getGitBranch(io, &branch_buf, cwd) else null;

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    try output.printOutput(&writer.interface, theme, stdin_info, scan_result, now_ms, utc_offset_s, git_branch);
    try writer.interface.flush();
}

// ============================================================
// Tests
// ============================================================

test "parseStdin context_tokens from current_usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"used_percentage":54.0,"current_usage":{"input_tokens":10000,"cache_creation_input_tokens":3000,"cache_read_input_tokens":7000}}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, 20000), info.context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 54.0), info.context_pct.?, 1e-10);
}

test "parseStdin null current_usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"used_percentage":10.0,"current_usage":null}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, null), info.context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), info.context_pct.?, 1e-10);
}

test "parseStdin missing current_usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"used_percentage":25.0}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, null), info.context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), info.context_pct.?, 1e-10);
}

test "parseStdin basic fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"model":{"id":"claude-opus-4-6","display_name":"Opus"},"cost":{"total_cost_usd":1.5},"session_id":"abc-123"}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("claude-opus-4-6", info.model_id.?);
    try std.testing.expectEqualStrings("Opus", info.model_name.?);
}

test "parseStdin empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "");
    try std.testing.expectEqual(@as(?[]const u8, null), info.model_id);
    try std.testing.expectEqual(@as(?f64, null), info.context_pct);
    try std.testing.expectEqual(@as(?i64, null), info.context_tokens);
}

test "parseStdin rate_limits full (unix epoch seconds)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"rate_limits":{"five_hour":{"used_percentage":42.3,"resets_at":1742479200},"seven_day":{"used_percentage":85.7,"resets_at":1742774400}}}
    ;
    const info = parseStdin(arena.allocator(), input);

    try std.testing.expect(info.rate_limit_5h != null);
    try std.testing.expectApproxEqAbs(@as(f64, 42.3), info.rate_limit_5h.?.used_percentage, 1e-10);
    try std.testing.expect(info.rate_limit_5h.?.resets_at_ms != null);
    try std.testing.expectEqual(@as(i64, 1742479200 * 1000), info.rate_limit_5h.?.resets_at_ms.?);

    try std.testing.expect(info.rate_limit_7d != null);
    try std.testing.expectApproxEqAbs(@as(f64, 85.7), info.rate_limit_7d.?.used_percentage, 1e-10);
    try std.testing.expect(info.rate_limit_7d.?.resets_at_ms != null);
    try std.testing.expectEqual(@as(i64, 1742774400 * 1000), info.rate_limit_7d.?.resets_at_ms.?);
}

test "parseStdin rate_limits full (ISO 8601 fallback)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"rate_limits":{"five_hour":{"used_percentage":42.3,"resets_at":"2026-03-20T15:00:00Z"},"seven_day":{"used_percentage":85.7,"resets_at":"2026-03-24T00:00:00Z"}}}
    ;
    const info = parseStdin(arena.allocator(), input);

    try std.testing.expect(info.rate_limit_5h != null);
    try std.testing.expectApproxEqAbs(@as(f64, 42.3), info.rate_limit_5h.?.used_percentage, 1e-10);
    try std.testing.expect(info.rate_limit_5h.?.resets_at_ms != null);

    try std.testing.expect(info.rate_limit_7d != null);
    try std.testing.expectApproxEqAbs(@as(f64, 85.7), info.rate_limit_7d.?.used_percentage, 1e-10);
    try std.testing.expect(info.rate_limit_7d.?.resets_at_ms != null);
}

test "parseStdin rate_limits partial (5h only, no resets_at)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"rate_limits":{"five_hour":{"used_percentage":10.0}}}
    ;
    const info = parseStdin(arena.allocator(), input);

    try std.testing.expect(info.rate_limit_5h != null);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), info.rate_limit_5h.?.used_percentage, 1e-10);
    try std.testing.expectEqual(@as(?i64, null), info.rate_limit_5h.?.resets_at_ms);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_7d);
}

test "parseStdin rate_limits spend_limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"rate_limits":{"spend_limit":{"used_percentage":120.5,"resets_at":1742774400}}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_5h);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_7d);
    try std.testing.expectApproxEqAbs(@as(f64, 120.5), info.rate_limit_spend.?.used_percentage, 1e-10);
    try std.testing.expectEqual(@as(i64, 1742774400 * 1000), info.rate_limit_spend.?.resets_at_ms.?);
}

test "parseStdin no rate_limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"model":{"id":"claude-opus-4-6","display_name":"Opus"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_5h);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_7d);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_spend);
}

test "parseStdin prompt_cache full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1738429200,"requests":14,"misses":2,"hit_ratio":0.91,"recache_tokens_if_cold":45000}}
    ;
    const info = parseStdin(arena.allocator(), input);

    try std.testing.expect(info.prompt_cache != null);
    const pc = info.prompt_cache.?;
    try std.testing.expect(pc.warm);
    try std.testing.expect(pc.caching_observed);
    try std.testing.expectEqual(types.CacheTtl.one_hour, pc.ttl.?);
    try std.testing.expectEqual(@as(i64, 1738429200 * 1000), pc.expires_at_ms.?);
    try std.testing.expectApproxEqAbs(@as(f64, 91.0), pc.hit_percentage.?, 1e-10);
    try std.testing.expectEqual(@as(i64, 45000), pc.recache_tokens_if_cold.?);
}

test "parseStdin prompt_cache 5m ttl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"prompt_cache":{"caching_observed":true,"ttl":"5m"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(types.CacheTtl.five_min, info.prompt_cache.?.ttl.?);
}

test "parseStdin prompt_cache cold with nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"prompt_cache":{"warm":false,"caching_observed":true,"ttl":"1h","expires_at":null,"hit_ratio":null,"recache_tokens_if_cold":null}}
    ;
    const info = parseStdin(arena.allocator(), input);

    const pc = info.prompt_cache.?;
    try std.testing.expect(!pc.warm);
    try std.testing.expect(pc.caching_observed);
    try std.testing.expectEqual(@as(?i64, null), pc.expires_at_ms);
    try std.testing.expectEqual(@as(?f64, null), pc.hit_percentage);
    try std.testing.expectEqual(@as(?i64, null), pc.recache_tokens_if_cold);
}

test "parseStdin prompt_cache unknown ttl keeps other fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"prompt_cache":{"warm":true,"caching_observed":true,"ttl":"10m","hit_ratio":0.5}}
    ;
    const info = parseStdin(arena.allocator(), input);

    const pc = info.prompt_cache.?;
    try std.testing.expectEqual(@as(?types.CacheTtl, null), pc.ttl);
    try std.testing.expect(pc.warm);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), pc.hit_percentage.?, 1e-10);
}

test "parseStdin rejects out-of-range numerics without trapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Every value here traps on an unchecked conversion: 1e20 is a finite
    // f64 outside i64, and 1e16 seconds overflows i64 when scaled to ms.
    const input =
        \\{"rate_limits":{"five_hour":{"used_percentage":42.0,"resets_at":1e20},"seven_day":{"used_percentage":10.0,"resets_at":10000000000000000}},"prompt_cache":{"caching_observed":true,"expires_at":1e20,"hit_ratio":0.5}}
    ;
    const info = parseStdin(arena.allocator(), input);

    // The window survives; only the unusable reset time drops out.
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), info.rate_limit_5h.?.used_percentage, 1e-10);
    try std.testing.expectEqual(@as(?i64, null), info.rate_limit_5h.?.resets_at_ms);
    try std.testing.expectEqual(@as(?i64, null), info.rate_limit_7d.?.resets_at_ms);

    try std.testing.expectEqual(@as(?i64, null), info.prompt_cache.?.expires_at_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), info.prompt_cache.?.hit_percentage.?, 1e-10);
}

test "parseStdin saturates the current_usage token sum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"current_usage":{"input_tokens":9223372036854775807,"cache_creation_input_tokens":9223372036854775807,"cache_read_input_tokens":9223372036854775807}}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), info.context_tokens);
}

test "parseStdin no prompt_cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"model":{"id":"claude-opus-5","display_name":"Opus"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?PromptCache, null), info.prompt_cache);
}

test "parseStdin agent.name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"agent":{"name":"security-reviewer"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("security-reviewer", info.agent_name.?);
}

test "parseStdin no agent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"model\":{\"id\":\"x\"}}");
    try std.testing.expectEqual(@as(?[]const u8, null), info.agent_name);
}

test "parseStdin effort.level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"effort":{"level":"xhigh"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("xhigh", info.effort_level.?);
}

test "parseStdin no effort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"model\":{\"id\":\"x\"}}");
    try std.testing.expectEqual(@as(?[]const u8, null), info.effort_level);
}

test "parseStdin session_name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"session_id":"abc-123","session_name":"my-session"}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("my-session", info.session_name.?);
}

test "parseStdin no session_name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"session_id\":\"abc-123\"}");
    try std.testing.expectEqual(@as(?[]const u8, null), info.session_name);
}

test "parseStdin context_window_size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"used_percentage":8.0,"context_window_size":200000}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, 200000), info.context_window_size);
}

test "parseStdin context_tokens falls back to total_input_tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"used_percentage":8.0,"total_input_tokens":15234}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, 15234), info.context_tokens);
}

test "parseStdin context_tokens prefers current_usage over total_input_tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"context_window":{"total_input_tokens":99999,"current_usage":{"input_tokens":10000,"cache_creation_input_tokens":3000,"cache_read_input_tokens":7000}}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?i64, 20000), info.context_tokens);
}

test "parseStdin exceeds_200k_tokens true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"exceeds_200k_tokens\":true}");
    try std.testing.expectEqual(true, info.exceeds_200k_tokens);
}

test "parseStdin exceeds_200k_tokens false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"exceeds_200k_tokens\":false}");
    try std.testing.expectEqual(false, info.exceeds_200k_tokens);
}

test "parseStdin exceeds_200k_tokens missing defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{}");
    try std.testing.expectEqual(false, info.exceeds_200k_tokens);
}

test "parseStdin session identity and cost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"session_id":"abc-123","transcript_path":"/home/user/.claude/projects/p/abc-123.jsonl","cost":{"total_cost_usd":2.5}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("abc-123", info.session_id.?);
    try std.testing.expectEqualStrings("/home/user/.claude/projects/p/abc-123.jsonl", info.transcript_path.?);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), info.session_cost.?, 1e-10);
}

test "parseStdin cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{\"cwd\":\"/home/user/project\"}");
    try std.testing.expectEqualStrings("/home/user/project", info.cwd.?);
}

// --- parseGitHead ---

test "parseGitHead branch ref" {
    try std.testing.expectEqualStrings("main", parseGitHead("ref: refs/heads/main\n").?);
    try std.testing.expectEqualStrings("feature/foo", parseGitHead("ref: refs/heads/feature/foo\n").?);
}

test "parseGitHead detached HEAD" {
    try std.testing.expectEqualStrings("abc1234", parseGitHead("abc1234def5678901234567890abcdef01234567\n").?);
}

test "parseGitHead short content" {
    try std.testing.expectEqualStrings("abc", parseGitHead("abc\n").?);
}

test "parseGitHead empty" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitHead(""));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitHead("\n"));
}

test "parseGitHead no trailing newline" {
    try std.testing.expectEqualStrings("main", parseGitHead("ref: refs/heads/main").?);
    try std.testing.expectEqualStrings("abc1234", parseGitHead("abc1234def5678901234567890abcdef01234567").?);
}

// --- parseGitdirPointer ---

test "parseGitdirPointer absolute path" {
    try std.testing.expectEqualStrings("/repo/.git/worktrees/wt", parseGitdirPointer("gitdir: /repo/.git/worktrees/wt\n").?);
    try std.testing.expectEqualStrings("/repo/.git/worktrees/wt", parseGitdirPointer("gitdir: /repo/.git/worktrees/wt").?);
}

test "parseGitdirPointer keeps relative paths for the caller to resolve" {
    try std.testing.expectEqualStrings("../main/.git/worktrees/wt", parseGitdirPointer("gitdir: ../main/.git/worktrees/wt\n").?);
}

test "parseGitdirPointer rejects missing prefix and empty" {
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitdirPointer("ref: refs/heads/main\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitdirPointer("gitdir: \n"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseGitdirPointer(""));
}

test "parseStdin empty input sets stdin_absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(parseStdin(arena.allocator(), "").stdin_absent);
}

test "parseStdin invalid json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{broken");
    try std.testing.expect(!info.stdin_absent);
    try std.testing.expectEqual(@as(?[]const u8, null), info.model_id);
    try std.testing.expectEqual(@as(?f64, null), info.context_pct);
}

// --- getGitBranch ---

test "getGitBranch finds .git/HEAD in current directory" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try TestTree.init(arena.allocator());
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(io, ".git");
    {
        var f = try tree.tmp.dir.createFile(io, ".git/HEAD", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ref: refs/heads/main\n");
    }
    var buf: [256]u8 = undefined;
    const branch = getGitBranch(io, &buf, tree.root);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "getGitBranch walks up to parent" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try TestTree.init(arena.allocator());
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(io, ".git");
    try tree.tmp.dir.createDirPath(io, "sub/dir");
    {
        var f = try tree.tmp.dir.createFile(io, ".git/HEAD", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ref: refs/heads/feature-x\n");
    }
    var buf: [256]u8 = undefined;
    const branch = getGitBranch(io, &buf, try tree.path("sub/dir"));
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("feature-x", branch.?);
}

test "getGitBranch follows a linked worktree's .git pointer file" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try TestTree.init(arena.allocator());
    defer tree.deinit();
    const gitdir = try tree.path("main/.git/worktrees/wt");
    const wt = try tree.path("wt");
    try tree.tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
    try tree.tmp.dir.createDirPath(io, "wt");
    {
        var f = try tree.tmp.dir.createFile(io, "main/.git/worktrees/wt/HEAD", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ref: refs/heads/feature-wt\n");
    }
    {
        var f = try tree.tmp.dir.createFile(io, "wt/.git", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "gitdir: ");
        try f.writeStreamingAll(io, gitdir);
        try f.writeStreamingAll(io, "\n");
    }
    var buf: [256]u8 = undefined;
    const branch = getGitBranch(io, &buf, wt);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("feature-wt", branch.?);

    // worktree.useRelativePaths=true writes the pointer relative to the worktree.
    {
        var f = try tree.tmp.dir.createFile(io, "wt/.git", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "gitdir: ../main/.git/worktrees/wt\n");
    }
    const rel_branch = getGitBranch(io, &buf, wt);
    try std.testing.expect(rel_branch != null);
    try std.testing.expectEqualStrings("feature-wt", rel_branch.?);
}

test "readGitHead accepts a HEAD that exactly fills the buffer and rejects a longer one" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try TestTree.init(arena.allocator());
    defer tree.deinit();
    const path = try tree.path("HEAD");
    const prefix = "ref: refs/heads/";
    // prefix (16) + 239 + "\n" = 256 bytes, the buffer size exactly.
    const exact = prefix ++ ("b" ** 239) ++ "\n";
    comptime std.debug.assert(exact.len == 256);
    {
        var f = try tree.tmp.dir.createFile(io, "HEAD", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, exact);
    }
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("b" ** 239, readGitHead(io, &buf, path).?);
    {
        var f = try tree.tmp.dir.createFile(io, "HEAD", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, prefix ++ ("b" ** 240) ++ "\n");
    }
    try std.testing.expectEqual(@as(?[]const u8, null), readGitHead(io, &buf, path));
}

test "getGitBranch returns null when no .git/HEAD" {
    // Not a TestTree: those live under .zig-cache inside this repository,
    // whose own .git/HEAD the walk-up would find. /tmp and / have none.
    const io = std.testing.io;
    const base = "/tmp/cc-test-gitbranch-empty";
    Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer Io.Dir.deleteDirAbsolute(io, base) catch {};
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), getGitBranch(io, &buf, base));
}

test {
    _ = output;
    _ = scan;
    _ = time;
    _ = @import("pricing.zig");
}
