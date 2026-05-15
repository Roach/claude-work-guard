# claude-work-guard

A Claude Code hook that interrupts long, untracked coding sessions to ask:
*"Should we file a JIRA ticket and/or cut a feature branch before going
further?"*

It's a guard-rail against the failure mode where you ask Claude a quick
question, that quick question turns into half an hour of edits on `main`,
and now there's a pile of uncommitted changes with no ticket, no branch,
and no paper trail.

## Demo

Twenty minutes into a session on `main`, with no JIRA key mentioned and
four files modified, Claude tries another edit. The hook fires, prints
to stderr with exit 2, and Claude Code surfaces it as a blocking note:

```
⚠  Work-guard check (20 min into this session):
  •  4 uncommitted files
  •  no JIRA ticket referenced yet
  •  on default branch `main`

Pause and ask the user whether to:
  →  create or reference a JIRA ticket
  →  cut a feature branch before further edits
If they decline, continue and don't ask again.
```

Claude pauses mid-task and asks the user. If the user says "go ahead,"
the hook stays quiet for the rest of the session — `warned: true` is
sticky. Only the bullets whose conditions tripped appear; if a JIRA key
shows up later or the user switches to a feature branch before the
threshold, the hook silently bows out.

## How it works

Two hook points, one shell script, one tiny JSON file per session.

```
┌──────────────────────┐                       ┌─────────────────────┐
│ UserPromptSubmit     │── prompt mode ──▶     │ scan for JIRA key   │
│ (every user message) │                       │ flip jira_seen=true │
└──────────────────────┘                       └─────────────────────┘

┌──────────────────────┐                       ┌─────────────────────┐
│ PostToolUse          │── edit mode ──▶       │ stamp first_edit;   │
│ Edit|Write|MultiEdit │                       │ if elapsed ≥ thresh │
│ |NotebookEdit        │                       │ and (no JIRA OR on  │
└──────────────────────┘                       │ default branch),    │
                                               │ print nag, exit 2   │
                                               └─────────────────────┘
```

The nag is printed to stderr with exit code 2. Claude Code forwards
stderr from exit-2 `PostToolUse` hooks back to the model as a blocking
note — so the model sees the warning mid-task and is expected to pause
and ask the user.

### Trigger conditions

The hook exits early (no state, no nag) when:

- `cwd` is not inside a git repo, or
- the repo contains a `.no-work-guard` marker file at its root.

Otherwise, the nag fires on the first edit that satisfies **all** of:

1. **Elapsed time** since the *first* edit in this session ≥ threshold
   (default 15 minutes).
2. **No prior warning** issued in this session (`warned: false`).
3. Either:
   - no JIRA-style key has been seen in any user prompt this session, **or**
   - the repo's current branch is one of `main`, `master`, `develop`,
     `trunk`, `dev`.

If neither (3) condition is met — JIRA key seen *and* on a feature branch
— the script silently marks the session `warned: true` and exits clean,
so it stops checking for the rest of the session.

### Message variants

Each bullet drops out individually when its condition isn't met: no
uncommitted-files line when the tree is clean, no JIRA bullet when a
key has been seen, no branch bullet when on a feature branch. When both
JIRA and branch conditions are satisfied, the hook exits silently — no
nag at all.

## JIRA: detection only, no integration

The hook does **not** talk to JIRA. It does not create tickets, validate
keys, or know whether a referenced key actually exists. It only watches
user prompts for strings matching `\b[A-Z][A-Z0-9]+-[0-9]+\b` (e.g.
`PROJ-123`, `SEC-7746`). The presence of a matching string in any prompt
during the session is enough to suppress the JIRA half of the nag.

The nag itself just instructs Claude to **ask the user** whether to
create or reference a ticket. Whatever ticket-creation tooling the user
prefers (JIRA MCP, browser, CLI) handles the actual work.

## Installation

1. Clone or place the repo wherever you like. Examples below assume
   `~/projects/claude-work-guard`.

2. Make sure the script is executable:

   ```bash
   chmod +x ~/projects/claude-work-guard/claude-work-guard.sh
   ```

