//! API cost the transcripts never record, mostly agent hook requests.
//!
//! Claude Code's `cost.total_cost_usd` includes those requests but is per
//! session, so it cannot feed `today` or the 5h block directly. Each call
//! carrying a session JSON compares it with the session's transcript cost
//! `T` and keeps the growth of the gap as timestamped increments, one state
//! file per session; the increments are then summed into any time window.
const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const scan = @import("scan.zig");
const types = @import("types.zig");
const TestTree = @import("test_tree.zig").TestTree;

pub const dir_name = "statusline-unlogged";
const state_ext = ".bin";
const magic = [4]u8{ 'C', 'C', 'U', 'L' };
const version: u32 = 1;
const max_state_bytes: usize = 1 * 1024 * 1024;
/// A writer holds its temp file for milliseconds; one older than this was
/// left by a process killed mid-write.
const stale_tmp_ms: i64 = 60 * 1000;

/// Increments older than this are never summed: `today` starts within the
/// last 24h, the block within the last 5h, plus an hour of timezone margin.
pub const retention_ms: i64 = 25 * 60 * 60 * 1000;

/// Below this, a gap change is float noise: `fullScan` re-sums lifetime
/// costs while `diffScan` accumulates them, so `T` wobbles by ULPs.
const epsilon: f64 = 1e-9;

pub const Increment = struct {
    timestamp_ms: i64,
    amount: f64,
};

/// One of the session's transcript files as last observed.
pub const FileRecord = struct {
    path: []const u8,
    size: i64,
    cost: f64,
};

pub const State = struct {
    transcript_path: []const u8,
    last_total: f64,
    last_transcript_cost: f64,
    /// Negative gap change no stored increment could absorb, held to cancel
    /// a later positive one. The stdin total is taken when Claude Code
    /// spawns the statusline and `T` after, so either can run ahead.
    pending_negative: f64,
    files: []const FileRecord,
    /// Oldest first, every amount > 0.
    increments: []const Increment,
};

/// Fold one observation into the session state. `transcript_cost` and
/// `files` must describe the same moment as far as the caller can tell.
pub fn observe(
    allocator: std.mem.Allocator,
    prev: ?State,
    transcript_path: []const u8,
    total: f64,
    transcript_cost: f64,
    files: []const FileRecord,
    now_ms: i64,
) !State {
    var increments: std.ArrayList(Increment) = .empty;
    if (prev) |p| {
        for (p.increments) |inc| {
            if (inc.timestamp_ms >= now_ms - retention_ms) try increments.append(allocator, inc);
        }
    }

    // A first sight takes the current gap as the baseline: for a resumed
    // session it was already counted before. `T` running ahead of the total
    // at that moment is held as pending so the total catching up is not
    // recorded as spend.
    const p = prev orelse return firstObservation(increments, transcript_path, total, transcript_cost, files);
    if (!mem.eql(u8, p.transcript_path, transcript_path)) {
        return firstObservation(increments, transcript_path, total, transcript_cost, files);
    }

    var state = p;
    state.files = files;
    state.increments = increments.items;

    const delta = (total - p.last_total) - (transcript_cost - p.last_transcript_cost);
    if (@abs(delta) < epsilon) return state;

    state.last_total = total;
    state.last_transcript_cost = transcript_cost;
    if (delta > 0) {
        const absorbed = @min(state.pending_negative, delta);
        state.pending_negative -= absorbed;
        const rest = delta - absorbed;
        if (rest >= epsilon) try increments.append(allocator, .{ .timestamp_ms = now_ms, .amount = rest });
    } else {
        // Cancel from the newest increments so a correction lands in the
        // window the overcount went to, not in the current one.
        var need = -delta;
        while (need > 0 and increments.items.len > 0) {
            const last = &increments.items[increments.items.len - 1];
            if (last.amount > need) {
                last.amount -= need;
                need = 0;
            } else {
                need -= last.amount;
                _ = increments.pop();
            }
        }
        state.pending_negative += need;
    }
    state.increments = increments.items;
    return state;
}

fn firstObservation(
    increments: std.ArrayList(Increment),
    transcript_path: []const u8,
    total: f64,
    transcript_cost: f64,
    files: []const FileRecord,
) State {
    return .{
        .transcript_path = transcript_path,
        .last_total = total,
        .last_transcript_cost = transcript_cost,
        .pending_negative = @max(0, transcript_cost - total),
        .files = files,
        .increments = increments.items,
    };
}

