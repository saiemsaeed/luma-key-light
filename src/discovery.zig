const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.os.tag == .linux)
    @cImport({
        @cInclude("avahi-client/client.h");
        @cInclude("avahi-client/lookup.h");
        @cInclude("avahi-common/malloc.h");
        @cInclude("avahi-common/simple-watch.h");
        @cInclude("avahi-common/strlst.h");
    })
else
    @cImport({
        @cInclude("dns_sd.h");
    });

pub const Device = struct {
    name: [128]u8 = @splat(0),
    host: [256]u8 = @splat(0),
    id: [64]u8 = @splat(0),
    model: [128]u8 = @splat(0),
    port: u16 = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return std.mem.sliceTo(self.name[0..], 0);
    }

    pub fn hostSlice(self: *const Device) []const u8 {
        return std.mem.sliceTo(self.host[0..], 0);
    }

    pub fn idSlice(self: *const Device) []const u8 {
        return std.mem.sliceTo(self.id[0..], 0);
    }

    pub fn modelSlice(self: *const Device) []const u8 {
        return std.mem.sliceTo(self.model[0..], 0);
    }
};

pub const Error = error{DiscoveryUnavailable};

pub fn discover(io: std.Io, devices: []Device, browse_timeout_ms: i32, resolve_timeout_ms: i32) Error!usize {
    if (devices.len == 0) return 0;
    return switch (builtin.os.tag) {
        .linux => discoverAvahi(io, devices, browse_timeout_ms, resolve_timeout_ms),
        .macos => discoverBonjour(io, devices, browse_timeout_ms, resolve_timeout_ms),
        else => error.DiscoveryUnavailable,
    };
}

fn cStringSlice(source: [*c]const u8) []const u8 {
    if (source == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(source)));
}

fn copyCString(destination: []u8, source: [*c]const u8) void {
    if (destination.len == 0 or source == null) return;
    const value = cStringSlice(source);
    const length = @min(value.len, destination.len - 1);
    @memcpy(destination[0..length], value[0..length]);
    destination[length] = 0;
}

fn sameDevice(a: *const Device, b: *const Device) bool {
    const a_id = a.idSlice();
    const b_id = b.idSlice();
    if (a_id.len > 0 and b_id.len > 0) return std.mem.eql(u8, a_id, b_id);
    return a.port == b.port and std.mem.eql(u8, a.hostSlice(), b.hostSlice());
}

fn appendUnique(devices: []Device, count: *usize, candidate: Device) void {
    for (devices[0..count.*]) |*device| {
        if (sameDevice(&candidate, device)) return;
    }
    if (count.* >= devices.len) return;
    devices[count.*] = candidate;
    count.* += 1;
}

// -------------------------------------------------------------------------
// Linux: native Avahi API

const AvahiContext = struct {
    devices: []Device,
    count: usize = 0,
    pending_resolvers: usize = 0,
    browse_complete: bool = false,
    failed: bool = false,
    client: ?*c.AvahiClient = null,
};

fn avahiContext(userdata: ?*anyopaque) *AvahiContext {
    return @ptrCast(@alignCast(userdata.?));
}

fn copyAvahiTxt(destination: []u8, txt: ?*c.AvahiStringList, key: [*:0]const u8) void {
    if (destination.len == 0 or txt == null) return;
    const entry = c.avahi_string_list_find(txt, key) orelse return;
    var returned_key: [*c]u8 = null;
    var value: [*c]u8 = null;
    var value_size: usize = 0;
    defer {
        c.avahi_free(returned_key);
        c.avahi_free(value);
    }
    if (c.avahi_string_list_get_pair(entry, &returned_key, &value, &value_size) != 0 or value == null) return;
    const length = @min(value_size, destination.len - 1);
    @memcpy(destination[0..length], value[0..length]);
    destination[length] = 0;
}

