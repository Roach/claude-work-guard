#!/usr/bin/env bash
# Claude Code work-guard hook.
#
# Goal: if Claude has been actively editing for ~15 minutes in a session and
# there is still no JIRA-style ticket referenced AND/OR the repo is sitting on
# a default branch, nudge the model (once) to ask the user whether to file a
# ticket or cut a branch.
#
# Wire-up (settings.json):
#   UserPromptSubmit -> this script with arg "prompt"
#   PostToolUse (Edit|Write|MultiEdit|NotebookEdit) -> this script with arg "edit"
#
# State lives at ~/.claude/work-guard/<session_id>.json

set -u

MODE="${1:-edit}"
THRESHOLD_SEC="${CLAUDE_WORK_GUARD_THRESHOLD:-900}"   # 15 min
STATE_DIR="$HOME/.claude/work-guard"
mkdir -p "$STATE_DIR"

input="$(cat)"

read_field() {
  printf '%s' "$input" | /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null
}

session_id="$(read_field session_id)"
cwd="$(read_field cwd)"
prompt="$(read_field prompt)"
[ -z "$session_id" ] && exit 0

state_file="$STATE_DIR/${session_id}.json"

now=$(date +%s)

# --- helpers ---------------------------------------------------------------

load_state() {
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    printf '{"first_edit":0,"jira_seen":false,"warned":false}'
  fi
}

save_state() {
  printf '%s' "$1" > "$state_file"
}

jq_set() {
  # $1 state json, $2 key, $3 value (raw JSON literal)
  printf '%s' "$1" | /usr/bin/python3 -c "
import json,sys
d=json.load(sys.stdin)
d['$2']=json.loads('''$3''')
print(json.dumps(d))
"
}

jq_get() {
  printf '%s' "$1" | /usr/bin/python3 -c "
import json,sys
d=json.load(sys.stdin)
v=d.get('$2','')
print(v if not isinstance(v,bool) else ('true' if v else 'false'))
"
}

state="$(load_state)"

# --- prompt mode: just record whether a JIRA key has appeared ---------------

if [ "$MODE" = "prompt" ]; then
  if printf '%s' "$prompt" | /usr/bin/grep -qE '\b[A-Z][A-Z0-9]+-[0-9]+\b'; then
    state="$(jq_set "$state" jira_seen true)"
    save_state "$state"
  fi
  exit 0
fi

# --- edit mode: timestamp, then maybe warn ---------------------------------

# Skip outside a git repo — the guard's whole frame (branch, ticket) is
# git-shaped. Also skip if the repo has opted out with a .no-work-guard
# marker file.
if [ -z "$cwd" ] || { [ ! -d "$cwd/.git" ] && [ ! -f "$cwd/.git" ]; }; then
  exit 0
fi
if [ -e "$cwd/.no-work-guard" ]; then
  exit 0
fi

first_edit="$(jq_get "$state" first_edit)"
if [ "$first_edit" = "0" ] || [ -z "$first_edit" ]; then
  state="$(jq_set "$state" first_edit "$now")"
  save_state "$state"
  exit 0
fi

warned="$(jq_get "$state" warned)"
[ "$warned" = "true" ] && exit 0

elapsed=$(( now - first_edit ))
[ "$elapsed" -lt "$THRESHOLD_SEC" ] && exit 0

# Threshold crossed — gather facts.
jira_seen="$(jq_get "$state" jira_seen)"

branch="$(/usr/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
on_default=0
case "$branch" in
  main|master|develop|trunk|dev) on_default=1 ;;
esac
dirty_count="$(/usr/bin/git -C "$cwd" status --porcelain 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

# If nothing to flag, mark warned (don't keep re-checking) and exit clean.
if [ "$jira_seen" = "true" ] && [ "$on_default" -eq 0 ]; then
  state="$(jq_set "$state" warned true)"
  save_state "$state"
  exit 0
fi

mins=$(( elapsed / 60 ))

facts=""
if [ -n "$dirty_count" ] && [ "$dirty_count" -gt 0 ]; then
  if [ "$dirty_count" -eq 1 ]; then
    facts+="  - 1 uncommitted file"$'\n'
  else
    facts+="  - ${dirty_count} uncommitted files"$'\n'
  fi
fi
if [ "$jira_seen" != "true" ]; then
  facts+="  - no JIRA ticket referenced yet"$'\n'
fi
if [ "$on_default" -eq 1 ]; then
  facts+="  - on default branch \`${branch}\`"$'\n'
fi

asks=""
if [ "$jira_seen" != "true" ]; then
  asks+="  - create or reference a JIRA ticket"$'\n'
fi
if [ "$on_default" -eq 1 ]; then
  asks+="  - cut a feature branch before further edits"$'\n'
fi

msg="Work-guard check (${mins} min into this session):"$'\n'
msg+="${facts}"
msg+=$'\n'"Pause and ask the user whether to:"$'\n'
msg+="${asks}"
msg+="If they decline, continue and don't ask again."

state="$(jq_set "$state" warned true)"
save_state "$state"

# PostToolUse + exit 2: stderr is surfaced back to Claude as a blocking note.
printf '%s\n' "$msg" 1>&2
exit 2
