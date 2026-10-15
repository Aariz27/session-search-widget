#!/bin/bash
# SessionStart hook: registers this session in <cwd>/sessions.json and, if it's a
# brand-new session, tells Claude to ask what to name it.
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
sid=$(echo "$input" | jq -r '.session_id // empty')

# The session search widget ranks results by running `claude -p --model haiku`.
# Those runs are not your work, so they must not be registered as sessions or asked
# to name themselves. The model is not in the hook's stdin, but the `claude` process
# that started this hook is the parent, and its command line carries the flag.
parent_command=$(ps -o args= -p "$PPID" 2>/dev/null)
case "$parent_command" in
  *--model" "haiku*|*--model=haiku*) exit 0 ;;
  *" --print "*|*" --print"|*" -p "*|*" -p") exit 0 ;;
esac
[ -z "$cwd" ] && exit 0
[ -z "$sid" ] && exit 0

lib="$HOME/.claude/hooks/session-log-lib.sh"
source "$lib"

file="$cwd/sessions.json"
[ -f "$file" ] || echo "[]" > "$file"

lock_acquire "$file" || exit 0

exists=$(jq --arg sid "$sid" '[.[] | select(.session_id==$sid)] | length' "$file")

if [ "$exists" = "0" ]; then
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp=$(mktemp)
  jq --arg sid "$sid" --arg cwd "$cwd" --arg now "$now" \
    '. += [{"session_id":$sid,"session_name":null,"cwd":$cwd,"started_at":$now,"session_summary":[]}]' \
    "$file" > "$tmp" && mv "$tmp" "$file"
fi

lock_release "$file"

if [ "$exists" = "0" ]; then
  msg="Before doing anything else, say exactly this one line and nothing more: \"Rename this session with /rename before we begin.\" Then stop and wait. Do NOT ask me to give you a name, and do NOT run any naming command yourself — /rename sets the name in the terminal UI, and the UserPromptSubmit hook picks it up from there on its own."
  jq -n --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
fi
exit 0
