const std = @import("std");
const mem = std.mem;

const token_200k: i64 = 200_000;

pub const TokenUsage = struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_creation_5m_input_tokens: i64 = 0,
    cache_creation_1h_input_tokens: i64 = 0,
    cache_read_input_tokens: i64 = 0,
    is_fast: bool = false,
};

pub const ModelPricing = struct {
    prefix: []const u8,
    input: f64,
    output: f64,
    cache_creation_5m: f64,
    cache_creation_1h: f64,
    cache_read: f64,
    input_above_200k: ?f64 = null,
    output_above_200k: ?f64 = null,
    cache_creation_5m_above_200k: ?f64 = null,
    cache_creation_1h_above_200k: ?f64 = null,
    cache_read_above_200k: ?f64 = null,
};

pub const pricing_table = [_]ModelPricing{
    // Opus 4.7 (1M context at standard pricing)
    .{ .prefix = "claude-opus-4-7", .input = 5e-6, .output = 25e-6, .cache_creation_5m = 6.25e-6, .cache_creation_1h = 10e-6, .cache_read = 5e-7 },
    // Opus 4.6 (1M context at standard pricing)
    .{ .prefix = "claude-opus-4-6", .input = 5e-6, .output = 25e-6, .cache_creation_5m = 6.25e-6, .cache_creation_1h = 10e-6, .cache_read = 5e-7 },
    // Opus 4.5 (200k context limit, no long context pricing)
    .{ .prefix = "claude-opus-4-5", .input = 5e-6, .output = 25e-6, .cache_creation_5m = 6.25e-6, .cache_creation_1h = 10e-6, .cache_read = 5e-7 },
    // Opus 4.1
    .{ .prefix = "claude-opus-4-1", .input = 15e-6, .output = 75e-6, .cache_creation_5m = 18.75e-6, .cache_creation_1h = 30e-6, .cache_read = 1.5e-6 },
    // Opus 4 (matches "claude-opus-4-" after more specific prefixes)
    .{ .prefix = "claude-opus-4", .input = 15e-6, .output = 75e-6, .cache_creation_5m = 18.75e-6, .cache_creation_1h = 30e-6, .cache_read = 1.5e-6 },
    // Claude 3 Opus
    .{ .prefix = "claude-3-opus", .input = 15e-6, .output = 75e-6, .cache_creation_5m = 18.75e-6, .cache_creation_1h = 30e-6, .cache_read = 1.5e-6 },
    // Sonnet 4.6 (1M context at standard pricing)
    .{ .prefix = "claude-sonnet-4-6", .input = 3e-6, .output = 15e-6, .cache_creation_5m = 3.75e-6, .cache_creation_1h = 6e-6, .cache_read = 3e-7 },
    // Sonnet 4.5
    .{
        .prefix = "claude-sonnet-4-5",
        .input = 3e-6,
        .output = 15e-6,
        .cache_creation_5m = 3.75e-6,
        .cache_creation_1h = 6e-6,
        .cache_read = 3e-7,
        .input_above_200k = 6e-6,
        .output_above_200k = 22.5e-6,
        .cache_creation_5m_above_200k = 7.5e-6,
        .cache_creation_1h_above_200k = 12e-6,
        .cache_read_above_200k = 6e-7,
    },
    // Sonnet 4 (matches "claude-sonnet-4-" after more specific prefixes)
    .{
        .prefix = "claude-sonnet-4",
        .input = 3e-6,
        .output = 15e-6,
        .cache_creation_5m = 3.75e-6,
        .cache_creation_1h = 6e-6,
        .cache_read = 3e-7,
        .input_above_200k = 6e-6,
        .output_above_200k = 22.5e-6,
        .cache_creation_5m_above_200k = 7.5e-6,
        .cache_creation_1h_above_200k = 12e-6,
        .cache_read_above_200k = 6e-7,
    },
    // Sonnet 3.7
    .{ .prefix = "claude-3-7-sonnet", .input = 3e-6, .output = 15e-6, .cache_creation_5m = 3.75e-6, .cache_creation_1h = 6e-6, .cache_read = 3e-7 },
    // Sonnet 3.5
    .{ .prefix = "claude-3-5-sonnet", .input = 3e-6, .output = 15e-6, .cache_creation_5m = 3.75e-6, .cache_creation_1h = 6e-6, .cache_read = 3e-7 },
    // Haiku 4.5
    .{ .prefix = "claude-haiku-4-5", .input = 1e-6, .output = 5e-6, .cache_creation_5m = 1.25e-6, .cache_creation_1h = 2e-6, .cache_read = 1e-7 },
    // Haiku 3.5
    .{ .prefix = "claude-3-5-haiku", .input = 8e-7, .output = 4e-6, .cache_creation_5m = 1e-6, .cache_creation_1h = 1.6e-6, .cache_read = 8e-8 },
};

