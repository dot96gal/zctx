const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== timeout: withTimeout ===\n", .{});

    // 100ms のタイムアウトを設定する
    const timeoutNs = 100 * std.time.ns_per_ms;
    const timeoutCtx = try zctx.withTimeout(io, zctx.background, timeoutNs, allocator);
    defer timeoutCtx.deinit(io);

    std.debug.print("err before timeout: {?}\n", .{timeoutCtx.context.err(io)});

    // タイムアウトまで待機する
    timeoutCtx.context.done().wait(io);

    std.debug.print("err after timeout:  {?}\n", .{timeoutCtx.context.err(io)});
}
