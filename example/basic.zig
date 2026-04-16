const zctx = @import("zctx");

const std = @import("std");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    // withCancel でキャンセル可能なコンテキストを作成する
    const result = try zctx.withCancel(io, zctx.background, allocator);
    defer result.deinit(io);

    std.debug.print("=== basic: withCancel ===\n", .{});
    std.debug.print("err before cancel: {?}\n", .{result.context.err(io)});
    std.debug.print("done fired before cancel: {}\n", .{result.context.done().isFired()});

    result.cancel(io);

    std.debug.print("err after cancel:  {?}\n", .{result.context.err(io)});
    std.debug.print("done fired after cancel:  {}\n", .{result.context.done().isFired()});
}