// ============================================================
// Session transcript cost
// ============================================================

/// The session's transcript files that exist now: the main transcript and
/// `<transcript minus .jsonl>/subagents/*.jsonl`. Subagent requests are in
/// `total_cost_usd`, so leaving their files out would count them as unlogged.
pub fn sessionFiles(io: Io, allocator: std.mem.Allocator, transcript_path: []const u8) []const scan.FileInfo {
    var files: std.ArrayList(scan.FileInfo) = .empty;
    if (Io.Dir.cwd().statFile(io, transcript_path, .{})) |st| {
        files.append(allocator, .{ .path = transcript_path, .size = @intCast(st.size) }) catch {};
    } else |_| {}

    if (!mem.endsWith(u8, transcript_path, ".jsonl")) return files.items;
    const sub_path = std.fmt.allocPrint(allocator, "{s}/subagents", .{transcript_path[0 .. transcript_path.len - ".jsonl".len]}) catch return files.items;
    var dir = Io.Dir.openDirAbsolute(io, sub_path, .{ .iterate = true }) catch return files.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, entry.name }) catch continue;
        files.append(allocator, .{ .path = path, .size = @intCast(st.size) }) catch continue;
    }
    return files.items;
}

const TranscriptCost = struct {
    total: f64,
    files: []const FileRecord,
};

/// Lifetime cost of each session file, preferring the cheapest source that
/// is current: the scan's list, then the value remembered at the same size,
/// then a full parse. The list holds only files modified in the last 25h and
/// misses files created since the last full scan; a file that dropped out
/// has not changed for 25h, so its remembered value still holds. Files
/// remembered but gone from disk keep counting: their requests stay in the
/// session total. Fails rather than return a partial sum.
fn transcriptCost(
    io: Io,
    allocator: std.mem.Allocator,
    current: []const scan.FileInfo,
    tracked: []const scan.CachedFileEntry,
    remembered: []const FileRecord,
) !TranscriptCost {
    var files: std.ArrayList(FileRecord) = .empty;
    var sum: f64 = 0;
    for (current) |c| {
        const rec: FileRecord = blk: {
            for (tracked) |t| {
                // The scan ran after `current` was stat'ed, so a larger
                // tracked size is the same file, read later.
                if (mem.eql(u8, t.path, c.path) and t.file_size >= c.size) {
                    break :blk .{ .path = c.path, .size = t.file_size, .cost = t.lifetime_cost };
                }
            }
            for (remembered) |r| {
                if (mem.eql(u8, r.path, c.path) and r.size == c.size) break :blk r;
            }
            // Leaving the file out would read as its cost turning unlogged.
            const parsed = scan.parseFileLifetimeCost(io, allocator, c.path) orelse return error.Unreadable;
            break :blk .{ .path = c.path, .size = parsed.size, .cost = parsed.cost };
        };
        try files.append(allocator, rec);
        sum += rec.cost;
    }
    outer: for (remembered) |r| {
        for (current) |c| {
            if (mem.eql(u8, r.path, c.path)) continue :outer;
        }
        try files.append(allocator, r);
        sum += r.cost;
    }
    return .{ .total = sum, .files = files.items };
}

// ============================================================
// State files
// ============================================================

/// Null for an id that could escape the directory or is not one Claude Code
/// produces (UUIDs).
pub fn statePath(allocator: std.mem.Allocator, config_dir: []const u8, session_id: []const u8) ?[]const u8 {
    if (session_id.len == 0 or session_id.len > 128) return null;
    for (session_id) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}", .{ config_dir, dir_name, session_id, state_ext }) catch null;
}

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, comptime T: type) ?T {
        if (self.data.len - self.pos < @sizeOf(T)) return null;
        const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
        const v: T = @bitCast(mem.readInt(Int, self.data[self.pos..][0..@sizeOf(T)], .little));
        self.pos += @sizeOf(T);
        return v;
    }

    fn bytes(self: *Cursor) ?[]const u8 {
        const len = self.take(u16) orelse return null;
        if (self.data.len - self.pos < len) return null;
        const out = self.data[self.pos..][0..len];
        self.pos += len;
        return out;
    }
};

