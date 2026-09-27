const std = @import("std");
const webview = @cImport({
    @cInclude("webview/api.h");
});

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const index_html = @embedFile("web/index.html");
const styles_css = @embedFile("web/styles.css");
const app_js = @embedFile("web/app.js");

const Config = struct {
    host: []const u8 = "elgato-key-light-mk-2-2840.local",
    device_port: u16 = 9123,
    listen_port: u16 = 9473,
    headless: bool = false,
};

const Context = struct {
    allocator: Allocator,
    io: Io,
    config: Config,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var config: Config = .{};

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            config.host = args.next() orelse return error.MissingHost;
        } else if (std.mem.eql(u8, arg, "--port")) {
            config.listen_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
        } else if (std.mem.eql(u8, arg, "--device-port")) {
            config.device_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
        } else if (std.mem.eql(u8, arg, "--headless")) {
            config.headless = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                "Usage: luma [--host HOST] [--device-port PORT] [--port PORT] [--headless]\n",
                .{},
            );
            return;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const address = Io.net.IpAddress.parse("127.0.0.1", config.listen_port) catch unreachable;
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var context: Context = .{ .allocator = allocator, .io = io, .config = config };
    var server_task = try io.concurrent(runServer, .{ &context, &listener });
    defer server_task.cancel(io) catch {};

    const url = try std.fmt.allocPrintSentinel(init.arena.allocator(), "http://127.0.0.1:{d}/", .{config.listen_port}, 0);
    std.debug.print("Luma is running at {s}\nLight: {s}:{d}\n", .{ url, config.host, config.device_port });

    if (config.headless) {
        _ = try server_task.await(io);
        return;
    }
    try runNativeWindow(url);
}

fn runServer(context: *Context, listener: *Io.net.Server) !void {
    while (true) {
        const stream = try listener.accept(context.io);
        serveConnection(context, stream);
    }
}

fn serveConnection(context: *Context, stream: Io.net.Stream) void {
    defer stream.close(context.io);
    var recv_buffer: [16 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var conn_reader = stream.reader(context.io, &recv_buffer);
    var conn_writer = stream.writer(context.io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch return;
        route(&request, context) catch |err| {
            std.log.warn("request {s} failed: {t}", .{ request.head.target, err });
            return;
        };
    }
}

fn route(request: *Request, context: *Context) !void {
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        return respond(request, index_html, "text/html; charset=utf-8");
    }
    if (std.mem.eql(u8, target, "/styles.css")) return respond(request, styles_css, "text/css; charset=utf-8");
    if (std.mem.eql(u8, target, "/app.js")) return respond(request, app_js, "application/javascript; charset=utf-8");
    if (std.mem.eql(u8, target, "/api/config")) {
        var buffer: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &buffer,
            "{{\"host\":\"{s}\",\"port\":{d}}}",
            .{ context.config.host, context.config.device_port },
        );
        return respond(request, body, "application/json");
    }

    const upstream_path: ?[]const u8 = if (std.mem.eql(u8, target, "/api/state"))
        "/elgato/lights"
    else if (std.mem.eql(u8, target, "/api/info"))
        "/elgato/accessory-info"
    else if (std.mem.eql(u8, target, "/api/settings"))
        "/elgato/lights/settings"
    else if (std.mem.eql(u8, target, "/api/identify"))
        "/elgato/identify"
    else
        null;

    if (upstream_path) |path| return proxy(request, context, path);

    try request.respond("{\"error\":\"not found\"}", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn proxy(request: *Request, context: *Context, path: []const u8) !void {
    var body_buffer: [64 * 1024]u8 = undefined;
    var payload: ?[]u8 = null;
    if (request.head.method.requestHasBody()) {
        const reader = try request.readerExpectContinue(&body_buffer);
        payload = try reader.allocRemaining(context.allocator, .limited(64 * 1024));
    }
    defer if (payload) |bytes| context.allocator.free(bytes);

    const url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}{s}", .{
        context.config.host,
        context.config.device_port,
        path,
    });
    defer context.allocator.free(url);

    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    var client: std.http.Client = .{ .allocator = context.allocator, .io = context.io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = request.head.method,
        .payload = payload,
        .response_writer = &output.writer,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch |err| {
        std.log.warn("light request failed: {t}", .{err});
        return request.respond("{\"error\":\"Light is unreachable\"}", .{
            .status = .bad_gateway,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    try request.respond(output.writer.buffered(), .{
        .status = result.status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn respond(request: *Request, content: []const u8, content_type: []const u8) !void {
    try request.respond(content, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn runNativeWindow(url: [:0]const u8) !void {
    const window = webview.webview_create(0, null) orelse return error.WebviewCreationFailed;
    defer _ = webview.webview_destroy(window);

    if (webview.webview_set_title(window, "Luma") != webview.WEBVIEW_ERROR_OK) return error.WebviewTitleFailed;
    if (webview.webview_set_size(window, 560, 840, webview.WEBVIEW_HINT_NONE) != webview.WEBVIEW_ERROR_OK) return error.WebviewSizeFailed;
    if (webview.webview_navigate(window, url.ptr) != webview.WEBVIEW_ERROR_OK) return error.WebviewNavigationFailed;
    if (webview.webview_run(window) != webview.WEBVIEW_ERROR_OK) return error.WebviewRunFailed;
}
