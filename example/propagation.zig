const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== propagation: 親のキャンセルが子に伝播する ===\n", .{});

    // 親コンテキストを作成する
    const parent = try zctx.withCancel(io, zctx.background, allocator);
    defer parent.deinit(io);

    // 子コンテキストを親から派生させる
    const child = try zctx.withCancel(io, parent.context, allocator);
    defer child.deinit(io);

    std.debug.print("parent err before cancel: {?}\n", .{parent.context.err(io)});
    std.debug.print("child  err before cancel: {?}\n", .{child.context.err(io)});

    // 親をキャンセルすると子にも伝播する
    parent.cancel(io);

    // 子の done シグナルが発火するまで少し待つ（スレッド伝播があるため）
    child.context.done().wait(io);

    std.debug.print("parent err after cancel:  {?}\n", .{parent.context.err(io)});
    std.debug.print("child  err after cancel:  {?}\n", .{child.context.err(io)});
}
