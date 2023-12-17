const std = @import("std");
const InsertError = @import("error.zig").InsertError;
const MatchError = @import("error.zig").MatchError;
const Params = @import("params.zig").Params;
const testing = std.testing;

/// An ordered list of route parameters keys for a specific route, stored at leaf nodes.
const ParamRemapping = std.ArrayList([]const u8);

pub fn Skipped(comptime T: type) type {
    return struct {
        path: []const u8,
        node: *Node(T),
        params: usize,
    };
}

pub fn deinitParamRemapping(param_remapping: *ParamRemapping) void {
    for (param_remapping.items) |item| {
        param_remapping.allocator.free(item);
    }
    param_remapping.deinit();
}

pub inline fn to_owned(allocator: std.mem.Allocator, slices: []const u8) !std.ArrayList(u8) {
    var new = std.ArrayList(u8).init(allocator);
    try new.appendSlice(slices);
    return new;
}

// Searches for a wildcard segment and checks the path for invalid characters.
fn find_wildcard(path: []const u8) !?struct {
    wildcard: []const u8,
    wildcard_index: usize,
} {
    for (path, 0..) |c, start| {
        // a wildcard starts with ':' (param) or '*' (catch-all)
        if (c != ':' and c != '*') {
            continue;
        }

        for (path[start + 1 ..], 0..) |cc, end| {
            switch (cc) {
                '/' => {
                    return .{ .wildcard = path[start .. start + 1 + end], .wildcard_index = start };
                },
                ':', '*' => {
                    return InsertError.TooManyParams;
                },
                else => {},
            }
        }

        return .{ .wildcard = path[start..], .wildcard_index = start };
    }

    return null;
}

/// Returns `path` with normalized route parameters, and a parameter remapping
/// to store at the leaf node for this route.
fn normalize_params(allocator: std.mem.Allocator, path: *std.ArrayList(u8)) !struct { route: std.ArrayList(u8), remapping: ParamRemapping } {
    var start: usize = 0;
    // TODO: remove this allocator
    var original = ParamRemapping.init(allocator);

    // parameter names are normalized alphabetically
    var next: u8 = 'a';

    while (true) {
        const r = try find_wildcard(path.items[start..]);
        if (r == null) {
            return .{
                .route = path.*,
                .remapping = original,
            };
        }
        const wildcard = r.?.wildcard;
        var wildcard_index = r.?.wildcard_index;

        // makes sure the param has a valid name
        if (wildcard.len < 2) {
            return InsertError.UnnamedParam;
        }

        // don't need to normalize catch-all parameters
        if (wildcard[0] == '*') {
            start += wildcard_index + wildcard.len;
            continue;
        }

        wildcard_index += start;

        // normalize the parameter
        const removed = path.items[wildcard_index..(wildcard_index + wildcard.len)];
        // remember the original name for remappings
        // TODO: remove this allocator
        try original.append(try allocator.dupe(u8, removed));

        try path.replaceRange(wildcard_index, wildcard.len, &[_]u8{ ':', next });

        // get the next key
        next += 1;
        if (next > 'z') {
            @panic("too many route parameters");
        }

        start = wildcard_index + 2;
    }
}

/// Restores `route` to it's original, denormalized form.
fn denormalize_params(route: *std.ArrayList(u8), params: ParamRemapping) !void {
    var start: usize = 0;
    var i: usize = 0;

    while (true) {
        // find the next wildcard
        const r = find_wildcard(route.items[start..]) catch unreachable;
        if (r == null) {
            return;
        }
        const wildcard = r.?.wildcard;
        var wildcard_index = r.?.wildcard_index;

        wildcard_index += start;

        if (params.items.len <= i) {
            return;
        }
        const next = params.items[i];

        try route.replaceRange(wildcard_index, wildcard.len, next);

        i += 1;
        start = wildcard_index + 2;
    }
}

