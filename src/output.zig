const std = @import("std");
const mem = std.mem;
const Writer = std.Io.Writer;
const types = @import("types.zig");
const time = @import("time.zig");

const RateLimitWindow = types.RateLimitWindow;
const BlockInfo = types.BlockInfo;
const ScanResult = types.ScanResult;
const StdinInfo = types.StdinInfo;
const ms_per_min = types.ms_per_min;

// ============================================================
// Constants
// ============================================================

pub const bar_width: u8 = 10;
pub const default_branch_max: usize = 24;

/// Upper bound enforced by `parseBranchMax` so `truncateBranch` can always
/// append its 3-byte ellipsis without overflowing its output buffer.
pub const branch_max_upper: usize = 254;

/// Buffer size for progress bars. `bar_width` (10 codepoints) × an extended
/// grapheme cluster of up to ~25 bytes keeps output inside a single memcpy.
const progress_bar_buf_size: usize = 256;

// ============================================================
// Theme
// ============================================================

pub const Theme = struct {
    model: []const u8,
    agent: []const u8,
    green: []const u8,
    yellow: []const u8,
    red: []const u8,
    dim: []const u8,
    reset: []const u8 = "\x1b[0m",
    bar_filled: []const u8 = "\xe2\x96\x88", // █ U+2588
    bar_transition: []const u8 = "\xe2\x96\x93", // ▓ U+2593
    bar_empty: []const u8 = "\xe2\x96\x91", // ░ U+2591
    branch_max: usize = default_branch_max,
};

pub const theme_default = Theme{
    .model = "\x1b[36m",
    .agent = "\x1b[35m",
    .green = "\x1b[32m",
    .yellow = "\x1b[33m",
    .red = "\x1b[31m",
    .dim = "\x1b[2m",
};

pub const theme_catppuccin_mocha = Theme{
    .model = "\x1b[38;2;137;180;250m", // Blue (#89b4fa)
    .agent = "\x1b[38;2;203;166;247m", // Mauve (#cba6f7)
    .green = "\x1b[38;2;166;227;161m", // Green (#a6e3a1)
    .yellow = "\x1b[38;2;249;226;175m", // Yellow (#f9e2af)
    .red = "\x1b[38;2;243;139;168m", // Red (#f38ba8)
    .dim = "\x1b[38;2;108;112;134m", // Overlay0 (#6c7086)
};

pub const theme_catppuccin_latte = Theme{
    .model = "\x1b[38;2;30;102;245m",
    .agent = "\x1b[38;2;136;57;239m", // Mauve (#8839ef)
    .green = "\x1b[38;2;64;160;43m",
    .yellow = "\x1b[38;2;223;142;29m",
    .red = "\x1b[38;2;210;15;57m",
    .dim = "\x1b[38;2;156;160;176m",
};

pub const theme_catppuccin_frappe = Theme{
    .model = "\x1b[38;2;140;170;238m",
    .agent = "\x1b[38;2;202;158;230m", // Mauve (#ca9ee6)
    .green = "\x1b[38;2;166;209;137m",
    .yellow = "\x1b[38;2;229;200;144m",
    .red = "\x1b[38;2;231;130;132m",
    .dim = "\x1b[38;2;115;121;148m",
};

pub const theme_catppuccin_macchiato = Theme{
    .model = "\x1b[38;2;138;173;244m",
    .agent = "\x1b[38;2;198;160;246m", // Mauve (#c6a0f6)
    .green = "\x1b[38;2;166;218;149m",
    .yellow = "\x1b[38;2;238;212;159m",
    .red = "\x1b[38;2;237;135;150m",
    .dim = "\x1b[38;2;110;115;141m",
};

pub const ThemeOverrides = struct {
    model: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    green: ?[]const u8 = null,
    yellow: ?[]const u8 = null,
    red: ?[]const u8 = null,
    dim: ?[]const u8 = null,
    bar_filled: ?[]const u8 = null,
    bar_transition: ?[]const u8 = null,
    bar_empty: ?[]const u8 = null,
    branch_max: ?[]const u8 = null,
};