/// Slices in the result borrow from `content`.
fn parseState(allocator: std.mem.Allocator, content: []const u8) ?State {
    if (content.len < magic.len or !mem.eql(u8, content[0..magic.len], &magic)) return null;
    var c: Cursor = .{ .data = content, .pos = magic.len };
    if ((c.take(u32) orelse return null) != version) return null;
    const transcript_path = c.bytes() orelse return null;
    const last_total = c.take(f64) orelse return null;
    const last_transcript_cost = c.take(f64) orelse return null;
    const pending_negative = c.take(f64) orelse return null;

    const file_count = c.take(u32) orelse return null;
    const files = allocator.alloc(FileRecord, @min(file_count, content.len)) catch return null;
    if (files.len != file_count) return null;
    for (files) |*f| {
        f.path = c.bytes() orelse return null;
        f.size = c.take(i64) orelse return null;
        f.cost = c.take(f64) orelse return null;
    }

    const inc_count = c.take(u32) orelse return null;
    const increments = allocator.alloc(Increment, @min(inc_count, content.len)) catch return null;
    if (increments.len != inc_count) return null;
    for (increments) |*inc| {
        inc.timestamp_ms = c.take(i64) orelse return null;
        inc.amount = c.take(f64) orelse return null;
    }

    return .{
        .transcript_path = transcript_path,
        .last_total = last_total,
        .last_transcript_cost = last_transcript_cost,
        .pending_negative = pending_negative,
        .files = files,
        .increments = increments,
    };
}

fn writeVal(w: *std.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    try w.writeInt(Int, @bitCast(value), .little);
}

fn writeBytes(w: *std.Io.Writer, b: []const u8) !void {
    try writeVal(w, @as(u16, @intCast(b.len)));
    try w.writeAll(b);
}

fn serializeState(w: *std.Io.Writer, state: State) !void {
    try w.writeAll(&magic);
    try writeVal(w, version);
    try writeBytes(w, state.transcript_path);
    try writeVal(w, state.last_total);
    try writeVal(w, state.last_transcript_cost);
    try writeVal(w, state.pending_negative);
    try writeVal(w, @as(u32, @intCast(state.files.len)));
    for (state.files) |f| {
        try writeBytes(w, f.path);
        try writeVal(w, f.size);
        try writeVal(w, f.cost);
    }
    try writeVal(w, @as(u32, @intCast(state.increments.len)));
    for (state.increments) |inc| {
        try writeVal(w, inc.timestamp_ms);
        try writeVal(w, inc.amount);
    }
}

fn readState(io: Io, allocator: std.mem.Allocator, path: []const u8) ?State {
    var f = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    return readStateFile(io, allocator, f);
}

fn readStateFile(io: Io, allocator: std.mem.Allocator, f: Io.File) ?State {
    var rbuf: [4096]u8 = undefined;
    var reader = f.readerStreaming(io, &rbuf);
    const content = reader.interface.allocRemaining(allocator, .limited(max_state_bytes)) catch return null;
    return parseState(allocator, content);
}

/// Null for a state past retention as well as a missing one, so a session
/// seen again after that starts over like `withUnlogged` would have made it.
fn readLiveState(io: Io, allocator: std.mem.Allocator, path: []const u8, now_ms: i64) ?State {
    var f = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    if (isExpired(st.mtime, now_ms, retention_ms)) return null;
    return readStateFile(io, allocator, f);
}

fn isExpired(mtime: Io.Timestamp, now_ms: i64, max_age_ms: i64) bool {
    const mtime_ms: i64 = @intCast(@divFloor(mtime.nanoseconds, std.time.ns_per_ms));
    return now_ms - mtime_ms > max_age_ms;
}

/// Replaces the whole file through a rename, so a concurrent writer for the
/// same session leaves one self-consistent state rather than a mix.
fn writeState(io: Io, allocator: std.mem.Allocator, path: []const u8, state: State) void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    serializeState(&aw.writer, state) catch return;

    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };
    }
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = scan.tmpPath(io, &tmp_buf, path) orelse return;
    var f = Io.Dir.createFileAbsolute(io, tmp, .{ .exclusive = true }) catch return;
    const written = blk: {
        f.writeStreamingAll(io, aw.written()) catch break :blk false;
        break :blk true;
    };
    f.close(io);
    if (!written) {
        Io.Dir.deleteFileAbsolute(io, tmp) catch {};
        return;
    }
    Io.Dir.renameAbsolute(tmp, path, io) catch Io.Dir.deleteFileAbsolute(io, tmp) catch {};
}