/// The types of nodes the tree can hold
pub const NodeType = enum {
    /// The root path
    Root,
    /// A route parameter, ex: `/:id`.
    Param,
    /// A catchall parameter, ex: `/*file`
    CatchAll,
    /// Static
    Static,
};

/// A radix tree used for URL path matching.
pub fn Node(comptime T: type) type {
    return struct {
        priority: u32,
        wild_child: bool,
        // TODO:
        indices: std.ArrayList(u8),
        value: ?T,
        param_remapping: ParamRemapping,
        node_type: NodeType,
        prefix: std.ArrayList(u8),
        children: std.ArrayList(@This()),

        // TODO:
        // really want to remove
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn default(allocator: std.mem.Allocator) Self {
            return .{
                .param_remapping = ParamRemapping.init(allocator),
                .prefix = std.ArrayList(u8).init(allocator),
                .wild_child = false,
                .node_type = .Static,
                .indices = std.ArrayList(u8).init(allocator),
                .children = std.ArrayList(Self).init(allocator),
                .value = null,
                .priority = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.children.items) |*child| {
                child.deinit();
            }

            self.children.deinit();
            self.indices.deinit();
            self.prefix.deinit();
            deinitParamRemapping(&self.param_remapping);
        }

        pub fn insert(self: *Self, route_: []const u8, value: T) !void {
            var route = std.ArrayList(u8).init(self.allocator);
            defer route.deinit();
            try route.appendSlice(route_);

            const rtn = try normalize_params(self.allocator, &route);
            var prefix = rtn.route.items;
            route = rtn.route;
            const param_remapping = rtn.remapping;

            self.priority += 1;

            // the tree is empty
            if (self.prefix.items.len == 0 and self.children.items.len == 0) {
                const last = try self.insert_child(prefix, route.items, value);
                last.param_remapping = param_remapping;
                self.node_type = NodeType.Root;
                return;
            }

            var current = self;

            walk: while (true) {
                // find the longest common prefix
                const len = @min(prefix.len, current.prefix.items.len);
                var common_prefix: usize = 0;
                for (0..len) |i| {
                    if (prefix[i] != current.prefix.items[i]) {
                        common_prefix = i;
                        break;
                    }
                } else {
                    common_prefix = len;
                }

                // the common prefix is a substring of the current node's prefix, split the node
                if (common_prefix < current.prefix.items.len) {
                    const child = Self{
                        .prefix = try to_owned(self.allocator, current.prefix.items[common_prefix..]),
                        .node_type = .Static,
                        // TODO: replace
                        .children = current.children,
                        .wild_child = current.wild_child,
                        .indices = try current.indices.clone(),
                        .value = current.value,
                        .param_remapping = current.param_remapping,
                        .priority = current.priority - 1,
                        .allocator = self.allocator,
                    };

                    current.children = std.ArrayList(Self).init(self.allocator);
                    current.indices = std.ArrayList(u8).init(self.allocator);
                    current.param_remapping = ParamRemapping.init(self.allocator);

                    // the current node now holds only the common prefix
                    try current.children.append(child);
                    try current.indices.append(current.prefix.items[common_prefix]);

                    current.prefix.deinit();
                    current.prefix = try to_owned(self.allocator, prefix[0..common_prefix]);
                    current.wild_child = false;
                }

                // the route has a common prefix, search deeper
                if (prefix.len > common_prefix) {
                    prefix = prefix[common_prefix..];

                    const next = prefix[0];

                    // `/` after param
                    if (current.node_type == .Param and next == '/' and current.children.items.len == 1) {
                        current = &(current.children.items[0]);
                        current.priority += 1;

                        continue :walk;
                    }

                    // find a child that matches the next path byte
                    var i: usize = 0;
                    while (i < current.indices.items.len) : (i += 1) {
                        // found a match
                        if (next == current.indices.items[i]) {
                            i = try current.update_child_priority(i);
                            current = &(current.children.items[i]);
                            continue :walk;
                        }
                    }

                    // not a wildcard and there is no matching child node, create a new one
                    if (!(next == ':' or next == '*') and current.node_type != .CatchAll) {
                        try current.indices.append(next);
                        var n_child = try current.add_child(Self.default(self.allocator));
                        n_child = try current.update_child_priority(n_child);

                        // insert into the new node
                        var last = try current.children.items[n_child].insert_child(prefix, route.items, value);
                        last.param_remapping = param_remapping;
                        return;
                    }

                    // inserting a wildcard, and this node already has a wildcard child
                    if (current.wild_child) {
                        // wildcards are always at the end
                        current = &(current.children.items[current.children.items.len - 1]);
                        current.priority += 1;

                        // make sure the wildcard matches
                        if (prefix.len < current.prefix.items.len or !std.mem.eql(u8, current.prefix.items, prefix[0..current.prefix.items.len])
                        // catch-alls cannot have children
                        or current.node_type == .CatchAll
                        // check for longer wildcard, e.g. :name and :names
                        or (current.prefix.items.len < prefix.len and prefix[current.prefix.items.len] != '/')) {
                            return InsertError.Conflict;
                        }

                        continue :walk;
                    }

                    // otherwise, create the wildcard node
                    var last = try current.insert_child(prefix, route.items, value);
                    last.param_remapping = param_remapping;
                    return;
                }

                // exact match, this node should be empty
                if (current.value != null) {
                    return InsertError.Conflict;
                }

                // add the value to current node
                current.value = value;
                current.param_remapping = param_remapping;

                return;
            }
        }

        // add a child node, keeping wildcards at the end
        fn add_child(self: *Self, child: Node(T)) !usize {
            const len = self.children.items.len;

            if (self.wild_child and len > 0) {
                try self.children.insert(len - 1, child);
                return len - 1;
            } else {
                try self.children.append(child);
                return len;
            }
        }

        // increments priority of the given child and reorders if necessary.
        //
        // returns the new index of the child
        fn update_child_priority(self: *Self, i: usize) !usize {
            self.children.items[i].priority += 1;
            const priority = self.children.items[i].priority;

            // adjust position (move to front)
            var updated = i;
            while (updated > 0 and self.children.items[updated - 1].priority < priority) {
                // swap node positions
                const tmp = self.children.items[updated];
                self.children.items[updated] = self.children.items[updated - 1];
                self.children.items[updated - 1] = tmp;
                updated -= 1;
            }

            // build new index list
            if (updated != i) {
                var tmp: [2048]u8 = undefined;
                std.mem.copyForwards(u8, tmp[0..], self.indices.items[0..updated]);
                std.mem.copyForwards(u8, tmp[updated..], self.indices.items[i .. i + 1]);
                std.mem.copyForwards(u8, tmp[updated + 1 ..], self.indices.items[updated..i]);
                std.mem.copyForwards(u8, tmp[updated + 1 + i - updated ..], self.indices.items[i + 1 ..]);

                const total = (updated + i + 1 - i + i - updated + self.indices.items.len - (i + 1));
                try self.indices.ensureTotalCapacity(total);
                @memcpy(self.indices.items[0..total], tmp[0..total]);
                self.indices.items.len = total;
            }

            return updated;
        }

        // insert a child node at this node
        fn insert_child(self: *Self, prefix_: []const u8, route: []const u8, val: T) !*Node(T) {
            var current = self;
            var prefix = prefix_;
            while (true) {
                // search for a wildcard segment
                const r = try find_wildcard(prefix);
                if (r == null) {
                    current.value = val;
                    current.prefix = try to_owned(self.allocator, prefix);
                    return current;
                }
                const wildcard = r.?.wildcard;
                const wildcard_index = r.?.wildcard_index;

                // regular route parameter
                if (wildcard[0] == ':') {
                    // insert prefix before the current wildcard
                    if (wildcard_index > 0) {
                        current.prefix = try to_owned(self.allocator, prefix[0..wildcard_index]);
                        // TODO: mutable slice
                        prefix = prefix[wildcard_index..];
                    }

                    var child = Self.default(self.allocator);
                    child.node_type = .Param;
                    child.prefix = try to_owned(self.allocator, wildcard);

                    var n_child = try current.add_child(child);
                    current.wild_child = true;
                    // TODO:
                    current = &(current.children.items[n_child]);
                    current.priority += 1;

                    // if the route doesn't end with the wildcard, then there
                    // will be another non-wildcard subroute starting with '/'
                    if (wildcard.len < prefix.len) {
                        {
                            prefix = prefix[wildcard.len..];
                            child = Self.default(self.allocator);
                            child.priority = 1;

                            n_child = try current.add_child(child);
                            current = &(current.children.items[n_child]);
                            continue;
                        }
                    }

                    // otherwise we're done. Insert the value in the new leaf
                    current.value = val;
                    return current;

                    // catch-all route
                } else if (wildcard[0] == '*') {
                    // "/foo/*x/bar"
                    if (wildcard_index + wildcard.len != prefix.len) {
                        return InsertError.InvalidCatchAll;
                    }

                    // "*x" without leading `/`
                    if (std.mem.eql(u8, prefix, route) and route[0] == '/') {
                        return InsertError.InvalidCatchAll;
                    }

                    // insert prefix before the current wildcard
                    if (wildcard_index > 0) {
                        current.prefix = try to_owned(self.allocator, prefix[0..wildcard_index]);
                        prefix = prefix[wildcard_index..];
                    }

                    var child = Self.default(self.allocator);
                    child.prefix = try to_owned(self.allocator, prefix);
                    child.node_type = .CatchAll;
                    child.value = val;
                    child.priority = 1;

                    const i = try current.add_child(child);
                    current.wild_child = true;

                    return &(current.children.items[i]);
                }
            }
        }

        // it's a bit sad that we have to introduce unsafe here but rust doesn't really have a way
        // to abstract over mutability, so `UnsafeCell` lets us avoid having to duplicate logic between
        // `at` and `at_mut`
        pub fn at(self: *Self, full_path: []const u8) !struct {
            value: T,
            params: Params,
        } {
            var current = self;
            var path = full_path;
            var backtracking = false;
            var params = Params.init(self.allocator);
            var skipped_nodes = std.ArrayList(Skipped(T)).init(self.allocator);

            walk: while (true) {
                // the path is longer than this node's prefix, we are expecting a child node
                if (path.len > current.prefix.items.len) {
                    // the prefix matches
                    const prefix = path[0..current.prefix.items.len];
                    const rest = path[current.prefix.items.len..];

                    if (std.mem.eql(u8, prefix, current.prefix.items)) {
                        const first = rest[0];
                        const consumed = path;
                        path = rest;

                        // try searching for a matching static child unless we are currently
                        // backtracking, which would mean we already traversed them
                        if (!backtracking) {
                            var i: ?usize = null;
                            for (0..current.indices.items.len) |j| {
                                if (current.indices.items[j] == first) {
                                    i = j;
                                    break;
                                }
                            }
                            if (i != null) {
                                // keep track of wildcard routes we skipped to backtrack to later if
                                // we don't find a math
                                if (current.wild_child) {
                                    try skipped_nodes
                                        .append(Skipped(T){
                                        .path = consumed,
                                        .node = current,
                                        .params = params.len(),
                                    });
                                }
                                // child won't match because of an extra trailing slash
                                if (std.mem.eql(u8, path, "/") and !std.mem.eql(u8, current.children.items[i.?].prefix.items, "/") and current.value != null) {
                                    return MatchError.ExtraTrailingSlash;
                                }

                                // continue with the child node
                                current = &current.children.items[i.?];
                                continue :walk;
                            }
                        }
                        if (!current.wild_child) {
                            if (std.mem.eql(u8, path, "/") and current.value != null) {
                                return MatchError.ExtraTrailingSlash;
                            }
                            if (!std.mem.eql(u8, path, "/")) {
                                while (skipped_nodes.popOrNull()) |*skipped| {
                                    if (std.mem.endsWith(u8, skipped.path, path)) {
                                        path = skipped.path;
                                        current = skipped.node;
                                        params.truncate(skipped.params);
                                        backtracking = true;
                                        continue :walk;
                                    }
                                }
                            }
                            return MatchError.NotFound;
                        }
                        current = @constCast(&current.children.getLast());
                        switch (current.node_type) {
                            .Param => {
                                var i: ?usize = null;
                                for (0..path.len) |j| {
                                    if (path[j] == '/') {
                                        i = j;
                                        break;
                                    }
                                }
                                if (i != null) {
                                    const param = path[0..i.?];
                                    const rest_ = path[i.?..];
                                    if (current.children.items.len == 1) {
                                        const child = current.children.items[0];
                                        if (std.mem.eql(u8, rest_, "/") and !(std.mem.eql(u8, child.prefix.items, "/")) and current.value != null) {
                                            return MatchError.ExtraTrailingSlash;
                                        }
                                        try params.push(current.prefix.items[1..], param);
                                        path = rest_;
                                        current = &current.children.items[0];
                                        backtracking = false;
                                        continue :walk;
                                    }
                                    if (path.len == i.? + 1) {
                                        return MatchError.ExtraTrailingSlash;
                                    }
                                    if (!std.mem.eql(u8, path, "/")) {
                                        while (skipped_nodes.popOrNull()) |*skipped| {
                                            if (std.mem.endsWith(u8, skipped.path, path)) {
                                                path = skipped.path;
                                                current = skipped.node;
                                                params.truncate(skipped.params);
                                                backtracking = true;
                                                continue :walk;
                                            }
                                        }
                                    }
                                    return MatchError.NotFound;
                                    // this is the last path segment
                                } else {
                                    // store the parameter value
                                    try params.push(current.prefix.items[1..], path);
                                    if (current.value != null) {
                                        switch (params.inner) {
                                            .None => {},
                                            .Small => {
                                                const length = params.inner.Small[1];
                                                for (0..length) |j| {
                                                    params.inner.Small[0][j].key = current.param_remapping.items[j][1..];
                                                }
                                            },
                                            .Large => {
                                                const length = params.inner.Large.items.len;
                                                for (0..length) |j| {
                                                    params.inner.Large.items[j].key = current.param_remapping.items[j][1..];
                                                }
                                            },
                                        }
                                        return .{
                                            .value = current.value.?,
                                            .params = params,
                                        };
                                    }

                                    // check the child node in case the path is missing a trailing slash
                                    if (current.children.items.len == 1) {
                                        current = &current.children.items[0];
                                        if ((std.mem.eql(u8, current.prefix.items, "/") and current.value != null) or (current.prefix.items.len == 0 and std.mem.eql(u8, current.indices.items, "/"))) {
                                            return MatchError.MissingTrailingSlash;
                                        }
                                        if (!std.mem.eql(u8, path, "/")) {
                                            while (skipped_nodes.popOrNull()) |*skipped| {
                                                if (std.mem.eql(u8, skipped.path, path)) {
                                                    path = skipped.path;
                                                    current = skipped.node;
                                                    params.truncate(skipped.params);
                                                    backtracking = true;
                                                    continue :walk;
                                                }
                                            }
                                        }
                                    }
                                    return MatchError.NotFound;
                                }
                            },
                            .CatchAll => {
                                if (current.value != null) {
                                    switch (params.inner) {
                                        .None => {},
                                        .Small => {
                                            const length = params.inner.Small[1];
                                            for (0..length) |i| {
                                                params.inner.Small[0][i].key = current.param_remapping.items[i][1..];
                                            }
                                        },
                                        .Large => {
                                            const length = params.inner.Large.items.len;
                                            for (0..length) |i| {
                                                params.inner.Large.items[i].key = current.param_remapping.items[i][1..];
                                            }
                                        },
                                    }

                                    // store the final catch-all parameter
                                    try params.push(current.prefix.items[1..], path);

                                    return .{
                                        .value = current.value.?,
                                        .params = params,
                                    };
                                } else {
                                    return MatchError.NotFound;
                                }
                            },
                            else => {
                                unreachable;
                            },
                        }
                    }
                }
                if (std.mem.eql(u8, path, current.prefix.items)) {
                    if (current.value != null) {
                        switch (params.inner) {
                            .None => {},
                            .Small => {
                                const length = params.inner.Small[1];
                                for (0..length) |i| {
                                    params.inner.Small[0][i].key = current.param_remapping.items[i][1..];
                                }
                            },
                            .Large => {
                                const length = params.inner.Large.items.len;
                                for (0..length) |i| {
                                    params.inner.Large.items[i].key = current.param_remapping.items[i][1..];
                                }
                            },
                        }
                        return .{
                            .value = current.value.?,
                            .params = params,
                        };
                    }
                    while (skipped_nodes.popOrNull()) |*skipped| {
                        if (std.mem.endsWith(u8, skipped.path, path)) {
                            path = skipped.path;
                            current = skipped.node;
                            params.truncate(skipped.params);
                            backtracking = true;
                            continue :walk;
                        }
                    }
                    if (std.mem.eql(u8, path, "/") and current.wild_child and current.node_type != .Root) {
                        if (full_path[full_path.len - 1] == '/') {
                            return MatchError.ExtraTrailingSlash;
                        } else {
                            return MatchError.MissingTrailingSlash;
                        }
                    }
                    if (!backtracking) {
                        var i: ?usize = null;
                        for (0..current.indices.items.len) |j| {
                            if (current.indices.items[j] == '/') {
                                i = j;
                                break;
                            }
                        }
                        if (i != null) {
                            current = &current.children.items[i.?];
                            if (current.prefix.items.len == 1 and current.value != null) {
                                return MatchError.MissingTrailingSlash;
                            }
                        }
                    }
                    return MatchError.NotFound;
                }
                const last = current.prefix.getLastOrNull();
                if (last != null and last.? == '/' and
                    std.mem.eql(u8, current.prefix.items[0 .. current.prefix.items.len - 1], path) and
                    current.value != null)
                {
                    return MatchError.MissingTrailingSlash;
                }
                if (!std.mem.eql(u8, path, "/")) {
                    while (skipped_nodes.popOrNull()) |*skipped| {
                        if (std.mem.endsWith(u8, skipped.path, path)) {
                            path = skipped.path;
                            current = skipped.node;
                            params.truncate(skipped.params);
                            backtracking = true;
                            continue :walk;
                        }
                    }
                }
                return MatchError.NotFound;
            }
        }
    };
}

