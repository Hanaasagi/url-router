const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

// 32 bytes
pub const Param = struct {
    key: []const u8, // 8 bytes + 8 bytes
    value: []const u8,

    const Self = @This();
    pub fn init(key: []const u8, value: []const u8) Self {
        return .{
            .key = key,
            .value = value,
        };
    }
};

// most routes have 1-3 dynamic parameters, so we can avoid a heap allocation in common cases.
const SMALL: usize = 3;

// 112 bytes
const ParamsInner = union(enum) {
    None: void,
    Small: std.meta.Tuple(&[_]type{ [SMALL]Param, usize }), // 32 bytes * 3 + 8 bytes
    Large: std.ArrayList(Param),
};

// 128 bytes
pub const Params = struct {
    inner: ParamsInner,
    allocator: Allocator, // 16 bytes

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .inner = .None,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.inner == .Large) {
            self.inner.Large.deinit();
        }
    }

    pub fn len(self: Self) usize {
        return switch (self.inner) {
            .None => 0,
            .Small => self.inner.Small[1],
            .Large => self.inner.Large.items.len,
        };
    }

    pub fn is_empty(self: Self) bool {
        return self.len() == 0;
    }

    pub fn truncate(self: *Self, n: usize) void {
        switch (self.inner) {
            .None => {},
            .Small => {
                // reset, no clean
                self.inner.Small[1] = n;
            },
            .Large => {
                self.inner.Large.shrinkRetainingCapacity(n);
            },
        }
    }

    pub fn get(self: Self, key: []const u8) ?[]const u8 {
        switch (self.inner) {
            .None => {
                return null;
            },
            .Small => |item| {
                const l = item[1];
                const arr = item[0];
                for (0..l) |i| {
                    const param = arr[i];
                    if (std.mem.eql(u8, param.key, key)) {
                        return arr[i].value;
                    }
                }
                return null;
            },
            .Large => |item| {
                for (item.items) |param| {
                    if (std.mem.eql(u8, param.key, key)) {
                        return param.value;
                    }
                }
                return null;
            },
        }
    }

    fn drain_to_large(self: *Self) !void {
        @setCold(true);
        var arr = std.ArrayList(Param).init(self.allocator);
        std.debug.assert(self.inner == .Small);

        for (0..self.inner.Small[1]) |i| {
            const param = self.inner.Small[0][i];
            try arr.append(param);
        }
        self.inner = ParamsInner{ .Large = arr };
    }

    pub fn push(self: *Self, key: []const u8, value: []const u8) !void {
        const param = Param.init(key, value);
        switch (self.inner) {
            .None => {
                self.inner = ParamsInner{ .Small = .{ [_]Param{ param, undefined, undefined }, 1 } };
            },
            .Small => {
                if (self.inner.Small[1] == SMALL) {
                    try self.drain_to_large();
                    std.debug.assert(self.inner == .Large);
                    try self.push(key, value);
                    return;
                }

                self.inner.Small[0][self.inner.Small[1]] = param;
                self.inner.Small[1] += 1;
            },
            .Large => {
                try self.inner.Large.append(param);
            },
        }
    }

    pub fn iter(self: *Self) ParamsIter {
        return ParamsIter.init(self);
    }
};

pub const ParamsIter = struct {
    inner: []Param,
    cursor: usize,
    length: usize,

    const Self = @This();

    pub fn init(params: *Params) Self {
        switch (params.inner) {
            .None => {
                return .{
                    .inner = undefined,
                    .cursor = 0,
                    .length = 0,
                };
            },
            .Small => {
                return .{
                    .inner = &params.inner.Small[0],
                    .cursor = 0,
                    .length = params.inner.Small[1],
                };
            },
            .Large => {
                return .{
                    .inner = params.inner.Large.items,
                    .cursor = 0,
                    .length = params.inner.Large.items.len,
                };
            },
        }
    }

    pub fn next(self: *Self) ?Param {
        if (self.length == 0 or self.cursor >= self.length) {
            return null;
        }

        const param = self.inner[self.cursor];
        self.cursor += 1;
        return param;
    }
};

test "test @sizeOf" {
    try testing.expect(@sizeOf(Param) == 32);
    try testing.expect(@sizeOf(ParamsInner) == 112);
    try testing.expect(@sizeOf(Params) == 128);
}

test "test Params.push" {
    var params = Params.init(testing.allocator);
    defer params.deinit();

    try testing.expect(params.len() == 0);

    try params.push("key_1", "value_1");
    try testing.expect(params.len() == 1);

    try params.push("key_2", "value_2");
    try testing.expect(params.len() == 2);

    try params.push("key_3", "value_3");
    try testing.expect(params.len() == 3);

    try params.push("key_4", "value_4");
    try testing.expect(params.len() == 4);
}

test "test Params.get" {
    var params = Params.init(testing.allocator);
    defer params.deinit();

    try testing.expect(params.len() == 0);

    try testing.expect(params.get("key_1") == null);
    try params.push("key_1", "value_1");
    try testing.expectEqualStrings("value_1", params.get("key_1").?);

    try testing.expect(params.get("key_2") == null);
    try params.push("key_2", "value_2");
    try testing.expectEqualStrings("value_2", params.get("key_2").?);

    try testing.expect(params.get("key_3") == null);
    try params.push("key_3", "value_3");
    try testing.expectEqualStrings("value_3", params.get("key_3").?);

    try testing.expect(params.get("key_4") == null);
    try params.push("key_4", "value_4");
    try testing.expectEqualStrings("value_4", params.get("key_4").?);
}

test "test Params.iter" {
    var params = Params.init(testing.allocator);
    defer params.deinit();

    {
        var iter = params.iter();
        while (iter.next()) |_| {
            try testing.expect(false);
        }
    }

    try params.push("key_1", "value_1");
    try params.push("key_2", "value_2");

    {
        var iter = params.iter();
        var param = iter.next().?;
        try testing.expectEqualStrings("key_1", param.key);
        try testing.expectEqualStrings("value_1", param.value);

        param = iter.next().?;
        try testing.expectEqualStrings("key_2", param.key);
        try testing.expectEqualStrings("value_2", param.value);

        try testing.expect(iter.next() == null);
    }

    try params.push("key_3", "value_3");
    try params.push("key_4", "value_4");

    {
        var iter = params.iter();
        var param = iter.next().?;
        try testing.expectEqualStrings("key_1", param.key);
        try testing.expectEqualStrings("value_1", param.value);

        param = iter.next().?;
        try testing.expectEqualStrings("key_2", param.key);
        try testing.expectEqualStrings("value_2", param.value);
        param = iter.next().?;

        try testing.expectEqualStrings("key_3", param.key);
        try testing.expectEqualStrings("value_3", param.value);

        param = iter.next().?;
        try testing.expectEqualStrings("key_4", param.key);
        try testing.expectEqualStrings("value_4", param.value);

        try testing.expect(iter.next() == null);
    }
}
