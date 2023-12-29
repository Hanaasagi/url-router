// export
pub const Router = @import("router.zig").Router;
pub const Match = @import("router.zig").Match;
pub const Params = @import("params.zig").Params;

const std = @import("std");
const testing = std.testing;

test "test all modules" {
    _ = @import("tree.zig");
    _ = @import("params.zig");
    _ = @import("error.zig");
    _ = @import("router.zig");

    testing.refAllDecls(@This());
}

// --------------------------------------------------------------------------------
//                                   Example
// --------------------------------------------------------------------------------

const Request = struct {
    params: Params,
    method: enum { GET, POST },
    // ...
};
const Response = struct {
    // ...
};

const App = struct {
    router: Router(*const (fn (*Request, *Response) void)),
    const Self = @This();
    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .router = Router(*const (fn (*Request, *Response) void)).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.router.deinit();
    }

    fn get(self: *Self, path: []const u8, handler: *const (fn (*Request, *Response) void)) void {
        self.router.insert(path, handler) catch @panic("TODO");
    }

    fn handle_request(self: *Self, full_url: []const u8) void {
        // parse the url
        const path = full_url;

        const match = self.router.match(path) catch @panic("TODO");
        var request = Request{
            .method = .GET,
            .params = match.params,
        };
        var response = Response{};
        _ = match.value(&request, &response);
    }

    // ...
};

fn search_handler(request: *Request, response: *Response) void {
    _ = request;
    _ = response;
    // std.log.err("search handler is called", .{});
    // ...
}

fn static_handler(request: *Request, response: *Response) void {
    _ = request;
    _ = response;
    // std.log.err("static handler is called, name is {s}", .{request.params.get("name").?});
    // ...
}

test "test" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    app.get("/search", search_handler);
    app.get("/static/:name", static_handler);

    app.handle_request("/search");
    app.handle_request("/static/robots.txt");
}
