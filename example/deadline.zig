const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    try stdout.print("=== deadline: withDeadline ===\n", .{});

    // 現在時刻から 100ms 後をデッドラインとして設定する
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = std.Io.Clock.Timestamp{
        .raw = .{ .nanoseconds = now_ns + 100 * std.time.ns_per_ms },
        .clock = .awake,
    };
    const deadline_ctx = try zctx.withDeadline(allocator, io, zctx.background, dl);
    defer deadline_ctx.deinit(allocator, io);

    try stdout.print("err before deadline: {?}\n", .{deadline_ctx.context.err(io)});

    // デッドラインまで待機する
    deadline_ctx.context.done().wait(io);

    try stdout.print("err after deadline:  {?}\n", .{deadline_ctx.context.err(io)});
    try stdout.flush();
}
