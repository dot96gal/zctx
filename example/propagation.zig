// 現在は example/src → src/ のシンボリックリンク経由でライブラリを参照している。
// TODO: Zig が macOS 26.x SDK + -M フラグに対応した際は、以下のように変更する:
//   1. example/src シンボリックリンクを削除する
//   2. @import("src/root.zig") → @import("zctx") に変更する
//   3. mise.toml のコンパイルコマンドで -Mzctx=src/root.zig を指定する
//      または build.zig にモジュール登録（b.addModule("zctx", ...)）を使うこと。
const zctx = @import("src/root.zig");

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== propagation: 親のキャンセルが子に伝播する ===\n", .{});

    // 親コンテキストを作成する
    const parent = try zctx.withCancel(allocator, zctx.background);
    defer parent.deinit();

    // 子コンテキストを親から派生させる
    const child = try zctx.withCancel(allocator, parent.context);
    defer child.deinit();

    std.debug.print("parent err before cancel: {?}\n", .{parent.context.err()});
    std.debug.print("child  err before cancel: {?}\n", .{child.context.err()});

    // 親をキャンセルすると子にも伝播する
    parent.cancel();

    // 子の done シグナルが発火するまで少し待つ（スレッド伝播があるため）
    child.context.done().wait();

    std.debug.print("parent err after cancel:  {?}\n", .{parent.context.err()});
    std.debug.print("child  err after cancel:  {?}\n", .{child.context.err()});
}
