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
sed -i '' "s/\\.version = \".*\"/\\.version = \"$VERSION\"/" build.zig.zon
git add build.zig.zon
git commit -m "chore: bump version to v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"
