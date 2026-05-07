const std = @import("std");
const json = std.json;
const mem = std.mem;
const Io = std.Io;
const pricing = @import("pricing.zig");
const time = @import("time.zig");
const types = @import("types.zig");
// Module-level io handle: cc-statusline is single-threaded and scanning touches
// dozens of callsites, so threading io through every helper balloons the diff.
var g_io: Io = undefined;

const ScanResult = types.ScanResult;
const BlockInfo = types.BlockInfo;
const ms_per_min = types.ms_per_min;
const TokenUsage = pricing.TokenUsage;

// ============================================================
// Constants
// ============================================================

pub const cache_path = "/tmp/cc-statusline-cache.bin";
const cache_ttl_s: i64 = 30;
const block_duration_ms: i64 = 5 * 60 * 60 * 1000;
const scan_window_ms: i64 = 25 * 60 * 60 * 1000; // 25h: 24h + 1h margin for timezone offsets

const cache_magic = [4]u8{ 'C', 'C', 'S', 'L' };
const cache_ver: u32 = 5;
const file_list_ttl_s: i64 = 300;
// Actual caches are ~tens of KB; cap at 1 MiB to fail fast on corruption.
const cache_max_bytes: usize = 1 * 1024 * 1024;

// ============================================================
// Types
// ============================================================

pub const TranscriptEntry = struct {
    timestamp_ms: i64,
    model: []const u8,
    usage: TokenUsage,
};

const CachedFileEntry = struct {
    path: []const u8,
    file_size: i64,
    per_file_cost: f64,
    parsed_size: i64,
};

const CacheResult = struct {
    scan: ScanResult,
    files: []const CachedFileEntry,
    write_time_s: i64,
    last_full_scan_s: i64,
    day_start_ms: i64,
};

// ============================================================
// Transcript Scanning
// ============================================================

fn resolveConfigDir(allocator: std.mem.Allocator, claude_config_dir: ?[]const u8, home: ?[]const u8) ![]const u8 {
    if (claude_config_dir) |dir| {
        return try allocator.dupe(u8, dir);
    }
    const h = home orelse return error.NoHome;
    return try std.fmt.allocPrint(allocator, "{s}/.claude", .{h});
}

fn getConfigDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    return resolveConfigDir(allocator, env.get("CLAUDE_CONFIG_DIR"), env.get("HOME"));
}

const FileInfo = struct {
    path: []const u8,
    size: i64,
};

fn logOpendirError(path: []const u8, err: anyerror) void {
    // FileNotFound is expected on fresh installs or removed subdirs — stay silent.
    // Permission / I/O errors are not, so surface them for debugging.
    if (err == error.FileNotFound) return;
    var buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "cc-statusline: opendir {s} failed: {s}\n", .{ path, @errorName(err) })) |msg| {
        Io.File.stderr().writeStreamingAll(g_io, msg) catch {};
    } else |_| {}
}

fn collectTranscriptFiles(allocator: std.mem.Allocator, projects_path: []const u8, now_ms: i64) []FileInfo {
    var files: std.ArrayList(FileInfo) = .empty;
    const cutoff_ms = now_ms - scan_window_ms;

    var projects_dir = Io.Dir.openDirAbsolute(g_io, projects_path, .{ .iterate = true }) catch |err| {
        logOpendirError(projects_path, err);
        return files.toOwnedSlice(allocator) catch &.{};
    };
    defer projects_dir.close(g_io);

    var proj_it = projects_dir.iterate();
    while (proj_it.next(g_io) catch null) |proj_entry| {
        if (proj_entry.kind != .directory) continue;
        const proj_name = allocator.dupe(u8, proj_entry.name) catch continue;
        scanDirRecursive(allocator, projects_path, proj_name, &files, cutoff_ms);
    }

    return files.toOwnedSlice(allocator) catch &.{};
}

fn scanDirRecursive(allocator: std.mem.Allocator, base_path: []const u8, rel_path: []const u8, files: *std.ArrayList(FileInfo), cutoff_ms: i64) void {
    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, rel_path }) catch return;
    var dir = Io.Dir.openDirAbsolute(g_io, full_path, .{ .iterate = true }) catch |err| {
        logOpendirError(full_path, err);
        return;
    };
    defer dir.close(g_io);

    var it = dir.iterate();
    while (it.next(g_io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub_rel = std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_path, entry.name }) catch continue;
            scanDirRecursive(allocator, base_path, sub_rel, files, cutoff_ms);
        } else if (entry.kind == .file and mem.endsWith(u8, entry.name, ".jsonl")) {
            const stat = dir.statFile(g_io, entry.name, .{}) catch continue;

            const mtime_ms: i64 = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms));
            if (mtime_ms < cutoff_ms) continue;

            const abs_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_path, entry.name }) catch continue;
            files.append(allocator, .{ .path = abs_path, .size = @intCast(stat.size) }) catch continue;
        }
    }
}

pub fn parseJsonlContent(allocator: std.mem.Allocator, dedup_alloc: std.mem.Allocator, content: []const u8, entries: *std.ArrayList(TranscriptEntry), seen: *std.StringHashMapUnmanaged(void)) void {
    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (mem.indexOf(u8, line, "\"input_tokens\"") == null) continue;
        parseJsonlLine(allocator, dedup_alloc, line, entries, seen) catch continue;
    }
}

