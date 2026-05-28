# zctx

## プロジェクトの概要

- Go の `context` パッケージを Zig に移植したライブラリを開発する

## 計画ファイル

- 計画ファイルは`.claude/plans/`ディレクトリに`YYYYMMDD_`の接頭辞を付与したファイル名で保存する

## 開発環境

- mise（zig のバージョンは `mise.toml` を参照）
- mise タスクでコマンドを実行する。利用可能なタスクは `mise.toml` を参照すること。

## 作業手順

- `.zig` ファイルを扱う前に必ず LSP ツール（`documentSymbol` / `hover` / `findReferences` / `goToDefinition`）を使うこと。Read/Grep は LSP が応答しない場合のフォールバック専用。

## 依存関係

- 外部ライブラリは使用しない。Zig 標準ライブラリ（`std`）のみを使用する

## コーディング規約

- [Zig スタイルガイド](https://ziglang.org/documentation/master/#Style-Guide) に従う。

### zig-standard のガイドラインに対するプロジェクト固有の例外

- **`Context` 型名の許容**：zig-standard では `Context` のような「あらゆる型に当てはまる汎用語」を型名に使わないよう定めているが、本プロジェクトでは例外として許容する。zctx は Go の `context` パッケージの移植ライブラリであり、`Context` という型名は Go 側の `context.Context` との対応を明示するために意図的に採用している。コードレビューや リファクタリングで `Context` の命名を指摘・変更提案しない。
