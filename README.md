# zctx

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zctx/)
[![test](https://github.com/dot96gal/zctx/actions/workflows/test.yml/badge.svg)](https://github.com/dot96gal/zctx/actions/workflows/test.yml)
[![release](https://github.com/dot96gal/zctx/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zctx/actions/workflows/release.yml)

Go の `context` パッケージを Zig に移植したキャンセル伝播ライブラリ。

- **`withCancel`** — 手動キャンセル
- **`withTimeout` / `withDeadline`** — タイムアウト・デッドライン
- **`withTypedValue`** — comptime 型安全なキーバリューストア

---

## 利用者向け

### インストール

最新のタグは [GitHub Releases](https://github.com/dot96gal/zctx/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zctx/archive/<tag>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zctx = .{
        .url = "https://github.com/dot96gal/zctx/archive/<tag>.tar.gz",
        .hash = "<hash>",
    },
},
```

```zig
// build.zig
const zctx = b.dependency("zctx", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zctx", zctx.module("zctx"));
```

### API 一覧

詳細なシグネチャ・型情報は [API ドキュメント](https://dot96gal.github.io/zctx/) を参照。

```zig
const zctx = @import("zctx");

// ルートコンテキスト（アロケータ不要）
zctx.background        // キャンセルされないルート
zctx.todo              // 未実装のプレースホルダー
zctx.canceled          // 最初からキャンセル済み

// 型安全キーの生成（comptime）
zctx.TypedKey(comptime T: type) // type — withTypedValue / typedValue で使うキー型を生成する

// 派生コンテキスト（返り値は OwnedContext）
zctx.withCancel(io, parent, alloc)                                     // error{OutOfMemory}!OwnedContext
zctx.withTimeout(io, parent, timeoutNs, alloc)                         // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext
zctx.withDeadline(io, parent, deadline: std.Io.Clock.Timestamp, alloc) // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedContext
zctx.withTypedValue(parent, Key, value, alloc)                         // error{OutOfMemory}!OwnedContext

// OwnedContext のメソッド
result.context      // Context 値
result.cancel(io)   // シグナルのみを発火する。メモリは解放しない。複数回呼んでも安全に動作する（冪等）。
result.deinit(io)   // メモリを解放する。未キャンセルなら先にキャンセルしてから解放する。defer で必ず呼ぶ。

// Context のメソッド
ctx.done()               // Signal（値型、fire() 不可）— isFired() / wait(io) で待機できる
ctx.err(io)              // ?ContextError  — null / error.Canceled / error.DeadlineExceeded
ctx.deadline()           // ?std.Io.Clock.Timestamp  — デッドライン（なければ null）
ctx.typedValue(Key)      // ?Key.Value  — キーに対応する値を型安全に返す。値が存在しなければ null を返す。

// Signal のメソッド（fire() は呼べない）
signal.isFired()                   // bool — 発火状態をノンブロッキングで確認する。
signal.wait(io)                    // void — 発火するまでブロックする。
signal.waitTimeout(io, timeoutNs)  // bool — 発火=true / タイムアウト=false
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
    std.debug.print("canceled: {?}\n", .{ctx.err(io)});
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

### デッドライン

```zig
const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = now_ns + 5 * std.time.ns_per_s }, .clock = .awake };
const result = try zctx.withDeadline(io, zctx.background, dl, allocator);
defer result.deinit(io);

// デッドラインまで待機
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

const ctx1 = try zctx.withTypedValue(zctx.background, RequestIdKey, 42, allocator);
defer ctx1.deinit(io);

const ctx2 = try zctx.withTypedValue(ctx1.context, UserNameKey, "alice", allocator);
defer ctx2.deinit(io);

// 子コンテキストから祖先の値を取り出せる
const req_id   = ctx2.context.typedValue(RequestIdKey); // ?u64 → 42
const username = ctx2.context.typedValue(UserNameKey);  // ?[]const u8 → "alice"
```

### 複数キャンセル条件の合成

タイムアウトと手動キャンセルを組み合わせる場合、親コンテキストを利用する。
いずれか先にキャンセルされた方が子コンテキストに伝播する。

```zig
// タイムアウト付き親コンテキスト（200ms）
const timeout_ctx = try zctx.withTimeout(io, zctx.background, 200 * std.time.ns_per_ms, allocator);
defer timeout_ctx.deinit(io);

// 手動キャンセル可能な子コンテキスト → タイムアウト OR 手動キャンセルで終了
const work_ctx = try zctx.withCancel(io, timeout_ctx.context, allocator);
defer work_ctx.deinit(io);

work_ctx.context.done().wait(io);
std.debug.print("err: {?}\n", .{work_ctx.context.err(io)});
```

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
defer t.join();          // 宣言順: 2番目 → 実行順: 1番目（先）
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
mise run test    # テスト実行

mise run build-docs  # API ドキュメント生成（zig-out/docs/ に出力）
mise run serve-docs  # API ドキュメントをローカルサーバーで配信

mise run release X.Y.Z  # バージョン更新・コミット・タグ・プッシュを一括実行（例: 1.0.0）

mise run example:basic        # withCancel の基本例
mise run example:timeout      # withTimeout の例
mise run example:deadline     # withDeadline の例
mise run example:propagation  # 親→子キャンセル伝播の例
mise run example:value        # TypedKey の例
mise run example:multi_cancel # 複数キャンセル条件の合成例
```

### ファイル構成

```
src/
  root.zig      — 公開 API の再エクスポート
  signal.zig    — SignalSource / Signal の実装とテスト
  context.zig   — Context / withCancel / withDeadline / withTypedValue の実装とテスト
example/
  basic.zig        — withCancel の基本的な使い方
  timeout.zig      — withTimeout
  deadline.zig     — withDeadline
  propagation.zig  — 親→子キャンセル伝播
  value.zig        — TypedKey による値の受け渡し
  multi_cancel.zig — 親コンテキストで複数キャンセル条件を合成
```

### アーキテクチャ

#### Context はタグ付き共用体

`Context` は vtable ではなくタグ付き共用体で実装している。種類が閉じた集合
（background / todo / canceled / cancel / deadline / value）であり、switch の網羅性が
コンパイル時に保証される。

```zig
pub const Context = union(enum) {
    background,
    todo,
    canceled,
    cancel:      *CancelCtx,
    deadlineCtx: *DeadlineCtx,
    valueCtx:    *ValueCtx,
    // ...
};
```

#### Signal / SignalSource

`SignalSource` は `fired`（`std.Io.Event`）のみで動作する内部型。`fire()` で一度だけ発火し、
複数のウェイターに一斉通知する。Go の `chan struct{}` を閉じる操作に相当する。

`Signal` は `SignalSource` への参照を持つ公開ラッパー型。`fire()` を持たないため、
`Context.done()` の呼び出し元が誤ってキャンセルを発火することをコンパイル時に防ぐ。

#### キャンセルと解放の分離

`OwnedContext.cancel(io)` はシグナルのみ発火し、`deinit(io)` がメモリを解放する。これにより
キャンセル後も `ctx.err(io)` などの読み取りが安全に行える。

#### 親→子伝播の TOCTOU 防止

`registerToState()` が親の `mutex` 保持下で「登録 or 即伝播」をアトミックに行う。
親の `cancel(io)` と子の登録が競合しても missed wakeup が発生しない。

### テスト

テストはソースファイル内にインラインで記述している（`src/signal.zig`、`src/context.zig`）。
`testing.allocator` でメモリリークを自動検出する。

```sh
mise run test
```
