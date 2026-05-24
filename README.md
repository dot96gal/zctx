# zctx

[![API Docs](https://img.shields.io/badge/API%20Docs-GitHub%20Pages-blue)](https://dot96gal.github.io/zctx/)
[![CI](https://github.com/dot96gal/zctx/actions/workflows/ci.yml/badge.svg)](https://github.com/dot96gal/zctx/actions/workflows/ci.yml)
[![Release](https://github.com/dot96gal/zctx/actions/workflows/release.yml/badge.svg)](https://github.com/dot96gal/zctx/actions/workflows/release.yml)

Go の `context` パッケージを Zig に移植したライブラリ。

> **注意:** このリポジトリは個人的な興味・学習を目的としたホビーライブラリです。設計上の判断はすべて作者が個人で行っており、事前の告知なく破壊的変更が加わることがあります。安定した API を前提としたい場合は、任意のコミットやタグ時点でフォークし、独自に管理されることをおすすめします。

---

## 要件

- Zig 0.16.0 以上

---

## 利用者向け

### インストール

#### 1. `build.zig.zon` に zctx を追加する。

最新のタグは [GitHub Releases](https://github.com/dot96gal/zctx/releases) で確認できる。

以下のコマンドを実行すると、`build.zig.zon` の `.dependencies` に自動的に追加される。

```sh
zig fetch --save https://github.com/dot96gal/zctx/archive/refs/tags/<version>.tar.gz
```

```zig
// build.zig.zon（自動追加される内容の例）
.dependencies = .{
    .zctx = .{
        .url = "https://github.com/dot96gal/zctx/archive/refs/tags/<version>.tar.gz",
        .hash = "<hash>",
    },
},
```

#### 2. `build.zig` で zctx モジュールをインポートする。

```zig
const zctx_dep = b.dependency("zctx", .{
    .target = target,
    .optimize = optimize,
});
const zctx_mod = zctx_dep.module("zctx");
exe.root_module.addImport("zctx", zctx_mod);
```

### 使い方

#### 基本的なキャンセル

```zig
const std = @import("std");
const zctx = @import("zctx");

pub fn main(env: std.process.Init) !void {
    const io = env.io;
    const allocator = env.gpa;

    const cancel_scope = try zctx.withCancel(allocator, io, zctx.background);
    defer cancel_scope.deinit(allocator, io);

    const thread = try std.Thread.spawn(.{}, doWork, .{ cancel_scope.context(), io });
    defer thread.join();

    std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    cancel_scope.cancel(io); // スレッドに中断を伝える
    // defer の LIFO 順: thread.join() → cancel_scope.deinit(allocator, io) の順に実行される
}

fn doWork(ctx: zctx.Context, io: std.Io) void {
    while (ctx.err(io) == null) {
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    std.debug.print("canceled: {?}\n", .{ctx.err(io)});
}
```

#### タイムアウト

```zig
const timeout_scope = try zctx.withTimeout(
    allocator, io, zctx.background,
    .{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_s }, .clock = .awake },
);
defer timeout_scope.deinit(allocator, io);

// タイムアウトまで待機
timeout_scope.context().done().wait(io);
std.debug.print("err: {?}\n", .{timeout_scope.context().err(io)}); // error.DeadlineExceeded
```

#### デッドライン

```zig
const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = now_ns + 5 * std.time.ns_per_s }, .clock = .awake };
const deadline_scope = try zctx.withDeadline(allocator, io, zctx.background, dl);
defer deadline_scope.deinit(allocator, io);

// デッドラインまで待機
deadline_scope.context().done().wait(io);
std.debug.print("err: {?}\n", .{deadline_scope.context().err(io)}); // error.DeadlineExceeded
```

#### 親→子キャンセル伝播

```zig
const parent = try zctx.withCancel(allocator, io, zctx.background);
defer parent.deinit(allocator, io);

const child = try zctx.withCancel(allocator, io, parent.context());
defer child.deinit(allocator, io);

parent.cancel(io); // child にも自動で伝播する
std.debug.print("child err: {?}\n", .{child.context().err(io)}); // error.Canceled
```

#### 型安全な値の受け渡し

```zig
// キーを型ごとに定義する（ファイルスコープで宣言することを推奨）
const RequestIdKey = zctx.TypedKey(u64);
const UserNameKey  = zctx.TypedKey([]const u8);

const scope1 = try zctx.withTypedValue(allocator, zctx.background, RequestIdKey, 42);
defer scope1.deinit(allocator);

const scope2 = try zctx.withTypedValue(allocator, scope1.context(), UserNameKey, "alice");
defer scope2.deinit(allocator);

// 子コンテキストから祖先の値を取り出せる
const req_id    = scope2.context().typedValue(RequestIdKey); // ?u64 → 42
const user_name = scope2.context().typedValue(UserNameKey);  // ?[]const u8 → "alice"
```

#### 複数キャンセル条件の合成

タイムアウトと手動キャンセルを組み合わせる場合、親コンテキストを利用する。
いずれか先にキャンセルされた方が子コンテキストに伝播する。

```zig
// タイムアウト付き親コンテキスト（200ms）
const timeout_scope = try zctx.withTimeout(
    allocator, io, zctx.background,
    .{ .raw = .{ .nanoseconds = 200 * std.time.ns_per_ms }, .clock = .awake },
);
defer timeout_scope.deinit(allocator, io);

// 手動キャンセル可能な子コンテキスト → タイムアウト OR 手動キャンセルで終了
const work_scope = try zctx.withCancel(allocator, io, timeout_scope.context());
defer work_scope.deinit(allocator, io);

work_scope.context().done().wait(io);
std.debug.print("err: {?}\n", .{work_scope.context().err(io)});
```

#### エラーハンドリング

```zig
fn handleRequest(ctx: zctx.Context, io: std.Io) !void {
    if (ctx.err(io)) |e| return e; // error.Canceled / error.DeadlineExceeded を伝播

    // ... 処理 ...
}
```

#### `defer` の順序に注意

`OwnedCancelScope.deinit(allocator, io)` はコンテキストのメモリを解放する。複数スレッドがコンテキストを
参照している場合、全スレッドが参照を終えてから `deinit(allocator, io)` を呼ぶこと。
`defer` の LIFO 順を活用して `deinit` を `join` より先に宣言する。

```zig
const cancel_scope = try zctx.withCancel(allocator, io, zctx.background);
defer cancel_scope.deinit(allocator, io); // 宣言順: 1番目 → 実行順: 2番目（後）

const t = try std.Thread.spawn(.{}, worker, .{cancel_scope.context()});
defer t.join();          // 宣言順: 2番目 → 実行順: 1番目（先）
```

### API リファレンス

詳細なシグネチャ・型情報は [API ドキュメント](https://dot96gal.github.io/zctx/) を参照。

```zig
const zctx = @import("zctx");

// ルートコンテキスト（アロケータ不要）
zctx.background        // キャンセルされないルート
zctx.todo              // 未実装のプレースホルダー
zctx.canceled          // 最初からキャンセル済み

// 型安全キーの生成（comptime）
zctx.TypedKey(comptime T: type) // type — withTypedValue / typedValue で使うキー型を生成する

// 派生コンテキスト
zctx.withCancel(alloc, io, parent)                                     // error{OutOfMemory}!OwnedCancelScope
zctx.withTimeout(alloc, io, parent, timeout: std.Io.Clock.Duration)    // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedDeadlineScope
zctx.withDeadline(alloc, io, parent, deadline: std.Io.Clock.Timestamp) // (error{OutOfMemory} || std.Thread.SpawnError)!OwnedDeadlineScope
zctx.withTypedValue(alloc, parent, Key, value)                         // error{OutOfMemory}!OwnedValueScope

// OwnedCancelScope / OwnedDeadlineScope のメソッド（withCancel / withTimeout / withDeadline の返り値）
scope.context()           // Context 値
scope.cancel(io)          // シグナルのみを発火する。メモリは解放しない。複数回呼んでも安全に動作する（冪等）。
scope.deinit(alloc, io)   // メモリを解放する。未キャンセルなら先にキャンセルしてから解放する。defer で必ず呼ぶ。

// OwnedValueScope のメソッド（withTypedValue の返り値）
scope.context()           // Context 値
scope.deinit(alloc)       // メモリを解放する。cancel() メソッドは持たない。defer で必ず呼ぶ。

// Context のメソッド
ctx.done()               // Signal（値型、fire() 不可）— isFired() / wait(io) で待機できる
ctx.err(io)              // ?ContextError  — null / error.Canceled / error.DeadlineExceeded
ctx.deadline()           // ?std.Io.Clock.Timestamp  — デッドライン（なければ null）
ctx.typedValue(Key)      // ?Key.Value  — キーに対応する値を型安全に返す。値が存在しなければ null を返す。

// Signal のメソッド（fire() は呼べない）
signal.isFired()                   // bool — 発火状態をノンブロッキングで確認する。
signal.wait(io)                    // void — 発火するまでブロックする。
signal.waitTimeout(io, timeout: std.Io.Clock.Duration)  // bool — 発火=true / タイムアウト=false
```

---

## 開発者向け

### 必要なツール

| ツール | 説明 |
|-------|------|
| [mise](https://mise.jdx.dev/) | ツールバージョン管理（Zig・zls を自動インストール） |
| `zig-lint` | Zig 簡易リントスクリプト（`~/.local/bin/` にインストール済み） |
| `zig-release` | バージョン更新・タグ付けスクリプト（`~/.local/bin/` にインストール済み） |

### セットアップ

```sh
git clone https://github.com/dot96gal/zctx
cd zctx
mise install
```

### タスク一覧

| コマンド | 説明 |
|---------|------|
| `mise run fmt` | フォーマット |
| `mise run fmt-check` | フォーマットチェック |
| `mise run lint` | リント |
| `mise run build` | ビルド |
| `mise run test` | テスト |
| `mise run build-coverage` | カバレッジレポート生成（zig-out/coverage/ に出力） |
| `mise run serve-coverage` | カバレッジレポートをローカルサーバーで配信 |
| `mise run build-docs` | API ドキュメント生成（zig-out/docs/ に出力） |
| `mise run serve-docs` | API ドキュメントをローカルサーバーで配信 |
| `mise run release X.Y.Z` | バージョン更新・コミット・タグ・プッシュを一括実行 |
| `mise run example:basic` | withCancel の基本例 |
| `mise run example:timeout` | withTimeout の例 |
| `mise run example:deadline` | withDeadline の例 |
| `mise run example:propagation` | 親→子キャンセル伝播の例 |
| `mise run example:value` | TypedKey の例 |
| `mise run example:multi_cancel` | 複数キャンセル条件の合成例 |

### ファイル構成

```
build.zig          # ビルドスクリプト
build.zig.zon      # パッケージメタデータ・依存関係定義
src/
  zctx.zig         # 公開 API の再エクスポート
  signal.zig       # SignalSource / Signal の実装とテスト
  context.zig      # Context / CancelState / CancelCtx / DeadlineCtx / ValueCtx / TypedKey の実装とテスト
  scope.zig        # OwnedCancelScope / OwnedDeadlineScope / OwnedValueScope / withCancel / withDeadline / withTimeout / withTypedValue の実装とテスト
example/
  basic.zig        # withCancel の基本的な使い方
  timeout.zig      # withTimeout
  deadline.zig     # withDeadline
  propagation.zig  # 親→子キャンセル伝播
  value.zig        # TypedKey による値の受け渡し
  multi_cancel.zig # 親コンテキストで複数キャンセル条件を合成
```

### 設計方針

#### Context はタグ付き共用体

`Context` は vtable ではなくタグ付き共用体で実装している。種類が閉じた集合
（background / todo / canceled / cancel / deadline / value）であり、switch の網羅性が
コンパイル時に保証される。

```zig
pub const Context = union(enum) {
    background,
    todo,
    canceled,
    cancel_ctx:   *CancelCtx,
    deadline_ctx: *DeadlineCtx,
    value_ctx:    *ValueCtx,
    // ...
};
```

#### 借用と所有の分離

`Context` は値渡しのコピー型で、`done()`・`err()` などの読み取り操作のみを持ちリソースを所有しない。
ファクトリ関数（`withCancel` など）が返す `OwnedCancelScope`・`OwnedDeadlineScope`・`OwnedValueScope`
が確保したメモリの所有者であり、`deinit` による解放責務を担う。

子コンテキストを生成する際は `scope.context()`（`Context` 型）を親として渡すことで、所有権を移さず
参照だけを共有できる。

```zig
const parent = try withCancel(allocator, io, background);
defer parent.deinit(allocator, io);                     // OwnedCancelScope が解放責務を持つ

const child = try withCancel(allocator, io, parent.context()); // Context（借用）を渡す
defer child.deinit(allocator, io);
```

Go の `context.Context` はインターフェース経由の参照渡しであるため所有と借用の区別が暗黙だが、
Zig ではこの違いを型で明示している。

#### Signal / SignalSource

`SignalSource` は `fired`（`std.Io.Event`）のみで動作する内部型。`fire()` で一度だけ発火し、
複数のウェイターに一斉通知する。Go の `chan struct{}` を閉じる操作に相当する。

`Signal` は `Context.done()` が返す公開ラッパー型。`fire()` を持たないため、
`Context.done()` の呼び出し元が誤ってキャンセルを発火することをコンパイル時に防ぐ。
`background`・`todo` は永遠に発火しないバリアント、`canceled` は発火済みバリアントとして実装され、
`cancel_ctx`・`deadline_ctx` は内部の `SignalSource` への参照を保持する。

#### キャンセルと解放の分離

`OwnedCancelScope.cancel(io) / OwnedDeadlineScope.cancel(io)` はシグナルのみ発火し、`deinit(alloc, io)` がメモリを解放する。これにより
キャンセル後も `ctx.err(io)` などの読み取りが安全に行える。

#### 親→子伝播の TOCTOU 防止

`registerToState()` が親の `mutex` 保持下で「登録 or 即伝播」をアトミックに行う。
親の `cancel(io)` と子の登録が競合しても missed wakeup が発生しない。

### テスト

テストはソースファイル内にインラインで記述している（`src/signal.zig`、`src/context.zig`、`src/scope.zig`）。
`testing.allocator` でメモリリークを自動検出する。

```sh
mise run test
```

---

## ライセンス

[MIT](LICENSE)