/// Record one observation of a session. `session_files` must be the list
/// passed to the scan as fresh, and `tracked` the scan's file list.
pub fn record(
    io: Io,
    allocator: std.mem.Allocator,
    config_dir: []const u8,
    session_id: []const u8,
    transcript_path: []const u8,
    total: f64,
    session_files: []const scan.FileInfo,
    tracked: []const scan.CachedFileEntry,
    now_ms: i64,
) void {
    const path = statePath(allocator, config_dir, session_id) orelse return;
    const prev = readLiveState(io, allocator, path, now_ms);
    // A changed transcript path starts over, so files remembered under the
    // old one must not carry into `T`.
    const remembered: []const FileRecord = if (prev) |p|
        (if (mem.eql(u8, p.transcript_path, transcript_path)) p.files else &.{})
    else
        &.{};
    const t = transcriptCost(io, allocator, session_files, tracked, remembered) catch return;
    const state = observe(allocator, prev, transcript_path, total, t.total, t.files, now_ms) catch return;
    writeState(io, allocator, path, state);
}

// ============================================================
// Aggregation
// ============================================================

/// `result` with every session's increments added to `today` and to the
/// block, whose burn rate is recomputed. Also deletes state files no session
/// has written for `retention_ms` and temp files abandoned mid-write, so
/// stdin-less callers keep the directory bounded too.
pub fn withUnlogged(io: Io, allocator: std.mem.Allocator, config_dir: []const u8, result: types.ScanResult, now_ms: i64, day_start_ms: i64) types.ScanResult {
    const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_dir, dir_name }) catch return result;
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    var today: f64 = 0;
    var block: f64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const is_state = mem.endsWith(u8, entry.name, state_ext);
        const is_tmp = mem.endsWith(u8, entry.name, ".tmp");
        if (!is_state and !is_tmp) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (isExpired(st.mtime, now_ms, if (is_tmp) stale_tmp_ms else retention_ms)) {
            dir.deleteFile(io, entry.name) catch {};
            continue;
        }
        if (is_tmp) continue;

        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const state = readState(io, allocator, path) orelse continue;
        for (state.increments) |inc| {
            if (inc.timestamp_ms >= day_start_ms) today += inc.amount;
            if (result.block) |b| {
                if (inc.timestamp_ms >= b.start_ms and inc.timestamp_ms <= b.end_ms) block += inc.amount;
            }
        }
    }

    var out = result;
    out.today_cost += today;
    if (out.block) |*b| {
        b.cost += block;
        b.burn_rate_per_hr = scan.computeBurnRate(b.cost, b.start_ms, now_ms);
    }
    return out;
}

// ============================================================
// Tests
// ============================================================

fn testObserve(alloc: std.mem.Allocator, prev: ?State, total: f64, t: f64, now_ms: i64) !State {
    return observe(alloc, prev, "/p/s.jsonl", total, t, &.{}, now_ms);
}

fn incrementSum(state: State) f64 {
    var sum: f64 = 0;
    for (state.increments) |inc| sum += inc.amount;
    return sum;
}

test "first observation records no increment, even mid-session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try testObserve(arena.allocator(), null, 5.0, 3.0, 1000);
    try std.testing.expectEqual(@as(usize, 0), s.increments.len);
    try std.testing.expectEqual(@as(f64, 5.0), s.last_total);
    try std.testing.expectEqual(@as(f64, 0), s.pending_negative);
}

test "hook cost between observations becomes an increment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1.0, 1.0, 1000);
    // Transcript +0.5, total +0.7: 0.2 never reached the transcript.
    s = try testObserve(a, s, 1.7, 1.5, 2000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), incrementSum(s), 1e-12);
    try std.testing.expectEqual(@as(i64, 2000), s.increments[0].timestamp_ms);
}

