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

pub const default_bar_width: u8 = 10;
pub const default_branch_max: usize = 24;

/// Upper bound enforced by `parseBranchMax` so `truncateBranch` can always
/// append its 3-byte ellipsis without overflowing its output buffer.
pub const branch_max_upper: usize = 254;

/// Buffer size for progress bars. `default_bar_width` (10 codepoints) × an extended
/// grapheme cluster of up to ~25 bytes keeps output inside a single memcpy.
const progress_bar_buf_size: usize = 256;

// ============================================================
// Theme
// ============================================================

/// How much reset-time information is shown after each rate-limit percentage,
/// chosen by `layoutForColumns` once the bar can no longer shrink further.
pub const ResetInfo = enum {
    /// duration ("3d 12h") + datetime ("MM/DD HH:MM").
    full,
    /// duration only — datetime is the first thing dropped because it is
    /// derivable from `now + duration`.
    duration_only,
    /// no reset info at all — the narrowest layout.
    none,
};

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
    /// Progress bar width in codepoints, sized to the terminal via `COLUMNS`.
    /// `0` hides the bar entirely.
    bar_width: u8 = default_bar_width,
    /// How much rate-limit reset info to render (also sized from `COLUMNS`).
    reset_info: ResetInfo = .full,
    /// Terminal width from `COLUMNS`; `planLine1` fits line 1 into it.
    /// `null` (absent or unparseable) leaves line 1 unconstrained.
    cols: ?u16 = null,
    /// Render the session name segment on line 1. `initTheme` enables it only
    /// when `CC_STATUSLINE_SHOW_SESSION=1`.
    show_session: bool = true,
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

