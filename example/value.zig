const zctx = @import("zctx");

const std = @import("std");

// TypedKey でコンテキストに格納するキーを定義する
const RequestIdKey = zctx.TypedKey(u64);
const UserNameKey = zctx.TypedKey([]const u8);

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== value: TypedKey によるコンテキスト値の受け渡し ===\n", .{});

    // リクエスト ID をコンテキストに格納する
    const ctx1 = try zctx.withTypedValue(zctx.background, RequestIdKey, 42, allocator);
    defer ctx1.deinit(io);

    // ユーザー名をさらに重ねて格納する
    const ctx2 = try zctx.withTypedValue(ctx1.context, UserNameKey, "alice", allocator);
    defer ctx2.deinit(io);

    // 子コンテキストから両方の値を取得できる
    const req_id = ctx2.context.typedValue(RequestIdKey);
    const user_name = ctx2.context.typedValue(UserNameKey);

    std.debug.print("request_id: {?}\n", .{req_id});
    std.debug.print("user_name:  {?s}\n", .{user_name});
}
