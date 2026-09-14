//! Test-only scratch directory, unique per test so two checkouts can run
//! `zig build test` at the same time. Lives under `.zig-cache/tmp`.
const std = @import("std");

pub const TestTree = struct {
    tmp: std.testing.TmpDir,
    allocator: std.mem.Allocator,
    root: []const u8,

    /// `scan` and `getGitBranch` open everything through absolute paths, so
    /// the tmpDir is resolved to an absolute root once.
    pub fn init(allocator: std.mem.Allocator) !TestTree {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buf);
        return .{ .tmp = tmp, .allocator = allocator, .root = try allocator.dupe(u8, buf[0..n]) };
    }

    pub fn deinit(self: *TestTree) void {
        self.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Absolute path of `rel` under the root; the directory need not exist.
    pub fn path(self: TestTree, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, rel });
    }
};