pub fn buildTheme(theme_name: ?[]const u8, overrides: ThemeOverrides) Theme {
    var theme = if (theme_name) |name| blk: {
        if (mem.eql(u8, name, "catppuccin-mocha")) break :blk theme_catppuccin_mocha;
        if (mem.eql(u8, name, "catppuccin-latte")) break :blk theme_catppuccin_latte;
        if (mem.eql(u8, name, "catppuccin-frappe")) break :blk theme_catppuccin_frappe;
        if (mem.eql(u8, name, "catppuccin-macchiato")) break :blk theme_catppuccin_macchiato;
        break :blk theme_default;
    } else theme_default;

    if (overrides.model) |v| theme.model = v;
    if (overrides.agent) |v| theme.agent = v;
    if (overrides.green) |v| theme.green = v;
    if (overrides.yellow) |v| theme.yellow = v;
    if (overrides.red) |v| theme.red = v;
    if (overrides.dim) |v| theme.dim = v;
    if (overrides.bar_filled) |v| theme.bar_filled = v;
    if (overrides.bar_transition) |v| theme.bar_transition = v;
    if (overrides.bar_empty) |v| theme.bar_empty = v;
    theme.branch_max = parseBranchMax(overrides.branch_max);

    return theme;
}

pub fn initTheme(env: *const std.process.Environ.Map) Theme {
    return buildTheme(
        env.get("CC_STATUSLINE_THEME"),
        .{
            .model = env.get("CC_STATUSLINE_COLOR_MODEL"),
            .agent = env.get("CC_STATUSLINE_COLOR_AGENT"),
            .green = env.get("CC_STATUSLINE_COLOR_GREEN"),
            .yellow = env.get("CC_STATUSLINE_COLOR_YELLOW"),
            .red = env.get("CC_STATUSLINE_COLOR_RED"),
            .dim = env.get("CC_STATUSLINE_COLOR_DIM"),
            .bar_filled = env.get("CC_STATUSLINE_BAR_FILLED"),
            .bar_transition = env.get("CC_STATUSLINE_BAR_TRANSITION"),
            .bar_empty = env.get("CC_STATUSLINE_BAR_EMPTY"),
            .branch_max = env.get("CC_STATUSLINE_BRANCH_MAX"),
        },
    );
}

// (Types moved to types.zig)

// ============================================================
// Formatting Functions
// ============================================================

pub fn formatCurrency(buf: []u8, value: f64) []const u8 {
    if (value < 0) return "$0.00";
    if (value > 0 and value < 0.01) {
        return std.fmt.bufPrint(buf, "${d:.4}", .{value}) catch "$?.??";
    }
    return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "$?.??";
}

fn thresholdColor(theme: Theme, value: f64, yellow: f64, red: f64) []const u8 {
    if (value < yellow) return theme.green;
    if (value < red) return theme.yellow;
    return theme.red;
}

pub fn contextColor(theme: Theme, pct: f64) []const u8 {
    return thresholdColor(theme, pct, 50.0, 75.0);
}

pub fn rateLimitUsageColor(theme: Theme, used_pct: f64) []const u8 {
    return thresholdColor(theme, used_pct, 50.0, 80.0);
}

pub fn rateLimitTimeColor(theme: Theme, remaining_ms: i64) []const u8 {
    if (remaining_ms < 30 * 60 * 1000) return theme.red;
    if (remaining_ms < 60 * 60 * 1000) return theme.yellow;
    return theme.green;
}

pub fn buildProgressBar(buf: []u8, pct: f64, width: u8, bar_filled: []const u8, bar_transition: []const u8, bar_empty: []const u8) []const u8 {
    const clamped = @max(@as(f64, 0), @min(@as(f64, 100), pct));
    const width_f: f64 = @floatFromInt(width);
    const filled_f = clamped * width_f / 100.0;
    const filled: u8 = @intCast(@min(@as(u64, @intFromFloat(filled_f)), @as(u64, width)));
    const frac = filled_f - @as(f64, @floatFromInt(filled));
    const has_transition = frac > 0 and filled < width;
    const empty = width - filled - if (has_transition) @as(u8, 1) else @as(u8, 0);
    var pos: usize = 0;
    for (0..filled) |_| {
        if (pos + bar_filled.len > buf.len) break;
        @memcpy(buf[pos..][0..bar_filled.len], bar_filled);
        pos += bar_filled.len;
    }
    if (has_transition) {
        if (pos + bar_transition.len <= buf.len) {
            @memcpy(buf[pos..][0..bar_transition.len], bar_transition);
            pos += bar_transition.len;
        }
    }
    for (0..empty) |_| {
        if (pos + bar_empty.len > buf.len) break;
        @memcpy(buf[pos..][0..bar_empty.len], bar_empty);
        pos += bar_empty.len;
    }
    return buf[0..pos];
}

