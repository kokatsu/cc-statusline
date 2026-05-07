const std = @import("std");
const mem = std.mem;
const Io = std.Io;

pub fn formatLocalDateTime(buf: []u8, epoch_ms: i64, utc_offset_s: i32) []const u8 {
    const local_s = @divFloor(epoch_ms, @as(i64, 1000)) + @as(i64, utc_offset_s);
    const c = epochToCivil(local_s);
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}", .{ c.month, c.day, c.hour, c.minute }) catch "??";
}

// ============================================================
// ISO 8601 Parser
// ============================================================

pub fn parseIso8601ToMs(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':') return null;

    const year = parseDecimal(s[0..4]) orelse return null;
    const month = parseDecimal(s[5..7]) orelse return null;
    const day = parseDecimal(s[8..10]) orelse return null;
    const hour = parseDecimal(s[11..13]) orelse return null;
    const minute = parseDecimal(s[14..16]) orelse return null;
    const second = parseDecimal(s[17..19]) orelse return null;

    var millis: i64 = 0;
    if (s.len > 19 and s[19] == '.') {
        var pos: usize = 20;
        var mult: i64 = 100;
        while (pos < s.len and s[pos] >= '0' and s[pos] <= '9' and mult > 0) : (pos += 1) {
            millis += @as(i64, s[pos] - '0') * mult;
            mult = @divFloor(mult, 10);
        }
    }

    const days = daysFromCivil(@intCast(year), @intCast(month), @intCast(day));
    const epoch_s = days * 86400 + @as(i64, @intCast(hour)) * 3600 + @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second));
    return epoch_s * 1000 + millis;
}

