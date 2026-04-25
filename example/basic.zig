const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    // withCancel でキャンセル可能なコンテキストを作成する
    const cancelCtx = try zctx.withCancel(io, zctx.background, allocator);
    defer cancelCtx.deinit(io);

    std.debug.print("=== basic: withCancel ===\n", .{});
    std.debug.print("err before cancel: {?}\n", .{cancelCtx.context.err(io)});
    std.debug.print("done fired before cancel: {}\n", .{cancelCtx.context.done().isFired()});

    cancelCtx.cancel(io);

    std.debug.print("err after cancel:  {?}\n", .{cancelCtx.context.err(io)});
    std.debug.print("done fired after cancel:  {}\n", .{cancelCtx.context.done().isFired()});
}
