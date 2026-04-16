const zctx = @import("zctx");

const std = @import("std");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== timeout: withTimeout ===\n", .{});

    // 100ms のタイムアウトを設定する
    const timeout_ns = 100 * std.time.ns_per_ms;
    const result = try zctx.withTimeout(io, zctx.background, timeout_ns, allocator);
    defer result.deinit(io);

    std.debug.print("err before timeout: {?}\n", .{result.context.err(io)});

    // タイムアウトまで待機する
    result.context.done().wait(io);

    std.debug.print("err after timeout:  {?}\n", .{result.context.err(io)});
}
