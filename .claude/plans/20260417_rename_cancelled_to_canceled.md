# cancelledContext → cancelled / CancelError → ContextError リネーム計画

## 目的

2つの命名を修正し、一貫性を高める。

1. **`cancelledContext` → `cancelled`**：`background` / `todo` と命名パターンを統一（サフィックスなし）
2. **`CancelError` → `ContextError`**：`DeadlineExceeded` もカバーする型名として役割を明確化

### 命名パターン統一後

| 定数 | enum variant |
|---|---|
| `background` | `.background` |
| `todo` | `.todo` |
| `cancelled` | `.cancelled` |

## 変更ファイル

### src/context.zig

#### cancelledContext → cancelled（定数・テスト）

enum variant `.cancelled` は変更不要。定数名とテスト内参照のみ変更。

| 行 | 変更前 | 変更後 |
|---|---|---|
| 120 | `pub const cancelledContext: Context = .cancelled;` | `pub const cancelled: Context = .cancelled;` |
| 368 | `test "cancelledContext: 即座にdone"` | `test "cancelled: 即座にdone"` |
| 370 | `cancelledContext.err(io).?` | `cancelled.err(io).?` |
| 371 | `cancelledContext.done().isFired()` | `cancelled.done().isFired()` |
| 436 | `test "withCancel: cancelledContextを親にすると即座にdone"` | `test "withCancel: cancelledを親にすると即座にdone"` |
| 438 | `cancelledContext,` | `cancelled,` |

#### CancelError → ContextError（型定義・参照・テスト全箇所を一括置換）

対象箇所：`src/context.zig` 内の `CancelError` をすべて `ContextError` に置換。

主な変更箇所：
- 行 5: ドキュメントコメント `/// キャンセル理由。` → `/// コンテキストの終了理由。`
- 行 6: 型定義 `pub const CancelError` → `pub const ContextError`
- 行 40: ドキュメントコメント `/// キャンセル理由を返す。` → `/// コンテキストの終了理由を返す。`
- 行 41: `err()` 戻り値型
- 行 44: `.cancelled => ContextError.Canceled,`
- 行 140: `cancelErr: ?ContextError,`
- 行 149, 168: `reason: ContextError` 引数
- 行 360, 365, 370, 378, 386, 411, 422, 433, 440, 449, 458, 466, 479: テスト内の `CancelError.*` 参照

### src/root.zig

| 行 | 変更前 | 変更後 |
|---|---|---|
| 10 | `/// キャンセル理由を表すエラー集合。` | `/// コンテキストの終了理由を表すエラー集合。` |
| 11 | `pub const CancelError = @import("context.zig").CancelError;` | `pub const ContextError = @import("context.zig").ContextError;` |
| 22 | `pub const cancelledContext = @import("context.zig").cancelledContext;` | `pub const cancelled = @import("context.zig").cancelled;` |

### README.md

| 行 | 変更前 | 変更後 |
|---|---|---|
| 32 | `zctx.cancelledContext  // 最初からキャンセル済み` | `zctx.cancelled  // 最初からキャンセル済み` |
| 47 | `ctx.err(io)              // ?CancelError  — ...` | `ctx.err(io)              // ?ContextError  — ...` |
| 234 | アーキテクチャブロック内 `cancelled,`（変更なし） | — |

## 作業手順

1. `src/context.zig` の定数 `cancelledContext` を `cancelled` にリネーム（宣言・テスト内参照）
2. `src/context.zig` の `CancelError` を `ContextError` に一括置換（ドキュメントコメント行 5 も含む）
3. `src/root.zig` の再エクスポートとドキュメントコメントを更新
4. `README.md` の API 一覧を更新
5. `mise run test` でテスト通過を確認
6. `mise run build` でビルド通過を確認

## 備考

- 破壊的変更（public API のリネーム）だが、現時点で外部利用者はいないため影響範囲はリポジトリ内のみ
- enum variant `.cancelled` は変更不要のため、switch 文などの内部実装に手を入れる箇所は最小限
