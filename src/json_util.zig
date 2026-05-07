const std = @import("std");
const json = std.json;

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

pub fn getI64(val: json.Value) ?i64 {
    return switch (val) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => null,
    };
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
