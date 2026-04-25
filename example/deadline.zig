const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== deadline: withDeadline ===\n", .{});

    // 現在時刻から 100ms 後をデッドラインとして設定する
    const nowNs = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = nowNs + 100 * std.time.ns_per_ms }, .clock = .awake };
    const deadlineCtx = try zctx.withDeadline(io, zctx.background, dl, allocator);
    defer deadlineCtx.deinit(io);

    std.debug.print("err before deadline: {?}\n", .{deadlineCtx.context.err(io)});

    // デッドラインまで待機する
    deadlineCtx.context.done().wait(io);

    std.debug.print("err after deadline:  {?}\n", .{deadlineCtx.context.err(io)});
}
