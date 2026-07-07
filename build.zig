//! Builds CPython "the normal way" (dynamic linking of extension modules and
//! system libraries), driving compilation directly through Zig's build
//! system instead of `make`.
//!
//! `./configure` is still used (POSIX only) to detect available system
//! libraries and to expand CPython's own Makefile.pre.in into a concrete
//! Makefile via its internal `makesetup` pass. We never execute that
//! Makefile with `make` -- see build/makefile.zig, which reads it purely as
//! data (object lists, per-module CFLAGS/LDFLAGS, frozen-module recipes) so
//! we can add the equivalent Zig compile steps ourselves.

const std = @import("std");
const Makefile = @import("build/makefile.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    switch (target.result.os.tag) {
        .windows => buildWindows(b, target, optimize),
        else => buildPosix(b, target, optimize),
    }
}

fn buildWindows(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    _ = b;
    _ = target;
    _ = optimize;
    @panic(
        "Windows is not supported yet. CPython builds on Windows via PCBuild/MSBuild " ++
            "project files, not autotools' configure+make -- that needs its own build " ++
            "path, not a target flavor of the POSIX one. TODO.",
    );
}

const BundledArchive = struct {
    path: []const u8,
    objs_var: []const u8,
    cflags_var: []const u8,
};

/// Extension modules that link a small vendored/static library (rather than
/// a system one) get that dependency spelled out as a literal ".a" path
/// baked into their link recipe, bypassing their own LDFLAGS variable. There
/// are only a handful of these in CPython; recognize them by the archive
/// path and compile their sources directly into the module instead of
/// building the intermediate archive make would have.
const bundled_archives = [_]BundledArchive{
    .{ .path = "Modules/_decimal/libmpdec/libmpdec.a", .objs_var = "LIBMPDEC_OBJS", .cflags_var = "LIBMPDEC_CFLAGS" },
    .{ .path = "Modules/expat/libexpat.a", .objs_var = "LIBEXPAT_OBJS", .cflags_var = "LIBEXPAT_CFLAGS" },
    .{ .path = "Modules/_hacl/libHacl_Hash_SHA2.a", .objs_var = "LIBHACL_SHA2_OBJS", .cflags_var = "LIBHACL_CFLAGS" },
};

fn findBundledArchive(path: []const u8) ?BundledArchive {
    for (bundled_archives) |a| {
        if (std.mem.eql(u8, a.path, path)) return a;
    }
    return null;
}

/// Modules that only exist to exercise CPython's own test suite / C API
/// internals -- never useful in a normal interpreter, so we don't build them.
const skip_modules = std.StaticStringMap(void).initComptime(.{
    .{"_testbuffer"},        .{"_testinternalcapi"},   .{"_testcapi"},
    .{"_testclinic"},        .{"_testimportmultiple"}, .{"_testmultiphase"},
    .{"_testsinglephase"},   .{"_ctypes_test"},        .{"xxlimited"},
    .{"xxlimited_35"},       .{"xxsubtype"},           .{"_xxtestfuzz"},
    .{"_xxsubinterpreters"}, .{"_xxinterpchannels"},
});