const Parser = struct {
    scanner: json.Scanner,
    allocator: std.mem.Allocator,
    timestamp_str: ?[]const u8 = null,
    msg_id: ?[]const u8 = null,
    req_id: ?[]const u8 = null,
    model: []const u8 = "unknown",
    have_usage: bool = false,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read: i64 = 0,
    cc_5m: i64 = 0,
    cc_1h: i64 = 0,
    /// True once a nested `cache_creation` object is entered. Nested values
    /// are authoritative, so the aggregate `cache_creation_input_tokens`
    /// fallback is ignored once this is set, regardless of key order.
    have_nested_cc: bool = false,
    is_fast: bool = false,

    fn init(allocator: std.mem.Allocator, line: []const u8) Parser {
        return .{
            .scanner = json.Scanner.initCompleteInput(allocator, line),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Parser) void {
        self.scanner.deinit();
    }

    /// Consumes `object_begin` if next, else skips the value entirely.
    /// Returns true when the caller should proceed to read keys.
    fn enterObject(self: *Parser) !bool {
        if ((try self.scanner.peekNextTokenType()) != .object_begin) {
            try self.scanner.skipValue();
            return false;
        }
        _ = try self.scanner.next();
        return true;
    }

    /// Returns the next object key as a slice, or null at `object_end`.
    /// Errors on unexpected tokens (malformed JSON).
    fn nextKey(self: *Parser) !?[]const u8 {
        const tok = try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
        return switch (tok) {
            .object_end => null,
            .string, .allocated_string => |s| s,
            else => error.UnexpectedToken,
        };
    }

    /// Reads the next value as a string. Skips and returns null for non-strings.
    fn readString(self: *Parser) !?[]const u8 {
        if ((try self.scanner.peekNextTokenType()) != .string) {
            try self.scanner.skipValue();
            return null;
        }
        const tok = try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
        return switch (tok) {
            .string, .allocated_string => |s| s,
            else => null,
        };
    }

    /// Reads the next value as an i64. Truncates floats. Skips and returns 0 for non-numbers.
    fn readI64(self: *Parser) !i64 {
        if ((try self.scanner.peekNextTokenType()) != .number) {
            try self.scanner.skipValue();
            return 0;
        }
        const tok = try self.scanner.nextAlloc(self.allocator, .alloc_if_needed);
        const slice = switch (tok) {
            .number, .allocated_number => |s| s,
            else => return 0,
        };
        if (std.fmt.parseInt(i64, slice, 10)) |v| return v else |_| {}
        if (std.fmt.parseFloat(f64, slice)) |f| return @intFromFloat(f) else |_| {}
        return 0;
    }

    fn parseTopLevel(self: *Parser) !void {
        while (try self.nextKey()) |key| {
            if (mem.eql(u8, key, "timestamp")) {
                self.timestamp_str = try self.readString();
            } else if (mem.eql(u8, key, "requestId")) {
                self.req_id = try self.readString();
            } else if (mem.eql(u8, key, "message")) {
                try self.parseMessage();
            } else {
                try self.scanner.skipValue();
            }
        }
    }

    fn parseMessage(self: *Parser) !void {
        if (!try self.enterObject()) return;
        while (try self.nextKey()) |key| {
            if (mem.eql(u8, key, "id")) {
                self.msg_id = try self.readString();
            } else if (mem.eql(u8, key, "model")) {
                if (try self.readString()) |m| self.model = m;
            } else if (mem.eql(u8, key, "usage")) {
                try self.parseUsage();
            } else {
                try self.scanner.skipValue();
            }
        }
    }

    fn parseUsage(self: *Parser) !void {
        if (!try self.enterObject()) return;
        self.have_usage = true;
        while (try self.nextKey()) |key| {
            if (mem.eql(u8, key, "input_tokens")) {
                self.input_tokens = try self.readI64();
            } else if (mem.eql(u8, key, "output_tokens")) {
                self.output_tokens = try self.readI64();
            } else if (mem.eql(u8, key, "cache_read_input_tokens")) {
                self.cache_read = try self.readI64();
            } else if (mem.eql(u8, key, "cache_creation_input_tokens")) {
                const v = try self.readI64();
                if (!self.have_nested_cc) self.cc_5m = v;
            } else if (mem.eql(u8, key, "speed")) {
                const s = try self.readString();
                self.is_fast = if (s) |v| mem.eql(u8, v, "fast") else false;
            } else if (mem.eql(u8, key, "cache_creation")) {
                try self.parseCacheCreation();
            } else {
                try self.scanner.skipValue();
            }
        }
    }

    fn parseCacheCreation(self: *Parser) !void {
        if (!try self.enterObject()) return;
        self.have_nested_cc = true;
        // Nested values authoritatively replace any aggregate fallback already
        // captured in this usage object (key order between aggregate and nested
        // is not guaranteed by the schema).
        self.cc_5m = 0;
        self.cc_1h = 0;
        while (try self.nextKey()) |key| {
            if (mem.eql(u8, key, "ephemeral_5m_input_tokens")) {
                self.cc_5m = try self.readI64();
            } else if (mem.eql(u8, key, "ephemeral_1h_input_tokens")) {
                self.cc_1h = try self.readI64();
            } else {
                try self.scanner.skipValue();
            }
        }
    }
};

fn parseJsonlLine(
    allocator: std.mem.Allocator,
    dedup_alloc: std.mem.Allocator,
    line: []const u8,
    entries: *std.ArrayList(TranscriptEntry),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var p = Parser.init(allocator, line);
    defer p.deinit();

    if ((try p.scanner.next()) != .object_begin) return error.NotObject;
    try p.parseTopLevel();

    // Order matches the previous DOM-based parser: dedup runs before
    // timestamp/usage validation, so a line with msg/req IDs but missing
    // timestamp still claims its dedup key.
    if (p.msg_id) |mid| if (p.req_id) |rid| {
        const dedup_key = try std.fmt.allocPrint(dedup_alloc, "{s}:{s}", .{ mid, rid });
        const gop = try seen.getOrPut(dedup_alloc, dedup_key);
        if (gop.found_existing) return;
    };

    if (!p.have_usage) return;
    const ts_str = p.timestamp_str orelse return;
    const timestamp_ms = time.parseIso8601ToMs(ts_str) orelse return;

    try entries.append(allocator, .{
        .timestamp_ms = timestamp_ms,
        .model = p.model,
        .usage = .{
            .input_tokens = p.input_tokens,
            .output_tokens = p.output_tokens,
            .cache_creation_5m_input_tokens = p.cc_5m,
            .cache_creation_1h_input_tokens = p.cc_1h,
            .cache_read_input_tokens = p.cache_read,
            .is_fast = p.is_fast,
        },
    });
}

// ============================================================
// Block Detection & Cost Calculation
// ============================================================

fn entryCost(entry: TranscriptEntry) f64 {
    const p = pricing.findPricing(entry.model) orelse return 0;
    return pricing.calculateEntryCost(p, entry.usage);
}

fn computeBurnRate(cost: f64, start_ms: i64, now_ms: i64) f64 {
    const elapsed_ms: i64 = @max(now_ms - start_ms, ms_per_min);
    const duration_min: f64 = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(ms_per_min));
    return cost / duration_min * 60.0;
}

fn identifyActiveBlock(entries: []TranscriptEntry, now_ms: i64) ?BlockInfo {
    if (entries.len == 0) return null;

    // Sort entries in-place by timestamp (mutates the input slice)
    mem.sort(TranscriptEntry, entries, {}, struct {
        fn f(_: void, a: TranscriptEntry, b: TranscriptEntry) bool {
            return a.timestamp_ms < b.timestamp_ms;
        }
    }.f);

    var block_start_ms = time.floorToHourMs(entries[0].timestamp_ms);
    var block_entry_start: usize = 0;

    for (entries, 0..) |entry, i| {
        if (i == 0) continue;
        const time_since_start = entry.timestamp_ms - block_start_ms;
        const time_since_prev = entry.timestamp_ms - entries[i - 1].timestamp_ms;
        if (time_since_start > block_duration_ms or time_since_prev > block_duration_ms) {
            block_start_ms = time.floorToHourMs(entry.timestamp_ms);
            block_entry_start = i;
        }
    }

    var block_cost: f64 = 0;
    for (entries[block_entry_start..]) |entry| {
        block_cost += entryCost(entry);
    }

    const block_end_ms = block_start_ms + block_duration_ms;
    return .{
        .start_ms = block_start_ms,
        .end_ms = block_end_ms,
        .cost = block_cost,
        .burn_rate_per_hr = computeBurnRate(block_cost, block_start_ms, now_ms),
    };
}

