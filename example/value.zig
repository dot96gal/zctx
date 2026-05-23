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
    const ctx1 = try zctx.withTypedValue(allocator, zctx.background, RequestIdKey, 42);
    defer ctx1.deinit(allocator, io);

    // ユーザー名をさらに重ねて格納する
    const ctx2 = try zctx.withTypedValue(allocator, ctx1.context, UserNameKey, "alice");
    defer ctx2.deinit(allocator, io);

    // 子コンテキストから両方の値を取得できる
    const req_id = ctx2.context.typedValue(RequestIdKey);
    const user_name = ctx2.context.typedValue(UserNameKey);

    try stdout.print("req_id: {?}\n", .{req_id});
    try stdout.print("user_name:  {?s}\n", .{user_name});
    try stdout.flush();
}