fn parseDecimal(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

pub fn computeLocalDayStartMs(now_ms: i64, utc_offset_s: i32) i64 {
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const offset_s: i64 = @intCast(utc_offset_s);
    const local_s = now_s + offset_s;
    const local_day_start_s = @divFloor(local_s, @as(i64, 86400)) * 86400;
    return (local_day_start_s - offset_s) * 1000;
}

/// Get the start of today in milliseconds (local timezone, pure Zig)
pub fn getLocalDayStartMs(io: Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, now_ms: i64) i64 {
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const offset_s = getUtcOffsetSeconds(io, env, allocator, now_s);
    return computeLocalDayStartMs(now_ms, offset_s);
}

pub fn floorToHourMs(ms: i64) i64 {
    const ms_per_hour: i64 = 3600 * 1000;
    return @divFloor(ms, ms_per_hour) * ms_per_hour;
}

// ============================================================
// TZif parser (pure Zig, no libc dependency)
// ============================================================

/// Resolve the current UTC offset in seconds for the given epoch timestamp.
/// Reads the TZ environment variable (via `env_map`) and parses TZif binary data.
/// Falls back to POSIX fixed-offset TZ strings (e.g. "JST-9"), then
/// /etc/localtime, then UTC (0) if nothing works.
pub fn getUtcOffsetSeconds(io: Io, env_map: *const std.process.Environ.Map, allocator: std.mem.Allocator, now_s: i64) i32 {
    if (env_map.get("TZ")) |tz_raw| {
        const tz = if (tz_raw.len > 0 and tz_raw[0] == ':') tz_raw[1..] else tz_raw;
        if (tz.len == 0 or mem.eql(u8, tz, "UTC") or mem.eql(u8, tz, "UTC0")) return 0;

        if (tz.len > 0 and tz[0] == '/') {
            if (readTzifOffset(io, allocator, tz, now_s)) |off| return off;
        }

        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/usr/share/zoneinfo/{s}", .{tz}) catch null;
        if (path) |p| {
            if (readTzifOffset(io, allocator, p, now_s)) |off| return off;
        }

        if (parsePosixTzFixed(tz)) |off| return off;
    }

    if (readTzifOffset(io, allocator, "/etc/localtime", now_s)) |off| return off;
    return 0;
}

/// Parse a POSIX TZ string with a fixed offset (e.g. "JST-9", "EST5", "<+0530>-5:30").
/// Returns the UTC offset in seconds (local − UTC), or null if parsing fails or
/// the string includes DST rules (not supported).
fn parsePosixTzFixed(tz: []const u8) ?i32 {
    if (tz.len == 0) return null;
    var i: usize = 0;

    if (tz[0] == '<') {
        const end = mem.indexOfScalarPos(u8, tz, 1, '>') orelse return null;
        i = end + 1;
    } else {
        while (i < tz.len and std.ascii.isAlphabetic(tz[i])) : (i += 1) {}
        if (i < 3) return null;
    }
    if (i >= tz.len) return null;

    var sign: i32 = 1;
    if (tz[i] == '+') {
        i += 1;
    } else if (tz[i] == '-') {
        sign = -1;
        i += 1;
    }

    const hours = readUint(tz, &i) orelse return null;
    var total: i32 = hours * 3600;
    if (i < tz.len and tz[i] == ':') {
        i += 1;
        const mins = readUint(tz, &i) orelse return null;
        total += mins * 60;
        if (i < tz.len and tz[i] == ':') {
            i += 1;
            const secs = readUint(tz, &i) orelse return null;
            total += secs;
        }
    }

    if (i < tz.len) return null;

    // POSIX TZ stores "time to add to local to get UTC" (positive = west of UTC),
    // so "JST-9" means UTC = local - (-9h), i.e. local is UTC+9. Negate to return local-UTC.
    return -sign * total;
}

fn readUint(s: []const u8, pos: *usize) ?i32 {
    const start = pos.*;
    while (pos.* < s.len and s[pos.*] >= '0' and s[pos.*] <= '9') : (pos.* += 1) {}
    if (pos.* == start) return null;
    return std.fmt.parseInt(i32, s[start..pos.*], 10) catch null;
}

fn readTzifOffset(io: Io, allocator: std.mem.Allocator, path: []const u8, now_s: i64) ?i32 {
    const f = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var reader = f.readerStreaming(io, &buf);
    const data = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(data);
    return parseTzif(data, now_s);
}

fn parseTzif(data: []const u8, now_s: i64) ?i32 {
    if (data.len < 44) return null;
    if (!mem.eql(u8, data[0..4], "TZif")) return null;

    const version = data[4];

    const v1_isutcnt = mem.readInt(u32, data[20..24], .big);
    const v1_isstdcnt = mem.readInt(u32, data[24..28], .big);
    const v1_leapcnt = mem.readInt(u32, data[28..32], .big);
    const v1_timecnt = mem.readInt(u32, data[32..36], .big);
    const v1_typecnt = mem.readInt(u32, data[36..40], .big);
    const v1_charcnt = mem.readInt(u32, data[40..44], .big);

    if (version == '2' or version == '3') {
        const v1_data_size = v1_timecnt * 5 + v1_typecnt * 6 + v1_charcnt + v1_leapcnt * 8 + v1_isstdcnt + v1_isutcnt;
        const v2_offset = 44 + v1_data_size;
        if (v2_offset + 44 > data.len) return null;
        if (!mem.eql(u8, data[v2_offset..][0..4], "TZif")) return null;

        const v2_timecnt = mem.readInt(u32, data[v2_offset + 32 ..][0..4], .big);
        const v2_typecnt = mem.readInt(u32, data[v2_offset + 36 ..][0..4], .big);
        return parseTzifData(data[v2_offset + 44 ..], v2_timecnt, v2_typecnt, now_s, true);
    }

    return parseTzifData(data[44..], v1_timecnt, v1_typecnt, now_s, false);
}

fn parseTzifData(data: []const u8, timecnt: u32, typecnt: u32, now_s: i64, is_64bit: bool) ?i32 {
    if (typecnt == 0) return null;
    const time_size: u32 = if (is_64bit) 8 else 4;
    const times_end = timecnt * time_size;
    const indices_end = times_end + timecnt;
    const types_offset = indices_end;

    if (data.len < types_offset + typecnt * 6) return null;

    var type_idx: u8 = 0;
    if (timecnt > 0) {
        var lo: u32 = 0;
        var hi: u32 = timecnt;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const t = readTransitionTime(data, mid, is_64bit);
            if (t <= now_s) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo > 0) {
            type_idx = data[times_end + lo - 1];
        } else {
            type_idx = findFirstNonDstType(data[types_offset..], typecnt);
        }
    }

    if (type_idx >= typecnt) return null;
    const type_off = types_offset + @as(u32, type_idx) * 6;
    if (type_off + 4 > data.len) return null;
    return mem.readInt(i32, data[type_off..][0..4], .big);
}

fn readTransitionTime(data: []const u8, idx: u32, is_64bit: bool) i64 {
    if (is_64bit) {
        const off = idx * 8;
        return mem.readInt(i64, data[off..][0..8], .big);
    } else {
        const off = idx * 4;
        return @as(i64, mem.readInt(i32, data[off..][0..4], .big));
    }
}