fn buildPosix(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const gpa = b.allocator;
    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");
    const cpython_dir_str = b.pathJoin(&.{ build_root, "cpython" });
    const cpython_dir = b.path("cpython");
    const prefix = b.pathJoin(&.{ build_root, "zig-out" });

    runConfigure(b, cpython_dir_str, prefix, target, optimize);

    const makefile_path = b.pathJoin(&.{ cpython_dir_str, "Makefile" });
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, makefile_path, gpa, .unlimited) catch |err|
        std.debug.panic("failed to read {s}: {t} (did ./configure run?)", .{ makefile_path, err });
    const mk: Makefile = .{ .text = text };

    const version = mk.get(gpa, "VERSION"); // e.g. "3.12"
    const ext_suffix = mk.get(gpa, "EXT_SUFFIX"); // e.g. ".cpython-312d-x86_64-linux-gnu.so"
    const core_cflags = Makefile.tokens(gpa, mk.get(gpa, "PY_CORE_CFLAGS"));
    const all_core_sources = fixupSourceExtensions(b, cpython_dir_str, Makefile.objsToSources(gpa, mk.get(gpa, "LIBRARY_OBJS_OMIT_FROZEN")));
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
    // (see packageExe), and it's a step toward this project's relocatability
    // goal (see research.md) rather than a bootstrap-only hack.
    const getpath_defines = [_][]const u8{
        "-DPREFIX=\"\"",
        "-DEXEC_PREFIX=\"\"",
        b.fmt("-DVERSION=\"{s}\"", .{version}),
        "-DPLATLIBDIR=\"lib\"",
        "-DVPATH=\"\"",
    };
    const getpath_flags = std.mem.concat(gpa, []const u8, &.{ core_cflags, &getpath_defines }) catch @panic("OOM");

    const freeze_entries = mk.freezeEntries(gpa);

    // ---- stage 1: freeze_module, a minimal interpreter that can only freeze
    // Modules/getpath.py and the importlib bootstrap modules (nothing else
    // works yet: there is no dynamic sys.path/import machinery at this point).
    const freeze_module_exe = addExe(b, cpython_dir, b.graph.host, .Debug, gpa, .{
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

    // ---- stage 2: _bootstrap_python, a real (if minimal) interpreter with
    // enough frozen modules to run pure-Python build scripts. Used only to
    // freeze/deepfreeze the rest of the stdlib bootstrap set below.
    const bootstrap_exe = addExe(b, cpython_dir, b.graph.host, .Debug, gpa, .{
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
    const bootstrap_packaged_exe = packageExe(b, cpython_dir, version, bootstrap_exe);

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

    const deepfreeze_c = addDeepfreeze(b, cpython_dir, bootstrap_packaged_exe, deepfreeze_headers.items, deepfreeze_names.items);

    // ---- stage 3: the real "python" executable. Extension modules that
    // configure detected are *not* linked in here -- they're built as
    // standalone shared objects below and dlopen()'d at import time, same as
    // any normal CPython build.
    const final_exe = addExe(b, cpython_dir, target, optimize, gpa, .{
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
        if (skip_modules.has(name)) continue;
        const lib = addSharedModule(b, cpython_dir, mk, gpa, target, optimize, common_module_cflags, name) orelse continue;
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

/// `objsToSources` assumes every object has a same-named `.c` source, which
/// holds for nearly everything -- except a couple of objects (e.g.
/// Python/asm_trampoline.o) that are actually built from a `.S` assembly
/// file. Swap those in place instead of guessing arch/config-specific rules.
fn fixupSourceExtensions(b: *std.Build, cpython_dir: []const u8, sources: [][]const u8) [][]const u8 {
    for (sources, 0..) |src, i| {
        const abs = b.pathJoin(&.{ cpython_dir, src });
        std.Io.Dir.cwd().access(b.graph.io, abs, .{}) catch {
            const alt = b.fmt("{s}S", .{src[0 .. src.len - 1]});
            const alt_abs = b.pathJoin(&.{ cpython_dir, alt });
            std.Io.Dir.cwd().access(b.graph.io, alt_abs, .{}) catch
                std.debug.panic("neither {s} nor {s} exist", .{ abs, alt_abs });
            sources[i] = alt;
        };
    }
    return sources;
}

fn runConfigure(
    b: *std.Build,
    cpython_dir: []const u8,
    prefix: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const makefile_path = b.pathJoin(&.{ cpython_dir, "Makefile" });
    std.Io.Dir.cwd().access(b.graph.io, makefile_path, .{}) catch {
        const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
        const cc = b.fmt("{s} cc -target {s}", .{ b.graph.zig_exe, triple });
        const cxx = b.fmt("{s} c++ -target {s}", .{ b.graph.zig_exe, triple });
        const ar = b.fmt("{s} ar", .{b.graph.zig_exe});
        const ranlib = b.fmt("{s} ranlib", .{b.graph.zig_exe});

        const argv = [_][]const u8{
            "./configure",
            b.fmt("--prefix={s}", .{prefix}),
            b.fmt("CC={s}", .{cc}),
            b.fmt("CXX={s}", .{cxx}),
            b.fmt("AR={s}", .{ar}),
            b.fmt("RANLIB={s}", .{ranlib}),
            switch (optimize) {
                .Debug => "--with-pydebug",
                .ReleaseFast, .ReleaseSmall, .ReleaseSafe => "--enable-optimizations",
            },
        };
        const result = std.process.run(b.allocator, b.graph.io, .{
            .argv = &argv,
            .cwd = .{ .path = cpython_dir },
        }) catch |err| std.debug.panic("failed to run ./configure: {t}", .{err});
        if (!result.term.success()) {
            std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
            std.debug.panic("./configure failed", .{});
        }
        return;
    };
}

const ExeOptions = struct {
    name: []const u8,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    link_libs: []const u8,
    /// LazyPaths to generated `Python/frozen_modules/*.h` headers this exe's
    /// sources #include; each needs its own include path (every freeze Run
    /// step's output lives in its own cache directory).
    frozen_headers: []const std.Build.LazyPath,
    /// Flags for Python/dynload_shlib.c (needs -DSOABI, which core_cflags lacks).
    dynload_flags: []const []const u8,
};

fn addExe(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gpa: std.mem.Allocator,
    opts: ExeOptions,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(cpython_dir);
    mod.addIncludePath(cpython_dir.path(b, "Include"));
    mod.addIncludePath(cpython_dir.path(b, "Include/internal"));
    for (opts.frozen_headers) |h| mod.addIncludePath(h.dirname().dirname());

    const core_flags = extractIncludePaths(mod, b, cpython_dir, gpa, opts.core_cflags);
    const extra_flags = extractIncludePaths(mod, b, cpython_dir, gpa, opts.extra_flags);
    const dynload_flags = extractIncludePaths(mod, b, cpython_dir, gpa, opts.dynload_flags);
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = opts.core_sources, .flags = core_flags });
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = opts.extra_sources, .flags = extra_flags });
    mod.addCSourceFile(.{ .file = cpython_dir.path(b, "Python/dynload_shlib.c"), .flags = dynload_flags });
    applyLinkTokens(mod, opts.link_libs);

    return b.addExecutable(.{ .name = opts.name, .root_module = mod });
}

/// `-I<path>` tokens pulled from the Makefile are relative to `$(srcdir)`
/// (i.e. cpython_dir in an in-tree build), which only holds if the C
/// compiler subprocess's cwd happens to match -- not guaranteed here. Turn
/// each into a real (absolute) `addIncludePath` call instead of leaving it as
/// an opaque, cwd-dependent flag string; return the remaining flags.
fn extractIncludePaths(
    mod: *std.Build.Module,
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    gpa: std.mem.Allocator,
    raw: []const []const u8,
) [][]const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    for (raw) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            const path = tok[2..];
            if (std.mem.startsWith(u8, path, "/")) {
                mod.addIncludePath(.{ .cwd_relative = path });
            } else {
                mod.addIncludePath(cpython_dir.path(b, path));
            }
        } else {
            flags.append(gpa, tok) catch @panic("OOM");
        }
    }
    return flags.toOwnedSlice(gpa) catch @panic("OOM");
}

