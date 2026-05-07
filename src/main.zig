const std = @import("std");
const json = std.json;
const mem = std.mem;
const Io = std.Io;
const output = @import("output.zig");
const scan = @import("scan.zig");
const time = @import("time.zig");
const types = @import("types.zig");
const ju = @import("json_util.zig");

const StdinInfo = types.StdinInfo;
const RateLimitWindow = types.RateLimitWindow;

const getObj = ju.getObj;
const getObjField = ju.getObjField;
const getStr = ju.getStr;
const getF64 = ju.getF64;
const getI64 = ju.getI64;
const getI64Field = ju.getI64Field;

// ============================================================
// Stdin Parsing
// ============================================================

fn parseRateLimitWindow(obj: json.ObjectMap) ?RateLimitWindow {
    const pct_val = obj.get("used_percentage") orelse return null;
    const pct = getF64(pct_val) orelse return null;
    var window = RateLimitWindow{ .used_percentage = pct };
    if (obj.get("resets_at")) |ra| {
        // Claude Code sends resets_at as Unix epoch seconds (number)
        if (getI64(ra)) |epoch_s| {
            window.resets_at_ms = epoch_s * 1000;
        } else if (getStr(ra)) |s| {
            window.resets_at_ms = time.parseIso8601ToMs(s);
        }
    }
    return window;
}

fn parseStdin(allocator: std.mem.Allocator, data: []const u8) StdinInfo {
    var info = StdinInfo{};
    if (data.len == 0) return info;
    const parsed = json.parseFromSlice(json.Value, allocator, data, .{}) catch return info;
    const root = getObj(parsed.value) orelse return info;

    if (getObjField(root, "model")) |model| {
        if (model.get("id")) |id| info.model_id = getStr(id);
        if (model.get("display_name")) |name| info.model_name = getStr(name);
    }
    if (getObjField(root, "cost")) |cost| {
        if (cost.get("total_cost_usd")) |usd| info.session_cost = getF64(usd);
        if (cost.get("total_lines_added")) |la| info.lines_added = getI64(la);
        if (cost.get("total_lines_removed")) |lr| info.lines_removed = getI64(lr);
        if (cost.get("total_duration_ms")) |dur| {
            if (getF64(dur)) |d| info.session_duration_ms = @as(i64, @intFromFloat(d));
        }
    }
    if (getObjField(root, "context_window")) |ctx| {
        if (ctx.get("used_percentage")) |pct| info.context_pct = getF64(pct);
        if (getObjField(ctx, "current_usage")) |usage| {
            info.context_tokens = getI64Field(usage, "input_tokens") +
                getI64Field(usage, "cache_creation_input_tokens") +
                getI64Field(usage, "cache_read_input_tokens");
        }
    }
    if (root.get("session_id")) |v| info.session_id = getStr(v);
    if (root.get("transcript_path")) |v| info.transcript_path = getStr(v);
    if (root.get("cwd")) |v| info.cwd = getStr(v);

    // Parse rate_limits (added in Claude Code v2.1.80)
    if (getObjField(root, "rate_limits")) |rl| {
        if (getObjField(rl, "five_hour")) |fh| info.rate_limit_5h = parseRateLimitWindow(fh);
        if (getObjField(rl, "seven_day")) |sd| info.rate_limit_7d = parseRateLimitWindow(sd);
    }

    if (getObjField(root, "agent")) |agent| {
        if (agent.get("name")) |n| info.agent_name = getStr(n);
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
    // Walk up from cwd looking for .git/HEAD
    var path_buf: [4096]u8 = undefined;
    var dir = cwd;

    while (true) {
        const head_path = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{dir}) catch return null;
        if (readGitHead(io, buf, head_path)) |branch| return branch;

        // Move to parent directory
        if (mem.lastIndexOfScalar(u8, dir, '/')) |sep| {
            if (sep == 0) {
                return readGitHead(io, buf, "/.git/HEAD");
            }
            dir = dir[0..sep];
        } else {
            return null;
        }
    }
}

fn readGitHead(io: std.Io, buf: *[256]u8, path: []const u8) ?[]const u8 {
    var f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var reader = f.readerStreaming(io, buf);
    const data = reader.interface.allocRemaining(std.heap.page_allocator, .limited(256)) catch return null;
    defer std.heap.page_allocator.free(data);
    const n = @min(data.len, buf.len);
    @memcpy(buf[0..n], data[0..n]);
    return parseGitHead(buf[0..n]);
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
    const scan_result = scan.scanTranscripts(io, init.environ_map, allocator, now_ms, day_start_ms, resets_at_ms);

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
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), info.session_cost.?, 1e-10);
    try std.testing.expectEqualStrings("abc-123", info.session_id.?);
}

