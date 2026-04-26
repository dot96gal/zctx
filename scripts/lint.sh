#!/usr/bin/env bash
set -uo pipefail
found=0
while IFS= read -r -d '' f; do
  snake_var=$(grep -nE '^\s*(pub\s+)?(var|const)\s+[a-z][a-zA-Z0-9]*_[a-z]' "$f" 2>/dev/null || true)
  snake_fn=$(grep -nE '^\s*(pub\s+)?fn\s+[a-z][a-zA-Z0-9]*_[a-z]' "$f" 2>/dev/null || true)
  bad_type=$(grep -nE '^\s*(pub\s+)?const\s+[a-z][a-zA-Z0-9]*\s*=\s*(struct|enum|union|opaque)\b' "$f" 2>/dev/null || true)
  bad_screaming=$(grep -nE '^(pub\s+)?const\s+[a-z][a-zA-Z0-9]*\s*=\s*("[^"]*"|[0-9]+)' "$f" 2>/dev/null || true)
  if [ -n "$snake_var" ] || [ -n "$snake_fn" ] || [ -n "$bad_type" ] || [ -n "$bad_screaming" ]; then
    echo "$f"
    [ -n "$snake_var"     ] && printf "  [camelCase 違反] 変数/const:\n%s\n"               "$snake_var"
    [ -n "$snake_fn"      ] && printf "  [camelCase 違反] 関数名:\n%s\n"                   "$snake_fn"
    [ -n "$bad_type"      ] && printf "  [PascalCase 違反] 型定義:\n%s\n"                  "$bad_type"
    [ -n "$bad_screaming" ] && printf "  [SCREAMING_SNAKE_CASE 違反] モジュールレベル定数:\n%s\n" "$bad_screaming"
    echo ""
    found=1
  fi
done < <(find src/ example/ -name "*.zig" -print0 2>/dev/null)
exit $found
