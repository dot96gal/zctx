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
    const timeout_ctx = try zctx.withTimeout(
        allocator,
        io,
        zctx.background,
        .{ .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms }, .clock = .awake },
    );
    defer timeout_ctx.deinit(allocator, io);

    try stdout.print("err before timeout: {?}\n", .{timeout_ctx.context.err(io)});

    // タイムアウトまで待機する
    timeout_ctx.context.done().wait(io);

    try stdout.print("err after timeout:  {?}\n", .{timeout_ctx.context.err(io)});
    try stdout.flush();
}