pub fn formatResetDuration(buf: []u8, remaining_ms: i64) []const u8 {
    if (remaining_ms <= 0) return "now";
    const total_min = @divFloor(remaining_ms, @as(i64, ms_per_min));
    const total_hours = @divFloor(total_min, @as(i64, 60));
    const mins = total_min - total_hours * 60;
    if (total_hours >= 24) {
        const days = @divFloor(total_hours, @as(i64, 24));
        const hours = total_hours - days * 24;
        return std.fmt.bufPrint(buf, "{d}d {d}h", .{ days, hours }) catch "??";
    }
    if (total_hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ total_hours, mins }) catch "??";
    }
    return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "??";
}

pub fn truncateBranch(buf: *[256]u8, branch: []const u8, max_len: usize) []const u8 {
    if (max_len < 4 or branch.len <= max_len) return branch;
    var cut = max_len - 1;
    // Avoid cutting in the middle of a multi-byte UTF-8 sequence
    while (cut > 0 and (branch[cut] & 0xC0) == 0x80) {
        cut -= 1;
    }
    @memcpy(buf[0..cut], branch[0..cut]);
    @memcpy(buf[cut..][0..3], "\xe2\x80\xa6"); // U+2026 …
    return buf[0 .. cut + 3];
}

pub fn parseBranchMax(val: ?[]const u8) usize {
    const s = val orelse return default_branch_max;
    const v = std.fmt.parseInt(i64, s, 10) catch return default_branch_max;
    if (v < 4) return default_branch_max;
    return @intCast(@min(v, @as(i64, branch_max_upper)));
}

// ============================================================
// Output
// ============================================================

fn writeRateLimitWindow(w: *Writer, theme: Theme, label: []const u8, rl: RateLimitWindow, now_ms: i64, utc_offset_s: i32) !void {
    const usage_color = rateLimitUsageColor(theme, rl.used_percentage);
    var bar_buf: [progress_bar_buf_size]u8 = undefined;
    const bar = buildProgressBar(&bar_buf, rl.used_percentage, bar_width, theme.bar_filled, theme.bar_transition, theme.bar_empty);
    try w.print("{s}{s}{s} {s}{s}{s} {s}{d:.0}%{s}", .{
        theme.dim,   label,
        theme.reset, usage_color,
        bar,         theme.reset,
        usage_color, rl.used_percentage,
        theme.reset,
    });
    if (rl.resets_at_ms) |reset_ms| {
        const remaining = reset_ms - now_ms;
        const time_color = rateLimitTimeColor(theme, remaining);
        var reset_buf: [64]u8 = undefined;
        try w.print(" {s}{s}{s}", .{ time_color, formatResetDuration(&reset_buf, remaining), theme.reset });
        var dt_buf: [16]u8 = undefined;
        try w.print(" {s}{s}{s}", .{ theme.dim, time.formatLocalDateTime(&dt_buf, reset_ms, utc_offset_s), theme.reset });
    }
}

