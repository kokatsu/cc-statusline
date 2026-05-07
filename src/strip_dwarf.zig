const std = @import("std");
const mem = std.mem;
const Io = std.Io;

/// Strip DW_LNCT_LLVM_source from DWARF v5 .debug_line sections.
///
/// Zig (via LLVM) emits DW_LNCT_LLVM_source (content type 0x2001) in DWARF v5
/// file name tables, which GNU binutils cannot parse. This tool replaces the
/// type code with DW_LNCT_timestamp (0x03) in a 2-byte ULEB128 encoding,
/// keeping the byte layout identical so no ELF structural changes are needed.
///
/// Pattern: 0x81 0x40 0x1f → 0x83 0x00 0x1f
///   0x81 0x40 = ULEB128 encoding of 0x2001 (DW_LNCT_LLVM_source)
///   0x83 0x00 = ULEB128 encoding of 0x0003 (DW_LNCT_timestamp)
///   0x1f      = DW_FORM_line_strp (unchanged)
const elf_magic = "\x7fELF";
const debug_line_name = ".debug_line";

const DW_LNCT_LLVM_SOURCE: [3]u8 = .{ 0x81, 0x40, 0x1f };
const DW_LNCT_TIMESTAMP: [3]u8 = .{ 0x83, 0x00, 0x1f };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        var buf: [256]u8 = undefined;
        var w = Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.writeAll("Usage: strip-dwarf <input-elf> <output-elf>\n");
        try w.interface.flush();
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    var out_buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &out_buf);

    // Read input ELF
    const data = blk: {
        var f = try Io.Dir.cwd().openFile(io, input_path, .{ .mode = .read_only });
        defer f.close(io);
        var rbuf: [8192]u8 = undefined;
        var reader = f.readerStreaming(io, &rbuf);
        break :blk try reader.interface.allocRemaining(allocator, .limited(256 * 1024 * 1024));
    };

    // Validate ELF
    if (data.len < 64 or !mem.eql(u8, data[0..4], elf_magic)) {
        try w.interface.writeAll("Error: not an ELF file\n");
        try w.interface.flush();
        std.process.exit(1);
    }

    // Find .debug_line section
    const section = findDebugLineSection(data) orelse {
        try w.interface.writeAll("Error: .debug_line section not found\n");
        try w.interface.flush();
        std.process.exit(1);
    };

    try w.interface.print(".debug_line: offset=0x{x}, size={d}\n", .{ section.offset, section.size });

    // Replace DW_LNCT_LLVM_source pattern within .debug_line
    var count: u32 = 0;
    const end = section.offset + section.size;
    var i: usize = section.offset;
    while (i + 3 <= end) : (i += 1) {
        if (data[i] == DW_LNCT_LLVM_SOURCE[0] and
            data[i + 1] == DW_LNCT_LLVM_SOURCE[1] and
            data[i + 2] == DW_LNCT_LLVM_SOURCE[2])
        {
            data[i] = DW_LNCT_TIMESTAMP[0];
            data[i + 1] = DW_LNCT_TIMESTAMP[1];
            count += 1;
        }
    }

    if (count == 0) {
        try w.interface.writeAll("No DW_LNCT_LLVM_source entries found, copying as-is\n");
    } else {
        try w.interface.print("Patched {d} DW_LNCT_LLVM_source entries\n", .{count});
    }

    // Write output
    const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, data);

    try w.interface.print("Written to {s}\n", .{output_path});
    try w.interface.flush();
}

const SectionInfo = struct {
    offset: usize,
    size: usize,
};

fn findDebugLineSection(data: []const u8) ?SectionInfo {
    // ELF64 only (Zig targets 64-bit)
    if (data[4] != 2) return null;

    const e_shoff = mem.readInt(u64, data[40..48], .little);
    const e_shentsize = mem.readInt(u16, data[58..60], .little);
    const e_shnum = mem.readInt(u16, data[60..62], .little);
    const e_shstrndx = mem.readInt(u16, data[62..64], .little);

    // Section header string table
    const shstrtab_hdr = e_shoff + @as(u64, e_shstrndx) * e_shentsize;
    if (shstrtab_hdr + 64 > data.len) return null;
    const shstrtab_offset = mem.readInt(u64, data[@intCast(shstrtab_hdr + 24)..][0..8], .little);
    const shstrtab_size = mem.readInt(u64, data[@intCast(shstrtab_hdr + 32)..][0..8], .little);
    const shstrtab = data[@intCast(shstrtab_offset)..][0..@intCast(shstrtab_size)];

    // Search sections for .debug_line
    var idx: u16 = 0;
    while (idx < e_shnum) : (idx += 1) {
        const sh_off: usize = @intCast(e_shoff + @as(u64, idx) * e_shentsize);
        if (sh_off + 64 > data.len) continue;

        const sh_name = mem.readInt(u32, data[sh_off..][0..4], .little);
        if (sh_name >= shstrtab.len) continue;

        const name_end = mem.indexOfScalar(u8, shstrtab[sh_name..], 0) orelse continue;
        const name = shstrtab[sh_name..][0..name_end];
        if (!mem.eql(u8, name, debug_line_name)) continue;

        const sh_offset = mem.readInt(u64, data[sh_off + 24 ..][0..8], .little);
        const sh_size = mem.readInt(u64, data[sh_off + 32 ..][0..8], .little);
        return .{ .offset = @intCast(sh_offset), .size = @intCast(sh_size) };
    }

    return null;
}

