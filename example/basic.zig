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

    // withCancel でキャンセル可能なコンテキストを作成する
    const result = try zctx.withCancel(allocator, zctx.background);
    defer result.deinit();

    std.debug.print("=== basic: withCancel ===\n", .{});
    std.debug.print("err before cancel: {?}\n", .{result.context.err()});
    std.debug.print("done fired before cancel: {}\n", .{result.context.done().isFired()});

    result.cancel();

    std.debug.print("err after cancel:  {?}\n", .{result.context.err()});
    std.debug.print("done fired after cancel:  {}\n", .{result.context.done().isFired()});
}