pub fn printOutput(w: *Writer, theme: Theme, stdin_info: StdinInfo, scan: ?ScanResult, now_ms: i64, utc_offset_s: i32, git_branch: ?[]const u8) !void {
    // === Line 1: Model + Agent + Branch + Context ===
    const model_name = stdin_info.model_name orelse "Unknown";
    try w.print("\xf0\x9f\xa4\x96 {s}{s}{s}", .{ theme.model, model_name, theme.reset });

    // Subagent indicator
    if (stdin_info.agent_name) |name| {
        // 🧩 U+1F9E9
        try w.print(" {s}|{s} \xf0\x9f\xa7\xa9 {s}{s}{s}", .{ theme.dim, theme.reset, theme.agent, name, theme.reset });
    }

    // Git branch
    if (git_branch) |branch| {
        var trunc_buf: [256]u8 = undefined;
        const display_branch = truncateBranch(&trunc_buf, branch, theme.branch_max);
        try w.print(" {s}|{s} \xf0\x9f\x8c\xbf {s}{s}{s}", .{ theme.dim, theme.reset, theme.green, display_branch, theme.reset });
    }

    // Context
    if (stdin_info.context_pct) |pct| {
        const color = contextColor(theme, pct);
        var bar_buf: [progress_bar_buf_size]u8 = undefined;
        const bar = buildProgressBar(&bar_buf, pct, bar_width, theme.bar_filled, theme.bar_transition, theme.bar_empty);
        try w.print(" {s}|{s} \xf0\x9f\xa7\xa0 {s}{s}{s} {s}{d:.0}%{s}", .{ theme.dim, theme.reset, color, bar, theme.reset, color, pct, theme.reset });
    } else {
        try w.print(" {s}|{s} \xf0\x9f\xa7\xa0 N/A", .{ theme.dim, theme.reset });
    }

    // 200K+ pricing tier marker
    if (stdin_info.exceeds_200k_tokens) {
        try w.writeAll(" \xf0\x9f\x9a\xa8"); // 🚨 U+1F6A8
    }

    try w.writeAll("\n");

    // === Line 2: Cost + Block ===
    if (scan) |s| {
        var today_buf: [32]u8 = undefined;
        try w.print("\xf0\x9f\x92\xb0 {s}{s}{s} today", .{ theme.yellow, formatCurrency(&today_buf, s.today_cost), theme.reset });
        if (s.block) |block| {
            var block_buf: [32]u8 = undefined;
            try w.print(" {s}|{s} \xf0\x9f\x93\x8a {s}{s}{s} block", .{
                theme.dim,
                theme.reset,
                theme.yellow,
                formatCurrency(&block_buf, block.cost),
                theme.reset,
            });
            var rate_buf: [32]u8 = undefined;
            try w.print(" \xf0\x9f\x94\xa5 {s}{s}{s} {s}/h{s}", .{ theme.yellow, formatCurrency(&rate_buf, block.burn_rate_per_hr), theme.reset, theme.dim, theme.reset });
        }
    } else {
        try w.writeAll("\xf0\x9f\x92\xb0 N/A today");
    }

    try w.writeAll("\n");

    // === Line 3: Rate Limits (5h + 7d) ===
    const has_rate_limits = stdin_info.rate_limit_5h != null or stdin_info.rate_limit_7d != null;
    if (has_rate_limits) {
        // 🕔 5h ████████░░ 42% 2h 30m | 📅 7d ██████████ 86% 3d 12h
        try w.print("\xf0\x9f\x95\x94 ", .{}); // 🕔

        if (stdin_info.rate_limit_5h) |rl5| {
            try writeRateLimitWindow(w, theme, "5h", rl5, now_ms, utc_offset_s);
        }

        if (stdin_info.rate_limit_5h != null and stdin_info.rate_limit_7d != null) {
            try w.print(" {s}|{s} ", .{ theme.dim, theme.reset });
        }

        if (stdin_info.rate_limit_7d) |rl7| {
            try w.print("\xf0\x9f\x93\x85 ", .{}); // 📅
            try writeRateLimitWindow(w, theme, "7d", rl7, now_ms, utc_offset_s);
        }

        try w.writeAll("\n");
    }
}

pub fn printFallback(w: *Writer) void {
    w.writeAll("\xf0\x9f\xa4\x96 Unknown | \xf0\x9f\xa7\xa0 N/A\n\xf0\x9f\x92\xb0 N/A today\n") catch {};
}

// ============================================================
// Tests
// ============================================================

fn contains(haystack: []const u8, needle: []const u8) bool {
    return mem.indexOf(u8, haystack, needle) != null;
}

fn countNewlines(data: []const u8) usize {
    var count: usize = 0;
    for (data) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

// --- formatCurrency ---

test "formatCurrency zero" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.00", formatCurrency(&buf, 0.0));
}

test "formatCurrency sub-cent" {
    var buf: [32]u8 = undefined;
    const result = formatCurrency(&buf, 0.005);
    try std.testing.expect(contains(result, "$0.005"));
}

test "formatCurrency normal" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$1.23", formatCurrency(&buf, 1.23));
}

test "formatCurrency negative" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.00", formatCurrency(&buf, -1.0));
}

// --- contextColor ---

test "contextColor thresholds" {
    const theme = theme_default;
    try std.testing.expectEqualStrings(theme.green, contextColor(theme, 0.0));
    try std.testing.expectEqualStrings(theme.green, contextColor(theme, 49.9));
    try std.testing.expectEqualStrings(theme.yellow, contextColor(theme, 50.0));
    try std.testing.expectEqualStrings(theme.yellow, contextColor(theme, 74.9));
    try std.testing.expectEqualStrings(theme.red, contextColor(theme, 75.0));
    try std.testing.expectEqualStrings(theme.red, contextColor(theme, 100.0));
}

// --- rateLimitUsageColor ---

test "rateLimitUsageColor thresholds" {
    const theme = theme_default;
    try std.testing.expectEqualStrings(theme.green, rateLimitUsageColor(theme, 0.0));
    try std.testing.expectEqualStrings(theme.green, rateLimitUsageColor(theme, 49.9));
    try std.testing.expectEqualStrings(theme.yellow, rateLimitUsageColor(theme, 50.0));
    try std.testing.expectEqualStrings(theme.yellow, rateLimitUsageColor(theme, 79.9));
    try std.testing.expectEqualStrings(theme.red, rateLimitUsageColor(theme, 80.0));
    try std.testing.expectEqualStrings(theme.red, rateLimitUsageColor(theme, 100.0));
}

