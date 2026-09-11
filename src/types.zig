const std = @import("std");

pub const ms_per_min = 60_000;

/// Checked f64 -> i64. Null when the value is outside i64 or is NaN.
///
/// `@intFromFloat` is illegal behavior in those cases, and both JSON parsers in
/// this repo can be handed such a value by malformed input, so neither converts
/// without going through here. They are independent parsers that do not import
/// each other; one definition keeps the bound from drifting apart.
///
/// -2^63 is exactly representable as f64. 2^63 is the first value past
/// maxInt(i64) — `@floatFromInt(maxInt(i64))` rounds *up* to it — so the upper
/// bound is exclusive. NaN fails both comparisons, which is what we want.
pub fn i64FromFloat(f: f64) ?i64 {
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (f >= min_f and f < -min_f) return @intFromFloat(f);
    return null;
}

pub const RateLimitWindow = struct {
    used_percentage: f64,
    resets_at_ms: ?i64 = null,
};

/// Lifetime of the cached prefix. Claude Code reports it as "5m" or "1h";
/// anything else parses to null so the cost segment and the countdown color,
/// which both depend on knowing the TTL, are skipped rather than guessed.
pub const CacheTtl = enum {
    five_min,
    one_hour,

    pub fn ms(self: CacheTtl) i64 {
        return switch (self) {
            .five_min => 5 * 60 * 1000,
            .one_hour => 60 * 60 * 1000,
        };
    }
};

/// The subset of Claude Code's `prompt_cache` object that the cache line
/// renders. The upstream object carries six more fields (requests, misses,
/// expected_rebuilds, cache_write_tokens, miss_recache_tokens, last_miss_at)
/// that nothing displays, so they are not kept.
pub const PromptCache = struct {
    warm: bool = false,
    caching_observed: bool = false,
    ttl: ?CacheTtl = null,
    expires_at_ms: ?i64 = null,
    /// `hit_ratio` (0..1 upstream) rescaled to 0..100 to match every other
    /// percentage in this struct family.
    hit_percentage: ?f64 = null,
    recache_tokens_if_cold: ?i64 = null,
};

pub const BlockInfo = struct {
    start_ms: i64,
    end_ms: i64,
    cost: f64,
    burn_rate_per_hr: f64,
};

pub const ScanResult = struct {
    today_cost: f64 = 0,
    block: ?BlockInfo = null,
};

pub const StdinInfo = struct {
    model_id: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    session_cost: ?f64 = null,
    session_duration_ms: ?i64 = null,
    context_pct: ?f64 = null,
    context_tokens: ?i64 = null,
    context_window_size: ?i64 = null,
    lines_added: ?i64 = null,
    lines_removed: ?i64 = null,
    session_id: ?[]const u8 = null,
    session_name: ?[]const u8 = null,
    effort_level: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    rate_limit_5h: ?RateLimitWindow = null,
    rate_limit_7d: ?RateLimitWindow = null,
    prompt_cache: ?PromptCache = null,
    agent_name: ?[]const u8 = null,
    exceeds_200k_tokens: bool = false,
    /// True only when standard input was empty (0 bytes). Defaults to false so
    /// a bare `StdinInfo{}` still means "a session JSON was present".
    stdin_absent: bool = false,
};
