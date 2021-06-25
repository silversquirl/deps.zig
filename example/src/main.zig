const std = @import("std");
const uuid = @import("uuid");
pub fn main() !void {
    std.debug.print("{}\n", .{uuid.Uuid.v4()});
}