test "test find_wildcard" {
    {
        const rtn = try find_wildcard("");
        try testing.expect(rtn == null);
    }

    {
        const rtn = try find_wildcard("/");
        try testing.expect(rtn == null);
    }

    {
        const rtn = try find_wildcard("/a/b/c");
        try testing.expect(rtn == null);
    }

    {
        const rtn = try find_wildcard("/a/b/*");
        try testing.expectEqualStrings("*", rtn.?.wildcard);
        try testing.expect(rtn.?.wildcard_index == 5);
    }

    {
        const rtn = try find_wildcard("/a/*/*");
        try testing.expectEqualStrings("*", rtn.?.wildcard);
        try testing.expect(rtn.?.wildcard_index == 3);
    }

    {
        const rtn = try find_wildcard("/:a");
        try testing.expectEqualStrings(":a", rtn.?.wildcard);
        try testing.expect(rtn.?.wildcard_index == 1);
    }

    {
        const rtn = try find_wildcard("/a/:b");
        try testing.expectEqualStrings(":b", rtn.?.wildcard);
        try testing.expect(rtn.?.wildcard_index == 3);
    }

    {
        const rtn = try find_wildcard("/a/*/:b");
        try testing.expectEqualStrings("*", rtn.?.wildcard);
        try testing.expect(rtn.?.wildcard_index == 3);
    }
    try testing.expectError(InsertError.TooManyParams, find_wildcard("/**/"));
}

