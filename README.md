# zctx

Go の `context` パッケージを Zig に移植したキャンセル伝播ライブラリ。

- **`withCancel`** — 手動キャンセル
- **`withTimeout` / `withDeadline`** — タイムアウト・デッドライン
- **`withTypedValue`** — comptime 型安全なキーバリューストア
- **`waitAny`** — 複数シグナルの同時待機（Go の `select` 相当）

---

## 利用者向け

### インストール

`build.zig.zon` に依存を追加し、`build.zig` でモジュールをインポートする。

```zig
// build.zig
const zctx = b.dependency("zctx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zctx", zctx.module("zctx"));
```

### API 一覧

```zig
const zctx = @import("zctx");

// ルートコンテキスト（アロケータ不要）
zctx.background        // キャンセルされないルート
zctx.todo              // 未実装のプレースホルダー
zctx.cancelledContext  // 最初からキャンセル済み

// 派生コンテキスト（返り値は OwnedContext）
zctx.withCancel(io, parent, alloc)                    // error{OutOfMemory}!OwnedContext
zctx.withTimeout(io, parent, timeoutNs, alloc)        // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext
zctx.withDeadline(io, parent, deadlineNs: i96, alloc) // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext
zctx.withTypedValue(Key, alloc, parent, value)        // error{OutOfMemory}!OwnedContext

// OwnedContext のメソッド
result.context      // Context 値
result.cancel(io)   // シグナルのみ発火。idempotent。メモリは解放しない。
result.deinit(io)   // メモリ解放（未キャンセルなら先にキャンセル）。defer で呼ぶ。

// Context のメソッド
ctx.done()               // *Signal  — isFired() / wait(io) で待機できる
ctx.err(io)              // ?CancelError  — null / error.Canceled / error.DeadlineExceeded
ctx.deadline()           // ?i96  — std.Io.Clock.Timestamp 基準のデッドライン
ctx.typedValue(Key)      // ?Key.Value  — 型安全な値の取り出し

// Signal のユーティリティ
zctx.waitAny(io, .{ .name = signal_ptr, ... })  // FieldEnum — exhaustive switch 可
signal.isFired()                                // bool — ノンブロッキング確認
signal.wait(io)                                 // void — 発火まで待機
signal.waitTimeout(io, timeoutNs)               // bool — 発火=true / タイムアウト=false
```

### 基本的なキャンセル

```zig
const zctx = @import("zctx");
const std = @import("std");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    const result = try zctx.withCancel(io, zctx.background, allocator);
    defer result.deinit(io);

    const thread = try std.Thread.spawn(.{}, doWork, .{ result.context, io });
    defer thread.join();

    std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    result.cancel(io); // スレッドに中断を伝える
    // defer の LIFO 順: thread.join() → result.deinit(io) の順に実行される
}

fn doWork(ctx: zctx.Context, io: std.Io) void {
    while (ctx.err(io) == null) {
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    std.debug.print("cancelled: {?}\n", .{ctx.err(io)});
}
```

### タイムアウト

```zig
const result = try zctx.withTimeout(io, zctx.background, 5 * std.time.ns_per_s, allocator);
defer result.deinit(io);

// タイムアウトまで待機
result.context.done().wait(io);
std.debug.print("err: {?}\n", .{result.context.err(io)}); // error.DeadlineExceeded
```

### 親→子キャンセル伝播

```zig
const parent = try zctx.withCancel(io, zctx.background, allocator);
defer parent.deinit(io);

const child = try zctx.withCancel(io, parent.context, allocator);
defer child.deinit(io);

parent.cancel(io); // child にも自動で伝播する
std.debug.print("child err: {?}\n", .{child.context.err(io)}); // error.Canceled
```

### 型安全な値の受け渡し

```zig
// キーを型ごとに定義する（ファイルスコープで宣言することを推奨）
const RequestIdKey = zctx.TypedKey(u64);
const UserNameKey  = zctx.TypedKey([]const u8);

const ctx1 = try zctx.withTypedValue(RequestIdKey, allocator, zctx.background, 42);
defer ctx1.deinit(io);

const ctx2 = try zctx.withTypedValue(UserNameKey, allocator, ctx1.context, "alice");
defer ctx2.deinit(io);

// 子コンテキストから祖先の値を取り出せる
const req_id   = ctx2.context.typedValue(RequestIdKey); // ?u64 → 42
const username = ctx2.context.typedValue(UserNameKey);  // ?[]const u8 → "alice"
```

