#!/usr/bin/env bash
# context-guard — Claude Code hook that steers project agents toward DISTILL
# instead of lossy auto-compaction.
#
# Installed globally (see setup.sh) but a no-op unless the session is a
# registered agent in a project. Handles two events:
#
#   Stop                    After each turn, measure how much the context has
#                           grown since the session's first turn. Past the
#                           threshold, nudge the agent once to request DISTILL.
#   SessionStart (compact)  Compaction happened anyway — remind the agent who it
#                           is, which instructions to re-read, and to DISTILL.
#
# Threshold: PROJECT_DISTILL_TOKENS (default 100000) of GROWTH above the
# session's first-turn baseline. The baseline (system prompt, tool and MCP
# definitions, CLAUDE.md, memory) can be 80k+ before the agent does anything and
# is identical in a fresh successor, so counting it would make a distilled agent
# hit the threshold again almost immediately.
#
# Never fails the session: every error path exits 0 silently.

set -uo pipefail
trap 'exit 0' ERR

PROJECTS_DIR="$HOME/.herdr/projects"
THRESHOLD="${PROJECT_DISTILL_TOKENS:-100000}"

input="$(cat)"
pane="${HERDR_PANE_ID:-}"
[[ -n "$pane" && -d "$PROJECTS_DIR" ]] || exit 0
command -v jq >/dev/null || exit 0

# --- Find project + role for this pane ---
project="" role=""
_match() {
  local f="$1" r
  r=$(jq -r --arg p "$pane" '.agents | to_entries[] | select(.value.pane_id == $p and (.value.stopped != true)) | .key' "$f" 2>/dev/null | head -1)
  if [[ -n "$r" ]]; then project="$(basename "$f" .json)"; role="$r"; fi
}
if [[ -n "${HERDR_PROJECT:-}" && -f "$PROJECTS_DIR/$HERDR_PROJECT.json" ]]; then
  _match "$PROJECTS_DIR/$HERDR_PROJECT.json"
else
  for f in "$PROJECTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    _match "$f"
    [[ -n "$role" ]] && break
  done
fi
[[ -n "$role" ]] || exit 0

proj_dir="$PROJECTS_DIR/$project"

# Where each role's instructions live
case "$role" in
  orchestrator)            reload="the /start-project skill" ;;
  librarian|researcher|watcher)
                           reload="~/.claude/skills/start-project/$role.md" ;;
  tester-*)                reload="the /project-tester skill" ;;
  *)                       reload="the /project-worker skill" ;;
esac

if [[ "$role" == "orchestrator" ]]; then
  distill_how="You can't DISTILL through yourself: write your state (wave, DAG, in-flight agents, pending decisions) to $proj_dir/orchestrator.distill.md, then tell the user you need a fresh orchestrator session that reads it."
else
  distill_how="Request it now: project prompt orchestrator \"DISTILL — context pressure is high (auto-detected)\". If you're one or two steps from done, finish first instead."
fi

event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)

case "$event" in
  Stop)
    [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]] && exit 0
    transcript=$(jq -r '.transcript_path // empty' <<<"$input")
    session=$(jq -r '.session_id // empty' <<<"$input")
    [[ -f "$transcript" && -n "$session" ]] || exit 0

    # Nudge once per session
    marker="$proj_dir/.distill-nudged/$session"
    [[ -f "$marker" ]] && exit 0

    # Context size = input side of an assistant turn. Baseline = first turn,
    # current = most recent turn.
    usage_sum='.message.usage // empty | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))'
    baseline=$(grep -m1 '"type":"assistant"' "$transcript" | jq "$usage_sum" 2>/dev/null)
    used=$(tail -n 200 "$transcript" \
      | jq -s "[.[] | select(.type == \"assistant\") | $usage_sum] | last // 0" 2>/dev/null)
    [[ "$used" =~ ^[0-9]+$ && "$baseline" =~ ^[0-9]+$ ]] || exit 0
    grown=$(( used - baseline ))
    (( grown >= THRESHOLD )) || exit 0

    mkdir -p "$proj_dir/.distill-nudged" && touch "$marker"
    msg="CONTEXT GUARD — your context has grown ~$((grown / 1000))k tokens this session (now ~$((used / 1000))k; threshold $((THRESHOLD / 1000))k of growth). Prefer DISTILL over auto-compaction: compaction is lossy and can drop what your role needs. $distill_how"
    jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $m}}'
    ;;

  SessionStart)
    [[ "$(jq -r '.source // empty' <<<"$input")" == "compact" ]] || exit 0
    msg="CONTEXT GUARD — your context was just compacted. You are '$role' in Herdr project '$project'. Agents talk via the 'project' CLI (project prompt / ask / research / punt), and the shared working dir is $proj_dir. Re-read $reload before doing anything else. Compaction lost detail your role may need, so get a clean session: $distill_how"
    jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
    ;;
esac
exit 0