pub fn findPricing(model: []const u8) ?ModelPricing {
    for (&pricing_table) |p| {
        if (mem.startsWith(u8, model, p.prefix)) return p;
    }
    return null;
}

const fast_multiplier: f64 = 6.0;

pub fn calculateEntryCost(pricing: ModelPricing, usage: TokenUsage) f64 {
    const cache_creation_total = usage.cache_creation_5m_input_tokens + usage.cache_creation_1h_input_tokens;
    const total_input = usage.input_tokens + cache_creation_total + usage.cache_read_input_tokens;
    const use_premium = total_input > token_200k and pricing.input_above_200k != null;

    const input_rate = if (use_premium) pricing.input_above_200k.? else pricing.input;
    const output_rate = if (use_premium) (pricing.output_above_200k orelse pricing.output) else pricing.output;
    const cc5m_rate = if (use_premium) (pricing.cache_creation_5m_above_200k orelse pricing.cache_creation_5m) else pricing.cache_creation_5m;
    const cc1h_rate = if (use_premium) (pricing.cache_creation_1h_above_200k orelse pricing.cache_creation_1h) else pricing.cache_creation_1h;
    const cr_rate = if (use_premium) (pricing.cache_read_above_200k orelse pricing.cache_read) else pricing.cache_read;

    const base = @as(f64, @floatFromInt(usage.input_tokens)) * input_rate +
        @as(f64, @floatFromInt(usage.output_tokens)) * output_rate +
        @as(f64, @floatFromInt(usage.cache_creation_5m_input_tokens)) * cc5m_rate +
        @as(f64, @floatFromInt(usage.cache_creation_1h_input_tokens)) * cc1h_rate +
        @as(f64, @floatFromInt(usage.cache_read_input_tokens)) * cr_rate;

    return if (usage.is_fast) base * fast_multiplier else base;
}

// ============================================================
// Tests
// ============================================================

test "findPricing" {
    const p1 = findPricing("claude-opus-4-7-20260101");
    try std.testing.expect(p1 != null);
    try std.testing.expectEqual(@as(f64, 5e-6), p1.?.input);
    try std.testing.expectEqual(@as(?f64, null), p1.?.input_above_200k);

    const p2 = findPricing("claude-sonnet-4-5-20250929");
    try std.testing.expect(p2 != null);
    try std.testing.expectEqual(@as(f64, 3e-6), p2.?.input);
    try std.testing.expect(p2.?.input_above_200k != null);

    try std.testing.expect(findPricing("unknown-model") == null);
}

test "calculateEntryCost" {
    const pricing = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
    };
    const cost = calculateEntryCost(pricing, usage);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0175), cost, 1e-10);
}

test "calculateEntryCost tiered" {
    const pricing = findPricing("claude-sonnet-4-5-20250929").?;
    const usage = TokenUsage{
        .input_tokens = 250_000,
        .output_tokens = 100,
    };
    const cost = calculateEntryCost(pricing, usage);
    try std.testing.expectApproxEqAbs(@as(f64, 1.50225), cost, 1e-10);
}