// Effort-level colors: Claude Code's own rainbow palette (`rainbow_*` theme
// colors), so the indicator matches the official UI in every theme. Unknown
// levels fall back to `theme.dim`.
const effort_low_color = "\x1b[38;2;250;195;95m"; // rainbow_yellow (#FAC35F)
const effort_medium_color = "\x1b[38;2;145;200;130m"; // rainbow_green (#91C882)
const effort_high_color = "\x1b[38;2;130;170;220m"; // rainbow_blue (#82AADC)
const effort_xhigh_color = "\x1b[38;2;200;130;180m"; // rainbow_violet (#C882B4)
/// "max" renders as a static rainbow: one color per glyph of "⚡max".
const effort_max_colors = [4][]const u8{
    "\x1b[38;2;235;95;87m", // rainbow_red (#EB5F57)
    "\x1b[38;2;250;195;95m", // rainbow_yellow (#FAC35F)
    "\x1b[38;2;145;200;130m", // rainbow_green (#91C882)
    "\x1b[38;2;130;170;220m", // rainbow_blue (#82AADC)
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

/// Bar width plus how much reset info to render, derived together from `COLUMNS`.
/// Line 1 has uncontrolled-width parts (model and agent names), so it is not
/// budgeted here; `planLine1` measures the actual rendered width instead.
pub const Layout = struct {
    bar_width: u8,
    reset_info: ResetInfo,
};

/// Map a terminal column count to a rate-limit-line layout via fixed breakpoints.
///
/// The 5h/7d rate-limit line is the widest fully-controlled line we render.
/// Each window is `label(2) + bar(W) + "100%"(4) + duration(max
/// `max_reset_duration_cols`=7, e.g. "23h 59m") + "MM/DD HH:MM"(11)` with
/// single-space gaps; there are two of them plus the leading 🕔/📅 emoji and
/// the " | " divider. Worst-case widths:
///
///     bar present:   65 + 2 * bar_width   (line = 69..85 for W ∈ {2..10})
///     bar hidden:    63                   (drops `bar+sp` per window → -2)
///     duration only: 39                   (drops ` MM/DD HH:MM` per window → -24)
///     none:          23                   (drops ` 23h 59m` per window → -16)
///
/// Each threshold is the smallest COLUMNS at which the corresponding worst-case
/// width still fits, so the line never wraps. Below ~23 columns there is nothing
/// left to drop short of splitting into multiple lines, so the floor stops there.
pub fn layoutForColumns(cols: u16) Layout {
    if (cols >= 85) return .{ .bar_width = 10, .reset_info = .full }; // 65 + 20
    if (cols >= 81) return .{ .bar_width = 8, .reset_info = .full }; // 65 + 16
    if (cols >= 77) return .{ .bar_width = 6, .reset_info = .full }; // 65 + 12
    if (cols >= 73) return .{ .bar_width = 4, .reset_info = .full }; // 65 + 8
    if (cols >= 69) return .{ .bar_width = 2, .reset_info = .full }; // 65 + 4
    if (cols >= 63) return .{ .bar_width = 0, .reset_info = .full }; // 63
    if (cols >= 39) return .{ .bar_width = 0, .reset_info = .duration_only }; // 39
    return .{ .bar_width = 0, .reset_info = .none }; // 23
}

/// Parse the `COLUMNS` value. Absent or unparseable (older Claude Code, or a
/// non-terminal pipe) yields null.
fn parseColumns(val: ?[]const u8) ?u16 {
    const s = val orelse return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

/// Map the `COLUMNS` value to a `Layout`, falling back to the full layout
/// when unparseable.
fn parseLayout(val: ?[]const u8) Layout {
    const cols = parseColumns(val) orelse
        return .{ .bar_width = default_bar_width, .reset_info = .full };
    return layoutForColumns(cols);
}

/// Apply the `CC_STATUSLINE_BAR_WIDTH` override to the `COLUMNS`-derived bar
/// width. The override can only shrink the bar (`0` hides it) — growing past
/// the layout width would break the no-wrap budget in `layoutForColumns`.
/// Absent or unparseable values leave the layout width untouched.
fn resolveBarWidth(layout_width: u8, val: ?[]const u8) u8 {
    const s = val orelse return layout_width;
    const v = std.fmt.parseInt(u8, s, 10) catch return layout_width;
    return @min(layout_width, v);
}

pub fn initTheme(env: *const std.process.Environ.Map) Theme {
    var theme = buildTheme(
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
    const layout = parseLayout(env.get("COLUMNS"));
    theme.bar_width = resolveBarWidth(layout.bar_width, env.get("CC_STATUSLINE_BAR_WIDTH"));
    theme.reset_info = layout.reset_info;
    theme.cols = parseColumns(env.get("COLUMNS"));
    theme.show_session = if (env.get("CC_STATUSLINE_SHOW_SESSION")) |v| mem.eql(u8, v, "1") else false;
    return theme;
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

pub fn formatTokens(buf: []u8, tokens: i64) []const u8 {
    if (tokens < 1000) {
        return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
    }
    if (tokens < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d}k", .{@divFloor(tokens, 1000)}) catch "?";
    }
    if (@rem(tokens, 1_000_000) == 0) {
        return std.fmt.bufPrint(buf, "{d}M", .{@divFloor(tokens, 1_000_000)}) catch "?";
    }
    const millions = @as(f64, @floatFromInt(tokens)) / 1_000_000.0;
    return std.fmt.bufPrint(buf, "{d:.1}M", .{millions}) catch "?";
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

/// Worst-case display width of `formatResetDuration`'s output, in columns.
/// Hit by the `"{d}h {d}m"` branch when hours have two digits and minutes have
/// two digits, e.g. `"23h 59m"` (7 columns). `layoutForColumns` depends on
/// this — bump it together if the formatter is ever widened.
pub const max_reset_duration_cols: u8 = 7;

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

const LastCodepoint = struct { cp: u21, start: usize };

/// Decode the last codepoint of `s`, or null when `s` is empty or ends in a
/// malformed sequence.
fn lastCodepoint(s: []const u8) ?LastCodepoint {
    if (s.len == 0) return null;
    var start = s.len - 1;
    while (start > 0 and (s[start] & 0xC0) == 0x80) start -= 1;
    const len = std.unicode.utf8ByteSequenceLength(s[start]) catch return null;
    if (start + len != s.len) return null;
    const cp = std.unicode.utf8Decode(s[start..]) catch return null;
    return .{ .cp = cp, .start = start };
}

/// Decode the codepoint starting at byte offset `i`, or null when out of
/// bounds or malformed.
fn codepointAt(s: []const u8, i: usize) ?u21 {
    if (i >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    return std.unicode.utf8Decode(s[i..][0..len]) catch null;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn trailingRegionalIndicatorRun(s: []const u8) usize {
    var count: usize = 0;
    var end = s.len;
    while (lastCodepoint(s[0..end])) |last| {
        if (!isRegionalIndicator(last.cp)) break;
        count += 1;
        end = last.start;
    }
    return count;
}

/// Walk `cut` back to the nearest grapheme-safe boundary of `s`, so the kept
/// prefix never ends mid-cluster. The codepoint after the cut decides: a
/// zero-width mark or skin-tone modifier there means the cluster continues
/// past the cut, and a regional indicator after an odd trailing run of them
/// is half a flag. A trailing ZWJ always dangles. Complete trailing
/// sequences (é, ☀️, 1️⃣) are kept intact — this approximates UAX #29 with
/// only the cluster kinds that occur in names.
fn stripTornFragments(s: []const u8, cut: usize) usize {
    var end = cut;
    while (end > 0) {
        const last = lastCodepoint(s[0..end]) orelse break;
        if (last.cp == 0x200D) { // dangling ZWJ
            end = last.start;
            continue;
        }
        const next = codepointAt(s, end) orelse break;
        const cluster_continues = isZeroWidth(next) or
            (next >= 0x1F3FB and next <= 0x1F3FF) or // skin-tone modifier
            (isRegionalIndicator(next) and isRegionalIndicator(last.cp) and
                trailingRegionalIndicatorRun(s[0..end]) % 2 == 1);
        if (!cluster_continues) break;
        end = last.start;
    }
    return end;
}

pub fn truncateBranch(buf: *[256]u8, branch: []const u8, max_len: usize) []const u8 {
    if (max_len < 4 or branch.len <= max_len) return branch;
    var cut = max_len - 1;
    // Avoid cutting in the middle of a multi-byte UTF-8 sequence
    while (cut > 0 and (branch[cut] & 0xC0) == 0x80) {
        cut -= 1;
    }
    cut = stripTornFragments(branch, cut);
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
    if (theme.bar_width > 0) {
        var bar_buf: [progress_bar_buf_size]u8 = undefined;
        const bar = buildProgressBar(&bar_buf, rl.used_percentage, theme.bar_width, theme.bar_filled, theme.bar_transition, theme.bar_empty);
        try w.print("{s}{s}{s} {s}{s}{s} {s}{d:.0}%{s}", .{
            theme.dim,   label,
            theme.reset, usage_color,
            bar,         theme.reset,
            usage_color, rl.used_percentage,
            theme.reset,
        });
    } else {
        try w.print("{s}{s}{s} {s}{d:.0}%{s}", .{
            theme.dim,   label,              theme.reset,
            usage_color, rl.used_percentage, theme.reset,
        });
    }
    if (rl.resets_at_ms) |reset_ms| {
        if (theme.reset_info != .none) {
            const remaining = reset_ms - now_ms;
            const time_color = rateLimitTimeColor(theme, remaining);
            var reset_buf: [64]u8 = undefined;
            try w.print(" {s}{s}{s}", .{ time_color, formatResetDuration(&reset_buf, remaining), theme.reset });
            if (theme.reset_info == .full) {
                var dt_buf: [16]u8 = undefined;
                try w.print(" {s}{s}{s}", .{ theme.dim, time.formatLocalDateTime(&dt_buf, reset_ms, utc_offset_s), theme.reset });
            }
        }
    }
}

/// Line-1 rendering decisions produced by `planLine1`. Fields start at their
/// richest setting and are degraded until the rendered line fits `COLUMNS`.
const Line1Plan = struct {
    bar_width: u8,
    name_cap: usize,
    show_tokens: bool = true,
    show_effort: bool = true,
    show_branch: bool = true,
    show_session: bool = true,
};

/// Scratch size for measuring line 1: two names at `branch_max_upper` plus
/// model/agent strings, fixed segments, and ANSI color codes.
const line1_scratch_size: usize = 2048;

/// East Asian Wide/Fullwidth ranges in the BMP, inclusive, sorted. Derived
/// from Unicode EastAsianWidth.txt (W/F): the CJK blocks plus the BMP emoji
/// with default emoji presentation (⌚⏰⭐✅ …). Unassigned gaps inside the
/// consolidated CJK ranges are counted wide, which errs toward truncating
/// early rather than wrapping. Codepoints at U+1F000 and above are handled
/// directly in `isDoubleWidth`.
const wide_bmp_ranges = [_][2]u21{
    .{ 0x1100, 0x115F }, // Hangul Jamo
    .{ 0x231A, 0x231B }, // ⌚⌛
    .{ 0x2329, 0x232A }, // 〈〉
    .{ 0x23E9, 0x23EC }, // ⏩⏪⏫⏬
    .{ 0x23F0, 0x23F0 }, // ⏰
    .{ 0x23F3, 0x23F3 }, // ⏳
    .{ 0x25FD, 0x25FE }, // ◽◾
    .{ 0x2614, 0x2615 }, // ☔☕
    .{ 0x2648, 0x2653 }, // ♈..♓
    .{ 0x267F, 0x267F }, // ♿
    .{ 0x2693, 0x2693 }, // ⚓
    .{ 0x26A1, 0x26A1 }, // ⚡
    .{ 0x26AA, 0x26AB }, // ⚪⚫
    .{ 0x26BD, 0x26BE }, // ⚽⚾
    .{ 0x26C4, 0x26C5 }, // ⛄⛅
    .{ 0x26CE, 0x26CE }, // ⛎
    .{ 0x26D4, 0x26D4 }, // ⛔
    .{ 0x26EA, 0x26EA }, // ⛪
    .{ 0x26F2, 0x26F3 }, // ⛲⛳
    .{ 0x26F5, 0x26F5 }, // ⛵
    .{ 0x26FA, 0x26FA }, // ⛺
    .{ 0x26FD, 0x26FD }, // ⛽
    .{ 0x2705, 0x2705 }, // ✅
    .{ 0x270A, 0x270B }, // ✊✋
    .{ 0x2728, 0x2728 }, // ✨
    .{ 0x274C, 0x274C }, // ❌
    .{ 0x274E, 0x274E }, // ❎
    .{ 0x2753, 0x2755 }, // ❓❔❕
    .{ 0x2757, 0x2757 }, // ❗
    .{ 0x2795, 0x2797 }, // ➕➖➗
    .{ 0x27B0, 0x27B0 }, // ➰
    .{ 0x27BF, 0x27BF }, // ➿
    .{ 0x2B1B, 0x2B1C }, // ⬛⬜
    .{ 0x2B50, 0x2B50 }, // ⭐
    .{ 0x2B55, 0x2B55 }, // ⭕
    .{ 0x2E80, 0x303E }, // CJK radicals .. CJK symbols/punctuation
    .{ 0x3041, 0xA4CF }, // kana, CJK unified, Yi (U+303F is narrow)
    .{ 0xA960, 0xA97F }, // Hangul Jamo Extended-A
    .{ 0xAC00, 0xD7A3 }, // Hangul syllables
    .{ 0xF900, 0xFAFF }, // CJK compatibility ideographs
    .{ 0xFE10, 0xFE19 }, // vertical forms
    .{ 0xFE30, 0xFE6F }, // CJK compatibility forms
    .{ 0xFF00, 0xFF60 }, // fullwidth forms
    .{ 0xFFE0, 0xFFE6 }, // fullwidth signs
};

/// Zero-width codepoints (wcwidth 0): joiners, variation selectors, and the
/// common combining-mark blocks, inclusive, sorted. Charged no columns so
/// sequences like 👩‍💻 (emoji + ZWJ + emoji) or a decomposed é are not
/// over-counted past their legacy-terminal rendering. Grapheme clustering
/// itself is intentionally not modeled: terminals disagree on it, and
/// assuming it would under-count on non-clustering terminals (e.g.
/// Terminal.app) and reintroduce wrapping. Rare combining blocks (Hebrew,
/// Arabic, Indic) are omitted; counting those as 1 errs toward truncating
/// early rather than wrapping.
const zero_width_ranges = [_][2]u21{
    .{ 0x0300, 0x036F }, // combining diacritical marks
    .{ 0x1160, 0x11FF }, // Hangul jungseong/jongseong (conjoining)
    .{ 0x1AB0, 0x1AFF }, // combining diacritical marks extended
    .{ 0x1DC0, 0x1DFF }, // combining diacritical marks supplement
    .{ 0x200B, 0x200F }, // ZWSP, ZWNJ, ZWJ, LRM, RLM
    .{ 0x2060, 0x2064 }, // word joiner, invisible operators
    .{ 0x20D0, 0x20FF }, // combining marks for symbols
    .{ 0xFE00, 0xFE0F }, // variation selectors
    .{ 0xFE20, 0xFE2F }, // combining half marks
    .{ 0xFEFF, 0xFEFF }, // zero-width no-break space
    .{ 0xE0000, 0xE01EF }, // tags and variation selectors supplement
};

fn isZeroWidth(cp: u21) bool {
    for (zero_width_ranges) |range| {
        if (cp < range[0]) return false; // sorted: no later range can match
        if (cp <= range[1]) return true;
    }
    return false;
}

/// True for codepoints rendered at two terminal columns: the BMP ranges in
/// `wide_bmp_ranges`, the U+16FE0–U+1B2FB supplementary CJK-script band
/// (Tangut, Khitan, kana supplements/extensions, Nushu), and everything from
/// U+1F000 up (emoji and the supplementary CJK ideograph planes).
fn isDoubleWidth(cp: u21) bool {
    if (cp >= 0x1F000) return true;
    if (cp >= 0x16FE0) return cp <= 0x1B2FB;
    for (wide_bmp_ranges) |range| {
        if (cp < range[0]) return false; // sorted: no later range can match
        if (cp <= range[1]) return true;
    }
    return false;
}

/// Terminal column width of one codepoint: 0 for joiners and combining
/// marks, 2 for East Asian wide and emoji, else 1. The zero check must run
/// first: U+E0000–U+E01EF (tags, variation selectors supplement) sits above
/// `isDoubleWidth`'s U+1F000 catch-all threshold.
fn charWidth(cp: u21) usize {
    if (isZeroWidth(cp)) return 0;
    if (isDoubleWidth(cp)) return 2;
    return 1;
}

/// Terminal display width: strips ANSI CSI escapes and sums `charWidth`
/// over the remaining codepoints, with one sequence rule: VS16 (U+FE0F,
/// emoji presentation) and U+20E3 (enclosing keycap) upgrade a narrow base
/// to 2 columns — ☀️ and 1️⃣ render as 2-column emoji even though their
/// bases are EAW-narrow. VS15 (U+FE0E, text presentation) stays zero.
fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var last_base_width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1; // params
            if (i < s.len) i += 1; // final byte
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
            i += 1;
            continue;
        };
        if (cp == 0xFE0F or cp == 0x20E3) {
            if (last_base_width == 1) {
                width += 1;
                last_base_width = 2;
            }
        } else {
            const w = charWidth(cp);
            width += w;
            if (w > 0) last_base_width = w; // zero-width marks keep the base
        }
        i += len;
    }
    return width;
}

fn effortColor(theme: Theme, level: []const u8) []const u8 {
    if (mem.eql(u8, level, "low")) return effort_low_color;
    if (mem.eql(u8, level, "medium")) return effort_medium_color;
    if (mem.eql(u8, level, "high")) return effort_high_color;
    if (mem.eql(u8, level, "xhigh")) return effort_xhigh_color;
    return theme.dim;
}

fn writeLine1(w: *Writer, theme: Theme, stdin_info: StdinInfo, git_branch: ?[]const u8, plan: Line1Plan) !void {
    const model_name = stdin_info.model_name orelse "Unknown";
    try w.print("\xf0\x9f\xa4\x96 {s}{s}{s}", .{ theme.model, model_name, theme.reset });

    // Reasoning effort level
    if (plan.show_effort) {
        if (stdin_info.effort_level) |level| {
            // ⚡ U+26A1
            if (mem.eql(u8, level, "max")) {
                const c = effort_max_colors;
                try w.print(" {s}\xe2\x9a\xa1{s}m{s}a{s}x{s}", .{ c[0], c[1], c[2], c[3], theme.reset });
            } else {
                try w.print(" {s}\xe2\x9a\xa1{s}{s}", .{ effortColor(theme, level), level, theme.reset });
            }
        }
    }

    // Subagent indicator
    if (stdin_info.agent_name) |name| {
        // 🧩 U+1F9E9
        try w.print(" {s}|{s} \xf0\x9f\xa7\xa9 {s}{s}{s}", .{ theme.dim, theme.reset, theme.agent, name, theme.reset });
    }

    // Session name
    if (plan.show_session) {
        if (stdin_info.session_name) |name| {
            var sess_buf: [256]u8 = undefined;
            const display_name = truncateBranch(&sess_buf, name, plan.name_cap);
            // 📛 U+1F4DB
            try w.print(" {s}|{s} \xf0\x9f\x93\x9b {s}{s}{s}", .{ theme.dim, theme.reset, theme.model, display_name, theme.reset });
        }
    }

    // Git branch
    if (plan.show_branch) {
        if (git_branch) |branch| {
            var trunc_buf: [256]u8 = undefined;
            const display_branch = truncateBranch(&trunc_buf, branch, plan.name_cap);
            try w.print(" {s}|{s} \xf0\x9f\x8c\xbf {s}{s}{s}", .{ theme.dim, theme.reset, theme.green, display_branch, theme.reset });
        }
    }

    // Context
    if (stdin_info.context_pct) |pct| {
        const color = contextColor(theme, pct);
        if (plan.bar_width > 0) {
            var bar_buf: [progress_bar_buf_size]u8 = undefined;
            const bar = buildProgressBar(&bar_buf, pct, plan.bar_width, theme.bar_filled, theme.bar_transition, theme.bar_empty);
            try w.print(" {s}|{s} \xf0\x9f\xa7\xa0 {s}{s}{s} {s}{d:.0}%{s}", .{ theme.dim, theme.reset, color, bar, theme.reset, color, pct, theme.reset });
        } else {
            try w.print(" {s}|{s} \xf0\x9f\xa7\xa0 {s}{d:.0}%{s}", .{ theme.dim, theme.reset, color, pct, theme.reset });
        }
        if (plan.show_tokens) {
            if (stdin_info.context_tokens) |tokens| {
                if (stdin_info.context_window_size) |size| {
                    var used_buf: [16]u8 = undefined;
                    var size_buf: [16]u8 = undefined;
                    try w.print(" {s}{s}/{s}{s}", .{
                        theme.dim,
                        formatTokens(&used_buf, tokens),
                        formatTokens(&size_buf, size),
                        theme.reset,
                    });
                }
            }
        }
    } else {
        try w.print(" {s}|{s} \xf0\x9f\xa7\xa0 N/A", .{ theme.dim, theme.reset });
    }

    // 200K+ pricing tier marker
    if (stdin_info.exceeds_200k_tokens) {
        try w.writeAll(" \xf0\x9f\x9a\xa8"); // 🚨 U+1F6A8
    }
}

fn line1Fits(theme: Theme, stdin_info: StdinInfo, git_branch: ?[]const u8, plan: Line1Plan, cols: u16) bool {
    var buf: [line1_scratch_size]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    writeLine1(&fw, theme, stdin_info, git_branch, plan) catch return false;
    return displayWidth(fw.buffered()) <= cols;
}

/// Largest name cap in `[floor, base.name_cap]` whose rendering fits, or
/// `floor` when none does. Width is monotone in the cap, so binary search.
fn largestFittingCap(theme: Theme, stdin_info: StdinInfo, git_branch: ?[]const u8, base: Line1Plan, cols: u16, floor: usize) usize {
    if (base.name_cap <= floor) return base.name_cap;
    var plan = base;
    plan.name_cap = floor;
    if (!line1Fits(theme, stdin_info, git_branch, plan, cols)) return floor;
    var lo = floor;
    var hi = base.name_cap;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        plan.name_cap = mid;
        if (line1Fits(theme, stdin_info, git_branch, plan, cols)) lo = mid else hi = mid - 1;
    }
    return lo;
}

/// Fit line 1 into `theme.cols` by measuring the actual rendered width —
/// model and agent names are uncontrolled, so no static budget can cover
/// them. Degradation order: shrink session/branch toward 12 columns, drop
/// token counts, shrink toward 8, hide the bar, shrink toward 4, then omit
/// effort, branch, and session. When even that exceeds the terminal (a very
/// long model or agent name on a very narrow terminal) the minimal plan is
/// rendered as-is.
fn planLine1(theme: Theme, stdin_info: StdinInfo, git_branch: ?[]const u8) Line1Plan {
    var plan = Line1Plan{ .bar_width = theme.bar_width, .name_cap = theme.branch_max, .show_session = theme.show_session };
    const cols = theme.cols orelse return plan;
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;

    plan.name_cap = largestFittingCap(theme, stdin_info, git_branch, plan, cols, 12);
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.show_tokens = false;
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.name_cap = largestFittingCap(theme, stdin_info, git_branch, plan, cols, 8);
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.bar_width = 0;
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.name_cap = largestFittingCap(theme, stdin_info, git_branch, plan, cols, 4);
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.show_effort = false;
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.show_branch = false;
    if (line1Fits(theme, stdin_info, git_branch, plan, cols)) return plan;
    plan.show_session = false;
    return plan;
}

pub fn printOutput(w: *Writer, theme: Theme, stdin_info: StdinInfo, scan: ?ScanResult, now_ms: i64, utc_offset_s: i32, git_branch: ?[]const u8) !void {
    // === Line 1: Model + Effort + Agent + Session + Branch + Context ===
    const plan = planLine1(theme, stdin_info, git_branch);
    try writeLine1(w, theme, stdin_info, git_branch, plan);
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

// --- formatTokens ---

test "formatTokens below 1000 raw" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatTokens(&buf, 0));
    try std.testing.expectEqualStrings("850", formatTokens(&buf, 850));
    try std.testing.expectEqualStrings("999", formatTokens(&buf, 999));
}

test "formatTokens thousands floored" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1k", formatTokens(&buf, 1000));
    try std.testing.expectEqualStrings("1k", formatTokens(&buf, 1999));
    try std.testing.expectEqualStrings("126k", formatTokens(&buf, 126456));
    try std.testing.expectEqualStrings("200k", formatTokens(&buf, 200000));
    try std.testing.expectEqualStrings("999k", formatTokens(&buf, 999999));
}