fn avahiResolveCallback(
    resolver: ?*c.AvahiServiceResolver,
    interface: c.AvahiIfIndex,
    protocol: c.AvahiProtocol,
    event: c.AvahiResolverEvent,
    name: [*c]const u8,
    service_type: [*c]const u8,
    domain: [*c]const u8,
    host_name: [*c]const u8,
    address: ?*const c.AvahiAddress,
    port: u16,
    txt: ?*c.AvahiStringList,
    flags: c.AvahiLookupResultFlags,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = interface;
    _ = protocol;
    _ = service_type;
    _ = domain;
    _ = address;
    _ = flags;
    const context = avahiContext(userdata);

    if (event == c.AVAHI_RESOLVER_FOUND and context.count < context.devices.len) {
        var candidate: Device = .{};
        copyCString(&candidate.name, name);
        copyCString(&candidate.host, host_name);
        const host_length = candidate.hostSlice().len;
        if (host_length > 0 and candidate.host[host_length - 1] == '.') candidate.host[host_length - 1] = 0;
        candidate.port = port;
        copyAvahiTxt(&candidate.id, txt, "id");
        copyAvahiTxt(&candidate.model, txt, "md");
        appendUnique(context.devices, &context.count, candidate);
    }

    if (context.pending_resolvers > 0) context.pending_resolvers -= 1;
    if (resolver) |value| _ = c.avahi_service_resolver_free(value);
}

fn avahiBrowseCallback(
    browser: ?*c.AvahiServiceBrowser,
    interface: c.AvahiIfIndex,
    protocol: c.AvahiProtocol,
    event: c.AvahiBrowserEvent,
    name: [*c]const u8,
    service_type: [*c]const u8,
    domain: [*c]const u8,
    flags: c.AvahiLookupResultFlags,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = browser;
    _ = flags;
    const context = avahiContext(userdata);

    if (event == c.AVAHI_BROWSER_NEW) {
        const resolver = c.avahi_service_resolver_new(
            context.client,
            interface,
            protocol,
            name,
            service_type,
            domain,
            c.AVAHI_PROTO_UNSPEC,
            0,
            avahiResolveCallback,
            context,
        );
        if (resolver != null) context.pending_resolvers += 1;
    } else if (event == c.AVAHI_BROWSER_ALL_FOR_NOW) {
        context.browse_complete = true;
    } else if (event == c.AVAHI_BROWSER_FAILURE) {
        context.failed = true;
    }
}

fn avahiClientCallback(client: ?*c.AvahiClient, state: c.AvahiClientState, userdata: ?*anyopaque) callconv(.c) void {
    _ = client;
    if (state == c.AVAHI_CLIENT_FAILURE) avahiContext(userdata).failed = true;
}

fn discoverAvahi(io: std.Io, devices: []Device, browse_timeout_ms: i32, resolve_timeout_ms: i32) Error!usize {
    if (builtin.os.tag != .linux) return error.DiscoveryUnavailable;

    const simple_poll = c.avahi_simple_poll_new() orelse return error.DiscoveryUnavailable;
    defer c.avahi_simple_poll_free(simple_poll);

    var context: AvahiContext = .{ .devices = devices };
    var avahi_error: c_int = 0;
    const client = c.avahi_client_new(
        c.avahi_simple_poll_get(simple_poll),
        0,
        avahiClientCallback,
        &context,
        &avahi_error,
    ) orelse return error.DiscoveryUnavailable;
    defer c.avahi_client_free(client);
    context.client = client;

    const browser = c.avahi_service_browser_new(
        client,
        c.AVAHI_IF_UNSPEC,
        c.AVAHI_PROTO_UNSPEC,
        "_elg._tcp",
        null,
        0,
        avahiBrowseCallback,
        &context,
    ) orelse return error.DiscoveryUnavailable;
    defer _ = c.avahi_service_browser_free(browser);

    const timeout = std.Io.Clock.Duration{
        .clock = .awake,
        .raw = .fromMilliseconds(@as(i64, browse_timeout_ms) + resolve_timeout_ms),
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout);
    while (!context.failed) {
        if (context.browse_complete and context.pending_resolvers == 0) break;
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (now.compare(.gte, deadline)) break;
        const remaining_ms = now.durationTo(deadline).raw.toMilliseconds();
        const step_ms: c_int = @intCast(@min(remaining_ms, 100));
        if (c.avahi_simple_poll_iterate(simple_poll, step_ms) < 0) {
            context.failed = true;
            break;
        }
    }

    if (context.failed) return error.DiscoveryUnavailable;
    return context.count;
}

