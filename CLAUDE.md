# claude-work-guard

A Claude Code hook that nudges the user to create a JIRA ticket and/or cut a
feature branch when a coding session has been running for a while without
either.

## What it does

- Stamps the time of the **first** Edit/Write in a Claude Code session.
- Watches every user prompt for a JIRA-style key (e.g. `PROJ-123`); if one
  appears, a session flag is set.
- On each subsequent edit, if **elapsed time ≥ threshold** (default 15 min)
  **AND** (no JIRA key has been seen in the session **OR** the repo is on a
  default branch — `main`/`master`/`develop`/`trunk`/`dev`), the hook prints
  a one-line nag to stderr and exits `2`. Claude Code surfaces stderr from
  exit-2 hooks back to the model, which then asks the user about filing a
  ticket / cutting a branch.
- Fires **once per session** — sets `warned: true` after the first nag so it
  doesn't keep interrupting.

## Files

- `claude-work-guard.sh` — the hook. Invoked in two modes:
  - `prompt` — wired to `UserPromptSubmit`. Records JIRA-key sightings.
  - `edit` — wired to `PostToolUse` for `Edit|Write|MultiEdit|NotebookEdit`.
    Stamps first-edit time and emits the nag when the threshold is crossed.

## Session state

Per-session JSON lives at `~/.claude/work-guard/<session_id>.json`:

```json
{ "first_edit": 1778825375, "jira_seen": false, "warned": false }
```

Safe to delete — it'll be recreated on the next session.

## Configuration

- `CLAUDE_WORK_GUARD_THRESHOLD` (env, seconds) — override the 15-minute
  trigger. e.g. `export CLAUDE_WORK_GUARD_THRESHOLD=600` for 10 minutes.
- Default branches treated as "needs a feature branch": `main`, `master`,
  `develop`, `trunk`, `dev`. Edit the `case` in the script to adjust.
- JIRA key regex: `\b[A-Z][A-Z0-9]+-[0-9]+\b`.

## Wiring (in `~/.claude/settings.json`)

```json
"UserPromptSubmit": [
  {
    "hooks": [
      { "type": "command", "command": "/Users/jasonroche/projects/claude-work-guard/claude-work-guard.sh prompt" }
    ]
  }
],
"PostToolUse": [
  {
    "matcher": "Edit|Write|MultiEdit|NotebookEdit",
    "hooks": [
      { "type": "command", "command": "/Users/jasonroche/projects/claude-work-guard/claude-work-guard.sh edit" }
    ]
  }
]
```

## Manual test

```bash
echo '{"session_id":"smoke","cwd":"'"$PWD"'","prompt":"fix the thing"}' \
  | ./claude-work-guard.sh edit          # stamps first_edit, exit 0
python3 -c "import json,os; p=os.path.expanduser('~/.claude/work-guard/smoke.json'); \
  d=json.load(open(p)); d['first_edit']-=1000; json.dump(d, open(p,'w'))"
echo '{"session_id":"smoke","cwd":"'"$PWD"'"}' \
  | ./claude-work-guard.sh edit          # prints nag, exit 2
rm ~/.claude/work-guard/smoke.json
```

## Design notes

- **Why `PostToolUse` + exit 2** instead of `additionalContext`: stderr from
  an exit-2 PostToolUse hook is forwarded to Claude as a blocking note,
  which is exactly the "interrupt and ask" semantics we want. A successful
  `additionalContext` injection is easier for the model to ignore.
- **Why first-edit time, not session-start time**: a session that begins
  with 20 minutes of Q&A or exploration shouldn't trip the guard — the
  clock should only start when actual code changes begin.
- **Why a session-scoped `warned` flag**: re-nagging on every subsequent
  edit would be hostile. One prompt per session, then quiet.
