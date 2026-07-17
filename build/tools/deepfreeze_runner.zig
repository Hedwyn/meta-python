//! Runs Tools/build/deepfreeze.py with its "path:modname" arguments composed
//! at process-run time. Zig's build graph can't stringify a LazyPath output
//! from an earlier Run step until that step has actually executed, so the
//! pairing (`<frozen header path>:<module name>`) can't be done in build.zig
//! itself -- this small native helper does it instead of shelling out to `sh`.
//!
//! argv: <python> <deepfreeze.py> <output.c> [<header> <name>]...

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 4 or (argv.len - 4) % 2 != 0) {
        std.process.fatal(
            "usage: {s} <python> <deepfreeze.py> <output.c> [<header> <name>]...",
            .{if (argv.len > 0) argv[0] else "deepfreeze_runner"},
        );
    }

    var child_argv: std.ArrayList([]const u8) = .empty;
    try child_argv.append(gpa, argv[1]);
    try child_argv.append(gpa, argv[2]);

    var i: usize = 4;
    while (i < argv.len) : (i += 2) {
        try child_argv.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{s}", .{ argv[i], argv[i + 1] }));
    }

    try child_argv.append(gpa, "-o");
    try child_argv.append(gpa, argv[3]);

    var child = try std.process.spawn(init.io, .{ .argv = child_argv.items });
    const term = try child.wait(init.io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}
