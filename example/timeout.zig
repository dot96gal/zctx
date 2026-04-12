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

    std.debug.print("=== timeout: withTimeout ===\n", .{});

    // 100ms のタイムアウトを設定する
    const timeout_ns = 100 * std.time.ns_per_ms;
    const result = try zctx.withTimeout(allocator, zctx.background, timeout_ns);
    defer result.deinit();

    std.debug.print("err before timeout: {?}\n", .{result.context.err()});

    // タイムアウトまで待機する
    result.context.done().wait();

    std.debug.print("err after timeout:  {?}\n", .{result.context.err()});
}
