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
- `mise run build-docs`: API ドキュメント生成（`zig build docs --summary all`、出力先: `zig-out/docs/`）
- `mise run serve-docs`: ドキュメントをローカルサーバーで開く（CORS制約のためファイル直接開示不可）

## 依存関係

- 外部ライブラリは使用しない。Zig 標準ライブラリ（`std`）のみを使用する

## コーディング規約

~/.claude/rules/zig.md を参照すること。