test "unchanged observation records nothing and keeps the snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1.0, 1.0, 1000);
    s = try testObserve(a, s, 1.0 + 1e-12, 1.0, 2000);
    try std.testing.expectEqual(@as(usize, 0), s.increments.len);
    try std.testing.expectEqual(@as(f64, 1.0), s.last_total);
}

test "transcript running ahead is held as pending and cancels the catch-up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 1, 1000);
    s = try testObserve(a, s, 1, 2, 2000);
    try std.testing.expectApproxEqAbs(@as(f64, 1), s.pending_negative, 1e-12);
    s = try testObserve(a, s, 2, 2, 3000);
    try std.testing.expectEqual(@as(f64, 0), incrementSum(s));
    try std.testing.expectApproxEqAbs(@as(f64, 0), s.pending_negative, 1e-12);
    // Same values again: nothing more.
    s = try testObserve(a, s, 2, 2, 4000);
    try std.testing.expectEqual(@as(f64, 0), incrementSum(s));
}

test "total running ahead is cancelled from the increment it created" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 1, 1000);
    s = try testObserve(a, s, 2, 1, 2000);
    try std.testing.expectApproxEqAbs(@as(f64, 1), incrementSum(s), 1e-12);
    s = try testObserve(a, s, 2, 2, 3000);
    try std.testing.expectEqual(@as(usize, 0), s.increments.len);
    try std.testing.expectEqual(@as(f64, 0), s.pending_negative);
}

test "both drift directions keep the real hook cost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Total ahead, then a 0.3 hook, then the transcript catches up.
    var s = try testObserve(a, null, 1, 1, 1000);
    s = try testObserve(a, s, 2, 1, 2000);
    s = try testObserve(a, s, 2.3, 1, 3000);
    s = try testObserve(a, s, 2.3, 2, 4000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), incrementSum(s), 1e-12);
    // Transcript ahead, then the total catches up with a 0.4 hook on top.
    var t = try testObserve(a, null, 1, 1, 1000);
    t = try testObserve(a, t, 1, 2, 2000);
    t = try testObserve(a, t, 2.4, 2, 3000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), incrementSum(t), 1e-12);
}

test "negative change beyond stored increments carries into pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 1, 1000);
    s = try testObserve(a, s, 1.5, 1, 2000);
    s = try testObserve(a, s, 1.5, 2.25, 3000);
    try std.testing.expectEqual(@as(usize, 0), s.increments.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), s.pending_negative, 1e-12);
}

test "first observation with the transcript ahead seeds pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 2, 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 1), s.pending_negative, 1e-12);
    const caught_up = try testObserve(a, s, 2, 2, 2000);
    try std.testing.expectEqual(@as(f64, 0), incrementSum(caught_up));
    const with_hook = try testObserve(a, s, 2.2, 2, 2000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), incrementSum(with_hook), 1e-12);
    // The total ahead at first sight is indistinguishable from a resumed
    // session's earlier unlogged cost; the catch-up then eats a later hook.
    s = try testObserve(a, null, 2, 1, 1000);
    s = try testObserve(a, s, 2, 2, 2000);
    s = try testObserve(a, s, 2.2, 2, 3000);
    try std.testing.expectEqual(@as(f64, 0), incrementSum(s));
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), s.pending_negative, 1e-12);
}

test "a changed transcript path starts over but keeps increments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 1, 1000);
    s = try testObserve(a, s, 1.5, 1, 2000);
    s = try observe(a, s, "/p/other.jsonl", 9, 3, &.{}, 3000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), incrementSum(s), 1e-12);
    try std.testing.expectEqual(@as(f64, 9), s.last_total);
}

test "increments past retention are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try testObserve(a, null, 1, 1, 0);
    s = try testObserve(a, s, 2, 1, 1000);
    s = try testObserve(a, s, 2, 1, 1000 + retention_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), s.increments.len);
}