test "formatTokens millions" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1M", formatTokens(&buf, 1_000_000));
    try std.testing.expectEqualStrings("1.2M", formatTokens(&buf, 1_234_567));
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

test "truncateBranch backs a torn cluster up to a complete boundary" {
    var buf: [256]u8 = undefined;
    // "👩‍💻👩‍💻" cut inside the second cluster backs up to the first one.
    const zwj = truncateBranch(&buf, "👩‍💻👩‍💻", 16);
    try std.testing.expectEqualStrings("👩‍💻\xe2\x80\xa6", zwj); // 👩‍💻…
    // When not even the first cluster fits, only the ellipsis remains.
    const tiny = truncateBranch(&buf, "👩‍💻👩‍💻", 8);
    try std.testing.expectEqualStrings("\xe2\x80\xa6", tiny); // …
    // "1️⃣2️⃣" cut mid-keycap backs up to the whole first keycap.
    const keycap = truncateBranch(&buf, "1\xef\xb8\x8f\xe2\x83\xa32\xef\xb8\x8f\xe2\x83\xa3", 12);
    try std.testing.expectEqualStrings("1\xef\xb8\x8f\xe2\x83\xa3\xe2\x80\xa6", keycap); // 1️⃣…
}

test "truncateBranch keeps complete trailing graphemes" {
    var buf: [256]u8 = undefined;
    // A combining accent right before the cut belongs to a complete é.
    const accent = truncateBranch(&buf, "cafe\xcc\x81xxxxx", 7);
    try std.testing.expectEqualStrings("cafe\xcc\x81\xe2\x80\xa6", accent); // café…
    // A complete keycap right before the cut is kept whole.
    const keycap = truncateBranch(&buf, "1\xef\xb8\x8f\xe2\x83\xa3abcd", 8);
    try std.testing.expectEqualStrings("1\xef\xb8\x8f\xe2\x83\xa3\xe2\x80\xa6", keycap); // 1️⃣…
}

