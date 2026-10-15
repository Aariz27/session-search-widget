#!/bin/bash
# Installs Session Search Widget: builds the app, copies the hooks and the session-search
# skill into ~/.claude, registers the hooks in ~/.claude/settings.json, and starts the app
# at login with a LaunchAgent. Safe to run again after a `git pull`.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
claude_dir="$HOME/.claude"
label="local.session-search-widget"
plist="$HOME/Library/LaunchAgents/$label.plist"

fail() { echo "error: $*" >&2; exit 1; }

# 1. Requirements
[ "$(uname)" = "Darwin" ] || fail "this only runs on macOS"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "macOS 14 or newer is required (you have $(sw_vers -productVersion))"
command -v swift >/dev/null || fail "swift not found. Install it with: xcode-select --install"
command -v jq >/dev/null || fail "jq not found. Install it with: brew install jq"
command -v claude >/dev/null || fail "claude not found. Install Claude Code: https://docs.claude.com/en/docs/claude-code"

# 2. Build the app
echo "Building the app (the first build takes a minute)..."
swift build -c release --package-path "$repo"
binary="$repo/.build/release/SessionSearchWidget"
[ -x "$binary" ] || fail "build finished but $binary is missing"

# 3. Copy the hooks and the skill
mkdir -p "$claude_dir/hooks" "$claude_dir/skills/session-search"
cp "$repo"/hooks/session-log-*.sh "$claude_dir/hooks/"
chmod +x "$claude_dir"/hooks/session-log-*.sh
cp "$repo"/skill/session-search/* "$claude_dir/skills/session-search/"
chmod +x "$claude_dir/skills/session-search/search.sh"
echo "Copied hooks to $claude_dir/hooks and the skill to $claude_dir/skills/session-search"

# 4. Register the hooks in settings.json, keeping everything already there
settings="$claude_dir/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
jq empty "$settings" 2>/dev/null || fail "$settings is not valid JSON, fix it and run again"
cp "$settings" "$settings.bak-session-search"
tmp=$(mktemp)
jq --arg tick '$HOME/.claude/hooks/session-log-tick.sh' \
   --arg start '$HOME/.claude/hooks/session-log-start.sh' '
  def addhook(event; cmd):
    if ([.hooks[event][]?.hooks[]?.command] | index(cmd)) then .
    else .hooks[event] = ((.hooks[event] // []) + [{"hooks": [{"type": "command", "command": cmd}]}])
    end;
  .hooks = (.hooks // {})
  | addhook("UserPromptSubmit"; $tick)
  | addhook("SessionStart"; $start)
' "$settings" > "$tmp" && mv "$tmp" "$settings"
echo "Registered the hooks in $settings (backup at $settings.bak-session-search)"

# 5. Start the app now and at every login
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$binary</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/session-search-widget.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/session-search-widget.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Started the app. Press Cmd+K anywhere to search your Claude Code sessions."
