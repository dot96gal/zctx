# Signal / SignalSource の分離 + waitAny 削除

## 目標

- `Context.done()` の戻り値を `Signal`（waitable-only の公開型）にし、呼び出し元が `.fire()` を呼べないようにする
- `waitAny` を完全削除する（ライブラリの責務はコンテキスト管理に限定する）
- `@constCast` は一切使わない

## 型の役割分担

| 型名 | 公開/内部 | 役割 | fire() |
|------|----------|------|--------|
| `Signal` | **公開** | waitable-only ラッパー。`done()` が返す型 | なし |
| `SignalSource` | **内部** | `fired` フィールドのみ保持。実際にキャンセルを発火する | あり |

`waitAny` 削除により `mutex` と `waiters` フィールドが不要になり、`SignalSource` が大幅にシンプルになる。

```
内部                               公開 API
SignalSource（firable）  →  Signal（waitable-only ラッパー）
  fire()    ← CancelState 等          isFired()
  wait()       が直接呼ぶ             wait()
  waitTimeout()                       waitTimeout()

Context.done() → Signal
```

## 変更ファイルと作業内容

### 1. `src/signal.zig`

#### 1-1. `waitAny` 関連コードを完全削除

削除対象：

| 削除する要素 | 種別 |
|------------|------|
| `pub fn waitAny(...)` | 関数 |
| `WaitTarget` 構造体 | 型 |
| `WaiterNode` 構造体 | 型 |
| `fn removeNode(...)` | 関数 |
| `SignalSource.waiters` フィールド | フィールド |
| `SignalSource.mutex` フィールド | フィールド |
| `waitAny` に関するテスト 4 件 | テスト |

#### 1-2. 既存の `Signal` を `SignalSource` にリネーム・簡略化

`mutex` と `waiters` が不要になるため、`fire()` もシンプルになる。

```zig
// 変更後（pub は維持するが root.zig には re-export しない）
pub const SignalSource = struct {
    fired: std.Io.Event = .unset,

    fn isFired(self: *const SignalSource) bool {
        return self.fired.isSet();
    }

    fn wait(self: *SignalSource, io: std.Io) void {
        self.fired.waitUncancelable(io);
    }

    fn waitTimeout(self: *SignalSource, io: std.Io, timeoutNs: u64) bool { ... }

    fn fire(self: *SignalSource, io: std.Io) void {
        if (self.fired.isSet()) return;
        self.fired.set(io);
    }

    fn signal(self: *SignalSource) Signal {
        return .{ .source = self };
    }
};
```

#### 1-3. 新しい公開型 `Signal` を追加

```zig
pub const Signal = struct {
    source: *SignalSource,

    pub fn isFired(self: Signal) bool {
        return self.source.isFired();
    }

    pub fn wait(self: Signal, io: std.Io) void {
        self.source.wait(io);
    }

    pub fn waitTimeout(self: Signal, io: std.Io, timeoutNs: u64) bool {
        return self.source.waitTimeout(io, timeoutNs);
    }
};
```

### 2. `src/context.zig`

#### 2-1. `SignalSource` の alias を追加

`context.zig` から `signal_mod.SignalSource`（内部型）を参照するため、ファイル先頭の import 付近に追加する。

```zig
// 追加
const SignalSource = signal_mod.SignalSource;
```

#### 2-2. モジュールレベル変数の型を変更

```zig
// 変更前
var neverFiredSignal: Signal = .{};
var alwaysFiredSignal: Signal = .{ .fired = .is_set };

// 変更後
var neverFiredSignal: SignalSource = .{};
var alwaysFiredSignal: SignalSource = .{ .fired = .is_set };
```

#### 2-3. `Context.done()` の戻り値を `Signal` に変更

```zig
// 変更前
pub fn done(ctx: Context) *Signal

// 変更後
pub fn done(ctx: Context) Signal
```

各 variant の返し方：

