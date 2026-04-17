const zctx = @import("zctx");

const std = @import("std");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== deadline: withDeadline ===\n", .{});

    // 現在時刻から 100ms 後をデッドラインとして設定する
    const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = now_ns + 100 * std.time.ns_per_ms }, .clock = .awake };
    const result = try zctx.withDeadline(io, zctx.background, dl, allocator);
    defer result.deinit(io);

    std.debug.print("err before deadline: {?}\n", .{result.context.err(io)});

    // デッドラインまで待機する
    result.context.done().wait(io);

    std.debug.print("err after deadline:  {?}\n", .{result.context.err(io)});
}
