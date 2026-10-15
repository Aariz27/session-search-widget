#!/bin/bash
# Background worker: slices the last 15 user/assistant transcript lines (plus every
# tool call/result between them), asks haiku for 3 bullets, appends to sessions.json.
cwd="$1"
sid="$2"
transcript="$3"
[ -f "$transcript" ] || exit 0

source "$HOME/.claude/hooks/session-log-lib.sh"

idx=()
while IFS= read -r ln; do
  idx+=("$ln")
done < <(jq -r 'select(.type=="user" or .type=="assistant") | input_line_number' "$transcript" 2>/dev/null)
count=${#idx[@]}
[ "$count" -eq 0 ] && exit 0

if [ "$count" -le 15 ]; then
  start_line=1
else
  start_line=${idx[$((count - 15))]}
fi

slice=$(tail -n "+$start_line" "$transcript")
[ -z "$slice" ] && exit 0

summary=$(printf '%s' "$slice" | claude -p "Summarize this excerpt of a Claude Code session transcript (JSONL, one event per line: user messages, assistant replies, tool calls, tool results). Output exactly 3 short bullet points describing what was worked on and decided. Plain text only, one bullet per line, each starting with '- ', no preamble, no other commentary." --model haiku 2>/dev/null)
[ -z "$summary" ] && exit 0

bullets_json=$(printf '%s\n' "$summary" | grep '^- ' | sed 's/^- //' | jq -R -s 'split("\n") | map(select(length>0))')
[ "$bullets_json" = "[]" ] && exit 0

file="$cwd/sessions.json"
[ -f "$file" ] || echo "[]" > "$file"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

lock_acquire "$file" || exit 0
tmp=$(mktemp)
jq --arg sid "$sid" --arg ts "$ts" --argjson bullets "$bullets_json" \
  '(.[] | select(.session_id==$sid) | .session_summary) += [{"at":$ts,"bullets":$bullets}]' \
  "$file" > "$tmp" && mv "$tmp" "$file"
lock_release "$file"
