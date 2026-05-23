const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    try stdout.print("=== multi_cancel: 親コンテキストで複数キャンセル条件を合成する ===\n", .{});

    // タイムアウト付き親コンテキストを作成（200ms）
    const timeout_ctx = try zctx.withTimeout(
        allocator,
        io,
        zctx.background,
        .{ .raw = .{ .nanoseconds = 200 * std.time.ns_per_ms }, .clock = .awake },
    );
    defer timeout_ctx.deinit(allocator, io);

    // 手動キャンセル可能な子コンテキストを親から派生
    // → タイムアウト OR 手動キャンセルのどちらかで終了する
    const work_ctx = try zctx.withCancel(allocator, io, timeout_ctx.context);
    defer work_ctx.deinit(allocator, io);

    // 別スレッドで 50ms 後に手動キャンセル（タイムアウトより先に到達）
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: zctx.OwnedContext, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch |err|
                std.debug.panic("sleep failed: {}", .{err});
            ctx.cancel(tio);
        }
    }.run, .{ work_ctx, io });
    defer thread.join();

    work_ctx.context.done().wait(io);

    try stdout.print("終了理由: {?}\n", .{work_ctx.context.err(io)});
    // → error.Canceled（手動キャンセルが 50ms で到達、タイムアウト 200ms より先）
    try stdout.flush();
}
