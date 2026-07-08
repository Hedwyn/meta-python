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

/// Reads `-D{lib}-linkage=...` for every third-party dependency (defaulting
/// to "off" when unset). Panics on "static": nothing actually builds any of
/// these libs from source yet, so it's a placeholder request for now.
pub fn parseOptions(b: *std.Build) BuildOptions {
    var options: BuildOptions = undefined;
    inline for (lib_names) |name| {
        const raw = b.option(
            []const u8,
            name ++ "-linkage",
            "Linkage for " ++ name ++ ": static, dynamic, or off (default: off)",
        ) orelse "off";
        const linkage = parseLinkage(raw);
        if (linkage) |l| if (l == .static)
            std.debug.panic(name ++ "-linkage=static: static linking not implemented yet", .{});
        @field(options, name ++ "_linkage") = linkage;
    }
    return options;
}
