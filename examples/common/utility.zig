const std = @import("std");

/// A type that formats an UTF-8 string and escape non-printable characters.
const DebugStr = struct {
    /// Allocated used in some cases during the formatting operation.
    allocator: std.mem.Allocator,
    /// The string to format.
    s: []const u8,

    fn formatUnpadded(self: DebugStr, quote: []const u8, writer: std.io.AnyWriter) !void {
        try writer.writeAll(quote);
        for (self.s) |c| {
            if (std.ascii.isPrint(c) or c >= 0x80) {
                try writer.writeByte(c);
            } else {
                switch (c) {
                    0x07 => try writer.writeAll("\\a"),
                    0x08 => try writer.writeAll("\\b"),
                    0x1B => try writer.writeAll("\\e"),
                    0x0C => try writer.writeAll("\\f"),
                    0x0A => try writer.writeAll("\\n"),
                    0x0D => try writer.writeAll("\\r"),
                    0x09 => try writer.writeAll("\\t"),
                    0x0B => try writer.writeAll("\\v"),
                    0x5C => try writer.writeAll("\\\\"),
                    else => try writer.print("\\x{X:>02}", .{c}),
                }
            }
        }
        try writer.writeAll(quote);
    }

    pub fn format(self: DebugStr, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        if (opts.width != null) {
            var list = std.ArrayList(u8).init(self.allocator);
            defer list.deinit();
            try list.ensureTotalCapacity(self.s.len);
            try self.formatUnpadded(fmt, list.writer().any());
            return std.fmt.formatBuf(list.items, opts, writer);
        } else {
            return self.formatUnpadded(fmt, writer);
        }
    }
};

/// Returns a type that formats the provided string by preventing unprintable characters from being
/// printed.
pub fn debugStr(a: std.mem.Allocator, s: []const u8) DebugStr {
    return DebugStr{ .allocator = a, .s = s };
}