test "truncateBranch drops a torn half flag" {
    var buf: [256]u8 = undefined;
    // "🇯🇵🇺🇸" cut after the third regional indicator keeps whole flags only.
    const flags = truncateBranch(&buf, "🇯🇵🇺🇸", 13);
    try std.testing.expectEqualStrings("\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5\xe2\x80\xa6", flags); // 🇯🇵…
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

test "printOutput line1 effort level colored per level" {
    const cases = [_]struct { level: []const u8, color: []const u8 }{
        .{ .level = "low", .color = effort_low_color },
        .{ .level = "medium", .color = effort_medium_color },
        .{ .level = "high", .color = effort_high_color },
        .{ .level = "xhigh", .color = effort_xhigh_color },
    };
    for (cases) |case| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        const info = StdinInfo{ .model_name = "Fable", .effort_level = case.level };
        try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
        var expected_buf: [64]u8 = undefined;
        // ⚡ U+26A1
        const expected = try std.fmt.bufPrint(&expected_buf, "{s}\xe2\x9a\xa1{s}", .{ case.color, case.level });
        try std.testing.expect(contains(aw.writer.buffered(), expected));
    }
}

test "printOutput line1 effort max rainbow per glyph" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Fable", .effort_level = "max" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const expected = effort_max_colors[0] ++ "\xe2\x9a\xa1" ++ effort_max_colors[1] ++ "m" ++
        effort_max_colors[2] ++ "a" ++ effort_max_colors[3] ++ "x"; // ⚡max
    try std.testing.expect(contains(aw.writer.buffered(), expected));
}