fn computeBlockFromWindow(entries: []const TranscriptEntry, window_start_ms: i64, window_end_ms: i64, now_ms: i64) ?BlockInfo {
    var block_cost: f64 = 0;
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.timestamp_ms >= window_start_ms and entry.timestamp_ms <= window_end_ms) {
            block_cost += entryCost(entry);
            count += 1;
        }
    }
    if (count == 0) return null;

    return .{
        .start_ms = window_start_ms,
        .end_ms = window_end_ms,
        .cost = block_cost,
        .burn_rate_per_hr = computeBurnRate(block_cost, window_start_ms, now_ms),
    };
}

fn computeBlock(entries: []TranscriptEntry, now_ms: i64, resets_at_ms: ?i64) ?BlockInfo {
    return if (resets_at_ms) |reset_ms| computeBlockFromWindow(
        entries,
        reset_ms - block_duration_ms,
        reset_ms,
        now_ms,
    ) else identifyActiveBlock(entries, now_ms);
}

fn computeCosts(entries: []TranscriptEntry, now_ms: i64, day_start_ms: i64, resets_at_ms: ?i64) ScanResult {
    var today_cost: f64 = 0;
    for (entries) |entry| {
        if (entry.timestamp_ms >= day_start_ms) {
            today_cost += entryCost(entry);
        }
    }

    return .{
        .today_cost = today_cost,
        .block = computeBlock(entries, now_ms, resets_at_ms),
    };
}

// ============================================================
// Cache
// ============================================================

const cache_header_size: usize =
    4 + // magic
    @sizeOf(u32) + // version
    @sizeOf(i64) + // write_time_s
    @sizeOf(i64) + // last_full_scan_s
    @sizeOf(f64) + // today_cost
    1 + // has_block
    @sizeOf(i64) + // block_start_ms
    @sizeOf(i64) + // block_end_ms
    @sizeOf(f64) + // block_cost
    @sizeOf(f64) + // block_burn_rate
    @sizeOf(i64) + // day_start_ms
    @sizeOf(u32); // file_count

fn readVal(comptime T: type, data: []const u8, pos: *usize) T {
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    const result: T = @bitCast(mem.readInt(Int, data[pos.*..][0..@sizeOf(T)], .little));
    pos.* += @sizeOf(T);
    return result;
}

fn parseCacheBytes(allocator: std.mem.Allocator, content: []const u8, day_start_ms: i64) ?CacheResult {
    if (content.len < cache_header_size) return null;

    if (!mem.eql(u8, content[0..4], &cache_magic)) return null;
    var pos: usize = 4;
    if (readVal(u32, content, &pos) != cache_ver) return null;

    const write_time_s = readVal(i64, content, &pos);
    const last_full_scan_s = readVal(i64, content, &pos);
    const today_cost = readVal(f64, content, &pos);
    const has_block = content[pos];
    pos += 1;
    const block_start_ms = readVal(i64, content, &pos);
    const block_end_ms = readVal(i64, content, &pos);
    const block_cost = readVal(f64, content, &pos);
    const block_burn_rate = readVal(f64, content, &pos);
    const hdr_day_start_ms = readVal(i64, content, &pos);
    const file_count = readVal(u32, content, &pos);

    if (hdr_day_start_ms != day_start_ms) return null;

    var scan = ScanResult{
        .today_cost = today_cost,
        .block = null,
    };
    if (has_block != 0) {
        scan.block = .{
            .start_ms = block_start_ms,
            .end_ms = block_end_ms,
            .cost = block_cost,
            .burn_rate_per_hr = block_burn_rate,
        };
    }

    // Read file entries
    var files: std.ArrayList(CachedFileEntry) = .empty;
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        if (pos + 2 > content.len) break;
        const path_len = readVal(u16, content, &pos);
        if (pos + path_len > content.len) break;
        const path = allocator.dupe(u8, content[pos..][0..path_len]) catch break;
        pos += path_len;
        if (pos + 24 > content.len) break;
        const file_size = readVal(i64, content, &pos);
        const per_file_cost = readVal(f64, content, &pos);
        const parsed_size = readVal(i64, content, &pos);
        files.append(allocator, .{
            .path = path,
            .file_size = file_size,
            .per_file_cost = per_file_cost,
            .parsed_size = parsed_size,
        }) catch break;
    }

    return .{
        .scan = scan,
        .files = files.toOwnedSlice(allocator) catch &.{},
        .write_time_s = write_time_s,
        .last_full_scan_s = last_full_scan_s,
        .day_start_ms = hdr_day_start_ms,
    };
}

fn readCache(allocator: std.mem.Allocator, day_start_ms: i64) ?CacheResult {
    var f = Io.Dir.openFileAbsolute(g_io, cache_path, .{}) catch return null;
    defer f.close(g_io);
    var rbuf: [4096]u8 = undefined;
    var reader = f.readerStreaming(g_io, &rbuf);
    const content = reader.interface.allocRemaining(allocator, .limited(cache_max_bytes)) catch return null;
    return parseCacheBytes(allocator, content, day_start_ms);
}

fn writeVal(w: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    var buf: [@sizeOf(T)]u8 = undefined;
    mem.writeInt(Int, &buf, @bitCast(value), .little);
    try w.writeAll(&buf);
}

fn serializeCacheBytes(w: anytype, result: ScanResult, files: []const CachedFileEntry, now_s: i64, last_full_scan_s: i64, day_start_ms: i64) !void {
    try w.writeAll(&cache_magic);
    try writeVal(w, cache_ver);
    try writeVal(w, now_s);
    try writeVal(w, last_full_scan_s);
    try writeVal(w, result.today_cost);
    try w.writeAll(&[_]u8{if (result.block != null) 1 else 0});
    try writeVal(w, if (result.block) |b| b.start_ms else @as(i64, 0));
    try writeVal(w, if (result.block) |b| b.end_ms else @as(i64, 0));
    try writeVal(w, if (result.block) |b| b.cost else @as(f64, 0));
    try writeVal(w, if (result.block) |b| b.burn_rate_per_hr else @as(f64, 0));
    try writeVal(w, day_start_ms);
    try writeVal(w, @as(u32, @intCast(files.len)));

    for (files) |entry| {
        var len_buf: [2]u8 = undefined;
        mem.writeInt(u16, &len_buf, @intCast(entry.path.len), .little);
        try w.writeAll(&len_buf);
        try w.writeAll(entry.path);
        try writeVal(w, entry.file_size);
        try writeVal(w, entry.per_file_cost);
        try writeVal(w, entry.parsed_size);
    }
}

