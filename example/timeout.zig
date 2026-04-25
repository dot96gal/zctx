const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    try stdout.print("=== timeout: withTimeout ===\n", .{});

    // 100ms のタイムアウトを設定する
    const timeoutNs = 100 * std.time.ns_per_ms;
    const timeoutCtx = try zctx.withTimeout(io, zctx.BACKGROUND, timeoutNs, allocator);
    defer timeoutCtx.deinit(io);

    try stdout.print("err before timeout: {?}\n", .{timeoutCtx.context.err(io)});

    // タイムアウトまで待機する
    timeoutCtx.context.done().wait(io);

    try stdout.print("err after timeout:  {?}\n", .{timeoutCtx.context.err(io)});
    try stdout.flush();
}
