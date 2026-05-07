pub const ms_per_min = 60_000;

pub const RateLimitWindow = struct {
    used_percentage: f64,
    resets_at_ms: ?i64 = null,
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
    lines_added: ?i64 = null,
    lines_removed: ?i64 = null,
    session_id: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    rate_limit_5h: ?RateLimitWindow = null,
    rate_limit_7d: ?RateLimitWindow = null,
    agent_name: ?[]const u8 = null,
    exceeds_200k_tokens: bool = false,
};