```zig
.background, .todo => neverFiredSignal.signal(),
.canceled          => alwaysFiredSignal.signal(),
.cancel            => |c| c.state.source.signal(),
.deadlineCtx       => |d| d.state.source.signal(),
.valueCtx          => |v| v.parent.done(),
```

#### 2-4. `CancelState.signal` フィールドのリネームと関連箇所の修正

| 箇所 | 変更前 | 変更後 |
|------|--------|--------|
| `CancelState` フィールド定義 | `signal: Signal` | `source: SignalSource` |
| `CancelState.init()` | `.signal = .{}` | `.source = .{}` |
| `CancelState.cancelFn()` | `self.signal.fire(io)` | `self.source.fire(io)` |
| `timerWorker()` | `ctx.state.signal.waitTimeout(...)` | `ctx.state.source.waitTimeout(...)` |

### 3. `src/root.zig`

`Signal` は引き続き re-export する（型名は同じだが内容が公開ラッパーに変わる）。
`SignalSource` と `waitAny` は re-export しない。

```zig
pub const Signal = @import("signal.zig").Signal;  // 変更なし（内容は変わる）
// SignalSource は re-export しない
// waitAny は削除済みのため re-export 行を削除
```

### 4. `example/wait_any.zig` の削除

`waitAny` 削除に伴い不要。ファイルを削除する。

### 5. `example/multi_cancel.zig` の追加

親コンテキストを使って複数のキャンセル条件を合成するパターンを示す。
`waitAny` の代替として「タイムアウト OR 手動キャンセル」を実現する例。

```zig
const zctx = @import("zctx");
const std = @import("std");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    std.debug.print("=== multi_cancel: 親コンテキストで複数キャンセル条件を合成する ===\n", .{});

    // タイムアウト付き親コンテキストを作成（200ms）
    const timeout_ctx = try zctx.withTimeout(io, zctx.background, 200 * std.time.ns_per_ms, allocator);
    defer timeout_ctx.deinit(io);

    // 手動キャンセル可能な子コンテキストを親から派生
    // → タイムアウト OR 手動キャンセルのどちらかで終了する
    const work_ctx = try zctx.withCancel(io, timeout_ctx.context, allocator);
    defer work_ctx.deinit(io);

    // 別スレッドで 50ms 後に手動キャンセル（タイムアウトより先に到達）
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: zctx.OwnedContext, tio: std.Io) void {
            std.Io.sleep(tio, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
            ctx.cancel(tio);
        }
    }.run, .{ work_ctx, io });
    defer thread.join();

    work_ctx.context.done().wait(io);

    std.debug.print("終了理由: {?}\n", .{work_ctx.context.err(io)});
    // → error.Canceled（手動キャンセルが 50ms で到達、タイムアウト 200ms より先）
}
```

### 6. `mise.toml` の更新

```toml
# 削除
[tasks."example:wait_any"]

# 追加
[tasks."example:multi_cancel"]
description = "run example/multi_cancel.zig"
run = "zig build run-example-multi_cancel --summary all"
```

### 7. `build.zig` の更新

`wait_any` の example エントリを削除し、`multi_cancel` を追加する。

## コメント・ドキュメントの更新

### `src/signal.zig`

| 箇所 | 変更内容 |
|------|---------|
| `SignalSource`（旧 `Signal`）の doc comment | `var sig = Signal{}` → `var src = SignalSource{}`。`waiters` / `mutex` 関連の説明を削除 |
| 新公開型 `Signal` の doc comment | 「待機専用シグナル。`fire()` は呼べない。`Context.done()` が返す型。」を追加 |
| 残存テスト 8 件のテスト名 | `"Signal: ..."` → `"SignalSource: ..."` に統一 |
| 残存テスト 8 件のテストコード | `var sig = Signal{}` → `var src = SignalSource{}`、`sig.fire(io)` → `src.fire(io)` など全変数名を更新 |