// --- rateLimitTimeColor ---

test "rateLimitTimeColor thresholds" {
    const theme = theme_default;
    try std.testing.expectEqualStrings(theme.red, rateLimitTimeColor(theme, 0));
    try std.testing.expectEqualStrings(theme.red, rateLimitTimeColor(theme, 29 * 60 * 1000));
    try std.testing.expectEqualStrings(theme.yellow, rateLimitTimeColor(theme, 30 * 60 * 1000));
    try std.testing.expectEqualStrings(theme.yellow, rateLimitTimeColor(theme, 59 * 60 * 1000));
    try std.testing.expectEqualStrings(theme.green, rateLimitTimeColor(theme, 60 * 60 * 1000));
    try std.testing.expectEqualStrings(theme.green, rateLimitTimeColor(theme, 3 * 3600 * 1000));
}

// --- buildProgressBar ---

test "buildProgressBar default UTF-8 chars" {
    var buf: [128]u8 = undefined;
    const bar = buildProgressBar(&buf, 50.0, 10, "\xe2\x96\x88", "\xe2\x96\x93", "\xe2\x96\x91");
    try std.testing.expectEqual(@as(usize, 30), bar.len);
    try std.testing.expectEqualStrings("\xe2\x96\x88", bar[0..3]);
    try std.testing.expectEqualStrings("\xe2\x96\x91", bar[27..30]);
}

test "buildProgressBar single-byte chars" {
    var buf: [128]u8 = undefined;
    const bar = buildProgressBar(&buf, 75.0, 8, "#", "=", "-");
    try std.testing.expectEqual(@as(usize, 8), bar.len);
    try std.testing.expectEqualStrings("######--", bar);
}

test "buildProgressBar transition char" {
    var buf: [128]u8 = undefined;
    const bar1 = buildProgressBar(&buf, 37.5, 8, "#", "=", "-");
    try std.testing.expectEqualStrings("###-----", bar1);

    const bar2 = buildProgressBar(&buf, 40.0, 8, "#", "=", "-");
    try std.testing.expectEqualStrings("###=----", bar2);
}

test "buildProgressBar 0% and 100%" {
    var buf: [128]u8 = undefined;
    const empty = buildProgressBar(&buf, 0.0, 4, "#", "=", "-");
    try std.testing.expectEqualStrings("----", empty);

    const full = buildProgressBar(&buf, 100.0, 4, "#", "=", "-");
    try std.testing.expectEqualStrings("####", full);
}

// --- formatResetDuration ---

test "formatResetDuration" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("now", formatResetDuration(&buf, 0));
    try std.testing.expectEqualStrings("now", formatResetDuration(&buf, -1000));
    try std.testing.expectEqualStrings("30m", formatResetDuration(&buf, 30 * 60 * 1000));
    try std.testing.expectEqualStrings("2h 15m", formatResetDuration(&buf, (2 * 60 + 15) * 60 * 1000));

    const three_days_4h = (3 * 24 + 4) * 3600 * 1000;
    try std.testing.expectEqualStrings("3d 4h", formatResetDuration(&buf, three_days_4h));
}

// --- truncateBranch ---

test "truncateBranch short branch unchanged" {
    var buf: [256]u8 = undefined;
    const result = truncateBranch(&buf, "main", 24);
    try std.testing.expectEqualStrings("main", result);
}

test "truncateBranch exact max unchanged" {
    var buf: [256]u8 = undefined;
    const branch = "feature/exactly-twentyfo";
    try std.testing.expectEqual(@as(usize, 24), branch.len);
    const result = truncateBranch(&buf, branch, 24);
    try std.testing.expectEqualStrings(branch, result);
}

test "truncateBranch long branch truncated" {
    var buf: [256]u8 = undefined;
    const result = truncateBranch(&buf, "feature/very-long-branch-name-that-overflows", 24);
    try std.testing.expectEqual(@as(usize, 26), result.len);
    try std.testing.expectEqualStrings("feature/very-long-branc\xe2\x80\xa6", result);
}

test "truncateBranch min max_len" {
    var buf: [256]u8 = undefined;
    const result = truncateBranch(&buf, "feature/something", 3);
    try std.testing.expectEqualStrings("feature/something", result);
}

