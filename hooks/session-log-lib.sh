#!/bin/bash
# Shared helpers for the session-log hooks: a mkdir-based mutex (macOS has no flock binary)
# plus a "set-name" CLI action the SessionStart hook tells Claude to call directly.

lock_acquire() {
  local dir="$1.lock"
  local tries=0
  while ! mkdir "$dir" 2>/dev/null; do
    if [ -d "$dir" ]; then
      local mtime age
      mtime=$(stat -f %m "$dir" 2>/dev/null || echo 0)
      age=$(( $(date +%s) - mtime ))
      if [ "$age" -gt 30 ]; then
        rm -rf "$dir" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      echo "session-log: lock timeout on $dir" >&2
      return 1
    fi
    sleep 0.1
  done
}

lock_release() {
  local dir="$1.lock"
  rmdir "$dir" 2>/dev/null || true
}

if [ "${1:-}" = "set-name" ]; then
  cwd="$2"; sid="$3"; name="$4"
  file="$cwd/sessions.json"
  [ -f "$file" ] || echo "[]" > "$file"
  lock_acquire "$file" || exit 1
  tmp=$(mktemp)
  jq --arg sid "$sid" --arg name "$name" \
    '(.[] | select(.session_id==$sid) | .session_name) = $name' \
    "$file" > "$tmp" && mv "$tmp" "$file"
  lock_release "$file"
fi