test "test normalize_params" {
    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/a/b/c");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try testing.expectEqualSlices(u8, "/a/b/c", rtn.route.items);
        try testing.expect(rtn.remapping.items.len == 0);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/a/:b/c");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try testing.expectEqualSlices(u8, "/a/:a/c", rtn.route.items);
        try testing.expect(rtn.remapping.items.len == 1);
        try testing.expectEqualSlices(u8, ":b", rtn.remapping.items[0]);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/foo/:bar/:baz");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try testing.expectEqualSlices(u8, "/foo/:a/:b", rtn.route.items);
        try testing.expect(rtn.remapping.items.len == 2);
        try testing.expectEqualSlices(u8, ":bar", rtn.remapping.items[0]);
        try testing.expectEqualSlices(u8, ":baz", rtn.remapping.items[1]);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/:zxcvbnm/:hjkl/:ab");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try testing.expectEqualSlices(u8, "/:a/:b/:c", rtn.route.items);
        try testing.expect(rtn.remapping.items.len == 3);
        try testing.expectEqualSlices(u8, ":zxcvbnm", rtn.remapping.items[0]);
        try testing.expectEqualSlices(u8, ":hjkl", rtn.remapping.items[1]);
        try testing.expectEqualSlices(u8, ":ab", rtn.remapping.items[2]);
    }
}