test "state round-trips through its file format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]FileRecord{
        .{ .path = "/p/s.jsonl", .size = 10, .cost = 0.5 },
        .{ .path = "/p/s/subagents/agent-1.jsonl", .size = 20, .cost = 0.25 },
    };
    const incs = [_]Increment{ .{ .timestamp_ms = 5, .amount = 0.1 }, .{ .timestamp_ms = 6, .amount = 0.2 } };
    const state: State = .{
        .transcript_path = "/p/s.jsonl",
        .last_total = 1.5,
        .last_transcript_cost = 0.75,
        .pending_negative = 0.125,
        .files = &files,
        .increments = &incs,
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try serializeState(&aw.writer, state);
    const bytes = aw.written();
    const back = parseState(a, bytes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(state.transcript_path, back.transcript_path);
    try std.testing.expectEqual(state.pending_negative, back.pending_negative);
    try std.testing.expectEqualStrings(files[1].path, back.files[1].path);
    try std.testing.expectEqual(files[1].size, back.files[1].size);
    try std.testing.expectEqual(incs[1].amount, back.increments[1].amount);
    // Every truncation is rejected, never misread.
    for (0..bytes.len) |n| try std.testing.expect(parseState(a, bytes[0..n]) == null);
}

test "statePath rejects ids that could leave the directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "/c/statusline-unlogged/0a1b-c2.bin",
        statePath(a, "/c", "0a1b-c2").?,
    );
    try std.testing.expect(statePath(a, "/c", "") == null);
    try std.testing.expect(statePath(a, "/c", "../x") == null);
    try std.testing.expect(statePath(a, "/c", "a/b") == null);
}

fn writeTestFile(tree: TestTree, rel: []const u8, content: []const u8) !void {
    var f = try Io.Dir.createFileAbsolute(std.testing.io, try tree.path(rel), .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, content);
}

const line_a =
    \\{"timestamp":"2025-06-15T10:00:00Z","message":{"id":"msg_a","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":100}},"requestId":"req_a"}
;
const line_b =
    \\{"timestamp":"2025-06-15T10:01:00Z","message":{"id":"msg_b","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":2000,"output_tokens":200}},"requestId":"req_b"}
;

test "sessionFiles finds the transcript and its subagents only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(std.testing.io, "p/s/subagents");
    try writeTestFile(tree, "p/s.jsonl", line_a ++ "\n");
    try writeTestFile(tree, "p/s/subagents/agent-1.jsonl", line_b ++ "\n");
    try writeTestFile(tree, "p/s/subagents/agent-1.meta.json", "{}");
    try writeTestFile(tree, "p/other.jsonl", line_b ++ "\n");

    const files = sessionFiles(std.testing.io, a, try tree.path("p/s.jsonl"));
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(try tree.path("p/s.jsonl"), files[0].path);
    try std.testing.expectEqualStrings(try tree.path("p/s/subagents/agent-1.jsonl"), files[1].path);
}

test "transcriptCost prefers the scan, then the remembered value, then a parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(std.testing.io, "p");
    try writeTestFile(tree, "p/tracked.jsonl", line_a ++ "\n");
    try writeTestFile(tree, "p/remembered.jsonl", line_a ++ "\n");
    try writeTestFile(tree, "p/new.jsonl", line_b ++ "\n");
    const tracked_path = try tree.path("p/tracked.jsonl");
    const remembered_path = try tree.path("p/remembered.jsonl");
    const new_path = try tree.path("p/new.jsonl");
    const current = [_]scan.FileInfo{
        .{ .path = tracked_path, .size = 100 },
        .{ .path = remembered_path, .size = 200 },
        .{ .path = new_path, .size = 300 },
    };
    const tracked = [_]scan.CachedFileEntry{
        .{ .path = tracked_path, .file_size = 100, .per_file_cost = 0, .lifetime_cost = 1.0, .parsed_size = 100 },
    };
    const remembered = [_]FileRecord{
        .{ .path = remembered_path, .size = 200, .cost = 2.0 },
        // Gone from disk, still part of the session's spend.
        .{ .path = "/gone/agent.jsonl", .size = 5, .cost = 4.0 },
    };
    const t = try transcriptCost(std.testing.io, a, &current, &tracked, &remembered);
    const parsed = scan.parseFileLifetimeCost(std.testing.io, a, new_path).?.cost;
    try std.testing.expect(parsed > 0);
    try std.testing.expectApproxEqAbs(1.0 + 2.0 + parsed + 4.0, t.total, 1e-12);
    try std.testing.expectEqual(@as(usize, 4), t.files.len);
}

