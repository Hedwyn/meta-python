//! Builds CPython "the normal way" (dynamic linking of extension modules and
//! system libraries), driving compilation directly through Zig's build
//! system instead of `make`.
//!
//! `./configure` is still used (POSIX only) to detect available system
//! libraries and to expand CPython's own Makefile.pre.in into a concrete
//! Makefile via its internal `makesetup` pass. We never execute that
//! Makefile with `make` -- see build/makefile.zig, which reads it purely as
//! data (object lists, per-module CFLAGS/LDFLAGS, frozen-module recipes) so
//! we can add the equivalent Zig compile steps ourselves (see build/utils.zig).

const std = @import("std");
const Makefile = @import("build/makefile.zig");
const Utils = @import("build/utils.zig");
const Options = @import("build/options.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = Options.parseOptions(b);

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize, options),
        else => buildPosix(b, target, optimize, options),
    }
}

fn buildWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options.BuildOptions) void {
    _ = b;
    _ = target;
    _ = optimize;
    _ = options;
    @panic(
        "Windows is not supported yet. CPython builds on Windows via PCBuild/MSBuild " ++
            "project files, not autotools' configure+make -- that needs its own build " ++
            "path, not a target flavor of the POSIX one. TODO.",
    );
}

fn buildPosix(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options.BuildOptions) void {
    // TODO: not yet consulted -- extension modules still link whatever
    // system libs `./configure` found, regardless of these options.
    _ = options;
    const gpa = b.allocator;
    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");
    const cpython_dir_str = b.pathJoin(&.{ build_root, "cpython" });
    const cpython_dir = b.path("cpython");
    const prefix = b.pathJoin(&.{ build_root, "zig-out" });

    Utils.runConfigure(b, cpython_dir_str, prefix, target, optimize);

    const makefile_path = b.pathJoin(&.{ cpython_dir_str, "Makefile" });
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, makefile_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t} (did ./configure run?)", .{ makefile_path, err });
    const mk: Makefile = .{ .text = text };

    const version = mk.get(gpa, "VERSION"); // e.g. "3.12"
    const ext_suffix = mk.get(gpa, "EXT_SUFFIX"); // e.g. ".cpython-312d-x86_64-linux-gnu.so"
    const core_cflags = Makefile.tokens(gpa, mk.get(gpa, "PY_CORE_CFLAGS"));
    const all_core_sources = Utils.fixupSourceExtensions(b, cpython_dir_str, Makefile.objsToSources(gpa, mk.get(gpa, "LIBRARY_OBJS_OMIT_FROZEN")));
    const link_libs = std.mem.concat(gpa, u8, &.{
        mk.get(gpa, "LIBS"), " ", mk.get(gpa, "MODLIBS"), " ", mk.get(gpa, "SYSLIBS"),
    }) catch @panic("OOM");

    // Python/dynload_shlib.c needs -DSOABI, which (unlike most core sources)
    // isn't part of the common PY_CORE_CFLAGS -- pull its real recipe instead
    // of bulk-compiling it with the wrong flags.
    const dynload_src = "Python/dynload_shlib.c";
    var core_sources: std.ArrayList([]const u8) = .empty;
    for (all_core_sources) |s| {
        if (!std.mem.eql(u8, s, dynload_src)) core_sources.append(gpa, s) catch @panic("OOM");
    }
    const dynload_flags = std.mem.concat(gpa, []const u8, &.{
        core_cflags,
        &[_][]const u8{b.fmt("-DSOABI=\"{s}\"", .{mk.get(gpa, "SOABI")})},
    }) catch @panic("OOM");

    // getpath.c is compiled with a blank install prefix everywhere (bootstrap
    // *and* final exe): it makes sys.path discovery relative to argv[0]
    // instead of an absolute path baked in at build time. That's what lets
    // the bootstrap interpreter below run straight out of the build cache
    // (see Utils.packageExe), and it's a step toward this project's
    // relocatability goal (see research.md) rather than a bootstrap-only hack.
    const getpath_defines = [_][]const u8{
        "-DPREFIX=\"\"",
        "-DEXEC_PREFIX=\"\"",
        b.fmt("-DVERSION=\"{s}\"", .{version}),
        "-DPLATLIBDIR=\"lib\"",
        "-DVPATH=\"\"",
    };
    const getpath_flags = std.mem.concat(gpa, []const u8, &.{ core_cflags, &getpath_defines }) catch @panic("OOM");

    const freeze_entries = mk.freezeEntries(gpa);

    // ---- stage 1: freeze_module (a compiled tool, not a real interpreter)
    // A minimal C program that embeds the CPython interpreter but only enough
    // to run Programs/_freeze_module.c's frozen-module compilation logic. Used
    // to freeze the first 4 bootstrap modules (importlib._bootstrap, etc.) whose
    // headers are required to compile stage 2. Uses getpath_noop.c (a stub) since
    // it doesn't need to discover sys.path -- it just freezes files passed as args.
    const freeze_module_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, gpa, .{
        .name = "freeze_module",
        .core_sources = core_sources.items,
        .core_cflags = core_cflags,
        .extra_sources = &.{ "Programs/_freeze_module.c", "Modules/getpath_noop.c" },
        .extra_flags = core_cflags,
        .link_libs = link_libs,
        .frozen_headers = &.{},
        .dynload_flags = dynload_flags,
    });

    var early_headers = std.StringHashMap(std.Build.LazyPath).init(gpa);
    var early_headers_list: std.ArrayList(std.Build.LazyPath) = .empty;
    for (freeze_entries) |f| {
        if (!f.bootstrap) continue;
        const run = b.addRunArtifact(freeze_module_exe);
        run.addArg(f.name);
        run.addFileArg(cpython_dir.path(b, f.src));
        const out = run.addOutputFileArg(f.out);
        early_headers.put(f.name, out) catch @panic("OOM");
        early_headers_list.append(gpa, out) catch @panic("OOM");
    }

    // ---- stage 2: _bootstrap_python (a real interpreter, not just a tool)
    // Has the 4 bootstrap frozen modules baked in and uses real getpath.c
    // (discovers Lib/ relative to argv[0]). Packaged together with Lib/ so it can
    // run pure-Python build scripts like Programs/_freeze_module.py (which freezes
    // the remaining ~20 stdlib modules). Not exposed to end users; only exists to
    // bootstrap stage 3.
    const bootstrap_exe = Utils.addExe(b, cpython_dir, b.graph.host, .Debug, gpa, .{
        .name = "_bootstrap_python",
        .core_sources = core_sources.items,
        .core_cflags = core_cflags,
        .extra_sources = &.{ "Programs/_bootstrap_python.c", "Modules/getpath.c" },
        .extra_flags = getpath_flags,
        .link_libs = link_libs,
        .frozen_headers = early_headers_list.items,
        .dynload_flags = dynload_flags,
    });

    // _bootstrap_python needs Lib/ sitting next to it (in the layout getpath.c's
    // relative landmark search expects) before it can run any Python at all.
    const bootstrap_packaged_exe = Utils.packageExe(b, cpython_dir, version, bootstrap_exe);

    var frozen_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_headers: std.ArrayList(std.Build.LazyPath) = .empty;
    var deepfreeze_names: std.ArrayList([]const u8) = .empty;

    // The remaining (non-bootstrap) frozen modules are frozen by running the
    // *packaged* bootstrap interpreter directly on Programs/_freeze_module.py
    // (a pure-Python re-implementation), exactly as the real Makefile does.
    for (freeze_entries) |f| {
        const out = if (f.bootstrap) early_headers.get(f.name).? else blk: {
            const run = std.Build.Step.Run.create(b, b.fmt("freeze {s}", .{f.name}));
            run.addFileArg(bootstrap_packaged_exe);
            run.addFileArg(cpython_dir.path(b, "Programs/_freeze_module.py"));
            run.addArg(f.name);
            run.addFileArg(cpython_dir.path(b, f.src));
            break :blk run.addOutputFileArg(f.out);
        };
        frozen_headers.append(gpa, out) catch @panic("OOM");
        if (!std.mem.eql(u8, f.name, "getpath")) {
            deepfreeze_headers.append(gpa, out) catch @panic("OOM");
            deepfreeze_names.append(gpa, f.name) catch @panic("OOM");
        }
    }

    const deepfreeze_c = Utils.addDeepfreeze(b, cpython_dir, bootstrap_packaged_exe, deepfreeze_headers.items, deepfreeze_names.items);

    // ---- stage 3: the final "python" executable (the one users run)
    // Built with the target optimization level (not Debug like stages 1-2).
    // Includes all ~24 frozen modules (4 bootstrap + 20 regular), deepfroze stdlib
    // bytecode, and core interpreter. Extension modules are NOT linked in statically
    // -- they're built as standalone .so files below and dlopen()'d at import time,
    // same as CPython normally does. This enables dynamic linking and relocatability.
    const final_exe = Utils.addExe(b, cpython_dir, target, optimize, gpa, .{
        .name = "python",
        .core_sources = core_sources.items,
        .core_cflags = core_cflags,
        .extra_sources = &.{ "Programs/python.c", "Modules/getpath.c", "Python/frozen.c" },
        .extra_flags = getpath_flags,
        .link_libs = link_libs,
        .frozen_headers = frozen_headers.items,
        .dynload_flags = dynload_flags,
    });
    final_exe.root_module.addCSourceFile(.{ .file = deepfreeze_c, .flags = core_cflags });
    final_exe.rdynamic = true; // -export-dynamic: extension .so's resolve Python C API symbols against us

    // ---- optional extension modules, one shared object each, dynamically linked.
    const common_module_cflags = Makefile.tokens(
        gpa,
        std.mem.concat(gpa, u8, &.{ mk.get(gpa, "PY_STDMODULE_CFLAGS"), " ", mk.get(gpa, "CCSHARED") }) catch @panic("OOM"),
    );
    const shared_names = Makefile.tokens(gpa, mk.get(gpa, "MODSHARED_NAMES"));
    var shared_libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (shared_names) |name| {
        if (Utils.skip_modules.has(name)) continue;
        const lib = Utils.addSharedModule(b, cpython_dir, mk, gpa, target, optimize, common_module_cflags, name) orelse continue;
        shared_libs.append(gpa, lib) catch @panic("OOM");
    }

    // ---- install.
    const lib_dir = b.fmt("lib/python{s}", .{version});
    b.getInstallStep().dependOn(&b.addInstallArtifact(final_exe, .{}).step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = cpython_dir.path(b, "Lib"),
        .install_dir = .prefix,
        .install_subdir = lib_dir,
    }).step);
    for (shared_libs.items) |lib| {
        const dest = b.fmt("{s}/lib-dynload/{s}{s}", .{ lib_dir, lib.name, ext_suffix });
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, dest).step);
    }
}
