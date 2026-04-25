const std = @import("std");
const zctx = @import("zctx");

// TypedKey でコンテキストに格納するキーを定義する
const RequestIdKey = zctx.TypedKey(u64);
const UserNameKey = zctx.TypedKey([]const u8);

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &buf);
    const stdout = &file_writer.interface;

    try stdout.print("=== value: TypedKey によるコンテキスト値の受け渡し ===\n", .{});

    // リクエスト ID をコンテキストに格納する
    const ctx1 = try zctx.withTypedValue(zctx.background, RequestIdKey, 42, allocator);
    defer ctx1.deinit(io);

    // ユーザー名をさらに重ねて格納する
    const ctx2 = try zctx.withTypedValue(ctx1.context, UserNameKey, "alice", allocator);
    defer ctx2.deinit(io);

    // 子コンテキストから両方の値を取得できる
    const reqId = ctx2.context.typedValue(RequestIdKey);
    const userName = ctx2.context.typedValue(UserNameKey);

    try stdout.print("reqId: {?}\n", .{reqId});
    try stdout.print("userName:  {?s}\n", .{userName});
    try stdout.flush();
}
