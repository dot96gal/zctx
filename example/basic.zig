const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    // withCancel でキャンセル可能なコンテキストを作成する
    const cancelCtx = try zctx.withCancel(io, zctx.BACKGROUND, allocator);
    defer cancelCtx.deinit(io);

    try stdout.print("=== basic: withCancel ===\n", .{});
    try stdout.print("err before cancel: {?}\n", .{cancelCtx.context.err(io)});
    try stdout.print("done fired before cancel: {}\n", .{cancelCtx.context.done().isFired()});

    cancelCtx.cancel(io);

    try stdout.print("err after cancel:  {?}\n", .{cancelCtx.context.err(io)});
    try stdout.print("done fired after cancel:  {}\n", .{cancelCtx.context.done().isFired()});
    try stdout.flush();
}