test "printOutput line1 unknown effort level falls back to dim" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const info = StdinInfo{ .model_name = "Fable", .effort_level = "turbo" };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), theme.dim ++ "\xe2\x9a\xa1turbo")); // ⚡
}

test "printOutput line1 no effort omits lightning emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Fable" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(!contains(aw.writer.buffered(), "\xe2\x9a\xa1")); // ⚡
}

test "printOutput line1 session name with name badge emoji in model color" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const theme = theme_catppuccin_mocha;
    const info = StdinInfo{ .model_name = "Fable", .session_name = "my-session" };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "\xf0\x9f\x93\x9b")); // 📛
    try std.testing.expect(contains(out, theme.model ++ "my-session"));
}

test "printOutput line1 long session name truncated" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .session_name = "my-very-long-session-name-that-overflows" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "my-very-long-session-na\xe2\x80\xa6")); // …
    try std.testing.expect(!contains(out, "overflows"));
}

test "printOutput line1 session name hidden when show_session off" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var theme = theme_default;
    theme.show_session = false;
    const info = StdinInfo{ .model_name = "Fable", .session_name = "my-session" };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(!contains(out, "\xf0\x9f\x93\x9b")); // 📛
    try std.testing.expect(!contains(out, "my-session"));
}

test "initTheme hides session name unless CC_STATUSLINE_SHOW_SESSION=1" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!initTheme(&env).show_session);
    try env.put("CC_STATUSLINE_SHOW_SESSION", "0");
    try std.testing.expect(!initTheme(&env).show_session);
    try env.put("CC_STATUSLINE_SHOW_SESSION", "1");
    try std.testing.expect(initTheme(&env).show_session);
}

test "printOutput line1 no session name omits name badge emoji" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .model_name = "Fable" };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(!contains(aw.writer.buffered(), "\xf0\x9f\x93\x9b")); // 📛
}

test "printOutput line1 token counts next to percentage" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .context_pct = 8.0,
        .context_tokens = 15500,
        .context_window_size = 200000,
    };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "8%"));
    try std.testing.expect(contains(out, "15k/200k"));
}

test "printOutput line1 token counts with 1M window" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .context_pct = 13.0,
        .context_tokens = 126456,
        .context_window_size = 1_000_000,
    };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(contains(aw.writer.buffered(), "126k/1M"));
}

test "printOutput line1 no token counts without context_window_size" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_pct = 8.0, .context_tokens = 15500 };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    try std.testing.expect(!contains(aw.writer.buffered(), "15k"));
}

test "printOutput line1 no token counts when context_pct null" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_tokens = 15500, .context_window_size = 200000 };
    try printOutput(&aw.writer, theme_default, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "N/A"));
    try std.testing.expect(!contains(out, "200k"));
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

// --- layoutForColumns ---

test "layoutForColumns bar-shrink breakpoints" {
    try std.testing.expectEqual(Layout{ .bar_width = 10, .reset_info = .full }, layoutForColumns(200));
    try std.testing.expectEqual(Layout{ .bar_width = 10, .reset_info = .full }, layoutForColumns(85));
    try std.testing.expectEqual(Layout{ .bar_width = 8, .reset_info = .full }, layoutForColumns(84));
    try std.testing.expectEqual(Layout{ .bar_width = 8, .reset_info = .full }, layoutForColumns(81));
    try std.testing.expectEqual(Layout{ .bar_width = 6, .reset_info = .full }, layoutForColumns(80));
    try std.testing.expectEqual(Layout{ .bar_width = 6, .reset_info = .full }, layoutForColumns(77));
    try std.testing.expectEqual(Layout{ .bar_width = 4, .reset_info = .full }, layoutForColumns(76));
    try std.testing.expectEqual(Layout{ .bar_width = 4, .reset_info = .full }, layoutForColumns(73));
    try std.testing.expectEqual(Layout{ .bar_width = 2, .reset_info = .full }, layoutForColumns(72));
    try std.testing.expectEqual(Layout{ .bar_width = 2, .reset_info = .full }, layoutForColumns(69));
}

