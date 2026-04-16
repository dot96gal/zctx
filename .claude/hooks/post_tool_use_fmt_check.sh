#!/bin/bash
file_path=$(jq -r '.tool_input.file_path // .tool_response.filePath // ""')

if [ -n "$file_path" ] && echo "$file_path" | grep -q '\.zig$'; then
  out=$(mise run fmt-check 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    jq -n --arg ctx "フォーマットチェック失敗: $out" \
      '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
  fi
fi
