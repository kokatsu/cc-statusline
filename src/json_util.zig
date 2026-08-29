const std = @import("std");
const json = std.json;
const types = @import("types.zig");

const max_epoch_s = std.math.maxInt(i64) / 1000;

pub fn getObj(val: json.Value) ?json.ObjectMap {
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

pub fn getObjField(obj: json.ObjectMap, key: []const u8) ?json.ObjectMap {
    return if (obj.get(key)) |v| getObj(v) else null;
}

pub fn getStr(val: json.Value) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getF64(val: json.Value) ?f64 {
    return switch (val) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => null,
    };
}

/// The `.float` branch is range-checked: `@intFromFloat` is illegal behavior
/// outside i64, and `std.json` hands back a `.float` for any number written
/// with `.`, `e`, or `E`, so `1e20` arrives here as a finite f64 far outside
/// range. An unusable number yields null, the same as a wrong-typed one.
/// Integer literals too large for i64 arrive as `.number_string` and already
/// fall through to `else`.
pub fn getI64(val: json.Value) ?i64 {
    return switch (val) {
        .integer => |i| i,
        .float => |f| types.i64FromFloat(f),
        else => null,
    };
}

/// Unix epoch seconds from a JSON number, as milliseconds. Null when the value
/// is not a number, is negative once converted, or would overflow i64 at x1000.
///
/// "Once converted" is literal: `getI64` truncates toward zero first, so a
/// float in (-1, 0) such as -0.5 arrives here as 0 and is accepted as the
/// epoch. That is harmless — it renders as a long-past time — and keeping the
/// truncation matches `getI64`'s behavior everywhere else.
///
/// Rejecting negatives is not only range hygiene. It also keeps the downstream
/// `resets_at_ms - now_ms` / `expires_at_ms - now_ms` subtractions in
/// output.zig from underflowing, because both operands then stay non-negative.
pub fn getEpochMs(val: json.Value) ?i64 {
    const s = getI64(val) orelse return null;
    if (s < 0 or s > max_epoch_s) return null;
    return s * 1000;
}

pub fn getI64Field(obj: json.ObjectMap, key: []const u8) i64 {
    return if (obj.get(key)) |v| getI64(v) orelse 0 else 0;
}

// ============================================================
// Tests
// ============================================================

test "getObj returns object" {
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, "{\"a\":1}", .{});
    defer parsed.deinit();
    try std.testing.expect(getObj(parsed.value) != null);
}

test "getObj returns null for non-object" {
    try std.testing.expect(getObj(.null) == null);
    try std.testing.expect(getObj(.{ .integer = 42 }) == null);
    try std.testing.expect(getObj(.{ .bool = true }) == null);
}

test "getStr returns string" {
    try std.testing.expectEqualStrings("hello", getStr(.{ .string = "hello" }).?);
}

test "getStr returns null for non-string" {
    try std.testing.expect(getStr(.null) == null);
    try std.testing.expect(getStr(.{ .integer = 42 }) == null);
    try std.testing.expect(getStr(.{ .bool = true }) == null);
}

test "getF64 returns float from float" {
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), getF64(.{ .float = 3.14 }).?, 1e-10);
}

test "getF64 returns float from integer" {
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), getF64(.{ .integer = 42 }).?, 1e-10);
}

test "getF64 returns null for non-numeric" {
    try std.testing.expect(getF64(.null) == null);
    try std.testing.expect(getF64(.{ .string = "3.14" }) == null);
    try std.testing.expect(getF64(.{ .bool = true }) == null);
}

test "getI64 returns integer from integer" {
    try std.testing.expectEqual(@as(i64, 42), getI64(.{ .integer = 42 }).?);
}

test "getI64 returns integer from float truncated" {
    try std.testing.expectEqual(@as(i64, 42), getI64(.{ .float = 42.7 }).?);
}

test "getI64 returns null for non-numeric" {
    try std.testing.expect(getI64(.null) == null);
    try std.testing.expect(getI64(.{ .string = "42" }) == null);
    try std.testing.expect(getI64(.{ .bool = true }) == null);
}

test "getI64 returns null for out-of-range float" {
    // std.json yields a `.float` for any number written with `.`, `e` or `E`,
    // so these reach the conversion as finite f64 values outside i64.
    try std.testing.expect(getI64(.{ .float = 1e20 }) == null);
    try std.testing.expect(getI64(.{ .float = -1e20 }) == null);
    try std.testing.expect(getI64(.{ .float = 1e300 }) == null);
}

test "getI64 returns null for non-finite float" {
    // parseFromSlice never produces these (non-finite numbers become
    // .number_string), but getI64 is public and must not trap on them either.
    try std.testing.expect(getI64(.{ .float = std.math.nan(f64) }) == null);
    try std.testing.expect(getI64(.{ .float = std.math.inf(f64) }) == null);
    try std.testing.expect(getI64(.{ .float = -std.math.inf(f64) }) == null);
}

test "getI64 float range bounds are min-inclusive and max-exclusive" {
    // Pins the bound itself: a coarse 1e20 case would still pass if the upper
    // comparison were accidentally inclusive. -2^63 converts exactly; 2^63 is
    // the first value past maxInt(i64).
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), getI64(.{ .float = min_f }).?);
    try std.testing.expect(getI64(.{ .float = -min_f }) == null);
}

// --- getEpochMs ---

test "getEpochMs converts epoch seconds to milliseconds" {
    try std.testing.expectEqual(@as(i64, 1742479200 * 1000), getEpochMs(.{ .integer = 1742479200 }).?);
    try std.testing.expectEqual(@as(i64, 0), getEpochMs(.{ .integer = 0 }).?);
}

test "getEpochMs returns null for negative and non-numeric" {
    try std.testing.expect(getEpochMs(.{ .integer = -1 }) == null);
    try std.testing.expect(getEpochMs(.null) == null);
    try std.testing.expect(getEpochMs(.{ .string = "1742479200" }) == null);
    try std.testing.expect(getEpochMs(.{ .float = 1e20 }) == null);
}

test "getEpochMs rejects seconds that would overflow at x1000" {
    try std.testing.expectEqual(@as(i64, max_epoch_s * 1000), getEpochMs(.{ .integer = max_epoch_s }).?);
    try std.testing.expect(getEpochMs(.{ .integer = max_epoch_s + 1 }) == null);
}

test "getEpochMs accepts a float that truncates to zero" {
    // getI64 truncates toward zero before the sign test, so -0.5 becomes 0.
    try std.testing.expectEqual(@as(i64, 0), getEpochMs(.{ .float = -0.5 }).?);
}