test "truncateBranch UTF-8 boundary" {
    var buf: [256]u8 = undefined;
    // "ab" + 日 (3 bytes: \xe6\x97\xa5) + "cd" = 7 bytes
    // max_len=4: cut=3 lands inside 日, should walk back to byte 2
    const result = truncateBranch(&buf, "ab\xe6\x97\xa5cd", 4);
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("ab\xe2\x80\xa6", result);
}

test "truncateBranch at branch_max_upper does not overflow buf" {
    var buf: [256]u8 = undefined;
    var branch: [300]u8 = undefined;
    for (&branch) |*b| b.* = 'a';
    const result = truncateBranch(&buf, &branch, branch_max_upper);
    try std.testing.expectEqual(@as(usize, branch_max_upper + 2), result.len);
    try std.testing.expectEqualStrings("\xe2\x80\xa6", result[result.len - 3 ..]);
}

// --- printOutput: Line 1 ---

test "printOutput line1 model name" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Opus 4.6" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "Opus 4.6"));
}

test "printOutput line1 model unknown" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{};
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "Unknown"));
}

test "printOutput line1 context percentage with color" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_pct = 80.0 };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "80%"));
    try std.testing.expect(contains(out, theme_default.red));
}

test "printOutput line1 context NA" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{};
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "N/A"));
}

test "printOutput line1 git branch" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{};
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, "main");
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "main"));
    try std.testing.expect(contains(out, "\xf0\x9f\x8c\xbf")); // 🌿
}

test "printOutput line1 agent name with puzzle emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Opus 4.6", .agent_name = "security-reviewer" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "\xf0\x9f\xa7\xa9")); // 🧩
    try std.testing.expect(contains(out, "security-reviewer"));
    // Agent name uses theme.agent color
    try std.testing.expect(contains(out, theme_default.agent ++ "security-reviewer"));
}

test "printOutput line1 no agent name does not emit puzzle emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Opus 4.6" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(!contains(out, "\xf0\x9f\xa7\xa9")); // 🧩
}

test "printOutput line1 exceeds_200k_tokens shows alarm emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_pct = 50.0, .exceeds_200k_tokens = true };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "\xf0\x9f\x9a\xa8")); // 🚨
}

test "printOutput line1 exceeds_200k_tokens false omits alarm emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_pct = 50.0, .exceeds_200k_tokens = false };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(!contains(aw.writer.buffered(), "\xf0\x9f\x9a\xa8")); // 🚨
}

// --- printOutput: Line 2 ---

test "printOutput line2 today cost" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const scan = ScanResult{ .today_cost = 1.50 };
    try printOutput(&aw.writer, theme_default, StdinInfo{}, scan, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "$1.50"));
    try std.testing.expect(contains(out, "today"));
}

test "printOutput line2 block cost and burn rate" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const scan = ScanResult{
        .today_cost = 0.50,
        .block = .{
            .start_ms = 0,
            .end_ms = 5 * 3600 * 1000,
            .cost = 2.00,
            .burn_rate_per_hr = 0.80,
        },
    };
    try printOutput(&aw.writer, theme_default, StdinInfo{}, scan, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "$2.00"));
    try std.testing.expect(contains(out, "block"));
    try std.testing.expect(contains(out, "\xf0\x9f\x93\x8a")); // 📊
    try std.testing.expect(contains(out, "$0.80"));
    try std.testing.expect(contains(out, "/h"));
    try std.testing.expect(contains(out, "\xf0\x9f\x94\xa5")); // 🔥
}

test "printOutput line2 scan null" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printOutput(&aw.writer, theme_default, StdinInfo{}, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "N/A today"));
}

// --- printOutput: Line 3 ---

test "printOutput line3 5h rate limit" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 42.0 },
    };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "\xf0\x9f\x95\x94")); // 🕔
    try std.testing.expect(contains(out, "5h"));
    try std.testing.expect(contains(out, "42%"));
    try std.testing.expect(contains(out, theme_default.green)); // 42% < 50% = green
}

test "printOutput line3 7d rate limit" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .rate_limit_7d = .{ .used_percentage = 86.0 },
    };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "\xf0\x9f\x93\x85")); // 📅
    try std.testing.expect(contains(out, "7d"));
    try std.testing.expect(contains(out, "86%"));
    try std.testing.expect(contains(out, theme_default.red)); // 86% >= 80% = red
}

test "printOutput line3 75pct uses yellow not red" {
    // 75-79% was red under contextColor but is yellow under rateLimitUsageColor
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 75.0 },
    };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, theme.yellow ++ "75%"));
    try std.testing.expect(!contains(out, theme.red ++ "75%"));
}

