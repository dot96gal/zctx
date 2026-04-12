# zctx

## プロジェクトの概要

- Zig向けのGoのContext（キャンセル）を開発する

## 計画ファイル

- 計画ファイルは`.claude/plans/`ディレクトリに`YYYYMMDD_`の接頭辞を付与したファイル名で保存する

## ツール

- mise（zig のバージョンは `mise.toml` を参照）

## 開発

mise タスクでコマンドを実行する。

- `mise run build`: ビルド（`zig build --summary all`）
- `mise run test`: テスト（`zig build test --summary all`）
- `mise run run`: 実行（`zig build run --summary all`）

## 依存関係

- 外部ライブラリは使用しない。Zig 標準ライブラリ（`std`）のみを使用する

## コーディング規約

Zig 公式のスタイルガイドに従う。

- 命名：型は `PascalCase`、変数・関数は `camelCase`、定数は `SCREAMING_SNAKE_CASE`
- エラーハンドリング：エラーは握り潰さず `try` / `catch` で適切に伝播またはハンドリングする
- メモリ管理：アロケータは呼び出し元から渡す。`defer` で確実に解放する
- テスト：各関数に対応するテストを同一ファイル内に記述する（`test "..." { ... }`）。同じ関数に対して入力/期待値のペアが複数ある場合はテーブルドリブンを検討する
- 出力：デバッグ用途は `std.debug.print`、実際の出力は `stdout` を使用する