test "layoutForColumns reset-info breakpoints" {
    // Bar gone, reset info still full.
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .full }, layoutForColumns(68));
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .full }, layoutForColumns(63));
    // Datetime dropped.
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .duration_only }, layoutForColumns(62));
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .duration_only }, layoutForColumns(39));
    // Duration dropped too.
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .none }, layoutForColumns(38));
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .none }, layoutForColumns(0));
}

test "parseLayout fallback and parsing" {
    const default: Layout = .{ .bar_width = default_bar_width, .reset_info = .full };
    try std.testing.expectEqual(default, parseLayout(null)); // COLUMNS unset
    try std.testing.expectEqual(default, parseLayout("not-a-number"));
    try std.testing.expectEqual(default, parseLayout("99999")); // overflow u16
    try std.testing.expectEqual(Layout{ .bar_width = 10, .reset_info = .full }, parseLayout("120"));
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .duration_only }, parseLayout("50"));
    try std.testing.expectEqual(Layout{ .bar_width = 0, .reset_info = .none }, parseLayout("30"));
}

test "parseColumns" {
    try std.testing.expectEqual(@as(?u16, null), parseColumns(null));
    try std.testing.expectEqual(@as(?u16, null), parseColumns("not-a-number"));
    try std.testing.expectEqual(@as(?u16, null), parseColumns("99999")); // overflow u16
    try std.testing.expectEqual(@as(?u16, 80), parseColumns("80"));
}

test "resolveBarWidth override only shrinks" {
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, null)); // unset
    try std.testing.expectEqual(@as(u8, 0), resolveBarWidth(10, "0")); // hides the bar
    try std.testing.expectEqual(@as(u8, 4), resolveBarWidth(10, "4"));
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, "10"));
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, "12")); // cannot grow
    try std.testing.expectEqual(@as(u8, 2), resolveBarWidth(2, "6")); // narrow terminal wins
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, "-1"));
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, "300")); // overflow u8
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, "abc"));
    try std.testing.expectEqual(@as(u8, 10), resolveBarWidth(10, ""));
}

// --- bar hiding (bar_width == 0) ---

test "printOutput hides context bar when bar_width 0" {
    var theme = theme_default;
    theme.bar_width = 0;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{ .context_pct = 42.0 };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "42%")); // percentage still shown
    try std.testing.expect(!contains(out, theme.bar_filled)); // █ gone
    try std.testing.expect(!contains(out, theme.bar_empty)); // ░ gone
    try std.testing.expect(!contains(out, "  ")); // no double space left behind
}

test "printOutput keeps token counts at tight COLUMNS when names are short" {
    // Dynamic planning: short session/branch leave room for tokens even at 80.
    var theme = theme_default;
    theme.bar_width = layoutForColumns(80).bar_width;
    theme.cols = 80;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .model_name = "Sonnet 4.5",
        .effort_level = "xhigh",
        .session_name = "abc",
        .context_pct = 63.0,
        .context_tokens = 126_456,
        .context_window_size = 200_000,
    };
    try printOutput(&aw.writer, theme, info, null, 0, 0, "main");
    try std.testing.expect(contains(aw.writer.buffered(), "126k/200k"));
}

test "printOutput drops token counts before names at tight COLUMNS" {
    var theme = theme_default;
    theme.bar_width = layoutForColumns(80).bar_width;
    theme.cols = 80;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var info = worstCaseLine1Info("Sonnet 4.5", null);
    info.context_pct = 63.0;
    info.context_tokens = 126_456;
    try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
    const out = aw.writer.buffered();
    try std.testing.expect(!contains(out, "126k")); // tokens dropped first
    try std.testing.expect(contains(out, "session-nam\xe2\x80\xa6")); // names at cap 12
    try std.testing.expect(contains(out, "63%")); // percentage kept
}

test "printOutput omits effort at very tight COLUMNS" {
    var theme = theme_default;
    theme.bar_width = layoutForColumns(47).bar_width;
    theme.cols = 47;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = worstCaseLine1Info("Sonnet 4.5", null);
    try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
    const out = aw.writer.buffered();
    try std.testing.expect(!contains(out, "\xe2\x9a\xa1")); // ⚡ dropped
    try std.testing.expect(contains(out, "\xf0\x9f\x93\x9b")); // 📛 kept
    try std.testing.expect(contains(out, "\xf0\x9f\x8c\xbf")); // 🌿 kept
}

test "printOutput omits branch before session at minimal COLUMNS" {
    var theme = theme_default;
    theme.bar_width = layoutForColumns(35).bar_width;
    theme.cols = 35;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = worstCaseLine1Info("Fable", null);
    try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
    const out = aw.writer.buffered();
    try std.testing.expect(!contains(out, "\xf0\x9f\x8c\xbf")); // 🌿 dropped
    try std.testing.expect(contains(out, "\xf0\x9f\x93\x9b")); // 📛 kept
}

test "printOutput hides rate-limit bars when bar_width 0" {
    var theme = theme_default;
    theme.bar_width = 0;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 42.0 },
        .rate_limit_7d = .{ .used_percentage = 86.0 },
    };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    const out = aw.writer.buffered();
    try std.testing.expect(contains(out, "42%"));
    try std.testing.expect(contains(out, "86%"));
    try std.testing.expect(!contains(out, theme.bar_filled));
    try std.testing.expect(!contains(out, "  "));
}

/// Render the worst-case rate-limit output for `cols` and return the rendered
/// rate-limit line (the last non-empty line). Caller owns the slice via `aw`.
///
/// Worst case: both windows, 100% usage ("100%" = 4 cols) and a reset duration
/// that hits `max_reset_duration_cols` — i.e. `"23h 59m"` (the `{d}h {d}m`
/// branch with two-digit hours and two-digit minutes). Using `"3d 12h"` would
/// understate the width by 1 column and miss the worst-case overflow.
fn renderWorstCaseRateLimit(aw: *Writer.Allocating, cols: u16) ![]const u8 {
    const reset_ms: i64 = (23 * 3600 + 59 * 60) * 1000; // now=0 → "23h 59m"
    const info = StdinInfo{
        .rate_limit_5h = .{ .used_percentage = 100.0, .resets_at_ms = reset_ms },
        .rate_limit_7d = .{ .used_percentage = 100.0, .resets_at_ms = reset_ms },
    };
    var theme = theme_default;
    const layout = layoutForColumns(cols);
    theme.bar_width = layout.bar_width;
    theme.reset_info = layout.reset_info;
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
    var last: []const u8 = "";
    while (it.next()) |line| {
        if (line.len > 0) last = line;
    }
    return last;
}