fn writeCache(result: ScanResult, files: []const CachedFileEntry, now_s: i64, last_full_scan_s: i64, day_start_ms: i64) void {
    const tmp_path = cache_path ++ ".tmp";
    var f = Io.Dir.createFileAbsolute(g_io, tmp_path, .{}) catch return;
    defer f.close(g_io);
    var wbuf: [8192]u8 = undefined;
    var writer = f.writerStreaming(g_io, &wbuf);
    serializeCacheBytes(&writer.interface, result, files, now_s, last_full_scan_s, day_start_ms) catch return;
    writer.interface.flush() catch return;
    Io.Dir.renameAbsolute(tmp_path, cache_path, g_io) catch {};
}

// ============================================================
// Scan Orchestration
// ============================================================

/// Bench-only entry that bypasses cache and forces a full scan from `projects_path`.
/// `cc-statusline` itself goes through `scanTranscripts`; benches use this to measure
/// the cold path in isolation without touching the on-disk cache.
pub fn benchFullScan(io: Io, allocator: std.mem.Allocator, projects_path: []const u8, now_ms: i64, day_start_ms: i64) ScanResult {
    g_io = io;
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    return fullScan(allocator, projects_path, now_ms, now_s, day_start_ms, null);
}

pub fn scanTranscripts(io: Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, now_ms: i64, day_start_ms: i64, resets_at_ms: ?i64) ?ScanResult {
    g_io = io;
    const config_dir = getConfigDir(allocator, env) catch return null;
    const projects_path = std.fmt.allocPrint(allocator, "{s}/projects", .{config_dir}) catch return null;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    // Try cache — TTL check before any I/O
    if (readCache(allocator, day_start_ms)) |cached| {
        if (now_s - cached.write_time_s <= cache_ttl_s) {
            return cached.scan;
        }
        // TTL expired, but file list is still fresh — try stat-only diff
        if (now_s - cached.last_full_scan_s <= file_list_ttl_s and cached.files.len > 0) {
            if (diffScan(allocator, cached, now_ms, now_s, day_start_ms, resets_at_ms)) |result| {
                return result;
            }
        }
    }

    return fullScan(allocator, projects_path, now_ms, now_s, day_start_ms, resets_at_ms);
}

/// Stat-only diff scan: check cached files for size changes, parse only new bytes.
/// Returns null if any file shrank/disappeared (caller should fall back to full scan).
fn diffScan(allocator: std.mem.Allocator, cached: CacheResult, now_ms: i64, now_s: i64, day_start_ms: i64, resets_at_ms: ?i64) ?ScanResult {
    // If resets_at changed since cache was written, the block window shifted — need full rescan
    if (resets_at_ms) |reset_ms| {
        if (cached.scan.block) |existing_block| {
            if (existing_block.end_ms != reset_ms) return null;
        }
    }

    var changed: std.StringHashMapUnmanaged(CachedFileEntry) = .empty;
    var any_shrunk = false;

    for (cached.files) |entry| {
        const stat = Io.Dir.cwd().statFile(g_io, entry.path, .{}) catch {
            any_shrunk = true;
            break;
        };
        const current_size: i64 = @intCast(stat.size);
        if (current_size < entry.file_size) {
            any_shrunk = true;
            break;
        } else if (current_size > entry.file_size) {
            changed.put(allocator, entry.path, .{
                .path = entry.path,
                .file_size = current_size,
                .per_file_cost = entry.per_file_cost,
                .parsed_size = entry.parsed_size,
            }) catch return null;
        }
    }

    if (any_shrunk) return null;

    if (changed.count() == 0) {
        writeCache(cached.scan, cached.files, now_s, cached.last_full_scan_s, day_start_ms);
        return cached.scan;
    }

    var block_diff_cost: f64 = 0;
    var new_files: std.ArrayList(CachedFileEntry) = .empty;
    var global_seen: std.StringHashMapUnmanaged(void) = .empty;

    for (cached.files) |entry| {
        if (changed.get(entry.path)) |ch| {
            var entries: std.ArrayList(TranscriptEntry) = .empty;

            parse_file: {
                var f = Io.Dir.openFileAbsolute(g_io, ch.path, .{}) catch break :parse_file;
                defer f.close(g_io);
                var rbuf: [8192]u8 = undefined;
                var reader = f.reader(g_io, &rbuf);
                if (ch.parsed_size > 0) {
                    reader.seekTo(@intCast(ch.parsed_size)) catch break :parse_file;
                }
                const content = reader.interface.allocRemaining(allocator, .limited(100 * 1024 * 1024)) catch break :parse_file;
                if (content.len > 0) {
                    parseJsonlContent(allocator, allocator, content, &entries, &global_seen);
                }
            }

            var today_file_diff_cost: f64 = 0;
            for (entries.items) |e| {
                const cost = entryCost(e);
                if (e.timestamp_ms >= day_start_ms) {
                    today_file_diff_cost += cost;
                }
                if (cached.scan.block) |existing_block| {
                    if (e.timestamp_ms >= existing_block.start_ms and e.timestamp_ms <= existing_block.end_ms) {
                        block_diff_cost += cost;
                    }
                }
            }

            new_files.append(allocator, .{
                .path = ch.path,
                .file_size = ch.file_size,
                .per_file_cost = entry.per_file_cost + today_file_diff_cost,
                .parsed_size = ch.file_size,
            }) catch continue;
        } else {
            new_files.append(allocator, entry) catch continue;
        }
    }

    var new_today_cost: f64 = 0;
    for (new_files.items) |entry| {
        new_today_cost += entry.per_file_cost;
    }

    const block = blk: {
        if (block_diff_cost == 0) break :blk cached.scan.block;
        if (cached.scan.block) |existing_block| {
            const new_block_cost = existing_block.cost + block_diff_cost;
            break :blk BlockInfo{
                .start_ms = existing_block.start_ms,
                .end_ms = existing_block.end_ms,
                .cost = new_block_cost,
                .burn_rate_per_hr = computeBurnRate(new_block_cost, existing_block.start_ms, now_ms),
            };
        }
        break :blk @as(?BlockInfo, null);
    };

    const result = ScanResult{
        .today_cost = new_today_cost,
        .block = block,
    };
    const new_file_entries = new_files.toOwnedSlice(allocator) catch cached.files;
    writeCache(result, new_file_entries, now_s, cached.last_full_scan_s, day_start_ms);
    return result;
}

