const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    // withCancel でキャンセル可能なコンテキストを作成する
    const cancel_scope = try zctx.withCancel(allocator, io, zctx.background);
    defer cancel_scope.deinit(allocator, io);

    try stdout.print("=== basic: withCancel ===\n", .{});
    try stdout.print("err before cancel: {?}\n", .{cancel_scope.context().err(io)});
    try stdout.print("signal fired before cancel: {}\n", .{
        cancel_scope.context().signal().isFired(),
    });

    cancel_scope.cancel(io);

    try stdout.print("err after cancel:  {?}\n", .{cancel_scope.context().err(io)});
    try stdout.print("signal fired after cancel:  {}\n", .{
        cancel_scope.context().signal().isFired(),
    });
    try stdout.flush();
}
