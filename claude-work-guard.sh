#!/usr/bin/env bash
# Claude Code work-guard hook.
#
# After ~15 minutes of editing in a session, if no Linear-style ticket has
# been referenced or the repo is sitting on a default branch, print a
# one-shot nag to stderr and exit 2. Claude Code surfaces exit-2 stderr
# back to the model as a blocking note, which prompts it to pause and
# ask the user about a ticket / feature branch.
#
# Skip conditions (edit mode): not inside a git repo, or a
# .no-work-guard marker file is present at the repo root.
#
# Wire-up (~/.claude/settings.json):
#   UserPromptSubmit                      -> this script with arg "prompt"
#   PostToolUse Edit|Write|MultiEdit|...  -> this script with arg "edit"
#
# State lives at ~/.claude/work-guard/<session_id>.json.

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

# --- state helpers ---------------------------------------------------------

# Reads the state file (or defaults) and emits three lines: first_edit,
# linear_seen, warned. State file path is passed as argv[1] so it never has
# to be interpolated into the Python source.
read_state() {
  /usr/bin/python3 - "$state_file" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
print(d.get('first_edit', 0))
print('true' if d.get('linear_seen') else 'false')
print('true' if d.get('warned') else 'false')
PY
}

# Writes the three state fields. Values come in via env vars, not source
# interpolation, so callers can pass anything safely.
write_state() {
  FE="$1" LS="$2" W="$3" /usr/bin/python3 - "$state_file" <<'PY'
import json, os, sys
d = {
    'first_edit':  int(os.environ['FE']),
    'linear_seen': os.environ['LS'] == 'true',
    'warned':      os.environ['W']  == 'true',
}
json.dump(d, open(sys.argv[1], 'w'))
PY
}

# --- prompt mode: record Linear mentions, nothing else ----------------------

if [ "$MODE" = "prompt" ]; then
  if printf '%s' "$prompt" | /usr/bin/grep -qE '\b[A-Z][A-Z0-9]+-[0-9]+\b'; then
    { read -r first_edit; read -r _linear_seen; read -r warned; } < <(read_state)
    write_state "$first_edit" true "$warned"
  fi

  # Auto-name unnamed sessions. Never overwrite a title set by /rename, --name
  # or an earlier hook (session_title), and skip slash commands like /rename.
  title="$(read_field session_title)"
  if [ -z "$title" ] && ! grep -q '"type":"custom-title"' "$(read_field transcript_path)" 2>/dev/null \
     && [ "${prompt#/}" = "$prompt" ]; then
    branch="$(/usr/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    slug="$(BR="$branch" PR="$prompt" /usr/bin/python3 -c "
import os, re, json
br = os.environ['BR']
if br in ('', 'HEAD', 'main', 'master', 'develop', 'trunk', 'dev'):
    br = ''
br = br.split('/')[-1]
words = re.findall(r'[a-z0-9]+', os.environ['PR'].lower())[:5]
s = re.sub(r'[^a-z0-9]+', '-', '-'.join(x for x in [br] + ['-'.join(words)] if x)).strip('-')[:60]
print(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'sessionTitle': s}}) if s else '')
" 2>/dev/null)"
    [ -n "$slug" ] && printf '%s\n' "$slug"
  fi
  exit 0
fi

# --- edit mode: skip-checks, then maybe warn -------------------------------

# Skip outside a git repo — the guard's frame (branch, ticket) is git-shaped.
if [ -z "$cwd" ] || { [ ! -d "$cwd/.git" ] && [ ! -f "$cwd/.git" ]; }; then
  exit 0
fi
# Per-repo opt-out.
if [ -e "$cwd/.no-work-guard" ]; then
  exit 0
fi

{ read -r first_edit; read -r linear_seen; read -r warned; } < <(read_state)

# First edit of the session: stamp the clock and exit clean.
if [ "$first_edit" -eq 0 ]; then
  write_state "$now" "$linear_seen" "$warned"
  exit 0
fi

# Already warned, or threshold not yet crossed.
[ "$warned" = "true" ] && exit 0
elapsed=$(( now - first_edit ))
[ "$elapsed" -lt "$THRESHOLD_SEC" ] && exit 0

# Threshold crossed — gather facts.
branch="$(/usr/bin/git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
on_default=0
case "$branch" in
  main|master|develop|trunk|dev) on_default=1 ;;
esac
dirty_count="$(/usr/bin/git -C "$cwd" status --porcelain 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

# Nothing to flag — Linear seen and on a feature branch. Mark warned so we
# don't keep re-checking for the rest of the session, then exit clean.
if [ "$linear_seen" = "true" ] && [ "$on_default" -eq 0 ]; then
  write_state "$first_edit" "$linear_seen" true
  exit 0
fi

# --- compose the nag -------------------------------------------------------

mins=$(( elapsed / 60 ))

facts=""
if [ -n "$dirty_count" ] && [ "$dirty_count" -gt 0 ]; then
  if [ "$dirty_count" -eq 1 ]; then
    facts+="  •  1 uncommitted file"$'\n'
  else
    facts+="  •  ${dirty_count} uncommitted files"$'\n'
  fi
fi
if [ "$linear_seen" != "true" ]; then
  facts+="  •  no Linear ticket referenced yet"$'\n'
fi
if [ "$on_default" -eq 1 ]; then
  facts+="  •  on default branch \`${branch}\`"$'\n'
fi

asks=""
if [ "$linear_seen" != "true" ]; then
  asks+="  →  create or reference a Linear ticket"$'\n'
fi
if [ "$on_default" -eq 1 ]; then
  asks+="  →  cut a feature branch before further edits"$'\n'
fi

msg="⚠  Work-guard check (${mins} min into this session):"$'\n'
msg+="${facts}"
msg+=$'\n'"Pause and ask the user whether to:"$'\n'
msg+="${asks}"
msg+="If they decline, continue and don't ask again."

write_state "$first_edit" "$linear_seen" true

# PostToolUse + exit 2: stderr is forwarded to Claude as a blocking note.
printf '%s\n' "$msg" 1>&2
exit 2