fn fullScan(allocator: std.mem.Allocator, projects_path: []const u8, now_ms: i64, now_s: i64, day_start_ms: i64, resets_at_ms: ?i64) ScanResult {
    const file_infos = collectTranscriptFiles(allocator, projects_path, now_ms);
    var all_entries: std.ArrayList(TranscriptEntry) = .empty;
    var cache_files: std.ArrayList(CachedFileEntry) = .empty;
    var total_today_cost: f64 = 0;

    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp_arena.deinit();
    var global_seen: std.StringHashMapUnmanaged(void) = .empty;

    for (file_infos) |fi| {
        _ = tmp_arena.reset(.retain_capacity);
        const tmp = tmp_arena.allocator();

        var f = Io.Dir.openFileAbsolute(g_io, fi.path, .{}) catch continue;
        defer f.close(g_io);
        var rbuf: [8192]u8 = undefined;
        var reader = f.readerStreaming(g_io, &rbuf);
        const content = reader.interface.allocRemaining(tmp, .limited(100 * 1024 * 1024)) catch continue;

        var file_entries: std.ArrayList(TranscriptEntry) = .empty;
        parseJsonlContent(tmp, allocator, content, &file_entries, &global_seen);

        const start_idx = all_entries.items.len;
        for (file_entries.items) |entry| {
            all_entries.append(allocator, .{
                .timestamp_ms = entry.timestamp_ms,
                .model = allocator.dupe(u8, entry.model) catch "unknown",
                .usage = entry.usage,
            }) catch continue;
        }

        const new_items = all_entries.items[start_idx..];
        var per_cost: f64 = 0;
        for (new_items) |entry| {
            if (entry.timestamp_ms >= day_start_ms) {
                per_cost += entryCost(entry);
            }
        }
        total_today_cost += per_cost;
        cache_files.append(allocator, .{
            .path = fi.path,
            .file_size = fi.size,
            .per_file_cost = per_cost,
            .parsed_size = fi.size,
        }) catch continue;
    }

    const result = ScanResult{
        .today_cost = total_today_cost,
        .block = computeBlock(all_entries.items, now_ms, resets_at_ms),
    };
    const cf = cache_files.toOwnedSlice(allocator) catch &.{};
    writeCache(result, cf, now_s, now_s, day_start_ms);
    return result;
}

// ============================================================
// Tests
// ============================================================

test "identifyActiveBlock empty entries" {
    var entries = [_]TranscriptEntry{};
    try std.testing.expectEqual(@as(?BlockInfo, null), identifyActiveBlock(&entries, 1000));
}

test "identifyActiveBlock single entry" {
    const now_ms: i64 = 1700000000 * 1000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = now_ms - 60000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    try std.testing.expect(block.?.cost > 0);
    try std.testing.expect(block.?.start_ms <= entries[0].timestamp_ms);
}

test "identifyActiveBlock gap detection" {
    const base_ms: i64 = 1700000000 * 1000;
    const gap = block_duration_ms + 1000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = base_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
        .{ .timestamp_ms = base_ms + gap, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 2000, .output_tokens = 1000 } },
    };
    const now_ms = base_ms + gap + 60000;
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    try std.testing.expect(block.?.start_ms >= base_ms + gap - 3600 * 1000);
}

test "computeCosts today entries only" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    const today_entry = TranscriptEntry{
        .timestamp_ms = now_ms - 2 * 3600 * 1000,
        .model = "claude-sonnet-4-5-20250929",
        .usage = .{ .input_tokens = 1000, .output_tokens = 500 },
    };
    const old_entry = TranscriptEntry{
        .timestamp_ms = now_ms - 30 * 3600 * 1000,
        .model = "claude-sonnet-4-5-20250929",
        .usage = .{ .input_tokens = 5000, .output_tokens = 2000 },
    };

    var entries = [_]TranscriptEntry{ old_entry, today_entry };
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start_ms = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    const result = computeCosts(&entries, now_ms, day_start_ms, null);
    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected_today = pricing.calculateEntryCost(p, today_entry.usage);
    try std.testing.expectApproxEqAbs(expected_today, result.today_cost, 1e-10);
}

test "computeCosts old entries excluded from today" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = now_ms - 48 * 3600 * 1000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 5000, .output_tokens = 2000 } },
    };
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start_ms = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    const result = computeCosts(&entries, now_ms, day_start_ms, null);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.today_cost, 1e-10);
}

test "parseJsonlContent global dedup across files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var global_seen = std.StringHashMapUnmanaged(void).empty;

    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"id":"msg_001","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}},"requestId":"req_001"}
    ;

    var entries1: std.ArrayList(TranscriptEntry) = .empty;
    parseJsonlContent(alloc, alloc, line, &entries1, &global_seen);
    try std.testing.expectEqual(@as(usize, 1), entries1.items.len);

    var entries2: std.ArrayList(TranscriptEntry) = .empty;
    parseJsonlContent(alloc, alloc, line, &entries2, &global_seen);
    try std.testing.expectEqual(@as(usize, 0), entries2.items.len);
}

test "parseJsonlContent per-file dedup still works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seen = std.StringHashMapUnmanaged(void).empty;

    const content =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"id":"msg_001","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}},"requestId":"req_001"}
        \\
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"id":"msg_001","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}},"requestId":"req_001"}
    ;

    var entries: std.ArrayList(TranscriptEntry) = .empty;
    parseJsonlContent(alloc, alloc, content, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
}

test "parseJsonlContent no dedup without ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var seen = std.StringHashMapUnmanaged(void).empty;

    const content =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}}}
        \\
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}}}
    ;

    var entries: std.ArrayList(TranscriptEntry) = .empty;
    parseJsonlContent(alloc, alloc, content, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
}

test "cache roundtrip with block" {
    const Writer = std.Io.Writer;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const scan = ScanResult{
        .today_cost = 12.345,
        .block = .{
            .start_ms = 1000000,
            .end_ms = 19000000,
            .cost = 5.67,
            .burn_rate_per_hr = 1.23,
        },
    };
    const files = [_]CachedFileEntry{
        .{ .path = "/tmp/test/file1.jsonl", .file_size = 4096, .per_file_cost = 3.21, .parsed_size = 4096 },
        .{ .path = "/tmp/test/file2.jsonl", .file_size = 8192, .per_file_cost = 9.12, .parsed_size = 8000 },
    };
    const now_s: i64 = 1700000000;
    const last_full_scan_s: i64 = 1699999900;
    const day_start_ms: i64 = 1699920000000;

    try serializeCacheBytes(&aw.writer, scan, &files, now_s, last_full_scan_s, day_start_ms);

    const result = parseCacheBytes(std.testing.allocator, aw.writer.buffered(), day_start_ms) orelse
        return error.TestUnexpectedResult;
    defer {
        for (result.files) |f| std.testing.allocator.free(f.path);
        std.testing.allocator.free(result.files);
    }

    try std.testing.expectEqual(now_s, result.write_time_s);
    try std.testing.expectEqual(last_full_scan_s, result.last_full_scan_s);
    try std.testing.expectEqual(day_start_ms, result.day_start_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 12.345), result.scan.today_cost, 1e-10);

    const block = result.scan.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 1000000), block.start_ms);
    try std.testing.expectEqual(@as(i64, 19000000), block.end_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 5.67), block.cost, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), block.burn_rate_per_hr, 1e-10);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("/tmp/test/file1.jsonl", result.files[0].path);
    try std.testing.expectEqual(@as(i64, 4096), result.files[0].file_size);
    try std.testing.expectApproxEqAbs(@as(f64, 3.21), result.files[0].per_file_cost, 1e-10);
    try std.testing.expectEqual(@as(i64, 4096), result.files[0].parsed_size);
    try std.testing.expectEqualStrings("/tmp/test/file2.jsonl", result.files[1].path);
    try std.testing.expectEqual(@as(i64, 8192), result.files[1].file_size);
    try std.testing.expectEqual(@as(i64, 8000), result.files[1].parsed_size);
}