// -------------------------------------------------------------------------
// macOS: native Bonjour DNS-SD API

const BonjourService = struct {
    name: [128]u8 = @splat(0),
    regtype: [64]u8 = @splat(0),
    domain: [128]u8 = @splat(0),
    interface_index: u32 = 0,
};

const BonjourBrowseContext = struct {
    services: [16]BonjourService = undefined,
    count: usize = 0,
    failed: bool = false,
};

const BonjourResolveContext = struct {
    device: *Device,
    completed: bool = false,
    resolved: bool = false,
};

const BonjourResolveSlot = struct {
    device: Device = .{},
    context: BonjourResolveContext = undefined,
    reference: c.DNSServiceRef = null,
};

fn bonjourBrowseCallback(
    sd_ref: c.DNSServiceRef,
    flags: c.DNSServiceFlags,
    interface_index: u32,
    error_code: c.DNSServiceErrorType,
    service_name: [*c]const u8,
    regtype: [*c]const u8,
    reply_domain: [*c]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = sd_ref;
    const context: *BonjourBrowseContext = @ptrCast(@alignCast(userdata.?));
    if (error_code != c.kDNSServiceErr_NoError) {
        context.failed = true;
        return;
    }
    if ((flags & c.kDNSServiceFlagsAdd) == 0) return;

    for (context.services[0..context.count]) |*service| {
        if (service.interface_index == interface_index and
            std.mem.eql(u8, std.mem.sliceTo(service.name[0..], 0), cStringSlice(service_name)))
        {
            return;
        }
    }
    if (context.count >= context.services.len) return;
    const service = &context.services[context.count];
    service.* = .{};
    copyCString(&service.name, service_name);
    copyCString(&service.regtype, regtype);
    copyCString(&service.domain, reply_domain);
    service.interface_index = interface_index;
    context.count += 1;
}

fn copyBonjourTxt(destination: []u8, txt_length: u16, txt: [*c]const u8, key: [*:0]const u8) void {
    if (destination.len == 0 or txt == null) return;
    var value_length: u8 = 0;
    const value = c.TXTRecordGetValuePtr(txt_length, txt, key, &value_length) orelse return;
    const bytes: [*]const u8 = @ptrCast(value);
    const length = @min(@as(usize, value_length), destination.len - 1);
    @memcpy(destination[0..length], bytes[0..length]);
    destination[length] = 0;
}

fn bonjourResolveCallback(
    sd_ref: c.DNSServiceRef,
    flags: c.DNSServiceFlags,
    interface_index: u32,
    error_code: c.DNSServiceErrorType,
    fullname: [*c]const u8,
    host_target: [*c]const u8,
    network_port: u16,
    txt_length: u16,
    txt: [*c]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = sd_ref;
    _ = flags;
    _ = interface_index;
    _ = fullname;
    const context: *BonjourResolveContext = @ptrCast(@alignCast(userdata.?));
    context.completed = true;
    if (error_code != c.kDNSServiceErr_NoError or host_target == null) return;
    copyCString(&context.device.host, host_target);
    const host_length = context.device.hostSlice().len;
    if (host_length > 0 and context.device.host[host_length - 1] == '.') context.device.host[host_length - 1] = 0;
    context.device.port = std.mem.bigToNative(u16, network_port);
    copyBonjourTxt(&context.device.id, txt_length, txt, "id");
    copyBonjourTxt(&context.device.model, txt_length, txt, "md");
    context.resolved = true;
}

fn deadlineFromMilliseconds(io: std.Io, timeout_ms: i32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
}

fn millisecondsUntil(io: std.Io, deadline: std.Io.Clock.Timestamp) ?i32 {
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    if (now.compare(.gte, deadline)) return null;
    const remaining = now.durationTo(deadline).raw.toMilliseconds();
    return @intCast(@min(remaining, std.math.maxInt(i32)));
}

fn processBonjourResult(reference: c.DNSServiceRef, timeout_ms: i32) bool {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = c.DNSServiceRefSockFD(reference),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (descriptors[0].fd < 0) return false;
    const ready = std.posix.poll(&descriptors, timeout_ms) catch return false;
    if (ready == 0 or (descriptors[0].revents & std.posix.POLL.IN) == 0) return false;
    return c.DNSServiceProcessResult(reference) == c.kDNSServiceErr_NoError;
}