test "calculateEntryCost opus 4.6 with cache over 200k uses base rate" {
    const pricing = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 50_000,
        .output_tokens = 10_000,
        .cache_creation_5m_input_tokens = 100_000,
        .cache_read_input_tokens = 100_000,
    };
    const cost = calculateEntryCost(pricing, usage);
    // total_input = 250k > 200k, but Opus 4.6 has no above_200k pricing
    // base rate: 50_000 * 5e-6 + 10_000 * 25e-6 + 100_000 * 6.25e-6 + 100_000 * 5e-7
    // = 0.25 + 0.25 + 0.625 + 0.05 = 1.175
    try std.testing.expectApproxEqAbs(@as(f64, 1.175), cost, 1e-10);
}

test "calculateEntryCost under 200k with cache uses base rate" {
    const pricing = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 50_000,
        .output_tokens = 5_000,
        .cache_creation_5m_input_tokens = 80_000,
        .cache_read_input_tokens = 60_000,
    };
    const cost = calculateEntryCost(pricing, usage);
    try std.testing.expectApproxEqAbs(@as(f64, 0.905), cost, 1e-10);
}

test "calculateEntryCost exactly 200k uses base rate" {
    const p = findPricing("claude-sonnet-4-5-20250929").?;
    // total_input = 200,000 exactly → condition is `> 200k` so base rate applies
    const usage = TokenUsage{
        .input_tokens = 200_000,
        .output_tokens = 100,
    };
    const cost = calculateEntryCost(p, usage);
    // base rate: 200_000 * 3e-6 + 100 * 15e-6 = 0.6 + 0.0015 = 0.6015
    try std.testing.expectApproxEqAbs(@as(f64, 0.6015), cost, 1e-10);
}

test "calculateEntryCost 200k+1 uses premium rate" {
    const p = findPricing("claude-sonnet-4-5-20250929").?;
    // total_input = 200,001 → premium rate applies
    const usage = TokenUsage{
        .input_tokens = 200_001,
        .output_tokens = 100,
    };
    const cost = calculateEntryCost(p, usage);
    // premium rate: 200_001 * 6e-6 + 100 * 22.5e-6 = 1.200006 + 0.00225 = 1.202256
    try std.testing.expectApproxEqAbs(@as(f64, 1.202256), cost, 1e-10);
}

test "calculateEntryCost opus 4.6 over 200k uses base rate" {
    const p = findPricing("claude-opus-4-6-20251212").?;
    try std.testing.expectEqual(@as(?f64, null), p.input_above_200k);
    const usage = TokenUsage{
        .input_tokens = 300_000,
        .output_tokens = 1000,
    };
    const cost = calculateEntryCost(p, usage);
    // base rate: 300_000 * 5e-6 + 1000 * 25e-6 = 1.5 + 0.025 = 1.525
    try std.testing.expectApproxEqAbs(@as(f64, 1.525), cost, 1e-10);
}

test "calculateEntryCost sonnet 4.6 over 200k uses base rate" {
    const p = findPricing("claude-sonnet-4-6-20251212").?;
    try std.testing.expectEqual(@as(?f64, null), p.input_above_200k);
    const usage = TokenUsage{
        .input_tokens = 300_000,
        .output_tokens = 1000,
    };
    const cost = calculateEntryCost(p, usage);
    // base rate: 300_000 * 3e-6 + 1000 * 15e-6 = 0.9 + 0.015 = 0.915
    try std.testing.expectApproxEqAbs(@as(f64, 0.915), cost, 1e-10);
}

test "calculateEntryCost fast mode 6x" {
    const pricing = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
        .is_fast = true,
    };
    const cost = calculateEntryCost(pricing, usage);
    // base: 1000 * 5e-6 + 500 * 25e-6 = 0.005 + 0.0125 = 0.0175
    // fast: 0.0175 * 6 = 0.105
    try std.testing.expectApproxEqAbs(@as(f64, 0.105), cost, 1e-10);
}