fn findFirstNonDstType(types_data: []const u8, typecnt: u32) u8 {
    // TZif transition indices are u8, so types beyond 256 are unreachable.
    const limit = @min(typecnt, 256);
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        const off = i * 6;
        if (off + 5 <= types_data.len and types_data[off + 4] == 0) return @intCast(i);
    }
    return 0;
}

// ============================================================
// Civil date ↔ epoch (Howard Hinnant's algorithm)
// ============================================================

const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// Days since 1970-01-01 for a proleptic Gregorian civil date.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Inverse of daysFromCivil combined with intra-day time breakdown.
/// Caller is responsible for timezone adjustment (pass `epoch_s + offset`
/// for local time; pass raw epoch seconds for UTC).
fn epochToCivil(epoch_s: i64) CivilDate {
    const days_raw: i64 = @divFloor(epoch_s, 86400);
    var rem: i64 = @mod(epoch_s, 86400);

    const hour: u8 = @intCast(@divFloor(rem, 3600));
    rem = @mod(rem, 3600);
    const minute: u8 = @intCast(@divFloor(rem, 60));
    const second: u8 = @intCast(@mod(rem, 60));

    const days = days_raw + 719468;
    const era: i64 = @divFloor(if (days >= 0) days else days - 146096, 146097);
    const doe: i64 = days - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year_adj: i64 = if (m <= 2) y + 1 else y;

    return .{
        .year = @intCast(year_adj),
        .month = m,
        .day = d,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

// ============================================================
// Tests
// ============================================================

test "parseIso8601ToMs" {
    const ts1 = parseIso8601ToMs("2025-01-15T10:30:00Z").?;
    const expected1: i64 = (daysFromCivil(2025, 1, 15) * 86400 + 10 * 3600 + 30 * 60) * 1000;
    try std.testing.expectEqual(expected1, ts1);

    const ts2 = parseIso8601ToMs("2025-01-15T10:30:00.123Z").?;
    try std.testing.expectEqual(expected1 + 123, ts2);

    try std.testing.expectEqual(@as(?i64, null), parseIso8601ToMs("invalid"));
    try std.testing.expectEqual(@as(?i64, null), parseIso8601ToMs(""));
}

test "parseDecimal overflow" {
    try std.testing.expectEqual(@as(?i64, 12345), parseDecimal("12345"));
    try std.testing.expectEqual(@as(?i64, 0), parseDecimal("0"));
    try std.testing.expectEqual(@as(?i64, null), parseDecimal("99999999999999999999"));
    try std.testing.expectEqual(@as(?i64, null), parseDecimal("12a3"));
    try std.testing.expectEqual(@as(?i64, null), parseDecimal(""));
}

test "floorToHourMs" {
    const ms = 3600 * 1000 + 30 * 60 * 1000 + 15 * 1000;
    try std.testing.expectEqual(@as(i64, 3600 * 1000), floorToHourMs(ms));
    try std.testing.expectEqual(@as(i64, 0), floorToHourMs(0));
}

test "getLocalDayStartMs returns valid day boundary" {
    const now_ms: i64 = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start = getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    try std.testing.expect(day_start <= now_ms);
    try std.testing.expect(now_ms - day_start < 86400 * 1000);
    const diff_ms = day_start - @divFloor(day_start, @as(i64, 1000)) * 1000;
    try std.testing.expectEqual(@as(i64, 0), diff_ms);
}

test "computeLocalDayStartMs UTC" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600 + 30 * 60) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, 0);
    const expected: i64 = daysFromCivil(2025, 6, 15) * 86400 * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs JST +9h" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 2 * 3600) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, 32400);
    const expected: i64 = (daysFromCivil(2025, 6, 14) * 86400 + 15 * 3600) * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs EST -5h" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 3 * 3600) * 1000;
    const day_start = computeLocalDayStartMs(now_ms, -18000);
    const expected: i64 = (daysFromCivil(2025, 6, 14) * 86400 + 5 * 3600) * 1000;
    try std.testing.expectEqual(expected, day_start);
}

test "computeLocalDayStartMs result is multiple of 1000" {
    const now_ms: i64 = (daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000 + 500;
    const day_start = computeLocalDayStartMs(now_ms, 32400);
    try std.testing.expectEqual(@as(i64, 0), @mod(day_start, 1000));
}

// --- parseIso8601ToMs edge cases ---

test "parseIso8601ToMs lowercase t separator" {
    const ts = parseIso8601ToMs("2025-01-15t10:30:00Z").?;
    const expected: i64 = (daysFromCivil(2025, 1, 15) * 86400 + 10 * 3600 + 30 * 60) * 1000;
    try std.testing.expectEqual(expected, ts);
}

test "parseIso8601ToMs milliseconds 1 digit" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.1Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 100, ts);
}

