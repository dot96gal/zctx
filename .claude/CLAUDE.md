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

~/.claude/rules/zig.md を参照すること。