test "test denormalize_params" {
    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/a/b/c");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try denormalize_params(&rtn.route, rtn.remapping);
        try testing.expectEqualSlices(u8, "/a/b/c", rtn.route.items);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/a/:b/c");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try denormalize_params(&rtn.route, rtn.remapping);
        try testing.expectEqualSlices(u8, "/a/:b/c", rtn.route.items);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/foo/:bar/:baz");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try denormalize_params(&rtn.route, rtn.remapping);
        try testing.expectEqualSlices(u8, "/foo/:bar/:baz", rtn.route.items);
    }

    {
        var path = std.ArrayList(u8).init(testing.allocator);
        defer path.deinit();

        try path.appendSlice("/:zxcvbnm/:hjkl/:ab");
        var rtn = try normalize_params(testing.allocator, &path);
        defer deinitParamRemapping(&rtn.remapping);

        try denormalize_params(&rtn.route, rtn.remapping);
        try testing.expectEqualSlices(u8, "/:zxcvbnm/:hjkl/:ab", rtn.route.items);
    }
}

test "test Node insert_child" {
    // TODO: leak
    // const allocator = std.testing.allocator;
    const allocator = std.heap.page_allocator;
    var root = Node([]const u8).default(allocator);

    var node = try root.insert_child("/search", "/search", "search handler");
    try testing.expectEqualStrings("search handler", node.value.?);
    try testing.expectEqualStrings("/search", node.prefix.items);
    try testing.expect(node.node_type == .Static);
    try testing.expect(node.children.items.len == 0);

    try testing.expectEqualStrings("search handler", root.value.?);
    try testing.expectEqualStrings("/search", root.prefix.items);
    try testing.expect(root.node_type == .Static);
    try testing.expect(root.children.items.len == 0);

    node = try node.insert_child("upport", "/support", "support handler");
    try testing.expectEqualStrings("support handler", node.value.?);
    try testing.expectEqualStrings("upport", node.prefix.items);
    try testing.expect(node.node_type == .Static);
    try testing.expect(node.children.items.len == 0);

    try testing.expectEqualStrings("support handler", root.value.?);
    try testing.expectEqualStrings("upport", root.prefix.items);
    try testing.expect(root.node_type == .Static);
    try testing.expect(root.children.items.len == 0);

    node = try node.insert_child("tatic/:a", "/static/:a", "static handler");
    try testing.expectEqualStrings("static handler", node.value.?);
    try testing.expectEqualStrings(":a", node.prefix.items);
    try testing.expect(node.node_type == .Param);
    try testing.expect(node.children.items.len == 0);

    try testing.expectEqualStrings("support handler", root.value.?);
    try testing.expectEqualStrings("tatic/", root.prefix.items);
    try testing.expect(root.node_type == .Static);
    try testing.expect(root.children.items.len == 1);

    node = &root.children.items[0];
    try testing.expectEqualStrings("static handler", node.value.?);
    try testing.expectEqualStrings(":a", node.prefix.items);
    try testing.expect(node.node_type == .Param);
    try testing.expect(node.children.items.len == 0);
}

