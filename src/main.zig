const std = @import("std");
const builtin = @import("builtin");
const webview = @cImport({
    @cInclude("webview/api.h");
});
const discovery = @import("discovery.zig");

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
    host_explicit: bool = false,
};

const Context = struct {
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    config: Config,
    selected_host: [256]u8 = undefined,
    selected_host_len: usize = 0,
    selected_port: u16 = 9123,
    devices: [16]discovery.Device = undefined,
    device_count: usize = 0,
    selection_locked: bool = false,

    fn host(self: *const Context) []const u8 {
        return self.selected_host[0..self.selected_host_len];
    }

    fn select(self: *Context, host_name: []const u8, port: u16) error{HostNameTooLong}!void {
        if (host_name.len > self.selected_host.len) return error.HostNameTooLong;
        @memcpy(self.selected_host[0..host_name.len], host_name);
        self.selected_host_len = host_name.len;
        self.selected_port = port;
    }
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
            config.host_explicit = true;
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

    // Zig 0.16 lazily scans the startup envp the first time it spawns a
    // process. GTK/WebKit may replace that envp before the first API request,
    // leaving Zig with a dangling pointer. Force the scan while envp is still
    // valid; proxyWithCurl supplies the owned environment snapshot afterward.
    if (builtin.os.tag == .linux and !config.headless) {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{"/usr/bin/true"},
            .environ_map = init.environ_map,
            .stdout_limit = .limited(0),
            .stderr_limit = .limited(0),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    const address = Io.net.IpAddress.parse("127.0.0.1", config.listen_port) catch unreachable;
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var context: Context = .{
        .allocator = allocator,
        .io = io,
        .environ_map = init.environ_map,
        .config = config,
        .selection_locked = config.host_explicit,
    };
    try context.select(config.host, config.device_port);
    var server_task = try io.concurrent(runServer, .{ &context, &listener });
    defer server_task.cancel(io) catch {};

    const url = try std.fmt.allocPrintSentinel(init.arena.allocator(), "http://127.0.0.1:{d}/", .{config.listen_port}, 0);
    std.debug.print("Luma is running at {s}\nLight: {s}:{d}\n", .{ url, context.host(), context.selected_port });

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
            "{{\"host\":\"{s}\",\"port\":{d},\"hostExplicit\":{}}}",
            .{ context.host(), context.selected_port, context.config.host_explicit },
        );
        return respond(request, body, "application/json");
    }
    if (std.mem.eql(u8, target, "/api/devices")) {
        return discoverDevices(request, context);
    }
    if (std.mem.eql(u8, target, "/api/devices/select") and request.head.method == .POST) {
        return selectDiscoveredDevice(request, context);
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

fn selectDiscoveredDevice(request: *Request, context: *Context) !void {
    var body_buffer: [2048]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buffer);
    const payload = try reader.allocRemaining(context.allocator, .limited(body_buffer.len));
    defer context.allocator.free(payload);

    const Selection = struct {
        id: ?[]const u8 = null,
        host: ?[]const u8 = null,
        port: ?u16 = null,
    };
    const parsed = std.json.parseFromSlice(Selection, context.allocator, payload, .{}) catch {
        return request.respond("{\"error\":\"Invalid device selection\"}", .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };
    defer parsed.deinit();

    const selection = parsed.value;
    for (context.devices[0..context.device_count]) |*device| {
        const has_stable_id = selection.id != null and selection.id.?.len > 0;
        const id_matches = has_stable_id and std.mem.eql(u8, selection.id.?, device.idSlice());
        const address_matches = if (!has_stable_id and selection.host != null)
            selection.port != null and selection.port.? == device.port and
                std.mem.eql(u8, selection.host.?, device.hostSlice())
        else
            false;
        if (!id_matches and !address_matches) continue;

        try context.select(device.hostSlice(), device.port);
        context.selection_locked = true;
        return respond(request, "{\"selected\":true}", "application/json");
    }

    return request.respond("{\"error\":\"Discovered device is no longer available\"}", .{
        .status = .conflict,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn discoverDevices(request: *Request, context: *Context) !void {
    context.device_count = discovery.discover(context.io, &context.devices, 1500, 750) catch {
        return request.respond("{\"error\":\"Device discovery is unavailable\"}", .{
            .status = .service_unavailable,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };

    if (!context.selection_locked and context.device_count > 0) {
        var selected_index: usize = 0;
        for (context.devices[0..context.device_count], 0..) |*device, index| {
            if (std.mem.eql(u8, context.host(), device.hostSlice()) and
                context.selected_port == device.port)
            {
                selected_index = index;
                break;
            }
        }
        const selected = &context.devices[selected_index];
        try context.select(selected.hostSlice(), selected.port);
    }

    const DeviceJson = struct {
        name: []const u8,
        host: []const u8,
        port: u16,
        id: []const u8,
        model: []const u8,
        selected: bool,
    };
    var devices: [16]DeviceJson = undefined;
    for (context.devices[0..context.device_count], 0..) |*device, index| {
        const name = device.nameSlice();
        const host = device.hostSlice();
        const model = device.modelSlice();
        devices[index] = .{
            .name = if (name.len > 0) name else if (model.len > 0) model else host,
            .host = host,
            .port = device.port,
            .id = device.idSlice(),
            .model = model,
            .selected = std.mem.eql(u8, context.host(), host) and context.selected_port == device.port,
        };
    }

    const body = try std.json.Stringify.valueAlloc(context.allocator, devices[0..context.device_count], .{});
    defer context.allocator.free(body);
    return respond(request, body, "application/json");
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
        context.host(),
        context.selected_port,
        path,
    });
    defer context.allocator.free(url);

    // Zig's resolver does not currently preserve mDNS IPv6 scope IDs on Linux.
    // curl uses the system resolver (Avahi/NSS), which handles .local lights correctly.
    if (builtin.os.tag == .linux) return proxyWithCurl(request, context, url, payload);

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

fn proxyWithCurl(request: *Request, context: *Context, url: []const u8, payload: ?[]const u8) !void {
    var argv: [16][]const u8 = undefined;
    var count: usize = 0;
    const add = struct {
        fn value(args: *[16][]const u8, len: *usize, item: []const u8) void {
            args[len.*] = item;
            len.* += 1;
        }
    }.value;

    add(&argv, &count, "curl");
    add(&argv, &count, "--silent");
    add(&argv, &count, "--show-error");
    add(&argv, &count, "--connect-timeout");
    add(&argv, &count, "3");
    add(&argv, &count, "--max-time");
    add(&argv, &count, "8");
    add(&argv, &count, "--request");
    add(&argv, &count, @tagName(request.head.method));
    add(&argv, &count, "--header");
    add(&argv, &count, "Content-Type: application/json");
    add(&argv, &count, "--write-out");
    add(&argv, &count, "\\n%{http_code}");
    if (payload) |body| {
        add(&argv, &count, "--data-binary");
        add(&argv, &count, body);
    }
    add(&argv, &count, url);

    const result = std.process.run(context.allocator, context.io, .{
        .argv = argv[0..count],
        // GTK/WebKit may mutate libc's environ after Zig captures it. Use the
        // owned startup snapshot so spawning curl never reads a stale envp.
        .environ_map = context.environ_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(8 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(10) } },
    }) catch {
        return request.respond("{\"error\":\"Light is unreachable\"}", .{
            .status = .bad_gateway,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    };
    defer context.allocator.free(result.stdout);
    defer context.allocator.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        return request.respond("{\"error\":\"Light is unreachable\"}", .{
            .status = .bad_gateway,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }

    const status_separator = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.InvalidUpstreamResponse;
    const status_code = try std.fmt.parseInt(u10, result.stdout[status_separator + 1 ..], 10);
    const response_body = result.stdout[0..status_separator];

    try request.respond(response_body, .{
        .status = @enumFromInt(status_code),
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
