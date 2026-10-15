# Session Search Widget

Press **Cmd+K** anywhere on your Mac to search every Claude Code session you have ever run,
then press Enter to reopen it in Terminal, in the right folder.

- **Type** to search session names, titles and summaries instantly, on your machine.
- **Tab** switches to asking Claude Haiku a question in plain English ("which session set up
  the Stripe webhook?"). This runs `claude -p --model haiku` and uses your Claude account.
- **Enter** opens a new Terminal window, `cd`s into the session's folder and resumes it. The
  resume command is also copied to your clipboard.

## How sessions get indexed

Two Claude Code hooks keep a `sessions.json` file in each folder you run Claude in:

- When a new session starts, it is added to `sessions.json` and Claude asks you to name it
  with `/rename`.
- On every message, the name you set with `/rename` is copied into `sessions.json`. Every
  10th message, Claude Haiku writes a 3-bullet summary of the last stretch of work in the
  background.

Add `sessions.json` and `.sessions-state.json` to the `.gitignore` of your own projects so
your session history does not end up in your repos.

## Requirements

- macOS 14 or newer
- Swift 6 (`xcode-select --install`)
- `jq` (`brew install jq`)
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on your PATH)

## Install

```bash
git clone <this-repo-url> session-search-widget
cd session-search-widget
./install.sh
```

`install.sh` does five things:

1. Checks the requirements above.
2. Builds the app with `swift build -c release`.
3. Copies `hooks/session-log-*.sh` to `~/.claude/hooks/` and `skill/session-search/` to
   `~/.claude/skills/session-search/`.
4. Adds the two hooks to `~/.claude/settings.json` without touching your other settings. A
   backup is saved as `~/.claude/settings.json.bak-session-search`.
5. Writes a LaunchAgent so the app starts now and at every login.

Run `./install.sh` again after `git pull` to rebuild and update.

No Apple Developer account is needed: the app is built on your own Mac, so macOS does not
block it.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/local.session-search-widget
rm ~/Library/LaunchAgents/local.session-search-widget.plist
rm ~/.claude/hooks/session-log-*.sh
rm -r ~/.claude/skills/session-search
```

Then remove the `session-log-tick.sh` and `session-log-start.sh` entries from the `hooks`
section of `~/.claude/settings.json`.

## Logs

The app writes to `/tmp/session-search-widget.log`.