test "rate-limit line fits within COLUMNS at every breakpoint" {
    // Tiers: bar shrinks (85..69), bar hidden full reset (68..63), duration only
    // (62..39), nothing (38..23). Worst case = both windows, 100%, "23h 59m", date.
    const widths = [_]u16{ 200, 85, 84, 81, 80, 77, 76, 73, 72, 69, 68, 63, 62, 39, 38, 23 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        const line = try renderWorstCaseRateLimit(&aw, cols);
        try std.testing.expect(displayWidth(line) <= cols);
    }
}

/// Worst-case line-1 input: everything the planner controls at its cap —
/// effort "xhigh", a long session name, 100% context with token counts, and
/// the 🚨 marker. Model and agent names come from the caller since the
/// planner must budget their actual widths.
fn worstCaseLine1Info(model: []const u8, agent: ?[]const u8) StdinInfo {
    return .{
        .model_name = model,
        .agent_name = agent,
        .effort_level = "xhigh",
        .session_name = "session-name-that-is-really-long",
        .context_pct = 100.0,
        .context_tokens = 200_000,
        .context_window_size = 200_000,
        .exceeds_200k_tokens = true,
    };
}

const worst_case_branch = "feature/branch-that-is-really-long";

/// Render the worst-case line 1 for `cols` and return it. Mirrors how
/// `initTheme` derives the theme from `COLUMNS`.
fn renderWorstCaseLine1(aw: *Writer.Allocating, cols: u16, model: []const u8, agent: ?[]const u8) ![]const u8 {
    var theme = theme_default;
    const layout = layoutForColumns(cols);
    theme.bar_width = layout.bar_width;
    theme.reset_info = layout.reset_info;
    theme.cols = cols;
    try printOutput(&aw.writer, theme, worstCaseLine1Info(model, agent), null, 0, 0, worst_case_branch);
    var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
    return it.next() orelse "";
}

test "displayWidth counts East Asian wide chars as 2 columns" {
    // Pins the metric itself: the planner trusts displayWidth, so a metric
    // regression is invisible to the pipeline tests below.
    try std.testing.expectEqual(@as(usize, 6), displayWidth("日本語"));
    try std.testing.expectEqual(@as(usize, 18), displayWidth("日本語日本語日本語"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("ab日")); // 1+1+2
    try std.testing.expectEqual(@as(usize, 4), displayWidth("ＡＢ")); // fullwidth forms
    try std.testing.expectEqual(@as(usize, 2), displayWidth("한")); // Hangul syllable
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xe2\x80\xa6")); // … stays narrow
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x9a\xa1")); // ⚡
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xf0\x9f\xa4\x96")); // 🤖
}

test "displayWidth counts BMP emoji with EAW wide as 2 columns" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x8f\xb0")); // ⏰ U+23F0
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x8c\x9a")); // ⌚ U+231A
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\xad\x90")); // ⭐ U+2B50
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x9c\x85")); // ✅ U+2705
    // EAW-narrow symbols stay at 1 column.
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xe2\x98\x80")); // ☀ U+2600
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xe2\x86\x92")); // → U+2192
}

test "displayWidth counts supplementary wide scripts as 2 columns" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xf0\x96\xbf\xa0")); // U+16FE0 Tangut iteration mark
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xf0\x9b\x80\x80")); // U+1B000 archaic kana
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xf0\x9b\x8b\xbb")); // U+1B2FB Nushu (band upper bound)
    // Supplementary EAW-narrow codepoints stay at 1 column.
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xf0\x9d\x90\x80")); // U+1D400 mathematical bold A
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xf0\x90\x80\x80")); // U+10000 Linear B
}

test "wide_bmp_ranges are sorted and non-overlapping" {
    // isDoubleWidth's early exit depends on this ordering.
    for (wide_bmp_ranges, 0..) |range, i| {
        try std.testing.expect(range[0] <= range[1]);
        if (i > 0) try std.testing.expect(range[0] > wide_bmp_ranges[i - 1][1]);
    }
}

test "zero_width_ranges are sorted and non-overlapping" {
    // isZeroWidth's early exit depends on this ordering.
    for (zero_width_ranges, 0..) |range, i| {
        try std.testing.expect(range[0] <= range[1]);
        if (i > 0) try std.testing.expect(range[0] > zero_width_ranges[i - 1][1]);
    }
}

test "displayWidth charges joiners and combining marks zero columns" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth("\xe2\x80\x8d")); // ZWJ alone
    try std.testing.expectEqual(@as(usize, 4), displayWidth("👩‍💻")); // emoji + ZWJ + emoji
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\xcc\x81")); // e + combining acute
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x9a\xa1\xef\xb8\x8f")); // ⚡ + VS16
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe9\x82\x8a\xf3\xa0\x84\x80")); // 邊 + U+E0100 (IVS)
    // Policy pin: a flag stays 2+2 — grapheme clustering is not modeled, so
    // regional-indicator pairs count as two emoji (safe on non-clustering
    // terminals).
    try std.testing.expectEqual(@as(usize, 4), displayWidth("🇯🇵"));
}

test "displayWidth upgrades VS16 and keycap sequences to emoji width" {
    // ☀ is EAW-narrow, but VS16 turns it into a 2-column emoji.
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe2\x98\x80\xef\xb8\x8f")); // ☀️
    try std.testing.expectEqual(@as(usize, 2), displayWidth("1\xef\xb8\x8f\xe2\x83\xa3")); // 1️⃣
    try std.testing.expectEqual(@as(usize, 2), displayWidth("#\xe2\x83\xa3")); // keycap without VS16
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\xe2\x98\x80\xef\xb8\x8f\xe2\x98\x80\xef\xb8\x8f")); // ☀️☀️
    // VS15 requests text presentation: stays narrow.
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xe2\x98\x80\xef\xb8\x8e")); // ☀︎
}

test "line 1 fits within COLUMNS with fullwidth session name" {
    // Regression: CJK renders at 2 columns; counting it as 1 made the planner
    // overestimate the remaining space (e.g. 82 actual columns at COLUMNS=80).
    const widths = [_]u16{ 100, 90, 85, 80, 69, 63 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var theme = theme_default;
        const layout = layoutForColumns(cols);
        theme.bar_width = layout.bar_width;
        theme.reset_info = layout.reset_info;
        theme.cols = cols;
        var info = worstCaseLine1Info("Sonnet 4.5", null);
        info.session_name = "日本語日本語日本語";
        try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
        var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
        const line = it.next() orelse "";
        try std.testing.expect(displayWidth(line) <= cols);
    }
}

