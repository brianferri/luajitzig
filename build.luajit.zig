const std = @import("std");

pub fn linkLibLuaJit(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
) !void {
    const target = lib.root_module.resolved_target.?;
    const optimize = lib.root_module.optimize.?;

    const luajit = b.dependency("luajit", .{});
    const lj_path = luajit.path("");

    const libluajit = b.addLibrary(.{
        .name = "luajit",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .link_libc = true,
            .optimize = optimize,
        }),
    });

    libluajit.link_gc_sections = true;
    libluajit.link_data_sections = true;
    libluajit.link_function_sections = true;

    libluajit.root_module.addCSourceFiles(.{
        .files = lua_sources,
        .root = lj_path,
        .flags = &.{},
    });

    const luajit_h = try genLuaJitHeader(b, "luajit/src/luajit_rolling.h");
    libluajit.root_module.addIncludePath(lj_path.path(b, "src"));
    libluajit.root_module.addIncludePath(luajit_h);

    const minilua = genMiniLua(b, lj_path);
    const ljvm = genLuaJitVM(b, libluajit, lj_path, luajit_h, minilua);
    genLuaJitLibs(b, libluajit, lj_path, ljvm);

    libluajit.root_module.addCMacro("LUAJIT_UNWIND_EXTERNAL", "");
    libluajit.root_module.linkSystemLibrary("unwind", .{});

    lib.root_module.linkLibrary(libluajit);
}

fn genLuaJitHeader(b: *std.Build, rolling_header: []const u8) !std.Build.LazyPath {
    const alloc = b.allocator;

    const rolling_header_file = try b.build_root.handle.openFile(rolling_header, .{});
    defer rolling_header_file.close();

    const file = try rolling_header_file.stat();
    const rolling_header_buffer = try b.build_root.handle.readFileAlloc(alloc, rolling_header, file.size);

    var start: usize = 0;
    while (std.mem.indexOfPos(u8, rolling_header_buffer, start, "#error")) |idx| {
        defer start = idx;
        rolling_header_buffer[idx] = '/';
        rolling_header_buffer[idx + 1] = '/';
    }

    var wf = b.addWriteFile("luajit.h", rolling_header_buffer);
    return wf.getDirectory();
}

