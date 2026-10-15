#!/bin/bash

# SSSF-GUARD: skip non-interactive (claude -p / --print) runs. Remove to re-enable.
case "$(ps -o args= -p "$PPID" 2>/dev/null)" in
  *" --print "*|*" --print"|*" -p "*|*" -p") exit 0 ;;
esac
# UserPromptSubmit hook: counts messages per session in <cwd>/.sessions-state.json.
# Every 10th message, kicks off a background summarizer. Never blocks, never adds context.
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
sid=$(echo "$input" | jq -r '.session_id // empty')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')

# The session search widget ranks results by running `claude -p --model haiku`.
# Those runs are not your work, so they must not be registered as sessions or asked
# to name themselves. The model is not in the hook's stdin, but the `claude` process
# that started this hook is the parent, and its command line carries the flag.
parent_command=$(ps -o args= -p "$PPID" 2>/dev/null)
case "$parent_command" in
  *--model" "haiku*|*--model=haiku*) exit 0 ;;
esac
[ -z "$cwd" ] && exit 0
[ -z "$sid" ] && exit 0
[ -z "$transcript" ] && exit 0

source "$HOME/.claude/hooks/session-log-lib.sh"

# The name you set with /rename lands in the transcript as a custom-title record, written
# the moment you run the command. SessionStart cannot read it because it fires before you have
# renamed anything, so the name is copied into sessions.json here instead — on every message,
# but only written when it has actually changed.
sync_name() {
  local name current file
  name=$(jq -r 'select(.type=="custom-title") | .customTitle' "$transcript" 2>/dev/null | tail -1)
  [ -n "$name" ] && [ "$name" != "null" ] || return 0

  file="$cwd/sessions.json"
  [ -f "$file" ] || return 0
  current=$(jq -r --arg sid "$sid" '.[] | select(.session_id==$sid) | .session_name // ""' "$file" 2>/dev/null)
  [ "$current" = "$name" ] && return 0

  "$HOME/.claude/hooks/session-log-lib.sh" set-name "$cwd" "$sid" "$name" 2>/dev/null || true
}
sync_name

state_file="$cwd/.sessions-state.json"
[ -f "$state_file" ] || echo "{}" > "$state_file"

lock_acquire "$state_file" || exit 0
count=$(jq --arg sid "$sid" '.[$sid] // 0' "$state_file")
count=$((count + 1))
tmp=$(mktemp)
jq --arg sid "$sid" --argjson c "$count" '.[$sid] = $c' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
lock_release "$state_file"

if [ $((count % 10)) -eq 0 ]; then
  nohup "$HOME/.claude/hooks/session-log-summarize.sh" "$cwd" "$sid" "$transcript" >/dev/null 2>&1 &
  disown
fi
exit 0
