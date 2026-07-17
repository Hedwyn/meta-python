//! Helper functions shared by build.zig: driving `./configure`, turning
//! parsed Makefile data into Zig compile steps, and other mechanical bits
//! that aren't part of the top-level build orchestration.

const std = @import("std");
const Makefile = @import("makefile.zig");

pub const BundledArchive = struct {
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
pub const bundled_archives = [_]BundledArchive{
    .{ .path = "Modules/_decimal/libmpdec/libmpdec.a", .objs_var = "LIBMPDEC_OBJS", .cflags_var = "LIBMPDEC_CFLAGS" },
    .{ .path = "Modules/expat/libexpat.a", .objs_var = "LIBEXPAT_OBJS", .cflags_var = "LIBEXPAT_CFLAGS" },
    .{ .path = "Modules/_hacl/libHacl_Hash_SHA2.a", .objs_var = "LIBHACL_SHA2_OBJS", .cflags_var = "LIBHACL_CFLAGS" },
};

pub fn findBundledArchive(path: []const u8) ?BundledArchive {
    for (bundled_archives) |a| {
        if (std.mem.eql(u8, a.path, path)) return a;
    }
    return null;
}

/// Modules that only exist to exercise CPython's own test suite / C API
/// internals -- never useful in a normal interpreter, so we don't build them.
pub const skip_modules = std.StaticStringMap(void).initComptime(.{
    .{"_testbuffer"},        .{"_testinternalcapi"},   .{"_testcapi"},
    .{"_testclinic"},        .{"_testimportmultiple"}, .{"_testmultiphase"},
    .{"_testsinglephase"},   .{"_ctypes_test"},        .{"xxlimited"},
    .{"xxlimited_35"},       .{"xxsubtype"},           .{"_xxtestfuzz"},
    .{"_xxsubinterpreters"}, .{"_xxinterpchannels"},
});

/// `objsToSources` assumes every object has a same-named `.c` source, which
/// holds for nearly everything -- except a couple of objects (e.g.
/// Python/asm_trampoline.o) that are actually built from a `.S` assembly
/// file. Swap those in place instead of guessing arch/config-specific rules.
pub fn fixupSourceExtensions(b: *std.Build, cpython_dir: []const u8, sources: [][]const u8) [][]const u8 {
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

pub fn runConfigure(
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

pub const ExeOptions = struct {
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
    /// Whether the executable itself (and the libc it links) is statically
    /// or dynamically linked -- independent of the third-party dependency
    /// StaticOverrides above, which only affect extension `.so`s.
    linkage: std.builtin.LinkMode,
};

/// Shared setup between `addExe` and `addPythonLib`: include paths, core +
/// extra sources, `dynload_shlib.c`, and system link tokens. Everything a
/// "contains the CPython core" compile step needs, regardless of whether it
/// ends up as an executable, a static archive, or a shared object.
fn addCoreObjects(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mod: *std.Build.Module,
    gpa: std.mem.Allocator,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    frozen_headers: []const std.Build.LazyPath,
    dynload_flags: []const []const u8,
    link_libs: []const u8,
) void {
    mod.addIncludePath(cpython_dir);
    mod.addIncludePath(cpython_dir.path(b, "Include"));
    mod.addIncludePath(cpython_dir.path(b, "Include/internal"));
    // Each generated `Python/frozen_modules/x.h` is #include-d two different
    // ways: `Python/frozen.c` says `#include "frozen_modules/x.h"` (root at
    // .../Python), while `Programs/_bootstrap_python.c` says `#include
    // "Python/frozen_modules/x.h"` (root one level up). Add both depths.
    for (frozen_headers) |h| {
        mod.addIncludePath(h.dirname().dirname());
        mod.addIncludePath(h.dirname().dirname().dirname());
    }

    const core_flags = extractIncludePaths(mod, b, cpython_dir, gpa, core_cflags);
    const resolved_extra_flags = extractIncludePaths(mod, b, cpython_dir, gpa, extra_flags);
    const resolved_dynload_flags = extractIncludePaths(mod, b, cpython_dir, gpa, dynload_flags);
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = core_sources, .flags = core_flags });
    mod.addCSourceFiles(.{ .root = cpython_dir, .files = extra_sources, .flags = resolved_extra_flags });
    mod.addCSourceFile(.{ .file = cpython_dir.path(b, "Python/dynload_shlib.c"), .flags = resolved_dynload_flags });
    applyLinkTokens(mod, link_libs, &.{});
}

pub fn addExe(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gpa: std.mem.Allocator,
    opts: ExeOptions,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    addCoreObjects(
        b,
        cpython_dir,
        mod,
        gpa,
        opts.core_sources,
        opts.core_cflags,
        opts.extra_sources,
        opts.extra_flags,
        opts.frozen_headers,
        opts.dynload_flags,
        opts.link_libs,
    );

    return b.addExecutable(.{ .name = opts.name, .root_module = mod, .linkage = opts.linkage });
}

pub const LibPythonOptions = struct {
    name: []const u8,
    core_sources: []const []const u8,
    core_cflags: []const []const u8,
    /// `Modules/getpath.c` and `Python/frozen.c` -- everything stage 3 used
    /// to compile straight into the executable that now belongs in the
    /// library instead. `Programs/python.c` is deliberately NOT here: it
    /// stays in the thin shim executable (see build.zig), same split
    /// upstream CPython uses for `--enable-shared` builds.
    extra_sources: []const []const u8,
    extra_flags: []const []const u8,
    link_libs: []const u8,
    frozen_headers: []const std.Build.LazyPath,
    dynload_flags: []const []const u8,
    deepfreeze_c: std.Build.LazyPath,
    /// `.static` -> libpythonX.Y.a (still ends up fully absorbed into
    /// whatever links it -- a build-organization split, not a runtime one).
    /// `.dynamic` -> a real libpythonX.Y.so with its own `.dynsym`, so
    /// extension modules and the shim resolve Python C-API symbols via an
    /// ordinary build-time dependency instead of `-rdynamic`.
    linkage: std.builtin.LinkMode,
};

pub fn addPythonLib(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gpa: std.mem.Allocator,
    opts: LibPythonOptions,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    addCoreObjects(
        b,
        cpython_dir,
        mod,
        gpa,
        opts.core_sources,
        opts.core_cflags,
        opts.extra_sources,
        opts.extra_flags,
        opts.frozen_headers,
        opts.dynload_flags,
        opts.link_libs,
    );
    mod.addCSourceFile(.{ .file = opts.deepfreeze_c, .flags = opts.core_cflags });

    const lib = b.addLibrary(.{ .name = opts.name, .root_module = mod, .linkage = opts.linkage });
    return lib;
}

/// `-I<path>` tokens pulled from the Makefile are relative to `$(srcdir)`
/// (i.e. cpython_dir in an in-tree build), which only holds if the C
/// compiler subprocess's cwd happens to match -- not guaranteed here. Turn
/// each into a real (absolute) `addIncludePath` call instead of leaving it as
/// an opaque, cwd-dependent flag string; return the remaining flags.
pub fn extractIncludePaths(
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

/// Maps a system library name (the `-l<name>` token CPython's own Makefile
/// would otherwise pass) to a Zig-built static artifact that should be baked
/// into the module instead of dynamically linking the host's `.so`.
pub const StaticOverride = struct {
    lib_name: []const u8,
    artifact: *std.Build.Step.Compile,
};

fn findOverride(overrides: []const StaticOverride, lib_name: []const u8) ?*std.Build.Step.Compile {
    for (overrides) |o| {
        if (std.mem.eql(u8, o.lib_name, lib_name)) return o.artifact;
    }
    return null;
}

pub fn applyLinkTokens(mod: *std.Build.Module, expanded: []const u8, overrides: []const StaticOverride) void {
    var it = std.mem.tokenizeAny(u8, expanded, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-l")) {
            if (findOverride(overrides, tok[2..])) |artifact| {
                mod.linkLibrary(artifact);
            } else {
                mod.linkSystemLibrary(tok[2..], .{});
            }
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
        }
    }
}

/// Copies an exe's binary next to a fresh copy of Lib/, in the relative
/// layout CPython's getpath.c landmark search expects, so it can run as a
/// real interpreter straight out of the build cache (see getpath_defines).
/// Returns the LazyPath of the copied executable.
pub fn packageExe(b: *std.Build, cpython_dir: std.Build.LazyPath, version: []const u8, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const wf = b.addNamedWriteFiles(exe.name);
    _ = wf.addCopyDirectory(cpython_dir.path(b, "Lib"), b.fmt("lib/python{s}", .{version}), .{});
    return wf.addCopyFile(exe.getEmittedBin(), b.fmt("bin/{s}", .{exe.out_filename}));
}

/// Invokes Tools/build/deepfreeze.py (a pure-Python script run by the stage-2
/// bootstrap interpreter) to combine all frozen module headers into a single
/// Python/deepfreeze/deepfreeze.c file, which embeds the entire frozen stdlib
/// bytecode into the final executable. Each frozen module header is passed as
/// a "path:name" argument. The path half is only known once the freeze Run
/// steps above actually execute, so the pairing can't be done in build.zig at
/// graph-construction time -- instead a small native helper
/// (build/tools/deepfreeze_runner.zig) does it at run time.
pub fn addDeepfreeze(
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

pub fn addSharedModule(
    b: *std.Build,
    cpython_dir: std.Build.LazyPath,
    mk: Makefile,
    gpa: std.mem.Allocator,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    common_cflags: []const []const u8,
    name: []const u8,
    overrides: []const StaticOverride,
    /// When the core interpreter is built as a real libpythonX.Y.so
    /// (`python-linkage=dynamic`), every extension module links against it
    /// directly instead of relying on `-rdynamic` to resolve its Python
    /// C-API references against the main executable at runtime.
    python_lib: ?*std.Build.Step.Compile,
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
    applyLinkTokens(mod, std.mem.join(gpa, " ", rule.recipe) catch @panic("OOM"), overrides);

    if (python_lib) |lib| {
        mod.linkLibrary(lib);
        // lib-dynload/foo.so -> ../.. reaches the prefix's lib/ dir, where
        // libpythonX.Y.so is installed (see build.zig's install step). Zig
        // also unconditionally emits an extra `-rpath <build-cache-dir>`
        // entry for same-build `linkLibrary` dynamic dependencies (no public
        // flag suppresses it) -- harmless: it's just a dead RUNPATH entry
        // once the tree is installed/moved elsewhere, and this $ORIGIN one
        // still resolves correctly (verified by relocating a built tree).
        mod.addRPathSpecial("$ORIGIN/../..");
    }

    return b.addLibrary(.{ .name = name, .root_module = mod, .linkage = .dynamic });
}