test "cache roundtrip without block" {
    const Writer = std.Io.Writer;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const scan = ScanResult{ .today_cost = 0.50 };
    const files = [_]CachedFileEntry{};
    const day_start_ms: i64 = 1699920000000;

    try serializeCacheBytes(&aw.writer, scan, &files, 100, 100, day_start_ms);

    const result = parseCacheBytes(std.testing.allocator, aw.writer.buffered(), day_start_ms) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(result.files);

    try std.testing.expectApproxEqAbs(@as(f64, 0.50), result.scan.today_cost, 1e-10);
    try std.testing.expectEqual(@as(?BlockInfo, null), result.scan.block);
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
}

test "cache day boundary invalidation" {
    const Writer = std.Io.Writer;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const day_start_ms: i64 = 1699920000000;
    try serializeCacheBytes(&aw.writer, ScanResult{}, &.{}, 100, 100, day_start_ms);

    // Different day_start_ms should return null
    const different_day: i64 = day_start_ms + 86400 * 1000;
    try std.testing.expectEqual(@as(?CacheResult, null), parseCacheBytes(std.testing.allocator, aw.writer.buffered(), different_day));
}

test "cache invalid magic" {
    var data: [cache_header_size]u8 = .{0} ** cache_header_size;
    @memcpy(data[0..4], "NOPE");
    try std.testing.expectEqual(@as(?CacheResult, null), parseCacheBytes(std.testing.allocator, &data, 0));
}

test "cache too short" {
    const data = [_]u8{ 'C', 'C', 'S', 'L' };
    try std.testing.expectEqual(@as(?CacheResult, null), parseCacheBytes(std.testing.allocator, &data, 0));
}

test "cache wrong version" {
    var data: [cache_header_size]u8 = .{0} ** cache_header_size;
    @memcpy(data[0..4], &cache_magic);
    // Write a different version (cache_ver + 1)
    mem.writeInt(u32, data[4..8], cache_ver + 1, .little);
    try std.testing.expectEqual(@as(?CacheResult, null), parseCacheBytes(std.testing.allocator, &data, 0));
}

test "computeBlockFromWindow entries within window" {
    const window_start: i64 = 1700000000 * 1000;
    const window_end: i64 = window_start + block_duration_ms;
    const now_ms: i64 = window_start + 2 * 3600 * 1000; // 2h into window

    const inside = TranscriptEntry{ .timestamp_ms = window_start + 60000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } };
    const outside = TranscriptEntry{ .timestamp_ms = window_start - 3600 * 1000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 5000, .output_tokens = 2000 } };
    var entries = [_]TranscriptEntry{ outside, inside };

    const block = computeBlockFromWindow(&entries, window_start, window_end, now_ms);
    try std.testing.expect(block != null);

    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected_cost = pricing.calculateEntryCost(p, inside.usage);
    try std.testing.expectApproxEqAbs(expected_cost, block.?.cost, 1e-10);
    try std.testing.expectEqual(window_start, block.?.start_ms);
    try std.testing.expectEqual(window_end, block.?.end_ms);
    try std.testing.expect(block.?.burn_rate_per_hr > 0);
}

test "computeBlockFromWindow empty window" {
    const window_start: i64 = 1700000000 * 1000;
    const window_end: i64 = window_start + block_duration_ms;
    const now_ms: i64 = window_start + 60000;

    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = window_start - 3600 * 1000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = computeBlockFromWindow(&entries, window_start, window_end, now_ms);
    try std.testing.expectEqual(@as(?BlockInfo, null), block);
}

test "computeCosts with resets_at_ms uses window" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    const resets_at_ms: i64 = now_ms + 3 * 3600 * 1000; // resets 3h from now
    const window_start = resets_at_ms - block_duration_ms; // started 2h ago

    const in_window = TranscriptEntry{
        .timestamp_ms = now_ms - 1 * 3600 * 1000, // 1h ago, within window
        .model = "claude-sonnet-4-5-20250929",
        .usage = .{ .input_tokens = 1000, .output_tokens = 500 },
    };
    const outside_window = TranscriptEntry{
        .timestamp_ms = window_start - 1 * 3600 * 1000, // before window
        .model = "claude-sonnet-4-5-20250929",
        .usage = .{ .input_tokens = 5000, .output_tokens = 2000 },
    };

    var entries = [_]TranscriptEntry{ outside_window, in_window };
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start_ms = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    const result = computeCosts(&entries, now_ms, day_start_ms, resets_at_ms);

    try std.testing.expect(result.block != null);
    try std.testing.expectEqual(window_start, result.block.?.start_ms);
    try std.testing.expectEqual(resets_at_ms, result.block.?.end_ms);

    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected_cost = pricing.calculateEntryCost(p, in_window.usage);
    try std.testing.expectApproxEqAbs(expected_cost, result.block.?.cost, 1e-10);
}

// --- resolveConfigDir ---

test "resolveConfigDir with CLAUDE_CONFIG_DIR" {
    const dir = try resolveConfigDir(std.testing.allocator, "/custom/dir", null);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/custom/dir", dir);
}

test "resolveConfigDir falls back to HOME/.claude" {
    const dir = try resolveConfigDir(std.testing.allocator, null, "/home/user");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/home/user/.claude", dir);
}

test "resolveConfigDir no HOME returns error" {
    try std.testing.expectError(error.NoHome, resolveConfigDir(std.testing.allocator, null, null));
}

// --- parseJsonlContent (skip branches) ---

test "parseJsonlContent skips invalid json with input_tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    // Contains "input_tokens" but is not valid JSON
    parseJsonlContent(alloc, alloc, "{broken input_tokens}", &entries, &seen);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "parseJsonlContent skips entry without timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    const line =
        \\{"message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "parseJsonlContent skips entry without usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    // Has timestamp and message but no usage (and "input_tokens" in another field to pass the prefix filter)
    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-sonnet-4-5"},"note":"input_tokens"}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "parseJsonlContent model fallback to unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    // No model field in message
    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":50}}}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("unknown", entries.items[0].model);
}

