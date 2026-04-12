// 現在は example/src → src/ のシンボリックリンク経由でライブラリを参照している。
// TODO: Zig が macOS 26.x SDK + -M フラグに対応した際は、以下のように変更する:
//   1. example/src シンボリックリンクを削除する
//   2. @import("src/root.zig") → @import("zctx") に変更する
//   3. mise.toml のコンパイルコマンドで -Mzctx=src/root.zig を指定する
//      または build.zig にモジュール登録（b.addModule("zctx", ...)）を使うこと。
const zctx = @import("src/root.zig");

const std = @import("std");

// TypedKey でコンテキストに格納するキーを定義する
const RequestIdKey = zctx.TypedKey(u64);
const UserNameKey = zctx.TypedKey([]const u8);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== value: TypedKey によるコンテキスト値の受け渡し ===\n", .{});

    // リクエスト ID をコンテキストに格納する
    const ctx1 = try zctx.withTypedValue(RequestIdKey, allocator, zctx.background, 42);
    defer ctx1.deinit();

    // ユーザー名をさらに重ねて格納する
    const ctx2 = try zctx.withTypedValue(UserNameKey, allocator, ctx1.context, "alice");
    defer ctx2.deinit();

    // 子コンテキストから両方の値を取得できる
    const req_id = ctx2.context.typedValue(RequestIdKey);
    const user_name = ctx2.context.typedValue(UserNameKey);

    std.debug.print("request_id: {?}\n", .{req_id});
    std.debug.print("user_name:  {?s}\n", .{user_name});
}