test "transcriptCost re-parses a remembered file whose size changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(std.testing.io, "p");
    try writeTestFile(tree, "p/s.jsonl", line_a ++ "\n" ++ line_b ++ "\n");
    const path = try tree.path("p/s.jsonl");
    const current = [_]scan.FileInfo{.{ .path = path, .size = 999 }};
    const remembered = [_]FileRecord{.{ .path = path, .size = 1, .cost = 100 }};
    const t = try transcriptCost(std.testing.io, a, &current, &.{}, &remembered);
    try std.testing.expectApproxEqAbs(scan.parseFileLifetimeCost(std.testing.io, a, path).?.cost, t.total, 1e-12);
}

test "record writes a state the next call builds on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    try tree.tmp.dir.createDirPath(std.testing.io, "projects/p");
    try writeTestFile(tree, "projects/p/s.jsonl", line_a ++ "\n");
    const transcript = try tree.path("projects/p/s.jsonl");

    // First sight of a session whose file no scan has listed yet.
    var files = sessionFiles(std.testing.io, a, transcript);
    record(std.testing.io, a, tree.root, "s", transcript, 0.5, files, &.{}, 1000);
    const path = statePath(a, tree.root, "s").?;
    const first = readState(std.testing.io, a, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), first.increments.len);

    // A response lands in the transcript, and a hook adds 0.3 off-transcript.
    try writeTestFile(tree, "projects/p/s.jsonl", line_a ++ "\n" ++ line_b ++ "\n");
    const added = scan.parseFileLifetimeCost(std.testing.io, a, transcript).?.cost - first.last_transcript_cost;
    files = sessionFiles(std.testing.io, a, transcript);
    record(std.testing.io, a, tree.root, "s", transcript, 0.5 + added + 0.3, files, &.{}, 2000);
    const second = readState(std.testing.io, a, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), incrementSum(second), 1e-9);
}

fn writeTestState(io: Io, alloc: std.mem.Allocator, config_dir: []const u8, id: []const u8, increments: []const Increment) !void {
    writeState(io, alloc, statePath(alloc, config_dir, id).?, .{
        .transcript_path = "/p/s.jsonl",
        .last_total = 0,
        .last_transcript_cost = 0,
        .pending_negative = 0,
        .files = &.{},
        .increments = increments,
    });
}

fn realNowMs() i64 {
    return Io.Clock.real.now(std.testing.io).toMilliseconds();
}

test "withUnlogged adds every session's increments to today and the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    const io = std.testing.io;

    const now_ms = realNowMs();
    const hour: i64 = 3600 * 1000;
    const day_start_ms = now_ms - 10 * hour;
    try writeTestState(io, a, tree.root, "s1", &.{
        .{ .timestamp_ms = now_ms - 12 * hour, .amount = 1.0 }, // before today
        .{ .timestamp_ms = now_ms - 6 * hour, .amount = 0.5 }, // today, before the block
        .{ .timestamp_ms = now_ms - hour, .amount = 0.25 }, // today and block
    });
    try writeTestState(io, a, tree.root, "s2", &.{.{ .timestamp_ms = now_ms - 2 * hour, .amount = 0.125 }});

    const base: types.ScanResult = .{
        .today_cost = 10,
        .block = .{ .start_ms = now_ms - 3 * hour, .end_ms = now_ms + 2 * hour, .cost = 2, .burn_rate_per_hr = 0 },
    };
    const out = withUnlogged(io, a, tree.root, base, now_ms, day_start_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 10 + 0.5 + 0.25 + 0.125), out.today_cost, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2 + 0.25 + 0.125), out.block.?.cost, 1e-12);
    try std.testing.expectApproxEqAbs(scan.computeBurnRate(2.375, now_ms - 3 * hour, now_ms), out.block.?.burn_rate_per_hr, 1e-12);

    // No block: increments go to today only.
    const no_block = withUnlogged(io, a, tree.root, .{ .today_cost = 1 }, now_ms, day_start_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 1 + 0.875), no_block.today_cost, 1e-12);
    try std.testing.expectEqual(@as(?types.BlockInfo, null), no_block.block);
}