test "parseIso8601ToMs milliseconds 2 digits" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.12Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 120, ts);
}

test "parseIso8601ToMs milliseconds 4+ digits truncated" {
    const ts = parseIso8601ToMs("2025-01-15T00:00:00.1234Z").?;
    const base: i64 = daysFromCivil(2025, 1, 15) * 86400 * 1000;
    try std.testing.expectEqual(base + 123, ts);
}

test "parseIso8601ToMs leap year Feb 29" {
    const ts = parseIso8601ToMs("2024-02-29T00:00:00Z").?;
    const expected: i64 = daysFromCivil(2024, 2, 29) * 86400 * 1000;
    try std.testing.expectEqual(expected, ts);
}

// --- floorToHourMs edge cases ---

test "floorToHourMs negative timestamp" {
    try std.testing.expectEqual(@as(i64, -3600000), floorToHourMs(-1));
}

test "floorToHourMs exactly on hour boundary" {
    try std.testing.expectEqual(@as(i64, 3600000), floorToHourMs(3600000));
}

test "floorToHourMs negative exactly on hour" {
    try std.testing.expectEqual(@as(i64, -3600000), floorToHourMs(-3600000));
}

// --- formatLocalDateTime ---

test "formatLocalDateTime UTC" {
    var buf: [16]u8 = undefined;
    const epoch_ms: i64 = (daysFromCivil(2026, 3, 20) * 86400 + 15 * 3600 + 7 * 60) * 1000;
    try std.testing.expectEqualStrings("03/20 15:07", formatLocalDateTime(&buf, epoch_ms, 0));
}

test "formatLocalDateTime JST +9h shifts forward" {
    var buf: [16]u8 = undefined;
    // 2026-03-20 15:00:00 UTC + 9h = 2026-03-21 00:00 JST
    const epoch_ms: i64 = (daysFromCivil(2026, 3, 20) * 86400 + 15 * 3600) * 1000;
    try std.testing.expectEqualStrings("03/21 00:00", formatLocalDateTime(&buf, epoch_ms, 32400));
}

test "formatLocalDateTime EST -5h shifts back" {
    var buf: [16]u8 = undefined;
    // 2026-03-20 02:30 UTC - 5h = 2026-03-19 21:30 EST
    const epoch_ms: i64 = (daysFromCivil(2026, 3, 20) * 86400 + 2 * 3600 + 30 * 60) * 1000;
    try std.testing.expectEqualStrings("03/19 21:30", formatLocalDateTime(&buf, epoch_ms, -18000));
}

test "formatLocalDateTime drops sub-second precision" {
    var buf: [16]u8 = undefined;
    const epoch_ms: i64 = (daysFromCivil(2026, 3, 20) * 86400 + 15 * 3600) * 1000 + 999;
    try std.testing.expectEqualStrings("03/20 15:00", formatLocalDateTime(&buf, epoch_ms, 0));
}

// --- TZif parser ---

test "parseTzif v2 fixed offset" {
    const header_size = 44;
    var v1_header: [header_size]u8 = .{0} ** header_size;
    @memcpy(v1_header[0..4], "TZif");
    v1_header[4] = '2';
    v1_header[39] = 1;
    v1_header[43] = 4;

    var v1_type: [6]u8 = .{0} ** 6;
    std.mem.writeInt(u32, v1_type[0..4], @bitCast(@as(i32, 32400)), .big);
    const v1_abbr = [4]u8{ 'J', 'S', 'T', 0 };

    var v2_header: [header_size]u8 = .{0} ** header_size;
    @memcpy(v2_header[0..4], "TZif");
    v2_header[4] = '2';
    v2_header[39] = 1;
    v2_header[43] = 4;

    var buf: [header_size + 10 + header_size + 10]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..header_size], &v1_header);
    pos += header_size;
    @memcpy(buf[pos..][0..6], &v1_type);
    pos += 6;
    @memcpy(buf[pos..][0..4], &v1_abbr);
    pos += 4;
    @memcpy(buf[pos..][0..header_size], &v2_header);
    pos += header_size;
    @memcpy(buf[pos..][0..6], &v1_type);
    pos += 6;
    @memcpy(buf[pos..][0..4], &v1_abbr);

    const offset = parseTzif(&buf, 1700000000);
    try std.testing.expect(offset != null);
    try std.testing.expectEqual(@as(i32, 32400), offset.?);
}

