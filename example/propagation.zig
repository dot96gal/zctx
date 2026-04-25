const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    try stdout.print("=== propagation: 親のキャンセルが子に伝播する ===\n", .{});

    // 親コンテキストを作成する
    const parent = try zctx.withCancel(io, zctx.background, allocator);
    defer parent.deinit(io);

    // 子コンテキストを親から派生させる
    const child = try zctx.withCancel(io, parent.context, allocator);
    defer child.deinit(io);

    try stdout.print("parent err before cancel: {?}\n", .{parent.context.err(io)});
    try stdout.print("child  err before cancel: {?}\n", .{child.context.err(io)});

    // 親をキャンセルすると子にも伝播する
    parent.cancel(io);

    // 子の done シグナルが発火するまで少し待つ（スレッド伝播があるため）
    child.context.done().wait(io);

    try stdout.print("parent err after cancel:  {?}\n", .{parent.context.err(io)});
    try stdout.print("child  err after cancel:  {?}\n", .{child.context.err(io)});
    try stdout.flush();
}