test "printOutput line3 both rate limits with separator" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 30.0 },
        .rate_limit_7d = .{ .used_percentage = 60.0 },
    };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "5h"));
    try std.testing.expect(contains(out, "7d"));
    // 3 newlines: line1 + line2 + line3
    try std.testing.expectEqual(@as(usize, 3), countNewlines(out));
}

test "printOutput line3 rate limit reset time" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const now_ms: i64 = 1000 * 1000;
    const info = StdinInfo{
        .rate_limit_5h = .{
            .used_percentage = 50.0,
            .resets_at_ms = now_ms + 2 * 3600 * 1000 + 30 * 60 * 1000, // +2h 30m
        },
    };
    try printOutput(&aw.writer, theme_default, info, null, now_ms, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "2h 30m"));
}

test "printOutput line3 absolute reset datetime in dim" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    // 2026-03-20 12:00:00 UTC
    const now_ms: i64 = (time.daysFromCivil(2026, 3, 20) * 86400 + 12 * 3600) * 1000;
    const reset_ms = now_ms + 3 * 3600 * 1000; // +3h → 15:00 UTC
    const info = StdinInfo{
        .rate_limit_5h = .{
            .used_percentage = 50.0,
            .resets_at_ms = reset_ms,
        },
    };
    // UTC (offset 0): expect "03/20 15:00"
    try printOutput(&aw.writer, theme, info, null, now_ms, 0, null);
    const out_utc = aw.writer.buffered();
    try std.testing.expect(contains(out_utc, theme.dim ++ "03/20 15:00"));

    // JST (+9h): 15:00 UTC → 24:00 = next day 00:00 → "03/21 00:00"
    aw.deinit();
    aw = .init(std.testing.allocator);
    try printOutput(&aw.writer, theme, info, null, now_ms, 32400, null);
    const out_jst = aw.writer.buffered();
    try std.testing.expect(contains(out_jst, theme.dim ++ "03/21 00:00"));
}

test "printOutput line3 5h usage and time colored independently" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const now_ms: i64 = 1000 * 1000;
    const info = StdinInfo{
        .rate_limit_5h = .{
            .used_percentage = 30.0, // usage → green
            .resets_at_ms = now_ms + 15 * 60 * 1000, // 15m < 30m → time red
        },
    };
    try printOutput(&aw.writer, theme, info, null, now_ms, 0, null);
    const out = aw.writer.buffered();
    // Usage (bar + percentage) should be green
    try std.testing.expect(contains(out, theme.green ++ "30%"));
    // Remaining time should be red (independent of usage)
    try std.testing.expect(contains(out, theme.red ++ "15m"));
}

test "printOutput line3 5h short remaining yellow, usage green" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const now_ms: i64 = 1000 * 1000;
    const info = StdinInfo{
        .rate_limit_5h = .{
            .used_percentage = 20.0, // usage → green
            .resets_at_ms = now_ms + 50 * 60 * 1000, // 50m → time yellow
        },
    };
    try printOutput(&aw.writer, theme, info, null, now_ms, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, theme.green ++ "20%"));
    try std.testing.expect(contains(out, theme.yellow ++ "50m"));
}

test "printOutput line3 7d time colored independently" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const now_ms: i64 = 1000 * 1000;
    const info = StdinInfo{
        .rate_limit_7d = .{
            .used_percentage = 60.0, // usage → yellow
            .resets_at_ms = now_ms + 3 * 24 * 3600 * 1000 + 4 * 3600 * 1000, // +3d 4h → time green
        },
    };
    try printOutput(&aw.writer, theme, info, null, now_ms, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, theme.yellow ++ "60%"));
    try std.testing.expect(contains(out, theme.green ++ "3d 4h"));
}

test "printOutput line3 regression: low usage with short remaining must not color bar red" {
    // Bug: usage 29% + remaining 11m was displayed entirely in red
    // because a single combined color was derived from both usage and time.
    // Fix: usage and time are colored independently.
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const now_ms: i64 = 1000 * 1000;
    const info = StdinInfo{
        .rate_limit_5h = .{
            .used_percentage = 29.0,
            .resets_at_ms = now_ms + 11 * 60 * 1000, // +11m
        },
    };
    try printOutput(&aw.writer, theme, info, null, now_ms, 0, null);
    const out = aw.writer.buffered();
    // Usage 29% must be green, NOT red
    try std.testing.expect(contains(out, theme.green ++ "29%"));
    try std.testing.expect(!contains(out, theme.red ++ "29%"));
    // Remaining 11m must be red
    try std.testing.expect(contains(out, theme.red ++ "11m"));
}