test "parseTzif invalid data" {
    try std.testing.expectEqual(@as(?i32, null), parseTzif("", 0));
    try std.testing.expectEqual(@as(?i32, null), parseTzif("short", 0));
    var bad: [44]u8 = .{0} ** 44;
    @memcpy(bad[0..4], "NOPE");
    try std.testing.expectEqual(@as(?i32, null), parseTzif(&bad, 0));
}

test "parseTzif reads /etc/localtime" {
    const now_s: i64 = std.Io.Clock.real.now(std.testing.io).toSeconds();
    if (readTzifOffset(std.testing.io, std.testing.allocator, "/etc/localtime", now_s)) |offset| {
        try std.testing.expect(offset >= -14 * 3600 and offset <= 14 * 3600);
    }
}

test "parseTzif v1 format" {
    const header_size = 44;
    var data: [header_size + 10]u8 = .{0} ** (header_size + 10);
    @memcpy(data[0..4], "TZif");
    data[4] = 0;
    std.mem.writeInt(u32, data[36..40], 1, .big);
    std.mem.writeInt(u32, data[40..44], 4, .big);

    std.mem.writeInt(u32, data[44..48], @bitCast(@as(i32, 3600)), .big);
    data[48] = 0;
    data[49] = 0;
    @memcpy(data[50..54], "CET\x00");

    const offset = parseTzif(&data, 1700000000);
    try std.testing.expect(offset != null);
    try std.testing.expectEqual(@as(i32, 3600), offset.?);
}

test "parseTzifData with transition table" {
    var data: [128]u8 = .{0} ** 128;
    const timecnt: u32 = 2;
    const typecnt: u32 = 2;

    std.mem.writeInt(u32, data[0..4], @bitCast(@as(i32, 1000)), .big);
    std.mem.writeInt(u32, data[4..8], @bitCast(@as(i32, 2000)), .big);

    data[8] = 1;
    data[9] = 0;

    std.mem.writeInt(u32, data[10..14], 0, .big);
    data[14] = 0;
    data[15] = 0;
    std.mem.writeInt(u32, data[16..20], @bitCast(@as(i32, 3600)), .big);
    data[20] = 1;
    data[21] = 0;

    try std.testing.expectEqual(@as(?i32, 0), parseTzifData(&data, timecnt, typecnt, 500, false));
    try std.testing.expectEqual(@as(?i32, 3600), parseTzifData(&data, timecnt, typecnt, 1500, false));
    try std.testing.expectEqual(@as(?i32, 0), parseTzifData(&data, timecnt, typecnt, 3000, false));
}

test "findFirstNonDstType first type is non-DST" {
    const types = [_]u8{ 0x00, 0x0e, 0x10, 0x00, 0, 0 };
    try std.testing.expectEqual(@as(u8, 0), findFirstNonDstType(&types, 1));
}

test "findFirstNonDstType all DST returns 0" {
    const types = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    try std.testing.expectEqual(@as(u8, 0), findFirstNonDstType(&types, 2));
}

test "findFirstNonDstType third type is first non-DST" {
    const types = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 2), findFirstNonDstType(&types, 3));
}

test "findFirstNonDstType large typecnt does not overflow" {
    const types = [_]u8{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 0), findFirstNonDstType(&types, 1_000_000));
}

// --- POSIX TZ fixed-offset parser ---

test "parsePosixTzFixed JST-9 returns +32400" {
    try std.testing.expectEqual(@as(?i32, 32400), parsePosixTzFixed("JST-9"));
}

test "parsePosixTzFixed EST5 returns -18000" {
    try std.testing.expectEqual(@as(?i32, -18000), parsePosixTzFixed("EST5"));
}

test "parsePosixTzFixed EST+5 returns -18000" {
    try std.testing.expectEqual(@as(?i32, -18000), parsePosixTzFixed("EST+5"));
}

test "parsePosixTzFixed with minutes NST3:30" {
    try std.testing.expectEqual(@as(?i32, -(3 * 3600 + 30 * 60)), parsePosixTzFixed("NST3:30"));
}

test "parsePosixTzFixed with seconds CUSTOM1:02:03" {
    try std.testing.expectEqual(@as(?i32, -(1 * 3600 + 2 * 60 + 3)), parsePosixTzFixed("CUSTOM1:02:03"));
}