test "parseStdin empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "");
    try std.testing.expectEqual(@as(?[]const u8, null), info.model_id);
    try std.testing.expectEqual(@as(?f64, null), info.session_cost);
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

test "parseStdin no rate_limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"model":{"id":"claude-opus-4-6","display_name":"Opus"}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_5h);
    try std.testing.expectEqual(@as(?RateLimitWindow, null), info.rate_limit_7d);
}

test "parseStdin cost and line fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"cost":{"total_cost_usd":2.5,"total_lines_added":150,"total_lines_removed":30,"total_duration_ms":60000}}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), info.session_cost.?, 1e-10);
    try std.testing.expectEqual(@as(?i64, 150), info.lines_added);
    try std.testing.expectEqual(@as(?i64, 30), info.lines_removed);
    try std.testing.expectEqual(@as(?i64, 60000), info.session_duration_ms);
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

test "parseStdin cwd and transcript_path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"cwd":"/home/user/project","transcript_path":"/home/user/.claude/projects/abc/transcript.jsonl"}
    ;
    const info = parseStdin(arena.allocator(), input);
    try std.testing.expectEqualStrings("/home/user/project", info.cwd.?);
    try std.testing.expectEqualStrings("/home/user/.claude/projects/abc/transcript.jsonl", info.transcript_path.?);
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

test "parseStdin invalid json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = parseStdin(arena.allocator(), "{broken");
    try std.testing.expectEqual(@as(?[]const u8, null), info.model_id);
    try std.testing.expectEqual(@as(?f64, null), info.session_cost);
    try std.testing.expectEqual(@as(?f64, null), info.context_pct);
}

// --- getGitBranch ---

test "getGitBranch finds .git/HEAD in current directory" {
    const io = std.testing.io;
    const base = "/tmp/cc-test-gitbranch";
    const git_dir = base ++ "/.git";
    const head_path = git_dir ++ "/HEAD";
    Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    Io.Dir.createDirAbsolute(io, git_dir, .default_dir) catch {};
    defer {
        Io.Dir.deleteFileAbsolute(io, head_path) catch {};
        Io.Dir.deleteDirAbsolute(io, git_dir) catch {};
        Io.Dir.deleteDirAbsolute(io, base) catch {};
    }
    {
        var f = try Io.Dir.createFileAbsolute(io, head_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ref: refs/heads/main\n");
    }
    var buf: [256]u8 = undefined;
    const branch = getGitBranch(io, &buf, base);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("main", branch.?);
}

test "getGitBranch walks up to parent" {
    const io = std.testing.io;
    const base = "/tmp/cc-test-gitbranch-walk";
    const git_dir = base ++ "/.git";
    const head_path = git_dir ++ "/HEAD";
    const sub_dir = base ++ "/sub";
    const sub_sub = base ++ "/sub/dir";
    Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    Io.Dir.createDirAbsolute(io, git_dir, .default_dir) catch {};
    Io.Dir.createDirAbsolute(io, sub_dir, .default_dir) catch {};
    Io.Dir.createDirAbsolute(io, sub_sub, .default_dir) catch {};
    defer {
        Io.Dir.deleteFileAbsolute(io, head_path) catch {};
        Io.Dir.deleteDirAbsolute(io, git_dir) catch {};
        Io.Dir.deleteDirAbsolute(io, sub_sub) catch {};
        Io.Dir.deleteDirAbsolute(io, sub_dir) catch {};
        Io.Dir.deleteDirAbsolute(io, base) catch {};
    }
    {
        var f = try Io.Dir.createFileAbsolute(io, head_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "ref: refs/heads/feature-x\n");
    }
    var buf: [256]u8 = undefined;
    const branch = getGitBranch(io, &buf, sub_sub);
    try std.testing.expect(branch != null);
    try std.testing.expectEqualStrings("feature-x", branch.?);
}

test "getGitBranch returns null when no .git/HEAD" {
    const io = std.testing.io;
    const base = "/tmp/cc-test-gitbranch-empty";
    Io.Dir.createDirAbsolute(io, base, .default_dir) catch {};
    defer Io.Dir.deleteDirAbsolute(io, base) catch {};
    var buf: [256]u8 = undefined;
    // /tmp has no .git/HEAD, neither does /
    try std.testing.expectEqual(@as(?[]const u8, null), getGitBranch(io, &buf, base));
}

test {
    _ = output;
    _ = scan;
    _ = time;
    _ = @import("pricing.zig");
}
