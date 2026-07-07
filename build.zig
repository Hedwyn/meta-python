const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cpython_dir = b.path("cpython");
    const jobs = std.Thread.getCpuCount() catch 4;

    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cc = b.fmt("{s} cc -target {s}", .{ b.graph.zig_exe, triple });
    const cxx = b.fmt("{s} c++ -target {s}", .{ b.graph.zig_exe, triple });
    const ar = b.fmt("{s} ar", .{b.graph.zig_exe});
    const ranlib = b.fmt("{s} ranlib", .{b.graph.zig_exe});

    const build_root = b.root.root_dir.path orelse @panic("expected absolute build root path");
    const prefix = b.pathJoin(&.{ build_root, "zig-out" });

    const configure = std.Build.Step.Run.create(b, "configure cpython");
    configure.setCwd(cpython_dir);
    configure.addArgs(&.{
        "./configure",
        b.fmt("--prefix={s}", .{prefix}),
        switch (optimize) {
            .Debug => "--with-pydebug",
            .ReleaseFast, .ReleaseSmall, .ReleaseSafe => "--enable-optimizations",
        },
    });
    configure.setEnvironmentVariable("CC", cc);
    configure.setEnvironmentVariable("CXX", cxx);
    configure.setEnvironmentVariable("AR", ar);
    configure.setEnvironmentVariable("RANLIB", ranlib);

    const make = std.Build.Step.Run.create(b, "make cpython");
    make.setCwd(cpython_dir);
    make.addArgs(&.{ "make", b.fmt("-j{d}", .{jobs}) });
    make.step.dependOn(&configure.step);

    const make_install = std.Build.Step.Run.create(b, "make install cpython");
    make_install.setCwd(cpython_dir);
    make_install.addArgs(&.{ "make", "install" });
    make_install.step.dependOn(&make.step);

    b.getInstallStep().dependOn(&make_install.step);
}