### `src/context.zig`

| 箇所 | 変更内容 |
|------|---------|
| `neverFiredSignal` 周辺のコメント（line 13） | 「外部から fire されることはない」→「`Signal` ラッパー経由では `fire()` を呼べない（型で保証）」。`waitAny` リーク警告は削除 |
| `done()` の doc comment（line 29） | 「キャンセルシグナルを返す」→「待機専用シグナルを返す（`fire()` 不可）。background / todo は永遠に発火しない」 |

### `src/root.zig`

| 箇所 | 変更内容 |
|------|---------|
| `Signal` の doc comment（line 3） | 「一射ブロードキャストシグナル」→「待機専用の一射シグナル。`fire()` は呼べない。GoのDone()チャンネルのclose相当」 |
| `waitAny` の doc comment 行 | 削除 |

### `README.md` の更新

| 箇所 | 変更内容 |
|------|---------|
| API 一覧（line 46） | `ctx.done() // *Signal` → `ctx.done() // Signal`（値型、`fire()` 不可） |
| `Signal のユーティリティ` セクション（line 51–55） | セクション全体を削除（`waitAny` 非公開のため） |
| `waitAny` の節（line 142–162） | セクション全体を削除 |
| アーキテクチャ「Signal は一射ブロードキャスト」（line 257–260） | `mutex` / `waiters` / `WaiterNode` の説明を削除し、`fired`（`std.Io.Event`）のみで動作することを記述 |
| ファイル構成（line 226） | `signal.zig` の説明を更新。`wait_any.zig` を削除し `multi_cancel.zig` を追加 |
| `example:wait_any` タスク説明 | 削除 |
| 新セクション追加 | 「複数キャンセル条件の合成」として `multi_cancel` 例を紹介 |

## 追加するテストケース

### `src/context.zig` に追加

```zig
test "withCancel: done().waitTimeout は未キャンセルならfalseを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    const fired = r.context.done().waitTimeout(io, 1); // 1ns → タイムアウト
    try std.testing.expect(!fired);
}

test "withCancel: done().waitTimeout はcancel後にtrueを返す" {
    const io = std.testing.io;
    const r = try withCancel(io, background, std.testing.allocator);
    defer r.deinit(io);
    r.cancel(io);
    const fired = r.context.done().waitTimeout(io, 1 * std.time.ns_per_s);
    try std.testing.expect(fired);
}
```

## 検証手順

1. `mise run build`（コンパイルエラーなし）
2. `mise run test`（32 テスト全通過）
3. `mise run example:basic` / `example:multi_cancel` など動作確認
4. `ctx.done().fire(io)` がコンパイルエラーになることを確認（`Signal` に `fire` が存在しない）
5. `zctx.waitAny` がコンパイルエラーになることを確認（`root.zig` に存在しない）

## 完了基準

- `done()` の戻り値が `Signal`（公開ラッパー型）
- `fire()` は `Signal` 経由では呼べない（コンパイル時保証）
- `waitAny` がコードベースから完全に削除されている
- `@constCast` がコードベース全体に存在しない
- 全テスト通過（32 件）

## 実装振り返り

### 計画との差異

**`SignalSource.fire()` と `waitTimeout()` の可視性**

| 項目 | 計画 | 実装 |
|------|------|------|
| `SignalSource.fire()` | `fn`（非公開） | `pub fn` |
| `SignalSource.waitTimeout()` | `fn`（非公開） | `pub fn` |

計画の擬似コードでは `fn`（非公開）と記述していたが、`context.zig` は `signal.zig` とは別ファイルであるため、クロスファイルアクセスに `pub` が必須だった。計画の擬似コードの記述漏れであり、設計意図（`fire()` を `Signal` 経由では呼べないようにする）は損なっていない。

次回同様の設計を行う際は、擬似コードに `pub` / 非公開の区別を明示し、呼び出し元ファイルとの関係も注記すること。