// --- diffScan ---

fn createTmpFile(path: []const u8, content: []const u8) !void {
    g_io = std.testing.io;
    var f = try Io.Dir.createFileAbsolute(std.testing.io, path, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, content);
}

fn removeTmpFile(path: []const u8) void {
    Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
}

fn statFileSize(path: []const u8) i64 {
    const stat = Io.Dir.cwd().statFile(std.testing.io, path, .{}) catch return 0;
    return @intCast(stat.size);
}

test "diffScan no files changed returns cached result" {
    const path = "/tmp/cc-test-diffscan-nochange.jsonl";
    const content =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
    ;
    try createTmpFile(path, content);
    defer removeTmpFile(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file_size = statFileSize(path);
    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    const cached = CacheResult{
        .scan = .{ .today_cost = 5.0, .block = null },
        .files = &[_]CachedFileEntry{
            .{ .path = path, .file_size = file_size, .per_file_cost = 5.0, .parsed_size = file_size },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    const result = diffScan(alloc, cached, now_ms, now_s, day_start_ms, null);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), result.?.today_cost, 1e-10);
}

test "diffScan file shrank returns null" {
    const path = "/tmp/cc-test-diffscan-shrunk.jsonl";
    try createTmpFile(path, "small");
    defer removeTmpFile(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    const cached = CacheResult{
        .scan = .{ .today_cost = 5.0 },
        .files = &[_]CachedFileEntry{
            .{ .path = path, .file_size = 99999, .per_file_cost = 5.0, .parsed_size = 99999 },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    try std.testing.expectEqual(@as(?ScanResult, null), diffScan(alloc, cached, now_ms, now_s, day_start_ms, null));
}

test "diffScan file disappeared returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    const cached = CacheResult{
        .scan = .{ .today_cost = 5.0 },
        .files = &[_]CachedFileEntry{
            .{ .path = "/tmp/cc-test-diffscan-nonexistent-xyz.jsonl", .file_size = 100, .per_file_cost = 5.0, .parsed_size = 100 },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    try std.testing.expectEqual(@as(?ScanResult, null), diffScan(alloc, cached, now_ms, now_s, day_start_ms, null));
}

test "diffScan resets_at changed returns null" {
    const path = "/tmp/cc-test-diffscan-reset.jsonl";
    try createTmpFile(path, "data");
    defer removeTmpFile(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));
    const resets_at_ms: i64 = now_ms + 3 * 3600 * 1000;

    const cached = CacheResult{
        .scan = .{
            .today_cost = 5.0,
            .block = .{ .start_ms = 0, .end_ms = resets_at_ms + 1000, .cost = 1.0, .burn_rate_per_hr = 0.5 },
        },
        .files = &[_]CachedFileEntry{
            .{ .path = path, .file_size = 4, .per_file_cost = 5.0, .parsed_size = 4 },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    try std.testing.expectEqual(@as(?ScanResult, null), diffScan(alloc, cached, now_ms, now_s, day_start_ms, resets_at_ms));
}

test "diffScan file grew recalculates cost" {
    const path = "/tmp/cc-test-diffscan-grew.jsonl";
    const old_content = "old data padding\n";
    const new_line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}}}
    ;
    var full_buf: [512]u8 = undefined;
    const full_content = std.fmt.bufPrint(&full_buf, "{s}{s}\n", .{ old_content, new_line }) catch unreachable;
    try createTmpFile(path, full_content);
    defer removeTmpFile(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const old_size: i64 = @intCast(old_content.len);
    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    const cached = CacheResult{
        .scan = .{ .today_cost = 1.0 },
        .files = &[_]CachedFileEntry{
            .{ .path = path, .file_size = old_size, .per_file_cost = 1.0, .parsed_size = old_size },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    const result = diffScan(alloc, cached, now_ms, now_s, day_start_ms, null);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.today_cost > 1.0);
}

test "diffScan total_diff_cost zero preserves cached block" {
    const path = "/tmp/cc-test-diffscan-nodiff.jsonl";
    const old_content = "some old data\n";
    const full_content = old_content ++ "not a valid jsonl line with input_tokens\n";
    try createTmpFile(path, full_content);
    defer removeTmpFile(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const old_size: i64 = @intCast(old_content.len);
    const day_start_ms: i64 = time.daysFromCivil(2025, 6, 15) * 86400 * 1000;
    const now_ms: i64 = day_start_ms + 12 * 3600 * 1000;
    const now_s = @divFloor(now_ms, @as(i64, 1000));

    const cached_block = BlockInfo{ .start_ms = now_ms - 3600 * 1000, .end_ms = now_ms + 4 * 3600 * 1000, .cost = 2.5, .burn_rate_per_hr = 1.0 };
    const cached = CacheResult{
        .scan = .{ .today_cost = 3.0, .block = cached_block },
        .files = &[_]CachedFileEntry{
            .{ .path = path, .file_size = old_size, .per_file_cost = 3.0, .parsed_size = old_size },
        },
        .write_time_s = now_s - 10,
        .last_full_scan_s = now_s - 100,
        .day_start_ms = day_start_ms,
    };

    const result = diffScan(alloc, cached, now_ms, now_s, day_start_ms, null);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.block != null);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), result.?.block.?.cost, 1e-10);
}

// --- parseJsonlContent fast mode ---

test "parseJsonlContent parses speed fast" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50,"speed":"fast"}}}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(entries.items[0].usage.is_fast);
}

test "parseJsonlContent speed non-fast is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50,"speed":"standard"}}}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(!entries.items[0].usage.is_fast);
}

test "parseJsonlContent no speed field is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var seen = std.StringHashMapUnmanaged(void).empty;
    var entries: std.ArrayList(TranscriptEntry) = .empty;

    const line =
        \\{"timestamp":"2025-06-15T10:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":100,"output_tokens":50}}}
    ;
    parseJsonlContent(alloc, alloc, line, &entries, &seen);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(!entries.items[0].usage.is_fast);
}

// --- identifyActiveBlock boundary conditions ---

test "identifyActiveBlock identical timestamps" {
    const now_ms: i64 = 1700000000 * 1000;
    const ts = now_ms - 60000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = ts, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
        .{ .timestamp_ms = ts, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 2000, .output_tokens = 1000 } },
    };
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    // Both entries in same block, costs should be combined
    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected = pricing.calculateEntryCost(p, entries[0].usage) + pricing.calculateEntryCost(p, entries[1].usage);
    try std.testing.expectApproxEqAbs(expected, block.?.cost, 1e-10);
}