test "line 1 fits within COLUMNS with BMP-emoji session name" {
    // Regression: ⏰ (U+23F0) is EAW wide but sits outside the CJK ranges;
    // counting it as 1 column wrapped the line (e.g. 82 actual at COLUMNS=80).
    const widths = [_]u16{ 100, 90, 85, 80, 69, 63 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var theme = theme_default;
        const layout = layoutForColumns(cols);
        theme.bar_width = layout.bar_width;
        theme.reset_info = layout.reset_info;
        theme.cols = cols;
        var info = worstCaseLine1Info("Sonnet 4.5", null);
        info.session_name = "⏰⏰⏰⏰⏰⏰⏰⏰";
        try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
        var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
        const line = it.next() orelse "";
        try std.testing.expect(displayWidth(line) <= cols);
    }
}

test "line 1 fits within COLUMNS with supplementary wide session name" {
    // Regression: U+16FE0 (Tangut) is EAW wide but sits below U+1F000 and
    // outside the BMP table; counting it as 1 column wrapped the line
    // (e.g. 83 actual columns at COLUMNS=80).
    const widths = [_]u16{ 100, 90, 80, 69, 63, 56 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var theme = theme_default;
        const layout = layoutForColumns(cols);
        theme.bar_width = layout.bar_width;
        theme.reset_info = layout.reset_info;
        theme.cols = cols;
        var info = worstCaseLine1Info("Sonnet 4.5", null);
        info.session_name = "\xf0\x96\xbf\xa0" ** 8; // U+16FE0 × 8
        try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
        var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
        const line = it.next() orelse "";
        try std.testing.expect(displayWidth(line) <= cols);
    }
}

test "line 1 keeps ZWJ session name and tokens at tight COLUMNS" {
    // Regression: charging ZWJ one column made the planner overestimate the
    // line (56 counted vs 54 rendered at COLUMNS=54) and truncate the
    // session name even though everything fit.
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var theme = theme_default;
    const layout = layoutForColumns(54);
    theme.bar_width = layout.bar_width;
    theme.reset_info = layout.reset_info;
    theme.cols = 54;
    const info = StdinInfo{
        .model_name = "Sonnet 4.5",
        .effort_level = "xhigh",
        .session_name = "👩‍💻👩‍💻",
        .context_pct = 63.0,
        .context_tokens = 126_456,
        .context_window_size = 200_000,
    };
    try printOutput(&aw.writer, theme, info, null, 0, 0, null);
    var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
    const line = it.next() orelse "";
    try std.testing.expect(contains(line, "👩‍💻👩‍💻")); // full session name kept
    try std.testing.expect(!contains(line, "\xe2\x80\xa6")); // no … truncation
    try std.testing.expect(contains(line, "126k/200k")); // tokens kept
    try std.testing.expect(displayWidth(line) <= 54);
}

test "line 1 fits within COLUMNS with VS16-emoji session name" {
    // Regression: ☀️ (EAW-narrow base + VS16) was counted as 1 column but
    // renders as 2, so the planner emitted 53 actual columns at COLUMNS=50.
    const widths = [_]u16{ 80, 63, 56, 52, 50, 44 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var theme = theme_default;
        const layout = layoutForColumns(cols);
        theme.bar_width = layout.bar_width;
        theme.reset_info = layout.reset_info;
        theme.cols = cols;
        var info = worstCaseLine1Info("Sonnet 4.5", null);
        info.session_name = "☀️" ** 6;
        try printOutput(&aw.writer, theme, info, null, 0, 0, worst_case_branch);
        var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
        const line = it.next() orelse "";
        try std.testing.expect(displayWidth(line) <= cols);
    }
}

test "line 1 never leaves dangling joiners before the ellipsis" {
    // Regression: byte-boundary truncation could cut a ZWJ sequence or
    // keycap right after its joiner, e.g. "👩‍…" at COLUMNS=40.
    const widths = [_]u16{ 60, 56, 52, 48, 44, 40, 36 };
    for (widths) |cols| {
        var aw: Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        var theme = theme_default;
        const layout = layoutForColumns(cols);
        theme.bar_width = layout.bar_width;
        theme.reset_info = layout.reset_info;
        theme.cols = cols;
        var info = worstCaseLine1Info("Sonnet 4.5", null);
        info.session_name = "👩‍💻👩‍💻";
        const keycap_branch = "1\xef\xb8\x8f\xe2\x83\xa32\xef\xb8\x8f\xe2\x83\xa33\xef\xb8\x8f\xe2\x83\xa34\xef\xb8\x8f\xe2\x83\xa3"; // 1️⃣2️⃣3️⃣4️⃣
        try printOutput(&aw.writer, theme, info, null, 0, 0, keycap_branch);
        var it = mem.splitScalar(u8, aw.writer.buffered(), '\n');
        const line = it.next() orelse "";
        try std.testing.expect(!contains(line, "\xe2\x80\x8d\xe2\x80\xa6")); // no ZWJ + …
        try std.testing.expect(!contains(line, "\xef\xb8\x8f\xe2\x80\xa6")); // no VS16 + …
        try std.testing.expect(!contains(line, "\xf0\x9f\x91\xa9\xe2\x80\xa6")); // no torn 👩 + …
    }
}

test "line 1 fits within COLUMNS across models, agents, and widths" {
    const cases = [_]struct { model: []const u8, agent: ?[]const u8 }{
        .{ .model = "Sonnet 4.5", .agent = null },
        .{ .model = "Opus 4.8 (1M context)", .agent = null }, // long model
        .{ .model = "Fable", .agent = "code-reviewer" }, // agent segment
        .{ .model = "Opus 4.8 (1M context)", .agent = "security-reviewer" },
    };
    const widths = [_]u16{ 200, 120, 100, 85, 80, 69, 63, 50, 40, 30 };
    for (cases) |case| {
        // The fully-degraded plan is the floor: uncontrolled parts (model,
        // agent, context, 🚨) can exceed tiny widths on their own.
        var min_aw: Writer.Allocating = .init(std.testing.allocator);
        defer min_aw.deinit();
        try writeLine1(&min_aw.writer, theme_default, worstCaseLine1Info(case.model, case.agent), worst_case_branch, .{
            .bar_width = 0,
            .name_cap = 4,
            .show_tokens = false,
            .show_effort = false,
            .show_branch = false,
            .show_session = false,
        });
        const minimal = displayWidth(min_aw.writer.buffered());
        for (widths) |cols| {
            var aw: Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            const line = try renderWorstCaseLine1(&aw, cols, case.model, case.agent);
            try std.testing.expect(displayWidth(line) <= @max(cols, minimal));
        }
    }
}

test "duration_only drops datetime but keeps duration" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const line = try renderWorstCaseRateLimit(&aw, 50);
    try std.testing.expect(contains(line, "23h 59m")); // duration kept
    try std.testing.expect(!contains(line, "/")); // no "MM/DD" datetime
}

test "none drops both duration and datetime" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const line = try renderWorstCaseRateLimit(&aw, 25);
    try std.testing.expect(contains(line, "100%"));
    try std.testing.expect(!contains(line, "23h 59m")); // duration gone
    try std.testing.expect(!contains(line, "/")); // datetime gone
}