fn genMiniLua(
    b: *std.Build,
    lj_path: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const ml_path = lj_path.path(b, "src/host");
    const ml = b.addExecutable(.{
        .name = "ml",
        .root_module = b.createModule(.{
            .optimize = .ReleaseSmall,
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    ml.root_module.addCSourceFile(.{ .file = ml_path.path(b, "minilua.c") });

    return ml;
}

fn genLuaJitVM(
    b: *std.Build,
    lj: *std.Build.Step.Compile,
    lj_path: std.Build.LazyPath,
    lj_h_path: std.Build.LazyPath,
    ml: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const target = lj.root_module.resolved_target.?;
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    const ljvm_path = lj_path.path(b, "src/host");
    const ljvm = b.addExecutable(.{
        .name = "ljvm",
        .root_module = b.createModule(.{
            .link_libc = true,
            .sanitize_c = .off,
            .optimize = .ReleaseSmall,
            .target = b.graph.host,
        }),
    });
    if (os == .windows) ljvm.root_module.addCMacro("LUAJIT_OS", "LUAJIT_OS_WINDOWS");

    const ml_exe = b.addRunArtifact(ml);
    ljvm.step.dependOn(&ml_exe.step);

    ml_exe.addFileArg(lj_path.path(b, "dynasm/dynasm.lua"));
    ml_exe.addArgs(&.{"-o"});
    const arch_h = ml_exe.addOutputFileArg("buildvm_arch.h");

    ml_exe.addArgs(&.{ "-D", "JIT", "-D", "FFI" });
    if (os == .windows) ml_exe.addArgs(&.{ "-D", "WIN" });
    if (target.result.ptrBitWidth() == 64) ml_exe.addArgs(&.{ "-D", "P64" });
    if (target.result.abi.float() == .hard) ml_exe.addArgs(&.{ "-D", "FPU", "-D", "HFABI" });

    ml_exe.addFileArg(lj_path.path(b, b.fmt(
        "src/vm_{s}.dasc",
        .{switch (arch) {
            .x86_64 => "x64",
            .x86 => "x86",
            .arm, .armeb => "arm",
            .aarch64, .aarch64_be => "arm64",
            .powerpc, .powerpc64le => "ppc",
            .mips, .mipsel => "mips",
            .mips64, .mips64el => "mips64",
            else => @panic("Unsupported target architecture"),
        }},
    )));

    ljvm.root_module.addIncludePath(arch_h.dirname());
    ljvm.root_module.addIncludePath(lj_h_path);
    ljvm.root_module.addIncludePath(lj_path.path(b, "src"));
    ljvm.root_module.addCSourceFiles(.{
        .root = ljvm_path,
        .files = &.{
            "buildvm.c",
            "buildvm_peobj.c",
            "buildvm_asm.c",
            "buildvm_lib.c",
            "buildvm_fold.c",
        },
    });

    return ljvm;
}

fn genLuaJitLibs(
    b: *std.Build,
    lj: *std.Build.Step.Compile,
    lj_path: std.Build.LazyPath,
    ljvm: *std.Build.Step.Compile,
) void {
    const ljvm_asm = b.addRunArtifact(ljvm);

    const target = lj.root_module.resolved_target.?;
    const arch = target.result.cpu.arch;
    const os = target.result.os.tag;

    ljvm_asm.addArgs(&.{ "-m", switch (os) {
        .windows => if (arch == .x86) "coffasm" else "peobj",
        .macos, .ios => "machasm",
        else => "elfasm",
    }, "-o" });
    const vm_asm = ljvm_asm.addOutputFileArg(if (os == .windows) "lj_vm.o" else "lj_vm.S");
    lj.root_module.link_objects.append(b.allocator, switch (os) {
        .windows => .{ .static_path = vm_asm },
        else => .{ .assembly_file = vm_asm },
    }) catch @panic("OOM");

    lj.addCSourceFiles(.{
        .root = lj_path,
        .files = lib_sources,
        .flags = &.{},
    });

    for ([_][]const u8{
        "bcdef",  "ffdef",
        "libdef", "recdef",
        "folddef",
        // "vmdef",
    }) |lj_lib| {
        const ljvm_exe = b.addRunArtifact(ljvm);
        ljvm_exe.addArgs(&.{ "-m", lj_lib, "-o" });
        const lib_header = ljvm_exe.addOutputFileArg(b.fmt("lj_{s}.h", .{lj_lib}));
        inline for (lib_sources) |file| ljvm_exe.addFileArg(lj_path.path(b, file));
        lj.addIncludePath(lib_header.dirname());
        lj.step.dependOn(&ljvm_exe.step);
    }
}

/// ! The order of these files is FUNCTIONALLY CRITICAL.
/// LuaJIT's `buildvm` tool parses these files in a single pass to generate
/// Fast Function (FF) IDs for the assembly-side jump table.
/// If this order is changed:
/// 1. The generated IDs in `lj_ffdef.h` will shift.
/// 2. The static assertions in `lib_base.c` will fail (FF_next mismatch).
/// 3. If assertions were disabled, the VM would execute the wrong assembly
///    code for a given C function (e.g., calling `math.sin` might execute `os.exit`).
/// This list must match the order defined in the official LuaJIT `src/Makefile`
/// @see https://github.com/LuaJIT/LuaJIT/blob/7152e15489d2077cd299ee23e3d51a4c599ab14f/src/Makefile#L512-L514
const lib_sources = &.{
    "src/lib_base.c",
    "src/lib_math.c",
    "src/lib_bit.c",
    "src/lib_string.c",
    "src/lib_table.c",
    "src/lib_io.c",
    "src/lib_os.c",
    "src/lib_package.c",
    "src/lib_debug.c",
    "src/lib_jit.c",
    "src/lib_ffi.c",
    "src/lib_buffer.c",
};

const lua_sources = &.{
    "src/lib_init.c",
    "src/lib_aux.c",

    "src/lj_trace.c",
    "src/lj_meta.c",
    "src/lj_api.c",
    "src/lj_debug.c",
    "src/lj_tab.c",
    "src/lj_vmmath.c",
    "src/lj_cconv.c",
    "src/lj_cparse.c",
    "src/lj_ccallback.c",
    "src/lj_dispatch.c",
    "src/lj_record.c",
    "src/lj_opt_sink.c",
    "src/lj_carith.c",
    "src/lj_ccall.c",
    "src/lj_bcread.c",
    "src/lj_alloc.c",
    "src/lj_crecord.c",
    "src/lj_cdata.c",
    "src/lj_prng.c",
    "src/lj_opt_split.c",
    "src/lj_char.c",
    "src/lj_bc.c",
    "src/lj_opt_narrow.c",
    "src/lj_opt_fold.c",
    "src/lj_strfmt_num.c",
    "src/lj_buf.c",
    "src/lj_serialize.c",
    "src/lj_asm.c",
    "src/lj_clib.c",
    "src/lj_gc.c",
    "src/lj_profile.c",
    "src/lj_gdbjit.c",
    "src/lj_assert.c",
    "src/lj_ir.c",
    "src/lj_func.c",
    "src/lj_bcwrite.c",
    "src/lj_opt_loop.c",
    "src/lj_opt_dce.c",
    "src/lj_vmevent.c",
    "src/lj_strscan.c",
    "src/lj_str.c",
    "src/lj_lex.c",
    "src/lj_parse.c",
    "src/lj_lib.c",
    "src/lj_err.c",
    "src/lj_opt_mem.c",
    "src/lj_strfmt.c",
    "src/lj_load.c",
    "src/lj_udata.c",
    "src/lj_obj.c",
    "src/lj_snap.c",
    "src/lj_ffrecord.c",
    "src/lj_state.c",
    "src/lj_ctype.c",
    "src/lj_mcode.c",
};