test "identifyActiveBlock exactly at block duration stays in block" {
    const base_ms: i64 = 1700000000 * 1000;
    const floored_base = time.floorToHourMs(base_ms);
    // Entry at exactly block_duration_ms from floored start → still in block (> not >=)
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = base_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
        .{ .timestamp_ms = floored_base + block_duration_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 2000, .output_tokens = 1000 } },
    };
    const now_ms = floored_base + block_duration_ms + 60000;
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    // Both entries should be in the same block since condition is `>`
    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected = pricing.calculateEntryCost(p, entries[0].usage) + pricing.calculateEntryCost(p, entries[1].usage);
    try std.testing.expectApproxEqAbs(expected, block.?.cost, 1e-10);
}

test "identifyActiveBlock reverse order input sorted correctly" {
    const now_ms: i64 = 1700000000 * 1000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = now_ms - 30000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 2000, .output_tokens = 1000 } },
        .{ .timestamp_ms = now_ms - 60000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    // After sort, first entry timestamp should be the earlier one
    try std.testing.expect(entries[0].timestamp_ms < entries[1].timestamp_ms);
}

test "identifyActiveBlock now_ms before entries clamps elapsed" {
    const entry_ms: i64 = 1700000000 * 1000;
    const now_ms: i64 = entry_ms - 120000; // now is before entries
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = entry_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    // elapsed clamped to 60000 → burn_rate = cost / 1min * 60
    try std.testing.expect(block.?.burn_rate_per_hr > 0);
}

test "identifyActiveBlock multiple gaps picks last block" {
    const base_ms: i64 = 1700000000 * 1000;
    const gap = block_duration_ms + 1000;
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = base_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
        .{ .timestamp_ms = base_ms + gap, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 2000, .output_tokens = 1000 } },
        .{ .timestamp_ms = base_ms + 2 * gap, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 3000, .output_tokens = 1500 } },
    };
    const now_ms = base_ms + 2 * gap + 60000;
    const block = identifyActiveBlock(&entries, now_ms);
    try std.testing.expect(block != null);
    // Only the last entry should be in the block
    const p = pricing.findPricing("claude-sonnet-4-5-20250929").?;
    const expected = pricing.calculateEntryCost(p, .{ .input_tokens = 3000, .output_tokens = 1500 });
    try std.testing.expectApproxEqAbs(expected, block.?.cost, 1e-10);
}

// --- computeBlockFromWindow boundary conditions ---

test "computeBlockFromWindow entry exactly at window_start" {
    const window_start: i64 = 1700000000 * 1000;
    const window_end: i64 = window_start + block_duration_ms;
    const now_ms: i64 = window_start + 2 * 3600 * 1000;

    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = window_start, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = computeBlockFromWindow(&entries, window_start, window_end, now_ms);
    try std.testing.expect(block != null);
    try std.testing.expect(block.?.cost > 0);
}

test "computeBlockFromWindow entry exactly at window_end" {
    const window_start: i64 = 1700000000 * 1000;
    const window_end: i64 = window_start + block_duration_ms;
    const now_ms: i64 = window_end + 60000;

    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = window_end, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = computeBlockFromWindow(&entries, window_start, window_end, now_ms);
    try std.testing.expect(block != null);
    try std.testing.expect(block.?.cost > 0);
}

test "computeBlockFromWindow now_ms before window clamps elapsed" {
    const window_start: i64 = 1700000000 * 1000;
    const window_end: i64 = window_start + block_duration_ms;
    const now_ms: i64 = window_start - 60000; // before window

    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = window_start + 1000, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const block = computeBlockFromWindow(&entries, window_start, window_end, now_ms);
    try std.testing.expect(block != null);
    // elapsed clamped to 60000 → burn_rate = cost / 1min * 60
    try std.testing.expect(block.?.burn_rate_per_hr > 0);
}

// --- computeCosts boundary conditions ---

test "computeCosts entry exactly at today_start_ms" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const today_start = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = today_start, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const result = computeCosts(&entries, now_ms, today_start, null);
    try std.testing.expect(result.today_cost > 0);
}

test "computeCosts unknown model contributes zero cost" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start_ms = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = now_ms - 1000, .model = "unknown-xyz", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const result = computeCosts(&entries, now_ms, day_start_ms, null);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.today_cost, 1e-10);
}

test "computeCosts resets_at_ms with no entries in window" {
    const now_ms: i64 = (time.daysFromCivil(2025, 6, 15) * 86400 + 12 * 3600) * 1000;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    const day_start_ms = time.getLocalDayStartMs(std.testing.io, &env, std.testing.allocator, now_ms);
    const resets_at_ms: i64 = now_ms + 3 * 3600 * 1000;
    // Entry is far before the window
    var entries = [_]TranscriptEntry{
        .{ .timestamp_ms = resets_at_ms - 2 * block_duration_ms, .model = "claude-sonnet-4-5-20250929", .usage = .{ .input_tokens = 1000, .output_tokens = 500 } },
    };
    const result = computeCosts(&entries, now_ms, day_start_ms, resets_at_ms);
    try std.testing.expectEqual(@as(?BlockInfo, null), result.block);
}

// --- parseCacheBytes corruption ---

test "cache partial file entries truncated" {
    const Writer = std.Io.Writer;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const scan = ScanResult{ .today_cost = 1.0 };
    const files = [_]CachedFileEntry{
        .{ .path = "/tmp/f1.jsonl", .file_size = 100, .per_file_cost = 0.5, .parsed_size = 100 },
        .{ .path = "/tmp/f2.jsonl", .file_size = 200, .per_file_cost = 0.5, .parsed_size = 200 },
    };
    const day_start_ms: i64 = 1699920000000;
    try serializeCacheBytes(&aw.writer, scan, &files, 100, 100, day_start_ms);

    const full_data = aw.writer.buffered();
    // Truncate after first file entry + partial second entry
    const truncated_len = cache_header_size + 2 + "/tmp/f1.jsonl".len + 24 + 5;
    const result = parseCacheBytes(std.testing.allocator, full_data[0..truncated_len], day_start_ms) orelse
        return error.TestUnexpectedResult;
    defer {
        for (result.files) |f| std.testing.allocator.free(f.path);
        std.testing.allocator.free(result.files);
    }
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
}

test "cache path length zero roundtrip" {
    const Writer = std.Io.Writer;
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const scan = ScanResult{ .today_cost = 0.5 };
    const files = [_]CachedFileEntry{
        .{ .path = "", .file_size = 0, .per_file_cost = 0, .parsed_size = 0 },
    };
    const day_start_ms: i64 = 1699920000000;
    try serializeCacheBytes(&aw.writer, scan, &files, 100, 100, day_start_ms);

    const result = parseCacheBytes(std.testing.allocator, aw.writer.buffered(), day_start_ms) orelse
        return error.TestUnexpectedResult;
    defer {
        for (result.files) |f| std.testing.allocator.free(f.path);
        std.testing.allocator.free(result.files);
    }
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("", result.files[0].path);
}