### 複数シグナルの同時待機（`waitAny`）

Go の `select` 文に相当する。戻り値は `FieldEnum` なので exhaustive switch が書ける。

```zig
fn worker(ctx: zctx.Context, workSignal: *zctx.Signal, io: std.Io) !void {
    const which = zctx.waitAny(io, .{
        .cancel = ctx.done(),
        .work   = workSignal,
    });
    switch (which) {
        .cancel => return error.Canceled,
        .work   => try processWork(),
        // else unreachable 不要。コンパイラが網羅性を保証。
    }
}
```

> **注意**: `Signal` は一射（one-shot）。発火後にリセットできないため、繰り返し通知には
> 呼び出し側で毎回新しい `Signal` を用意すること。

### エラーハンドリング

```zig
fn handleRequest(ctx: zctx.Context, io: std.Io) !void {
    if (ctx.err(io)) |e| return e; // error.Canceled / error.DeadlineExceeded を伝播

    // ... 処理 ...
}
```

### `defer` の順序に注意

`OwnedContext.deinit(io)` はコンテキストのメモリを解放する。複数スレッドがコンテキストを
参照している場合、全スレッドが参照を終えてから `deinit(io)` を呼ぶこと。
`defer` の LIFO 順を活用して `deinit` を `join` より先に宣言する。

```zig
const result = try zctx.withCancel(io, zctx.background, allocator);
defer result.deinit(io); // 宣言順: 1番目 → 実行順: 2番目（後）

const t = try std.Thread.spawn(.{}, worker, .{result.context});
defer t.join();           // 宣言順: 2番目 → 実行順: 1番目（先）
```

---

## 開発者向け

### 必要なツール

- [mise](https://mise.jdx.dev/) — ツールバージョン管理
- Zig 0.16.0（`mise install` で自動インストール）

### セットアップ

```sh
git clone https://github.com/dot96gal/zctx
cd zctx
mise install
```

### タスク

```sh
mise run build   # コンパイルチェック（zig build --summary all）
mise run test    # テスト実行（33件）

mise run example:basic       # withCancel の基本例
mise run example:timeout     # withTimeout の例
mise run example:propagation # 親→子キャンセル伝播の例
mise run example:value       # TypedKey の例
mise run example:wait_any    # waitAny の例
```

### ファイル構成

```
src/
  root.zig      — 公開 API の再エクスポート
  signal.zig    — Signal / waitAny の実装とテスト
  context.zig   — Context / withCancel / withDeadline / withTypedValue の実装とテスト
example/
  basic.zig       — withCancel の基本的な使い方
  timeout.zig     — withTimeout
  propagation.zig — 親→子キャンセル伝播
  value.zig       — TypedKey による値の受け渡し
  wait_any.zig    — waitAny による複数シグナル待機
```

### アーキテクチャ

#### Context はタグ付き共用体

`Context` は vtable ではなくタグ付き共用体で実装している。種類が閉じた集合
（background / todo / cancelled / cancel / deadline / value）であり、switch の網羅性が
コンパイル時に保証される。

```zig
pub const Context = union(enum) {
    background,
    todo,
    cancelled,
    cancel:      *CancelCtx,
    deadlineCtx: *DeadlineCtx,
    valueCtx:    *ValueCtx,
    // ...
};
```

#### Signal は一射ブロードキャスト

Go の `chan struct{}` を閉じる操作に相当する。リスナー（`WaiterNode`）を侵入的リンクリストで
管理するため、`Signal{}` で初期化可能でアロケータ不要。

#### キャンセルと解放の分離

`OwnedContext.cancel(io)` はシグナルのみ発火し、`deinit(io)` がメモリを解放する。これにより
キャンセル後も `ctx.err(io)` などの読み取りが安全に行える。

#### 親→子伝播の TOCTOU 防止

`registerToState()` が親の `mutex` 保持下で「登録 or 即伝播」をアトミックに行う。
親の `cancel(io)` と子の登録が競合しても missed wakeup が発生しない。

### テスト

テストはソースファイル内にインラインで記述している（`src/signal.zig` に12件、`src/context.zig`
に21件、計33件）。`testing.allocator` でメモリリークを自動検出する。

```sh
mise run test
# All 33 tests passed.
```
