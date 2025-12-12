const std = @import("std");
const linkLibLuaJit = @import("build.luajit.zig").linkLibLuaJit;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const luabindings = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("bindings/libluajit.h"),
    });
    const libluajit = luabindings.addModule("libluajit");

    const luajit = b.addLibrary(.{
        .name = "libluajit",
        .linkage = .static,
        .root_module = libluajit,
    });
    try linkLibLuaJit(b, luajit);

    const lib = b.addLibrary(.{
        .name = "luajitzig",
        .linkage = .dynamic,
        .root_module = b.addModule("luajitzig", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
            .imports = &.{
                .{ .name = "luajit", .module = libluajit },
            },
        }),
    });
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "luajitzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libluajit", .module = lib.root_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
