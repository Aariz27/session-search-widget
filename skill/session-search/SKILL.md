---
name: session-search
description: Search across every past Claude Code session on this machine — find which session did something, list sessions that used a slash command or skill, pull out what was discussed, or get the command to resume one. Use whenever the question is about past sessions, past conversations, "which session did X", "when did I", "find the session where", "have I done this before", or resuming earlier work. Also use before answering "I can only see this folder" — session transcripts are NOT in the working directory.
---

# Searching every Claude Code session on this machine

Claude Code stores every session as a file on disk. They are **not** in the folder you are
working in, which is why a session asked to "find my earlier work" usually says it cannot.
This skill tells you exactly where they are and how to read them.

## Where the sessions live

```
~/.claude/projects/<encoded-working-directory>/<session-id>.jsonl
```

One folder per working directory a session ran in, one file per session. Each file is JSON
Lines: one JSON object per line, one line per event.

**Do not try to decode the folder name.** The encoding changed between Claude Code versions,
so the same project appears as both `-Users-x-Documents-MY_PROJECT` and
`-Users-x-Documents-MY-PROJECT`, and some folders keep spaces. Read the real path from the
`cwd` field inside any record instead.

## What counts as a session

Only files named `<uuid>.jsonl` — eight hex, four, four, four, twelve. Everything else in
those folders is not a session and must be excluded:

| file | what it is |
|---|---|
| `<uuid>.jsonl` | a real session you can resume |
| `agent-*.jsonl` | a subagent run inside some session |
| `skill-injections.jsonl` | plugin bookkeeping |
| `journal.jsonl` | not a session |

The filter that works:

```bash
find ~/.claude/projects -name '*.jsonl' \
  | grep -E '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$'
```

## Reading the records

Every line has a `type`. The ones that matter:

- `user` — what the human typed. `.message.content` is **either a plain string or an array
  of blocks**; when it is an array, take the blocks whose `type` is `"text"`.
- `assistant` — Claude's reply, same content shape.
- `ai-title` — Claude's own one-line title for the session. Take the **last** one; it is
  rewritten as the session goes on. Many sessions have none.
- `system`, `attachment`, `file-history-snapshot`, `last-prompt`, `mode` — machinery, skip.

Every record also carries `cwd`, `timestamp`, `sessionId` and `uuid`.

Skip `user` records where `isMeta` is `true` or `isSidechain` is `true`. They are injected
context and subagent traffic, not the human talking.

## Four traps that make searches miss

**1. Slash commands hide the real instruction.** When the human runs a slash command, the
message is stored as tags, and the words they actually typed are in `<command-args>`:

```
<command-name>/goal</command-name><command-message>goal</command-message>
<command-args>go to ~/Library/Application Support/localwispr and fix the bugs</command-args>
```

Searching the plain text finds nothing. Search inside `<command-args>` too. On this machine
87 real instructions were stored this way.

**2. Some "user" messages are machines talking.** Text beginning with
`Another Claude session sent a message` or containing `<teammate-message ...>` is one agent
messaging another, not the human. Also injected, and worth excluding: `<system-reminder`,
`<local-command-stdout>`, `<user-prompt-submit-hook`, `Caveat: The messages below`, and
`This session is being continued from a previous conversation`.

**3. One conversation is spread over several files.** Every resume and every compaction
writes a **new** file that copies the earlier messages into it, keeping the same title. Files
belonging to the same conversation share message `uuid` values — group by that, transitively,
because a resume of a resume may share nothing with the original once compaction has dropped
the early messages. Report the most recently modified file of the group; that is the one to
resume.

**4. Sessions get deleted.** Claude Code prunes old transcripts on a schedule set by
`cleanupPeriodDays` in `~/.claude/settings.json`. A project folder that exists but contains
no `<uuid>.jsonl` means those conversations are already gone. Say so rather than reporting
"not found".

## Titles

Two different names exist for a session and they are unrelated:

- **Claude's auto-title** — the `ai-title` record inside the transcript. This is what the
  terminal tab and the `/resume` picker show, and what `/rename` changes.
- **A hand-written name** — if session-logging hooks are installed, `<cwd>/sessions.json`
  holds `{session_id, session_name, cwd, started_at, session_summary}` rows. Changing this
  does **not** change the auto-title.

Check both. Sessions with neither are best labelled by the first thing the human typed.

## Recipes

All of these were run on this machine and their timings are real.

**Which sessions used a slash command** (~1 second across every transcript):

```bash
grep -rl "<command-name>/goal</command-name>" ~/.claude/projects --include='*.jsonl' \
  | grep -E '/[0-9a-f]{8}-[0-9a-f]{4}-'
```

Swap `/goal` for any command. If the result is empty, the command was genuinely never used —
say that, rather than assuming the search failed.

**Which sessions mention a topic** (searches everything, including tool output):

```bash
grep -rli "marketing strategy" ~/.claude/projects --include='*.jsonl' \
  | grep -E '/[0-9a-f]{8}-[0-9a-f]{4}-'
```

To search only what the human typed, pipe each file through:

```bash
jq -r 'select(.type=="user" and (.isMeta|not) and (.isSidechain|not))
       | .message.content
       | if type=="string" then . else (map(select(.type=="text").text)|join(" ")) end' FILE
```

**Describe one session** — title, folder, when it ran:

```bash
jq -r 'select(.type=="ai-title") | .aiTitle' FILE | tail -1
jq -r 'select(.cwd) | .cwd' FILE | head -1
jq -r 'select(.timestamp) | .timestamp' FILE | head -1
```

**Read what was actually discussed** — pull the human's messages in order and summarise them
rather than dumping the file; a busy session transcript is several megabytes.

## Resuming a session

`claude --resume <session-id>` only searches the **current** project directory, so you must
move to the folder the session ran in first:

```bash
cd '<the cwd you read from the transcript>' && claude --resume <session-id>
```

Give the human this exact line, with the real path and id filled in and the path quoted —
folder names contain spaces.

## Answering well

- Say how many sessions you searched, so the human knows the scope was everything.
- Give each result its title, its folder, and the date it ran — a bare id is useless.
- Quote the line that made you pick a session; do not just assert relevance.
- When nothing matches, check the spelling of any project name against the folder names
  under `~/.claude/projects` before concluding it does not exist.
