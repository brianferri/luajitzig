## luajitzig

Build LuaJIT with a minimal setup, using zig

## Installation

```sh
git submodule add git@github.com:brianferri/luajitzig.git
```

In your `build.zig.zon`:

```zig
.dependencies = .{
    .luajitzig = .{
        .path = "luajitzig",
    },
},
```

And import it on your `build.zig` file:

```zig
const luajitzig = b.dependency("luajitzig", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "your_project",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "luajitzig", .module = luajitzig.module("luajitzig") },
        },
    }),
});
b.installArtifact(exe);
```
