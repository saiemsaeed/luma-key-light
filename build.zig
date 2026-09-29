const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("vendor/webview/core/include"));
    module.addCSourceFile(.{
        .file = b.path("vendor/webview/core/src/webview.cc"),
        .flags = &.{ "-std=c++11", "-DWEBVIEW_STATIC" },
    });
    module.link_libcpp = true;

    switch (target.result.os.tag) {
        .macos => {
            if (b.graph.environ_map.get("SDKROOT")) |sdk_root| {
                const frameworks = b.pathResolve(&.{ sdk_root, "System/Library/Frameworks" });
                module.addFrameworkPath(.{ .cwd_relative = frameworks });
            }
            module.linkFramework("WebKit", .{});
            module.linkSystemLibrary("dns_sd", .{});
            module.linkSystemLibrary("dl", .{});
        },
        .linux => {
            module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
            module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
            module.linkSystemLibrary("avahi-client", .{ .use_pkg_config = .force });
            module.linkSystemLibrary("dl", .{});
        },
        else => @panic("Luma currently supports macOS and Linux"),
    }

    const exe = b.addExecutable(.{ .name = "luma", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Luma").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