test "parsePosixTzFixed quoted name <+0530>-5:30" {
    try std.testing.expectEqual(@as(?i32, 5 * 3600 + 30 * 60), parsePosixTzFixed("<+0530>-5:30"));
}

test "parsePosixTzFixed rejects DST form EST5EDT,M3.2.0,M11.1.0" {
    try std.testing.expectEqual(@as(?i32, null), parsePosixTzFixed("EST5EDT,M3.2.0,M11.1.0"));
}

test "parsePosixTzFixed rejects zone-path Asia/Tokyo" {
    try std.testing.expectEqual(@as(?i32, null), parsePosixTzFixed("Asia/Tokyo"));
}

test "parsePosixTzFixed rejects name-only UTC" {
    try std.testing.expectEqual(@as(?i32, null), parsePosixTzFixed("UTC"));
}

test "parsePosixTzFixed rejects empty string" {
    try std.testing.expectEqual(@as(?i32, null), parsePosixTzFixed(""));
}

test "parsePosixTzFixed rejects short name AB5" {
    try std.testing.expectEqual(@as(?i32, null), parsePosixTzFixed("AB5"));
}

// --- daysFromCivil / epochToCivil ---

test "daysFromCivil epoch and Y2000" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 10957), daysFromCivil(2000, 1, 1));
}

test "daysFromCivil leap year" {
    const feb28 = daysFromCivil(2024, 2, 28);
    const feb29 = daysFromCivil(2024, 2, 29);
    const mar1 = daysFromCivil(2024, 3, 1);
    try std.testing.expectEqual(feb28 + 1, feb29);
    try std.testing.expectEqual(feb29 + 1, mar1);
}

test "daysFromCivil year boundary Dec 31 to Jan 1" {
    const dec31 = daysFromCivil(2024, 12, 31);
    const jan1 = daysFromCivil(2025, 1, 1);
    try std.testing.expectEqual(dec31 + 1, jan1);
}

test "daysFromCivil pre-epoch" {
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
}

test "epochToCivil Unix epoch" {
    const c = epochToCivil(0);
    try std.testing.expectEqual(@as(i32, 1970), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 1), c.day);
    try std.testing.expectEqual(@as(u8, 0), c.hour);
    try std.testing.expectEqual(@as(u8, 0), c.minute);
    try std.testing.expectEqual(@as(u8, 0), c.second);
}

test "epochToCivil known date 2025-06-15T12:30:45Z" {
    const days = daysFromCivil(2025, 6, 15);
    const seconds = days * 86400 + 12 * 3600 + 30 * 60 + 45;
    const c = epochToCivil(seconds);
    try std.testing.expectEqual(@as(i32, 2025), c.year);
    try std.testing.expectEqual(@as(u8, 6), c.month);
    try std.testing.expectEqual(@as(u8, 15), c.day);
    try std.testing.expectEqual(@as(u8, 12), c.hour);
    try std.testing.expectEqual(@as(u8, 30), c.minute);
    try std.testing.expectEqual(@as(u8, 45), c.second);
}

test "epochToCivil leap year Feb 29 2024" {
    const days = daysFromCivil(2024, 2, 29);
    const c = epochToCivil(days * 86400);
    try std.testing.expectEqual(@as(i32, 2024), c.year);
    try std.testing.expectEqual(@as(u8, 2), c.month);
    try std.testing.expectEqual(@as(u8, 29), c.day);
}

test "epochToCivil year 2000 boundary" {
    const days = daysFromCivil(2000, 1, 1);
    const c = epochToCivil(days * 86400);
    try std.testing.expectEqual(@as(i32, 2000), c.year);
    try std.testing.expectEqual(@as(u8, 1), c.month);
    try std.testing.expectEqual(@as(u8, 1), c.day);
}

test "epochToCivil roundtrip via daysFromCivil for many dates" {
    const samples = [_]struct { y: i32, m: u8, d: u8 }{
        .{ .y = 1970, .m = 1, .d = 1 },
        .{ .y = 1999, .m = 12, .d = 31 },
        .{ .y = 2000, .m = 2, .d = 29 },
        .{ .y = 2100, .m = 3, .d = 1 },
        .{ .y = 2400, .m = 2, .d = 29 },
        .{ .y = 1969, .m = 12, .d = 31 },
    };
    for (samples) |s| {
        const days = daysFromCivil(s.y, s.m, s.d);
        const c = epochToCivil(days * 86400);
        try std.testing.expectEqual(s.y, c.year);
        try std.testing.expectEqual(s.m, c.month);
        try std.testing.expectEqual(s.d, c.day);
    }
}