fn discoverBonjour(io: std.Io, devices: []Device, browse_timeout_ms: i32, resolve_timeout_ms: i32) Error!usize {
    if (builtin.os.tag != .macos) return error.DiscoveryUnavailable;

    var browse: BonjourBrowseContext = .{};
    var browse_ref: c.DNSServiceRef = null;
    if (c.DNSServiceBrowse(
        &browse_ref,
        0,
        c.kDNSServiceInterfaceIndexAny,
        "_elg._tcp",
        null,
        bonjourBrowseCallback,
        &browse,
    ) != c.kDNSServiceErr_NoError or browse_ref == null) return error.DiscoveryUnavailable;
    defer c.DNSServiceRefDeallocate(browse_ref);

    // MoreComing only describes the currently queued batch. Keep browsing until
    // the absolute deadline so slower devices can answer a cold-cache query.
    const browse_deadline = deadlineFromMilliseconds(io, browse_timeout_ms);
    while (!browse.failed) {
        const remaining = millisecondsUntil(io, browse_deadline) orelse break;
        if (!processBonjourResult(browse_ref, remaining)) break;
    }
    if (browse.failed) return error.DiscoveryUnavailable;

    // Start all resolutions first, then poll every resolver under one shared
    // deadline. A slow device therefore cannot add its timeout to every other
    // device's timeout or stall the serial HTTP server for many seconds.
    var slots: [16]BonjourResolveSlot = undefined;
    var slot_count: usize = 0;
    for (browse.services[0..browse.count]) |*service| {
        if (slot_count >= slots.len or slot_count >= devices.len) break;
        const slot = &slots[slot_count];
        slot.* = .{};
        copyCString(&slot.device.name, service.name[0..].ptr);
        slot.context = .{ .device = &slot.device };
        if (c.DNSServiceResolve(
            &slot.reference,
            0,
            service.interface_index,
            service.name[0..].ptr,
            service.regtype[0..].ptr,
            service.domain[0..].ptr,
            bonjourResolveCallback,
            &slot.context,
        ) != c.kDNSServiceErr_NoError or slot.reference == null) continue;
        slot_count += 1;
    }
    defer for (slots[0..slot_count]) |*slot| {
        if (slot.reference != null) c.DNSServiceRefDeallocate(slot.reference);
    };

    const resolve_deadline = deadlineFromMilliseconds(io, resolve_timeout_ms);
    while (true) {
        var descriptors: [16]std.posix.pollfd = undefined;
        var descriptor_slots: [16]usize = undefined;
        var descriptor_count: usize = 0;
        for (slots[0..slot_count], 0..) |*slot, index| {
            if (slot.reference == null or slot.context.completed) continue;
            const fd = c.DNSServiceRefSockFD(slot.reference);
            if (fd < 0) {
                slot.context.completed = true;
                continue;
            }
            descriptors[descriptor_count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
            descriptor_slots[descriptor_count] = index;
            descriptor_count += 1;
        }
        if (descriptor_count == 0) break;
        const remaining = millisecondsUntil(io, resolve_deadline) orelse break;
        const ready = std.posix.poll(descriptors[0..descriptor_count], remaining) catch break;
        if (ready == 0) break;
        for (descriptors[0..descriptor_count], descriptor_slots[0..descriptor_count]) |descriptor, slot_index| {
            if ((descriptor.revents & std.posix.POLL.IN) == 0) continue;
            const slot = &slots[slot_index];
            if (c.DNSServiceProcessResult(slot.reference) != c.kDNSServiceErr_NoError)
                slot.context.completed = true;
        }
        for (slots[0..slot_count]) |*slot| {
            if (!slot.context.completed or slot.reference == null) continue;
            c.DNSServiceRefDeallocate(slot.reference);
            slot.reference = null;
        }
    }

    var count: usize = 0;
    for (slots[0..slot_count]) |*slot| {
        if (slot.context.resolved) appendUnique(devices, &count, slot.device);
    }
    return count;
}
