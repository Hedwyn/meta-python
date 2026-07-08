//! Build-time options for how CPython's third-party dependencies get linked,
//! passed on the `zig build` command line (e.g. `-Dopenssl-linkage=dynamic`).

const std = @import("std");

/// static/dynamic linkage of a dependency; same enum std.Build.Step.Compile
/// uses for its own `.linkage` field (see build/utils.zig's addSharedModule).
pub const Linkage = std.builtin.LinkMode;

pub const BuildOptions = struct {
    openssl_linkage: ?Linkage,
    libffi_linkage: ?Linkage,
    ncurses_linkage: ?Linkage,
    readline_linkage: ?Linkage,
    sqlite_linkage: ?Linkage,
    zlib_linkage: ?Linkage,
    bz2_linkage: ?Linkage,
    lzma_linkage: ?Linkage,
    tk_linkage: ?Linkage,
};

const lib_names = [_][]const u8{
    "openssl", "libffi", "ncurses", "readline", "sqlite", "zlib", "bz2", "lzma", "tk",
};

/// "static" / "dynamic" / "off" -> `?Linkage` ("off" -> null, i.e. don't link
/// this dependency at all). Panics on anything else -- a build option typo is
/// a developer error, not something to recover from at runtime.
fn parseLinkage(raw: []const u8) ?Linkage {
    if (std.mem.eql(u8, raw, "static")) return .static;
    if (std.mem.eql(u8, raw, "dynamic")) return .dynamic;
    if (std.mem.eql(u8, raw, "off")) return null;
    std.debug.panic("invalid linkage '{s}': expected 'static', 'dynamic', or 'off'", .{raw});
}

/// Libs that can actually be built from source and statically linked in.
/// Everything else in `lib_names` still only supports "dynamic"/"off".
const static_implemented = std.StaticStringMap(void).initComptime(.{
    .{"zlib"}, .{"openssl"}, .{"libffi"},
});

/// Default linkage per lib: mirrors python-build-standalone (pbs, what `uv`
/// ships) for now -- pbs statically embeds every one of these except tk into
/// its `libpython`, keeping only `_tkinter` as an external dlopen'd `.so`
/// (see dynlibs.md §6). We default to "static" wherever that's actually
/// implemented (`static_implemented`) and fall back to "dynamic" -- stock
/// CPython's own auto-detect-and-link behavior -- for the rest, until static
/// support for them lands too.
const default_overrides = std.StaticStringMap([]const u8).initComptime(.{
    .{ "zlib", "static" },
    .{ "openssl", "static" },
    .{ "libffi", "static" },
});

/// Reads `-D{lib}-linkage=...` for every third-party dependency (see
/// `default_overrides` for per-lib defaults). Panics on "static" for libs
/// not in `static_implemented`: nothing builds those from source yet.
pub fn parseOptions(b: *std.Build) BuildOptions {
    var options: BuildOptions = undefined;
    inline for (lib_names) |name| {
        const default = default_overrides.get(name) orelse "dynamic";
        const raw = b.option(
            []const u8,
            name ++ "-linkage",
            b.fmt("Linkage for " ++ name ++ ": static, dynamic, or off (default: {s})", .{default}),
        ) orelse default;
        const linkage = parseLinkage(raw);
        if (linkage) |l| if (l == .static and !static_implemented.has(name))
            std.debug.panic(name ++ "-linkage=static: static linking not implemented yet", .{});
        @field(options, name ++ "_linkage") = linkage;
    }
    return options;
}

const ModuleDeps = struct {
    linkage_field: []const u8,
    modules: []const []const u8,
};

/// Which CPython extension module(s) each dependency's linkage option gates.
const module_deps = [_]ModuleDeps{
    .{ .linkage_field = "openssl_linkage", .modules = &.{ "_ssl", "_hashlib" } },
    .{ .linkage_field = "libffi_linkage", .modules = &.{"_ctypes"} },
    .{ .linkage_field = "ncurses_linkage", .modules = &.{ "_curses", "_curses_panel" } },
    .{ .linkage_field = "readline_linkage", .modules = &.{"readline"} },
    .{ .linkage_field = "sqlite_linkage", .modules = &.{"_sqlite3"} },
    .{ .linkage_field = "zlib_linkage", .modules = &.{"zlib"} },
    .{ .linkage_field = "bz2_linkage", .modules = &.{"_bz2"} },
    .{ .linkage_field = "lzma_linkage", .modules = &.{"_lzma"} },
    .{ .linkage_field = "tk_linkage", .modules = &.{"_tkinter"} },
};

/// True if `name` is a third-party-backed module whose dependency is off (linkage=null).
pub fn isModuleDisabled(options: BuildOptions, name: []const u8) bool {
    inline for (module_deps) |dep| {
        for (dep.modules) |m| {
            if (std.mem.eql(u8, m, name)) return @field(options, dep.linkage_field) == null;
        }
    }
    return false;
}