test "calculateEntryCost fast mode with cache" {
    const pricing = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_creation_5m_input_tokens = 2000,
        .cache_read_input_tokens = 3000,
        .is_fast = true,
    };
    const cost = calculateEntryCost(pricing, usage);
    // base: 1000*5e-6 + 500*25e-6 + 2000*6.25e-6 + 3000*5e-7
    // = 0.005 + 0.0125 + 0.0125 + 0.0015 = 0.0315
    // fast: 0.0315 * 6 = 0.189
    try std.testing.expectApproxEqAbs(@as(f64, 0.189), cost, 1e-10);
}

test "calculateEntryCost no above_200k model over 200k uses base rate" {
    // claude-opus-4-1 has no above_200k pricing
    const p = findPricing("claude-opus-4-1-20250929").?;
    try std.testing.expectEqual(@as(?f64, null), p.input_above_200k);
    const usage = TokenUsage{
        .input_tokens = 250_000,
        .output_tokens = 100,
    };
    const cost = calculateEntryCost(p, usage);
    // use_premium is false because input_above_200k == null
    // base rate: 250_000 * 15e-6 + 100 * 75e-6 = 3.75 + 0.0075 = 3.7575
    try std.testing.expectApproxEqAbs(@as(f64, 3.7575), cost, 1e-10);
}

test "calculateEntryCost all-zero usage returns zero" {
    const p = findPricing("claude-opus-4-6-20251212").?;
    const cost = calculateEntryCost(p, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 0), cost, 1e-10);
}

test "calculateEntryCost output only no input" {
    const p = findPricing("claude-opus-4-6-20251212").?;
    const cost = calculateEntryCost(p, .{ .output_tokens = 1000 });
    // 0 + 1000 * 25e-6 = 0.025
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), cost, 1e-10);
}

test "calculateEntryCost fast mode with tiered pricing" {
    const p = findPricing("claude-sonnet-4-5-20250929").?;
    const usage = TokenUsage{
        .input_tokens = 250_000,
        .output_tokens = 100,
        .is_fast = true,
    };
    const cost = calculateEntryCost(p, usage);
    // premium: 250_000 * 6e-6 + 100 * 22.5e-6 = 1.5 + 0.00225 = 1.50225
    // fast: 1.50225 * 6 = 9.0135
    try std.testing.expectApproxEqAbs(@as(f64, 9.0135), cost, 1e-10);
}

test "calculateEntryCost 1h cache charges 1h rate on opus 4.6" {
    const p = findPricing("claude-opus-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 0,
        .output_tokens = 0,
        .cache_creation_1h_input_tokens = 10_000,
    };
    const cost = calculateEntryCost(p, usage);
    // 10_000 * 10e-6 = 0.1
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), cost, 1e-10);
}

test "calculateEntryCost mixed 5m + 1h cache on sonnet 4.6" {
    const p = findPricing("claude-sonnet-4-6-20251212").?;
    const usage = TokenUsage{
        .input_tokens = 1000,
        .output_tokens = 500,
        .cache_creation_5m_input_tokens = 2000,
        .cache_creation_1h_input_tokens = 3000,
        .cache_read_input_tokens = 4000,
    };
    const cost = calculateEntryCost(p, usage);
    // 1000*3e-6 + 500*15e-6 + 2000*3.75e-6 + 3000*6e-6 + 4000*3e-7
    // = 0.003 + 0.0075 + 0.0075 + 0.018 + 0.0012 = 0.0372
    try std.testing.expectApproxEqAbs(@as(f64, 0.0372), cost, 1e-10);
}

test "calculateEntryCost sonnet 4.5 above 200k uses 1h premium rate" {
    const p = findPricing("claude-sonnet-4-5-20250929").?;
    const usage = TokenUsage{
        .input_tokens = 250_000,
        .output_tokens = 0,
        .cache_creation_1h_input_tokens = 10_000,
    };
    const cost = calculateEntryCost(p, usage);
    // total_input = 260k > 200k → premium
    // 250_000 * 6e-6 + 10_000 * 12e-6 = 1.5 + 0.12 = 1.62
    try std.testing.expectApproxEqAbs(@as(f64, 1.62), cost, 1e-10);
}

// --- findPricing exhaustive ---

