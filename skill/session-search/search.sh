#!/bin/bash
# One command that answers "which sessions match this pattern".
#
# Doing this as a single command matters for cost: an agent that runs find, then grep, then
# jq for each title spends five turns, and every turn re-sends the whole conversation. This
# returns everything needed to answer in one turn.
#
# Usage:  search.sh <extended-regex> [max-results]
# Output: one line per session, tab separated:  <session-id>  <title>  <folder>  <hits>
#         sorted by hit count, most hits first.

pattern="$1"
limit="${2:-12}"

if [ -z "$pattern" ]; then
  echo "usage: search.sh <extended-regex> [max-results]" >&2
  exit 2
fi

projects="$HOME/.claude/projects"
[ -d "$projects" ] || { echo "no sessions found at $projects" >&2; exit 1; }

# Only <uuid>.jsonl files are real sessions. agent-*.jsonl are subagent runs and
# skill-injections.jsonl is plugin bookkeeping; neither can be resumed.
find "$projects" -type f -name '*.jsonl' \
  | grep -E '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' \
  | while IFS= read -r file; do
      hits=$(grep -ciE -- "$pattern" "$file" 2>/dev/null)
      [ "${hits:-0}" -gt 0 ] || continue
      id=$(basename "$file" .jsonl)
      title=$(jq -r 'select(.type=="ai-title") | .aiTitle' "$file" 2>/dev/null | tail -1)
      cwd=$(jq -r 'select(.cwd != null) | .cwd' "$file" 2>/dev/null | head -1)
      # No auto-title: fall back to the opening words the human typed.
      if [ -z "$title" ]; then
        title=$(jq -r 'select(.type=="user" and (.isMeta|not) and (.isSidechain|not))
                       | .message.content
                       | if type=="string" then . else (map(select(.type=="text").text)|join(" ")) end' \
                     "$file" 2>/dev/null \
                | sed 's/^[[:space:]]*//' \
                | grep -v '^[[:space:]]*$' | grep -v '^<' | head -1 | cut -c1-60)
      fi
      printf '%s\t%s\t%s\t%s\n' "$hits" "$id" "${title:-untitled}" "${cwd:-unknown}"
    done \
  | sort -rn | head -n "$limit" \
  | awk -F'\t' '{printf "%s\t%s\t%s\t%s hits\n", $2, $3, $4, $1}'
