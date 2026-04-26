---
description: Zig のコーディング規約とバージョン別注意事項
globs:
  - "**/*.zig"
---

# Zig コーディング規約

Zig 公式のスタイルガイドに従う。

## 命名

- 型は `PascalCase`、変数・関数は `camelCase`、定数は `SCREAMING_SNAKE_CASE`

## エラーハンドリング

- エラーは握り潰さず `try` / `catch` で適切に伝播またはハンドリングする
- 公開 API のエラー集合は明示的に定義する（`anyerror` は動的なケースのみ）
- エラー名は意味のある名前にする（`error.InvalidInput` など）

## Optional (`?T`)

- 安全な unwrap には `if (opt) |val| { ... }` を使う
- デフォルト値には `orelse` を使う：`opt orelse default`
- エラーとして伝播するには `orelse return error.Foo` を使う
- `opt.?`（強制 unwrap）は論理的に null にならない場合のみ使う

## メモリ管理

- アロケータは呼び出し元から渡す。`defer` で確実に解放する
- テストでは `std.testing.allocator` を使う（リークを自動検出できる）

## テスト

- 各関数に対応するテストを同一ファイル内に記述する（`test "..." { ... }`）
- 同じ関数に対して入力/期待値のペアが複数ある場合はテーブルドリブンを検討する
- アサーションには `std.testing.expect*` 系を使う：
  - `std.testing.expect(condition)` — 真偽値
  - `std.testing.expectEqual(expected, actual)` — 値の等価性
  - `std.testing.expectError(expected_error, expr)` — エラーの検証
  - `std.testing.expectEqualStrings(expected, actual)` — 文字列の等価性

## 出力

- デバッグ用途は `std.debug.print`、実際の出力は `stdout` を使用する

## LSP（zls）の活用

`.zig` ファイルを扱う際は Read/Grep より先に LSP ツールを使う。

| 操作 | 用途 |
|------|------|
| `documentSymbol` | ファイルの全シンボル一覧（公開 API の網羅確認、命名チェック） |
| `hover` | 型情報・エラー集合・deprecated 警告の取得 |
| `findReferences` | 非推奨 API や特定シンボルの使用箇所の正確な列挙 |
| `goToDefinition` | 型・関数の定義元の確認 |

LSP が応答しない場合のみ Read + Grep にフォールバックする。

## バージョン別注意事項

基本的には最新の安定版を使用する。
コードを書く際はプロジェクトのバージョン管理ファイルで現在のバージョンを確認し、該当バージョン以前の NG パターンを使わないこと。

### v0.14 → v0.15 の破壊的変更

**std.io の全面刷新（"Writergate"）**：`std.io.Reader` / `std.io.Writer` が廃止され、`std.Io.Reader` / `std.Io.Writer` に置き換えられた。
非ジェネリックになり、バッファを呼び出し側が持つ設計に変更。flush を忘れずに呼ぶこと。

```zig
// NG: 0.14 以前
const stdout = std.io.getStdOut().writer();
try stdout.print("hello\n", .{});

// OK: 0.15（std.fs.File.stdout() は 0.16 で廃止されるため一時的な書き方）
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
try stdout.print("hello\n", .{});
try stdout.flush();
```

**std.ArrayList のアロケータ渡し変更**：`std.ArrayList` が "managed" ラッパーとなり、各メソッド呼び出しにアロケータを渡す必要がある。
アロケータを構造体に保持しない "unmanaged" スタイルが推奨される。

```zig
// NG: 0.14 以前
var list = std.ArrayList(u8).init(allocator);

// OK: 0.15 以降
var list = std.ArrayListUnmanaged(u8){};
try list.append(allocator, item);
defer list.deinit(allocator);
```

**std.fifo.LinearFifo の削除**：代替として `std.ArrayListUnmanaged` や `std.RingBuffer` を使用する。

**comptime での整数→浮動小数点変換の厳格化**：精度上正確に表現できない場合はコンパイルエラーになる。
明示的なキャスト `@floatFromInt` を使用する。

### v0.15 → v0.16 の破壊的変更

**`std.Io` インスタンスが必須化**：すべての I/O・ファイルシステム・ネットワーク操作に `Io` インスタンスの受け渡しが必要になった。
関数設計時は `io: std.Io` を引数として受け取るようにする。

`main` のシグネチャは以下の3形式が有効（`std/start.zig` の dispatch による）：

```zig
// 1. 引数なし（テスト・シンプル用途）
pub fn main() !void { ... }

// 2. 軽量初期化（args・environ のみ）
pub fn main(env: std.process.Init.Minimal) !void { ... }

// 3. フル初期化（GPA・arena・io・args を含む、通常はこちらを使う）
pub fn main(env: std.process.Init) !void {
    const allocator = env.gpa;
    const io = env.io;
    const raw_args = try env.minimal.args.toSlice(env.arena.allocator());
    ...
}
```

```zig
// NG: 0.15 以前
file.close();
const cwd = std.fs.cwd();

// OK: 0.16 以降
file.close(io);
const cwd = std.Io.Dir.cwd();
```

**ファイルシステム API の移動・改名**：`std.fs` 配下の多くが `std.Io` 配下に移動した。

| 旧 (0.15 以前) | 新 (0.16 以降) |
|---|---|
| `fs.cwd()` | `std.Io.Dir.cwd()` |
| `fs.Dir.makeDir` | `std.Io.Dir.createDir` |
| `fs.File.setEndPos` | `std.Io.File.setLength` |
| `fs.File.getEndPos` | `std.Io.File.length` |
| `fs.File.read/write` | `std.Io.File.readStreaming/writeStreaming` |
| `fs.File.pread/pwrite` | `std.Io.File.readPositional/writePositional` |

**`@Type` 廃止、個別ビルトインに分割**：

```zig
// NG: 0.15 以前
@Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } })

// OK: 0.16 以降
@Int(.unsigned, 10)
```

他にも `@Tuple`, `@Pointer`, `@Fn`, `@Struct`, `@Union`, `@Enum`, `@EnumLiteral` が追加された。

**乱数 API の変更**：

```zig
// NG: 0.15 以前
std.crypto.random.bytes(&buffer);

// OK: 0.16 以降
io.random(&buffer);         // 通常用途
io.randomSecure(&buffer);   // セキュリティ用途
```

**`std.Thread.Pool` / `std.Thread.Mutex.Recursive` / `std.Thread.ResetEvent` 削除**：
- `std.Thread.Pool` は直接代替なし（タスク並列化の設計を見直す）
- `std.Thread.WaitGroup` → `std.Io.Group`
- `std.Thread.ResetEvent` → `std.Io.Event`

**`@cImport` 廃止**：ビルドシステム経由の `addTranslateC()` に移行する。

**`@intFromFloat` 廃止**：代わりに `@floor`, `@ceil`, `@round`, `@trunc` が直接整数を返すようになった。

**エラー名の変更**：

| 旧 | 新 |
|---|---|
| `error.EnvironmentVariableNotFound` | `error.EnvironmentVariableMissing` |
| `error.RenameAcrossMountPoints` / `error.NotSameFileSystem` | `error.CrossDevice` |
| `error.SharingViolation` | `error.FileBusy` |

**`std.time.Instant` / `std.time.Timer` 廃止**：代替として `std.Io.Timestamp` を使用する。

**`std.heap.ThreadSafeAllocator` 削除**：`std.heap.ArenaAllocator` がロックフリーかつスレッドセーフになったため。

**`std.SegmentedList` 削除**：代替として `std.ArrayListUnmanaged` を使用する。

