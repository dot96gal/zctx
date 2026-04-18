# リリース自動化計画

## 目的

`mise` タスクと GitHub Actions を組み合わせて、Zig ライブラリ（zctx）のバージョンリリースを自動化する。

## 作業手順

### 1. `mise` タスクの追加（`mise.toml`）

`mise run release 0.1.0` 一発で `build.zig.zon` のバージョン更新からタグpushまで完了するタスクを追加する。

```toml
[tasks.release]
description = "bump version, commit, tag, and push"
run = """
#!/usr/bin/env bash
set -euo pipefail
VERSION=${1:?usage: mise run release <version>}

echo "v$VERSION のリリースを実行します:"
echo "  1. build.zig.zon の .version を \"$VERSION\" に更新"
echo "  2. git commit \"chore: bump version to v$VERSION\""
echo "  3. git tag v$VERSION"
echo "  4. git push origin main v$VERSION"
echo ""
read -r -p "続行しますか? [y/N]: " confirm
case "$confirm" in
  [yY]) ;;
  *) echo "キャンセルしました。"; exit 0 ;;
esac

# 注意: sed -i '' は macOS (BSD sed) 専用。Linux (GNU sed) では -i のみで動作する。
sed -i '' "s/\.version = \".*\"/\.version = \"$VERSION\"/" build.zig.zon
git add build.zig.zon
git commit -m "chore: bump version to v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"
"""
```

**注意点**:
- `sed -i ''` は macOS (BSD sed) 専用。Linux (GNU sed) では `-i` のみで動作する。
- `set -euo pipefail` でエラー時に即座に停止

### 2. GitHub Actions ワークフローの追加

`.github/workflows/release.yml` を作成する。

```yaml
name: Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: softprops/action-gh-release@v3
        with:
          generate_release_notes: true
```

- `permissions: contents: write` が必要（Releaseの作成に必要）
- `generate_release_notes: true` でコミット履歴からリリースノートを自動生成

### 3. `.claude/settings.json` に deny 設定を追加

Claude が `mise run release` を実行できないよう deny ルールを追加する。

```json
{
  "permissions": {
    "deny": [
      "Bash(mise run release*)"
    ]
  }
}
```

## 実行フロー（完成後）

```
mise run release 0.1.0
  └─ build.zig.zon の .version を "0.1.0" に更新
  └─ git commit "chore: bump version to v0.1.0"
  └─ git tag v0.1.0
  └─ git push origin main v0.1.0
       └─ GitHub Actions が起動
            └─ GitHub Release v0.1.0 を自動作成（リリースノート付き）
```

## チェックリスト

- [x] `mise.toml` に `release` タスクを追加
- [x] `.github/workflows/release.yml` を作成
- [x] `.claude/settings.json` に `mise run release` の deny 設定を追加
- [x] 動作確認（`mise run release 0.1.0` を実行）