test "test Node insert" {
    const allocator = std.testing.allocator;

    var root = Node([]const u8).default(allocator);
    defer root.deinit();

    try root.insert("/search", "search handler");
    try root.insert("/support", "support handler");
    try root.insert("/static/:name", "static handler");
    try root.insert("/static-files/*.zig", "files handler");

    try testing.expect(root.node_type == .Root);
    try testing.expectEqualStrings("/s", root.prefix.items);
    try testing.expect(root.children.items.len == 3);
    try testing.expect(root.indices.items.len == 3);
    try testing.expectEqualStrings("teu", root.indices.items);

    var node = &root.children.items[0];
    try testing.expect(node.node_type == .Static);
    try testing.expectEqualStrings("tatic", node.prefix.items);
    try testing.expect(node.children.items.len == 2);

    node = &root.children.items[0].children.items[0];
    try testing.expect(node.node_type == .Static);
    try testing.expectEqualStrings("/", node.prefix.items);
    try testing.expect(node.children.items.len == 1);

    node = &root.children.items[0].children.items[0].children.items[0];
    try testing.expect(node.node_type == .Param);
    try testing.expectEqualStrings(":a", node.prefix.items);
    try testing.expectEqualStrings(":name", node.param_remapping.items[0]);
    try testing.expect(node.children.items.len == 0);

    node = &root.children.items[0].children.items[1];
    try testing.expect(node.node_type == .Static);
    try testing.expectEqualStrings("-files/", node.prefix.items);
    try testing.expect(node.children.items.len == 1);

    node = &root.children.items[0].children.items[1].children.items[0];
    try testing.expect(node.node_type == .CatchAll);
    try testing.expectEqualStrings("*.zig", node.prefix.items);
    try testing.expect(node.children.items.len == 0);

    node = &root.children.items[1];
    try testing.expect(node.node_type == .Static);
    try testing.expectEqualStrings("earch", node.prefix.items);
    try testing.expect(node.children.items.len == 0);

    node = &root.children.items[2];
    try testing.expect(node.node_type == .Static);
    try testing.expectEqualStrings("upport", node.prefix.items);
    try testing.expect(node.children.items.len == 0);
}

test "test Node at" {
    const allocator = std.testing.allocator;

    var root = Node([]const u8).default(allocator);
    defer root.deinit();

    try root.insert("/search", "search handler");
    try root.insert("/support", "support handler");
    try root.insert("/static/:name", "static handler");
    try root.insert("/static-files/*p", "files handler");

    try testing.expectError(MatchError.NotFound, root.at("/search/Hanaasagi"));
    try testing.expectError(MatchError.ExtraTrailingSlash, root.at("/search/"));
    try testing.expectError(MatchError.NotFound, root.at("/suppor"));

    var rtn = try root.at("/search");
    try testing.expectEqualStrings("search handler", rtn.value);

    rtn = try root.at("/static/anime.js");
    try testing.expectEqualStrings("static handler", rtn.value);
    try testing.expectEqualStrings("anime.js", rtn.params.get("name").?);
    try testing.expect(rtn.params.get("eman") == null);

    rtn = try root.at("/static-files/root.zig");
    try testing.expectEqualStrings("files handler", rtn.value);
    try testing.expectEqualStrings("root.zig", rtn.params.get("p").?);
}