test "findPricing all model prefixes" {
    const expected = [_]struct { model: []const u8, prefix: []const u8 }{
        .{ .model = "claude-opus-4-7-20260101", .prefix = "claude-opus-4-7" },
        .{ .model = "claude-opus-4-6-20251212", .prefix = "claude-opus-4-6" },
        .{ .model = "claude-opus-4-5-20250929", .prefix = "claude-opus-4-5" },
        .{ .model = "claude-opus-4-1-20250929", .prefix = "claude-opus-4-1" },
        .{ .model = "claude-opus-4-20250929", .prefix = "claude-opus-4" },
        .{ .model = "claude-3-opus-20240229", .prefix = "claude-3-opus" },
        .{ .model = "claude-sonnet-4-6-20251212", .prefix = "claude-sonnet-4-6" },
        .{ .model = "claude-sonnet-4-5-20250929", .prefix = "claude-sonnet-4-5" },
        .{ .model = "claude-sonnet-4-3-20250929", .prefix = "claude-sonnet-4" },
        .{ .model = "claude-3-7-sonnet-20250219", .prefix = "claude-3-7-sonnet" },
        .{ .model = "claude-3-5-sonnet-20241022", .prefix = "claude-3-5-sonnet" },
        .{ .model = "claude-haiku-4-5-20251001", .prefix = "claude-haiku-4-5" },
        .{ .model = "claude-3-5-haiku-20241022", .prefix = "claude-3-5-haiku" },
    };
    for (expected) |e| {
        const p = findPricing(e.model) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(e.prefix, p.prefix);
    }
}

test "findPricing prefix ordering specific before generic" {
    try std.testing.expectEqualStrings("claude-opus-4-7", findPricing("claude-opus-4-7-20260101").?.prefix);
    try std.testing.expectEqualStrings("claude-opus-4-6", findPricing("claude-opus-4-6-20251212").?.prefix);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", findPricing("claude-sonnet-4-6-20251212").?.prefix);
}

test "findPricing prefix ordering specific sonnet-4 variants before generic sonnet-4" {
    // If the generic claude-sonnet-4 entry is reordered before a more specific
    // variant, these models would incorrectly match the generic entry.
    try std.testing.expectEqualStrings("claude-sonnet-4-6", findPricing("claude-sonnet-4-6-20251212").?.prefix);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", findPricing("claude-sonnet-4-5-20250929").?.prefix);
    try std.testing.expectEqualStrings("claude-sonnet-4", findPricing("claude-sonnet-4-3-20250929").?.prefix);
}

test "findPricing prefix ordering specific opus-4 variants before generic opus-4" {
    try std.testing.expectEqualStrings("claude-opus-4-7", findPricing("claude-opus-4-7-20260101").?.prefix);
    try std.testing.expectEqualStrings("claude-opus-4-6", findPricing("claude-opus-4-6-20251212").?.prefix);
    try std.testing.expectEqualStrings("claude-opus-4-5", findPricing("claude-opus-4-5-20250929").?.prefix);
    try std.testing.expectEqualStrings("claude-opus-4-1", findPricing("claude-opus-4-1-20250929").?.prefix);
    try std.testing.expectEqualStrings("claude-opus-4", findPricing("claude-opus-4-20250929").?.prefix);
}

test "findPricing haiku variants resolve to correct prefix" {
    try std.testing.expectEqualStrings("claude-haiku-4-5", findPricing("claude-haiku-4-5-20251001").?.prefix);
    try std.testing.expectEqualStrings("claude-3-5-haiku", findPricing("claude-3-5-haiku-20241022").?.prefix);
}

test "findPricing 3-7-sonnet and 3-5-sonnet do not collide" {
    try std.testing.expectEqualStrings("claude-3-7-sonnet", findPricing("claude-3-7-sonnet-20250219").?.prefix);
    try std.testing.expectEqualStrings("claude-3-5-sonnet", findPricing("claude-3-5-sonnet-20241022").?.prefix);
}

test "findPricing empty string returns null" {
    try std.testing.expect(findPricing("") == null);
}
