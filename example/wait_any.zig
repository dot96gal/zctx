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

    std.debug.print("=== wait_any: 複数のシグナルのいずれかを待機する ===\n", .{});

    // 2つのキャンセル可能なコンテキストを作成する
    const ctx_a = try zctx.withCancel(allocator, zctx.background);
    defer ctx_a.deinit();

    const ctx_b = try zctx.withCancel(allocator, zctx.background);
    defer ctx_b.deinit();

    // 別スレッドで ctx_b をキャンセルする
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(owned: zctx.OwnedContext) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            owned.cancel();
        }
    }.run, .{ctx_b});
    thread.detach();

    // ctx_a または ctx_b のいずれかがキャンセルされるまで待機する
    const which = zctx.waitAny(.{
        .a = ctx_a.context.done(),
        .b = ctx_b.context.done(),
    });

    std.debug.print("fired: {s}\n", .{@tagName(which)});
    std.debug.print("ctx_a err: {?}\n", .{ctx_a.context.err()});
    std.debug.print("ctx_b err: {?}\n", .{ctx_b.context.err()});
}
