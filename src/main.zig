const std = @import("std");
const liblua = @import("libluajit").c;

fn lua_pcall(L: ?*liblua.lua_State, n: c_int, r: c_int, f: c_int) callconv(.c) c_int {
    return liblua.lua_pcall(L, n, r, f);
}

fn luaL_dostring(L: ?*liblua.lua_State, s: [*c]const u8) callconv(.c) bool {
    return (liblua.luaL_loadstring(L, s) != 0) or (lua_pcall(L, @as(c_int, 0), liblua.LUA_MULTRET, @as(c_int, 0)) != 0);
}

pub fn main() !void {
    const L = liblua.luaL_newstate();
    if (L == null) return error.OutOfMemory;

    liblua.lua_register(L, "c_add", c_add);
    liblua.lua_register(L, "print", zig_print);

    const chunk1 =
        \\print("Calling Zig-registered function c_add from Lua:")
        \\local r = c_add(10, 32)
        \\print("10 + 32 = ", r)
    ;

    if (luaL_dostring(L, chunk1)) {
        const err = liblua.lua_tolstring(L, -1, null);
        std.debug.print("Error running chunk1: {s}\n", .{err});
        liblua.lua_pop(L, 1);
    }

    const chunk2 = "function lua_add(a, b) return a + b end";
    if (luaL_dostring(L, chunk2)) {
        const err = liblua.lua_tolstring(L, -1, null);
        std.debug.print("Error defining lua_add: {s}\n", .{err});
        liblua.lua_pop(L, 1);
    } else {
        _ = liblua.lua_getglobal(L, "lua_add");
        liblua.lua_pushinteger(L, 7);
        liblua.lua_pushinteger(L, 5);

        if (lua_pcall(L, 2, 1, 0) != liblua.LUA_OK) {
            const err = liblua.lua_tolstring(L, -1, null);
            std.debug.print("Error calling lua_add: {s}\n", .{err});
            liblua.lua_pop(L, 1);
        } else {
            const res = liblua.lua_tointegerx(L, -1, null);
            std.debug.print("lua_add(7,5) returned: {d}\n", .{res});
            liblua.lua_pop(L, 1);
        }
    }

    liblua.lua_close(L);
}

fn c_add(L: ?*liblua.lua_State) callconv(.c) c_int {
    const a = liblua.luaL_checkinteger(L, 1);
    const b = liblua.luaL_checkinteger(L, 2);

    liblua.lua_pushinteger(L, a + b);
    return 1;
}

fn zig_print(L: ?*liblua.lua_State) callconv(.c) c_int {
    const nargs = liblua.lua_gettop(L);
    var i: c_int = 1;
    while (i <= nargs) : (i += 1) {
        const str = liblua.lua_tolstring(L, i, null);
        if (str != null) {
            std.debug.print("{s}", .{str});
        } else {
            if (liblua.lua_isnil(L, i)) {
                std.debug.print("nil", .{});
            } else if (liblua.lua_isboolean(L, i)) {
                const b = liblua.lua_toboolean(L, i);
                std.debug.print("{}", .{b != 0});
            } else if (liblua.lua_isnumber(L, i) != 0) {
                const n = liblua.lua_tonumberx(L, i, null);
                std.debug.print("{d}", .{n});
            } else {
                const t = liblua.luaL_typename(L, i);
                std.debug.print("<{s}>", .{t});
            }
        }
    }
    std.debug.print("\n", .{});
    return 0;
}