test "printOutput no line3 without rate limits" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printOutput(&aw.writer, theme_default, StdinInfo{}, null, 0, 0, null);
    // Only 2 newlines (line1 + line2), no line3
    try std.testing.expectEqual(@as(usize, 2), countNewlines(aw.writer.buffered()));
}

test "printOutput rate limit usage colors" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 60.0 }, // 50-79 = yellow
        .rate_limit_7d = .{ .used_percentage = 90.0 }, // >=80 = red
    };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, theme.yellow ++ "60%"));
    try std.testing.expect(contains(out, theme.red ++ "90%"));
}

// --- printFallback ---

test "printFallback output" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    printFallback(&aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "Unknown"));
    try std.testing.expect(contains(out, "N/A"));
    try std.testing.expect(contains(out, "N/A today"));
    try std.testing.expectEqual(@as(usize, 2), countNewlines(out));
}

// --- buildTheme ---

test "buildTheme default" {
    const theme = buildTheme(null, .{});
    try std.testing.expectEqualStrings(theme_default.model, theme.model);
    try std.testing.expectEqualStrings(theme_default.green, theme.green);
    try std.testing.expectEqual(default_branch_max, theme.branch_max);
}

test "buildTheme catppuccin-mocha" {
    const theme = buildTheme("catppuccin-mocha", .{});
    try std.testing.expectEqualStrings(theme_catppuccin_mocha.model, theme.model);
    try std.testing.expectEqualStrings(theme_catppuccin_mocha.red, theme.red);
}

test "buildTheme unknown falls back to default" {
    const theme = buildTheme("nonexistent-theme", .{});
    try std.testing.expectEqualStrings(theme_default.model, theme.model);
}

test "buildTheme with overrides" {
    const custom = "\x1b[35m";
    const theme = buildTheme(null, .{ .model = custom });
    try std.testing.expectEqualStrings(custom, theme.model);
    // Other fields remain default
    try std.testing.expectEqualStrings(theme_default.green, theme.green);
}

test "buildTheme with branch_max" {
    const theme = buildTheme(null, .{ .branch_max = "30" });
    try std.testing.expectEqual(@as(usize, 30), theme.branch_max);
}

// --- parseBranchMax ---

test "parseBranchMax" {
    try std.testing.expectEqual(default_branch_max, parseBranchMax(null));
    try std.testing.expectEqual(@as(usize, 30), parseBranchMax("30"));
    try std.testing.expectEqual(@as(usize, 4), parseBranchMax("4"));
    try std.testing.expectEqual(default_branch_max, parseBranchMax("3"));
    try std.testing.expectEqual(default_branch_max, parseBranchMax("abc"));
    try std.testing.expectEqual(default_branch_max, parseBranchMax(""));
    try std.testing.expectEqual(branch_max_upper, parseBranchMax("254"));
    try std.testing.expectEqual(branch_max_upper, parseBranchMax("255"));
    try std.testing.expectEqual(branch_max_upper, parseBranchMax("10000"));
}

// --- formatResetDuration (edge cases) ---

test "formatResetDuration sub-minute" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0m", formatResetDuration(&buf, 30000)); // 30s
    try std.testing.expectEqualStrings("0m", formatResetDuration(&buf, 59999)); // 59.999s
    try std.testing.expectEqualStrings("1m", formatResetDuration(&buf, 60000)); // exactly 1min
}

// --- formatCurrency edge cases ---

test "formatCurrency exactly 0.01 boundary" {
    var buf: [32]u8 = undefined;
    const result = formatCurrency(&buf, 0.01);
    try std.testing.expectEqualStrings("$0.01", result);
}

test "formatCurrency large value" {
    var buf: [32]u8 = undefined;
    const result = formatCurrency(&buf, 99999.99);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[0] == '$');
}

// --- buildProgressBar edge cases ---

test "buildProgressBar over 100 percent clamped" {
    var buf1: [256]u8 = undefined;
    const over = buildProgressBar(&buf1, 150.0, 10, "#", "=", "-");
    var buf2: [256]u8 = undefined;
    const full = buildProgressBar(&buf2, 100.0, 10, "#", "=", "-");
    try std.testing.expectEqualStrings(full, over);
}

test "buildProgressBar width 1" {
    var buf: [256]u8 = undefined;
    const result = buildProgressBar(&buf, 50.0, 1, "#", "=", "-");
    try std.testing.expect(result.len > 0);
}