3. Wire it into Claude Code via `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "UserPromptSubmit": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "/Users/you/projects/claude-work-guard/claude-work-guard.sh prompt"
             }
           ]
         }
       ],
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|NotebookEdit",
           "hooks": [
             {
               "type": "command",
               "command": "/Users/you/projects/claude-work-guard/claude-work-guard.sh edit"
             }
           ]
         }
       ]
     }
   }
   ```

   Use absolute paths — hooks don't get your shell's `PATH` expansion.

4. Restart any active Claude Code sessions so the new hook config loads.

## Configuration

| What | How |
|---|---|
| Trigger threshold | `CLAUDE_WORK_GUARD_THRESHOLD` env var, in seconds. Default `900` (15 min). |
| Per-repo opt-out | Create an empty `.no-work-guard` file at the repo root. |
| Non-git directories | Always skipped automatically — scratch dirs and script folders won't trip it. |
| Default-branch list | Edit the `case "$branch" in main\|master\|develop\|trunk\|dev) ...` line in the script. |
| JIRA key regex | Edit the `grep -qE '\b[A-Z][A-Z0-9]+-[0-9]+\b'` line. |
| State location | `~/.claude/work-guard/<session_id>.json`. Safe to delete at any time. |

Example: nag after 10 minutes instead of 15 —

```bash
export CLAUDE_WORK_GUARD_THRESHOLD=600
```

(set it in your shell rc so Claude Code inherits it).

## Session state

Per-session JSON, one file per `session_id`:

```json
{
  "first_edit": 1778825375,
  "jira_seen": false,
  "warned": false
}
```

- `first_edit` — Unix timestamp of the first `Edit|Write|MultiEdit|NotebookEdit`
  in this session. The clock starts here, not at session start, so a
  session that opens with Q&A doesn't burn the budget.
- `jira_seen` — set to `true` the first time a JIRA-style key appears in
  any user prompt.
- `warned` — set to `true` after the nag fires (or after the script
  determines no nag is needed). Prevents repeated interruptions.

Delete the file to reset the session's state. The next edit will
re-stamp `first_edit`.

## Manual test

```bash
# 1. Stamp first_edit on a fake session.
echo '{"session_id":"smoke","cwd":"'"$PWD"'","prompt":"fix the thing"}' \
  | ./claude-work-guard.sh edit          # exit 0, state file created

# 2. Backdate first_edit by 1000 seconds to force the threshold.
python3 -c "import json,os; p=os.path.expanduser('~/.claude/work-guard/smoke.json'); \
  d=json.load(open(p)); d['first_edit']-=1000; json.dump(d, open(p,'w'))"

# 3. Re-run — should print the nag to stderr and exit 2.
echo '{"session_id":"smoke","cwd":"'"$PWD"'"}' \
  | ./claude-work-guard.sh edit

# 4. Cleanup.
rm ~/.claude/work-guard/smoke.json
```

To verify JIRA detection suppresses the JIRA half of the nag:

```bash
echo '{"session_id":"smoke2","prompt":"working on PROJ-123"}' \
  | ./claude-work-guard.sh prompt
cat ~/.claude/work-guard/smoke2.json   # jira_seen should be true
```

## Design notes

- **`PostToolUse` + exit 2 vs. `additionalContext`.** A successful
  `additionalContext` injection is easy for the model to skim past.
  Exit-2 stderr is surfaced as a blocking note, which is the
  "interrupt and ask" semantic the guard exists to provide.
- **First-edit time, not session-start time.** A session that begins
  with 20 minutes of exploration shouldn't trip the guard. The clock
  only starts when actual code changes begin.
- **Session-scoped `warned` flag.** Re-nagging on every subsequent edit
  would be hostile. One prompt per session, then quiet — the user
  either course-corrects or has chosen not to, and either way the hook
  gets out of the way.
- **No JIRA validation.** Checking that `PROJ-123` actually exists would
  require credentials, network calls, and per-org config — too much
  surface for a nudge. Pattern-match is good enough: if the user typed
  a key-shaped string, they're at least *thinking* about tickets.

## Files

- `claude-work-guard.sh` — the hook, invoked as either `prompt` or `edit`.
- `README.md` — this file.

## License

No license declared — treat as personal tooling. Fork freely.