// ============================================================
// Tests
// ============================================================

test "ULEB128 encoding of DW_LNCT_LLVM_source is 0x2001" {
    const val = (@as(u16, DW_LNCT_LLVM_SOURCE[0] & 0x7f)) | (@as(u16, DW_LNCT_LLVM_SOURCE[1]) << 7);
    try std.testing.expectEqual(@as(u16, 0x2001), val);
}

test "ULEB128 encoding of replacement is DW_LNCT_timestamp (0x0003)" {
    const val = (@as(u16, DW_LNCT_TIMESTAMP[0] & 0x7f)) | (@as(u16, DW_LNCT_TIMESTAMP[1]) << 7);
    try std.testing.expectEqual(@as(u16, 0x0003), val);
}

// Build a minimal ELF64 binary with one named section for testing.
// Layout: ELF header (64) | section_data padding (sec_offset..sec_offset+sec_size)
//         | shstrtab data | null section header (64) | shstrtab section header (64) | named section header (64)
fn buildTestElf64(buf: []u8, section_name: []const u8, sec_offset: u64, sec_size: u64) []u8 {
    @memset(buf, 0);

    // shstrtab: "\0" + section_name + "\0"
    const shstrtab_size: u16 = @intCast(1 + section_name.len + 1);
    const shstrtab_offset: u64 = sec_offset + sec_size;
    const sh_offset: u64 = shstrtab_offset + shstrtab_size;
    const e_shentsize: u16 = 64;
    const e_shnum: u16 = 3; // null + shstrtab + target section
    const e_shstrndx: u16 = 1; // shstrtab is section 1
    const total_len: usize = @intCast(sh_offset + @as(u64, e_shnum) * e_shentsize);

    // ELF magic
    @memcpy(buf[0..4], elf_magic);
    buf[4] = 2; // ELF64
    buf[5] = 1; // little-endian
    buf[6] = 1; // ELF version

    // e_shoff (offset 40, 8 bytes, little-endian)
    mem.writeInt(u64, buf[40..48], sh_offset, .little);
    // e_shentsize (offset 58, 2 bytes)
    mem.writeInt(u16, buf[58..60], e_shentsize, .little);
    // e_shnum (offset 60, 2 bytes)
    mem.writeInt(u16, buf[60..62], e_shnum, .little);
    // e_shstrndx (offset 62, 2 bytes)
    mem.writeInt(u16, buf[62..64], e_shstrndx, .little);

    // Write shstrtab data: "\0" + section_name + "\0"
    const strtab_start: usize = @intCast(shstrtab_offset);
    buf[strtab_start] = 0;
    @memcpy(buf[strtab_start + 1 ..][0..section_name.len], section_name);
    buf[strtab_start + 1 + section_name.len] = 0;

    // Section headers start at sh_offset
    const sh_base: usize = @intCast(sh_offset);

    // Section 0: null (all zeros, already done)

    // Section 1: shstrtab
    const sh1 = sh_base + e_shentsize;
    mem.writeInt(u32, buf[sh1..][0..4], 0, .little); // sh_name (points to "\0" which is fine)
    // sh_offset (offset +24)
    mem.writeInt(u64, buf[sh1 + 24 ..][0..8], shstrtab_offset, .little);
    // sh_size (offset +32)
    mem.writeInt(u64, buf[sh1 + 32 ..][0..8], @as(u64, shstrtab_size), .little);

    // Section 2: target section (e.g., .debug_line)
    const sh2 = sh_base + 2 * e_shentsize;
    mem.writeInt(u32, buf[sh2..][0..4], 1, .little); // sh_name = 1 (offset into shstrtab)
    mem.writeInt(u64, buf[sh2 + 24 ..][0..8], sec_offset, .little);
    mem.writeInt(u64, buf[sh2 + 32 ..][0..8], sec_size, .little);

    return buf[0..total_len];
}

test "findDebugLineSection valid ELF64 with .debug_line" {
    var buf: [1024]u8 = undefined;
    const elf = buildTestElf64(&buf, ".debug_line", 64, 100);
    const result = findDebugLineSection(elf);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 64), result.?.offset);
    try std.testing.expectEqual(@as(usize, 100), result.?.size);
}

test "findDebugLineSection ELF32 returns null" {
    var buf: [1024]u8 = undefined;
    const elf = buildTestElf64(&buf, ".debug_line", 64, 100);
    // Overwrite EI_CLASS to ELFCLASS32
    elf[4] = 1;
    try std.testing.expectEqual(@as(?SectionInfo, null), findDebugLineSection(elf));
}

test "findDebugLineSection no .debug_line section" {
    var buf: [1024]u8 = undefined;
    const elf = buildTestElf64(&buf, ".text", 64, 100);
    try std.testing.expectEqual(@as(?SectionInfo, null), findDebugLineSection(elf));
}

test "findDebugLineSection truncated section header" {
    var buf: [1024]u8 = undefined;
    const elf = buildTestElf64(&buf, ".debug_line", 64, 100);
    // Truncate so last section header is incomplete
    const truncated = elf[0 .. elf.len - 10];
    try std.testing.expectEqual(@as(?SectionInfo, null), findDebugLineSection(truncated));
}