test "withUnlogged deletes stale states and abandoned temp files only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    const io = std.testing.io;

    const now_ms = realNowMs();
    try writeTestState(io, a, tree.root, "s1", &.{.{ .timestamp_ms = now_ms, .amount = 0.5 }});
    // A temp file is a half-written state; it must never be summed.
    try writeTestFile(tree, dir_name ++ "/s2.bin.abc.tmp", "garbage");
    const dir_rel = dir_name;

    // Within both limits: everything stays, the temp file is not read.
    var out = withUnlogged(io, a, tree.root, .{}, now_ms, now_ms - 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), out.today_cost, 1e-12);
    try tree.tmp.dir.access(io, dir_rel ++ "/s1.bin", .{});
    try tree.tmp.dir.access(io, dir_rel ++ "/s2.bin.abc.tmp", .{});

    // Two minutes on: the temp file is abandoned, the state still live.
    out = withUnlogged(io, a, tree.root, .{}, now_ms + 2 * 60 * 1000, now_ms - 1000);
    try tree.tmp.dir.access(io, dir_rel ++ "/s1.bin", .{});
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(io, dir_rel ++ "/s2.bin.abc.tmp", .{}));

    // Past retention: the state goes, and with it its increments.
    out = withUnlogged(io, a, tree.root, .{}, now_ms + retention_ms + 60 * 1000, now_ms - 1000);
    try std.testing.expectEqual(@as(f64, 0), out.today_cost);
    try std.testing.expectError(error.FileNotFound, tree.tmp.dir.access(io, dir_rel ++ "/s1.bin", .{}));
}

test "record skips an observation whose transcript cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    const io = std.testing.io;
    try tree.tmp.dir.createDirPath(io, "projects/p");
    try writeTestFile(tree, "projects/p/s.jsonl", line_a ++ "\n");
    const transcript = try tree.path("projects/p/s.jsonl");

    const now_ms = realNowMs();
    record(io, a, tree.root, "s", transcript, 0.5, sessionFiles(io, a, transcript), &.{}, now_ms);
    const path = statePath(a, tree.root, "s").?;
    const before = readState(io, a, path) orelse return error.TestUnexpectedResult;

    // Stat'ed at a new size, gone by the time it is parsed.
    try tree.tmp.dir.deleteFile(io, "projects/p/s.jsonl");
    const vanished = [_]scan.FileInfo{.{ .path = transcript, .size = 99999 }};
    record(io, a, tree.root, "s", transcript, 0.5, &vanished, &.{}, now_ms + 1000);

    const after = readState(io, a, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), after.increments.len);
    try std.testing.expectEqual(before.last_transcript_cost, after.last_transcript_cost);
}

test "record starts over from a state past retention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    const io = std.testing.io;
    try tree.tmp.dir.createDirPath(io, "projects/p");
    try writeTestFile(tree, "projects/p/s.jsonl", line_a ++ "\n");
    const transcript = try tree.path("projects/p/s.jsonl");

    const now_ms = realNowMs();
    record(io, a, tree.root, "s", transcript, 0.5, sessionFiles(io, a, transcript), &.{}, now_ms);
    // Unobserved for longer than retention, the gap grew by 2.
    const later = now_ms + retention_ms + 60 * 1000;
    record(io, a, tree.root, "s", transcript, 2.5, sessionFiles(io, a, transcript), &.{}, later);

    const state = readState(io, a, statePath(a, tree.root, "s").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), state.increments.len);
    try std.testing.expectEqual(@as(f64, 2.5), state.last_total);
}

test "record skips an observation whose transcript fails mid-read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try TestTree.init(a);
    defer tree.deinit();
    const io = std.testing.io;
    try tree.tmp.dir.createDirPath(io, "projects/p");
    try writeTestFile(tree, "projects/p/s.jsonl", line_a ++ "\n");
    const transcript = try tree.path("projects/p/s.jsonl");

    const now_ms = realNowMs();
    record(io, a, tree.root, "s", transcript, 0.5, sessionFiles(io, a, transcript), &.{}, now_ms);

    // A directory at the path opens, then fails on read.
    try tree.tmp.dir.deleteFile(io, "projects/p/s.jsonl");
    try tree.tmp.dir.createDirPath(io, "projects/p/s.jsonl");
    const broken = [_]scan.FileInfo{.{ .path = transcript, .size = 99999 }};
    record(io, a, tree.root, "s", transcript, 0.5, &broken, &.{}, now_ms + 1000);

    const state = readState(io, a, statePath(a, tree.root, "s").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), state.increments.len);
}
