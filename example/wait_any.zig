const zctx = @import("zctx");

const std = @import("std");

const ThreadArgs = struct {
    owned: zctx.OwnedContext,
    io: std.Io,
};

fn cancelAfterDelay(thread_args: ThreadArgs) void {
    std.Io.sleep(thread_args.io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    thread_args.owned.cancel(thread_args.io);
}

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== wait_any: 複数のシグナルのいずれかを待機する ===\n", .{});

    // 2つのキャンセル可能なコンテキストを作成する
    const ctx_a = try zctx.withCancel(io, zctx.background, allocator);
    defer ctx_a.deinit(io);

    const ctx_b = try zctx.withCancel(io, zctx.background, allocator);
    defer ctx_b.deinit(io);

    // 別スレッドで ctx_b をキャンセルする
    const thread = try std.Thread.spawn(.{}, cancelAfterDelay, .{ThreadArgs{ .owned = ctx_b, .io = io }});
    thread.detach();

    // ctx_a または ctx_b のいずれかがキャンセルされるまで待機する
    const which = zctx.waitAny(io, .{
        .a = ctx_a.context.done(),
        .b = ctx_b.context.done(),
    });

    std.debug.print("fired: {s}\n", .{@tagName(which)});
    std.debug.print("ctx_a err: {?}\n", .{ctx_a.context.err(io)});
    std.debug.print("ctx_b err: {?}\n", .{ctx_b.context.err(io)});
}