fn applyLinkTokens(mod: *std.Build.Module, expanded: []const u8) void {
    var it = std.mem.tokenizeAny(u8, expanded, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-l")) {
            mod.linkSystemLibrary(tok[2..], .{});
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
        }
    }
}

/// Copies an exe's binary next to a fresh copy of Lib/, in the relative
/// layout CPython's getpath.c landmark search expects, so it can run as a
/// real interpreter straight out of the build cache (see getpath_defines).
/// Returns the LazyPath of the copied executable.
fn packageExe(b: *std.Build, cpython_dir: std.Build.LazyPath, version: []const u8, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const wf = b.addNamedWriteFiles(exe.name);
    _ = wf.addCopyDirectory(cpython_dir.path(b, "Lib"), b.fmt("lib/python{s}", .{version}), .{});
    return wf.addCopyFile(exe.getEmittedBin(), b.fmt("bin/{s}", .{exe.out_filename}));
}

/// Runs Tools/build/deepfreeze.py, which expects each frozen-module header
/// paired with its module name as a single "path:name" argument. The path
/// half is only known once the freeze Run steps above actually execute, so
/// the pairing can't be done in build.zig at graph-construction time --
/// instead a small native helper (build/tools/deepfreeze_runner.zig) does it
/// at run time, rather than shelling out to `sh`.
fn addDeepfreeze(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    bootstrap_packaged_exe: std.Build.LazyPath,
    headers: []const std.Build.LazyPath,
    names: []const []const u8,
) std.Build.LazyPath {
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("build/tools/deepfreeze_runner.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const runner = b.addExecutable(.{ .name = "deepfreeze_runner", .root_module = runner_mod });

    const run = b.addRunArtifact(runner);
    run.addFileArg(bootstrap_packaged_exe);
    run.addFileArg(cpython_dir.path(b, "Tools/build/deepfreeze.py"));
    const out = run.addOutputFileArg("deepfreeze.c");
    for (headers, names) |h, name| {
        run.addFileArg(h);
        run.addArg(name);
    }
    return out;
}

fn addSharedModule(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mk: Makefile,
    gpa: std.mem.Allocator,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    common_cflags: []const []const u8,
    name: []const u8,
) ?*std.Build.Step.Compile {
    const rule = mk.findSharedModuleRule(gpa, name) orelse {
        std.debug.print("warning: no build rule found for module '{s}', skipping\n", .{name});
        return null;
    };

    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(cpython_dir);
    mod.addIncludePath(cpython_dir.path(b, "Include"));
    mod.addIncludePath(cpython_dir.path(b, "Include/internal"));

    var upper_buf: [64]u8 = undefined;
    const upper_name = std.ascii.upperString(&upper_buf, name);
    const fallback_cflags_raw = std.mem.concat(
        gpa,
        []const u8,
        &.{ common_cflags, Makefile.tokens(gpa, mk.get(gpa, b.fmt("MODULE_{s}_CFLAGS", .{upper_name}))) },
    ) catch @panic("OOM");

    for (rule.prereqs) |tok| {
        if (!std.mem.endsWith(u8, tok, ".o")) continue;
        const src = b.fmt("{s}c", .{tok[0 .. tok.len - 1]});
        // Prefer the object's real recipe over the MODULE_<NAME>_CFLAGS naming
        // convention: not every module's own object follows it (sha3module.o
        // inlines its own -I flag directly, for instance).
        const flags_raw = if (mk.findObjectFlags(gpa, tok)) |f| Makefile.tokens(gpa, f) else fallback_cflags_raw;
        mod.addCSourceFile(.{
            .file = cpython_dir.path(b, src),
            .flags = extractIncludePaths(mod, b, cpython_dir, gpa, flags_raw),
        });
    }

    for (rule.recipe) |tok| {
        if (!std.mem.endsWith(u8, tok, ".a")) continue;
        const archive = findBundledArchive(tok) orelse {
            std.debug.print("warning: module '{s}' needs unrecognized archive '{s}', skipping\n", .{ name, tok });
            return null;
        };
        mod.addCSourceFiles(.{
            .root = cpython_dir,
            .files = Makefile.objsToSources(gpa, mk.get(gpa, archive.objs_var)),
            .flags = extractIncludePaths(mod, b, cpython_dir, gpa, Makefile.tokens(gpa, mk.get(gpa, archive.cflags_var))),
        });
    }
    applyLinkTokens(mod, std.mem.join(gpa, " ", rule.recipe) catch @panic("OOM"));

    return b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .dynamic });
}
