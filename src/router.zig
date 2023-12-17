const std = @import("std");
const testing = std.testing;
const Node = @import("tree.zig").Node;
const Params = @import("params.zig").Params;

pub fn Match(comptime T: type) type {
    return struct {
        value: T,
        params: Params,

        pub fn deinit(sellf: *Match) void {
            sellf.params.deinit();
        }
    };
}

pub fn Router(comptime T: type) type {
    return struct {
        root: Node(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .root = Node(T).default(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }

        pub fn insert(self: *Self, path: []const u8, value: T) !void {
            try self.root.insert(path, value);
        }

        pub fn match(self: *Self, path: []const u8) !Match(T) {
            const rtn = try self.root.at(path);
            return .{
                .value = rtn.value,
                .params = rtn.params,
            };
        }
    };
}

test "test Router" {
    var router = Router([]const u8).init(std.testing.allocator);
    defer router.deinit();

    try router.insert("/search", "search handler");
    try router.insert("/support", "support handler");
    try router.insert("/static/:name", "static handler");
    try router.insert("/static-files/*p", "files handler");

    {
        const match = try router.match("/search");
        try testing.expectEqualStrings("search handler", match.value);
    }

    {
        const match = try router.match("/support");
        try testing.expectEqualStrings("support handler", match.value);
    }

    {
        const match = try router.match("/static/layout.css");
        try testing.expectEqualStrings("static handler", match.value);
        try testing.expectEqualStrings("layout.css", match.params.get("name").?);
    }
}
