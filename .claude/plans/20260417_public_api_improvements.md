# 公開 API の改善

## 背景

公開 API を Zig 標準ライブラリのスタイルおよびユーザー視点での一貫性に合わせて改善する。

---

## 改善 1: `withDeadline` の引数を `std.Io.Clock.Timestamp` に変更

### 問題

`withDeadline` が絶対時刻を `i96`（内部的な生値）で受け取っており、
ユーザーが `std.Io.Clock.Timestamp` から `.raw.nanoseconds` を取り出す手間が発生している。

### 変更箇所

**`DeadlineCtx.deadlineNs: i96`** → **`deadline: std.Io.Clock.Timestamp`**

**`Context.deadline()` 戻り値型**
```zig
// Before
pub fn deadline(ctx: Context) ?i96

// After
pub fn deadline(ctx: Context) ?std.Io.Clock.Timestamp
```

**`withDeadline` 引数**
```zig
// Before
pub fn withDeadline(io, parent, deadlineNs: i96, allocator)

// After
pub fn withDeadline(io, parent, deadline: std.Io.Clock.Timestamp, allocator)
```

**`timerWorker`**: `ctx.deadlineNs` → `ctx.deadline.raw.nanoseconds`

**`withTimeout`**: `std.Io.Clock.Timestamp` を構築して `withDeadline` に渡す
```zig
// Before
const dl = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + @as(i96, timeoutNs);
return withDeadline(io, parent, dl, allocator);

// After（構築方法はコンパイル時に確認する）
const now_ns = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
const dl = std.Io.Clock.Timestamp{ .raw = .{ .nanoseconds = now_ns + @as(i96, timeoutNs) } };
return withDeadline(io, parent, dl, allocator);
```

**テスト**: `i96` を直接使っている4箇所を `std.Io.Clock.Timestamp` に置き換える
- `withDeadline: 過去のdeadlineは即座にDeadlineExceeded（fast-path）`（L463, L476）
- `Context.deadline: withDeadlineで設定した値を返す`（L517-L521）
- `Context.deadline: withCancelはnullを返す`（L528）

---

## 改善 2: `cancelled` を `canceled` に変更（米国英語統一）

### 問題

Zig は米国英語を採用している（`error.Canceled`, `error.OutOfMemory` など）。
`pub const cancelled` だけ英国綴りになっており不一致。

### 変更箇所

- `pub const cancelled: Context = .cancelled` → `pub const canceled: Context = .canceled`
- `Context` union の variant 名: `.cancelled` → `.canceled`
- 全参照箇所（switch 文、テスト等）を一括置換

---

## 改善 3: `withTypedValue` の引数順序を統一

### 問題

他の `with*` 関数は `(io, parent, ..., allocator)` の順だが、
`withTypedValue` だけ `allocator` が `parent` より前になっている。

```zig
// 他の with* 関数
withCancel(io, parent, alloc)
withDeadline(io, parent, deadline, alloc)
withTimeout(io, parent, timeoutNs, alloc)

// withTypedValue（不一致）
withTypedValue(Key, alloc, parent, value)  // alloc が parent より前
```

### 変更箇所

key と value の結びつきが強いため `parent, Key, val, allocator` の順とする。
`std.Io` 関連関数（`futexWait` 等）が `io` の直後に `comptime` を置く慣習とも整合する。

```zig
// Before
pub fn withTypedValue(comptime Key, allocator, parent, val)

// After
pub fn withTypedValue(parent, comptime Key, val, allocator)
```

テストおよび example の呼び出し箇所もすべて更新する。

---

## ドキュメント・サンプルの更新

### context.zig コメント

- L59: `/// デッドライン（std.Io.Clock.Timestamp 基準ナノ秒）を返す。` → `/// デッドラインを返す。なければ null。`
- L282: `/// デッドライン付きコンテキストを作成する。deadlineNs は std.Io.Clock.Timestamp 基準（i96）。` → `/// デッドライン付きコンテキストを作成する。`

### README.md

- API 一覧（L37）: `withDeadline` の引数型、`ctx.deadline()` の戻り値型を更新
- API 一覧（L32）: `cancelled` → `canceled`
- アーキテクチャセクション（L227 説明文・L234 コードブロック）: `cancelled` → `canceled`
- API 一覧（L37）: `withTypedValue` の引数順序を更新
- 使い方セクション（L118-119）: `withTypedValue` の引数順序を更新
- `withDeadline` の使い方セクションを追加
- 開発者向けタスク一覧に `mise run example:deadline` を追加

### example/deadline.zig（新規作成）

`withTimeout` の例（`timeout.zig`）に倣い、`std.Io.Clock.Timestamp` を構築して
`withDeadline` に渡すサンプルを作成する。

> **対象外**: `todo` と `canceled` は example を作成しない。
> `todo` は `background` との使い分けがユースケース次第であり、`canceled` はテスト用途が主なため。

### build.zig

`example_names` に `"deadline"` を追加。

### mise.toml

`example:deadline` タスクを追加。

---

## 作業手順

1. 改善 2: `cancelled` → `canceled` の一括置換（影響範囲が広いため先に実施）
2. 改善 1: `DeadlineCtx` フィールド名変更
3. 改善 1: `Context.deadline()` 戻り値型変更
4. 改善 1: `withDeadline` 引数・内部処理変更
5. 改善 1: `timerWorker` 更新
6. 改善 1: `withTimeout` 更新
7. 改善 1: 関連テスト更新
8. 改善 3: `withTypedValue` 引数順序変更・全呼び出し箇所更新
9. context.zig コメント更新
10. README.md 更新
11. `example/deadline.zig` 新規作成
12. `build.zig` に `"deadline"` 追加
13. `mise.toml` に `example:deadline` タスク追加
14. `mise run test` でテスト通過確認
15. `mise run example:deadline` で動作確認
