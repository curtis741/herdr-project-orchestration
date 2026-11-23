#!/usr/bin/env bash
set -euo pipefail

# project — agent roster for multi-agent project orchestration
#
# Every agent in a project can address any other agent by role.
# The orchestrator registers agents as it spawns them; workers just use them.
#
# State file: ~/.herdr/projects/<project-name>.json
# Signal log: ~/.herdr/projects/<project-name>.signals.log
# Project name comes from: HERDR_PROJECT env var (injected via herdr tab create --env)

PROJECTS_DIR="$HOME/.herdr/projects"
mkdir -p "$PROJECTS_DIR"

# Deliver a prompt to an agent pane without clobbering a human's half-typed draft.
# `herdr agent prompt` types into the input box, so any draft gets concatenated
# with the incoming message. Ctrl+S is Claude Code's stash: it parks the draft,
# and Claude Code restores it automatically after the next submit. On an empty
# input it's a no-op. Same args as `herdr agent prompt`.
_prompt() {
  herdr agent send-keys "$1" ctrl+s >/dev/null 2>&1 || true
  herdr agent prompt "$@"
}

# --- Auto-update check (never blocks) ---
_update_check() {
  local marker="$PROJECTS_DIR/.last-update-check"
  local cache="$PROJECTS_DIR/.update-check-result"
  local today
  today="$(date +%Y-%m-%d)"

  # Phase 1: surface any cached result from a previous background check
  if [[ -f "$cache" ]]; then
    local msg
    msg="$(cat "$cache")"
    if [[ -n "$msg" ]]; then
      echo "$msg" >&2
    fi
    rm -f "$cache"
  fi

  # Phase 2: if we already checked today, skip
  if [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$today" ]]; then
    return
  fi

  # Write today's date so concurrent invocations don't all spawn checks
  echo "$today" > "$marker"

  # Background: compare installed SHA with remote HEAD
  (
    local plugin_info
    plugin_info=$(herdr plugin list 2>/dev/null) || exit 0
    local entry
    entry=$(echo "$plugin_info" | grep 'project-orchestration' | grep 'github:') || exit 0
    local installed_sha
    installed_sha=$(echo "$entry" | grep -oE '@[0-9a-f]+' | tr -d '@') || exit 0
    local repo_ref
    repo_ref=$(echo "$entry" | grep -oE 'github:[^@]+' | sed 's/github://') || exit 0
    local owner="${repo_ref%%/*}"
    local repo="${repo_ref#*/}"

    local remote_sha
    remote_sha=$(git ls-remote "https://github.com/$owner/$repo.git" HEAD 2>/dev/null \
      | awk '{print $1}') || exit 0

    if [[ -n "$remote_sha" && -n "$installed_sha" && "$remote_sha" != "$installed_sha" ]]; then
      echo "project: plugin update available — run 'herdr plugin update' to get the latest" > "$cache"
    fi
  ) &>/dev/null &
  disown
}

_update_check

# NATO phonetic alphabet for worker names
WORKER_NAMES=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu)

usage() {
  cat <<'EOF'
Usage: project <command> [args...]

Commands:
  start <epic-key> [workspace-label]
                                   Create workspace, start orchestrator, run /start-project
  init <project-name> [workspace-id]  Create a project state file (orchestrator only)
  register <role>                   Register this agent and signal READY to orchestrator
  stop <role>                      Stop an agent (preserves session ID for resume)
  next-worker                      Print the next available worker name (NATO alphabet)
  assign <role> <ticket-key>       Track a ticket assignment to a worker
  prompt <role> <message>          Send a message (fire-and-forget)
  prompt <role> <message> --wait [--timeout N]
                                   Send and wait for completion
  ask <role> <question> [--timeout N] [--lines N]
                                   Send, wait, read and print the reply (blocking)
  read <role> [--lines N]          Read an agent's recent pane output (non-blocking)
  roster                           Print the current role → pane ID map
  status                           Show agent states for all registered roles
  info                             Print epic key and workspace ID
  research <question>               Ask a research question (async, answer comes back via prompt)
  punt "<problem>"                 Hand a suspected problem to the researcher to own (no answer comes back)
  spinoff "<title>" [--notify] [--repo <path>] <<brief
                                   Spawn a throwaway worker on a scoped one-off fix (brief on stdin)
  spinoff-done "<outcome>"         Spinoff worker's last command: notify requester, stop, close tab
  resolve <role>                   Print the pane ID for a role (for scripting)
  session <role>                   Print the session ID for a role
  file                             Print the path to the state file
  dir                              Print the project working dir (shared, uncommitted scratch space)
  retire <old-pane-id>             Close a predecessor's tab after a DISTILL takeover (new agent runs this)
  dump [--timeout SECS]            Pause: every other live agent writes unreported state to
                                   <role>.final.md, then is stopped and its pane closed
  reset [--timeout SECS]           Orchestrator: dump all agents + write a master-distill template
                                   (from anywhere else: asks the orchestrator to run it)
  reset --handoff                  Orchestrator: spawn a fresh orchestrator that boots from the distill
  log [--tail N]                   Print the signal log (default: last 50 entries)
  log-decision <decision-type> <payload>
                                   Log an orchestrator decision (wave transition, spawn, etc.)
  feedback "<observation>"         Log a qualitative observation for skill refinement
  cleanup [--dry-run] [--repo <path>]
                                   Detect and remove orphan worktrees (no active agent)
  recover                          Diagnose project state after restart — show what's resumable
  check-in [--since <timestamp>]   Developer summary: what happened, what needs you
  observe                          Read-only snapshot: agents, signals, blockers, worktrees

Project name is auto-detected from $HERDR_PROJECT, falling back to the state
file that claims this pane/workspace (e.g. sessions resumed after a reboot).
Override with --project <name>.
EOF
  exit 1
}

# Resolve project name: explicit flag > env var > state-file lookup by pane/workspace
# (the lookup runs once at startup, see below the global flag parsing).
resolve_project() {
  local name="${HERDR_PROJECT:-}"
  if [[ -z "$name" ]]; then
    echo "error: no project name — set HERDR_PROJECT or pass --project <name>" >&2
    exit 1
  fi
  echo "$name"
}

# Find the single project whose state file claims this pane (any agent) or,
# failing that, this workspace. Prints nothing if zero or multiple match.
_project_from_state_files() {
  local pane="${HERDR_PANE_ID:-}" ws="${HERDR_WORKSPACE_ID:-}"
  [[ -z "$pane" && -z "$ws" ]] && return 0
  local f matches=()
  if [[ -n "$pane" ]]; then
    for f in "$PROJECTS_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      jq -e --arg p "$pane" '[.agents[]?.pane_id] | index($p) != null' "$f" >/dev/null 2>&1 \
        && matches+=("$(basename "$f" .json)")
    done
  fi
  if [[ ${#matches[@]} -eq 0 && -n "$ws" ]]; then
    for f in "$PROJECTS_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      jq -e --arg w "$ws" '.workspace_id == $w' "$f" >/dev/null 2>&1 \
        && matches+=("$(basename "$f" .json)")
    done
  fi
  if [[ ${#matches[@]} -eq 1 ]]; then
    echo "note: HERDR_PROJECT unset — resolved '${matches[0]}' from state file (export HERDR_PROJECT=${matches[0]} to silence)" >&2
    echo "${matches[0]}"
  fi
}

# Project working directory: shared scratch space for all agents, lives for the
# project's lifetime, never committed. Feedback, research, distill files, test
# plans, scripts, and cross-agent notes all go here.
project_dir() {
  local name
  name="$(resolve_project)" || exit 1
  local d="$PROJECTS_DIR/$name"
  mkdir -p "$d"
  echo "$d"
}

state_file() {
  echo "$PROJECTS_DIR/$(resolve_project).json"
}

ensure_state() {
  local f
  f="$(state_file)"
  if [[ ! -f "$f" ]]; then
    echo "error: no project state file at $f — run 'project init' first" >&2
    exit 1
  fi
  echo "$f"
}

signals_file() {
  echo "$PROJECTS_DIR/$(resolve_project).signals.log"
}

log_signal() {
  local sender="$1" receiver="$2" signal_type="$3" payload="$4"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$sender" "$receiver" "$signal_type" "$payload" \
    >> "$(signals_file)"
}

read_field() {
  local f="$1" field="$2"
  jq -r ".$field // empty" "$f"
}

read_pane() {
  local f="$1" role="$2"
  jq -r ".agents.\"$role\".pane_id // empty" "$f"
}

read_session() {
  local f="$1" role="$2"
  jq -r ".agents.\"$role\".session_id // empty" "$f"
}

resolve_caller() {
  local f="$1"
  if [[ -n "${HERDR_PANE_ID:-}" ]]; then
    jq -r --arg pane "$HERDR_PANE_ID" \
      '.agents | to_entries[] | select(.value.pane_id == $pane) | .key' "$f" 2>/dev/null || true
  fi
}

cmd_init() {
  local name="${1:-}"
  local ws="${2:-}"
  if [[ -z "$name" ]]; then
    echo "usage: project init <project-name> [workspace-id]" >&2
    exit 1
  fi
  local f="$PROJECTS_DIR/$name.json"
  if [[ -f "$f" ]]; then
    echo "warning: state file already exists at $f — overwriting" >&2
  fi
  jq -n \
    --arg name "$name" \
    --arg ws "$ws" \
    '{project: $name, workspace_id: $ws, agents: {}, created_at: (now | todate)}' \
    > "$f"
  echo "project initialized: $name → $f" >&2
  # Print the export so the caller can eval it: eval "$(project init my-project wW)"
  echo "export HERDR_PROJECT=$name"
}

cmd_start() {
  local name="${1:-}"
  local label="${2:-}"
  if [[ -z "$name" ]]; then
    echo "usage: project start <epic-key> [workspace-label]" >&2
    echo "  Creates a workspace, starts an orchestrator agent, and runs /start-project." >&2
    exit 1
  fi

  if ! command -v herdr &>/dev/null; then
    echo "error: herdr CLI not found" >&2
    exit 1
  fi

  # Default workspace label to the project name
  if [[ -z "$label" ]]; then
    label="$name"
  fi

  # Create the workspace
  local ws_output
  ws_output=$(herdr workspace create --cwd "$PWD" --label "$label" --env "HERDR_PROJECT=$name" --no-focus 2>&1) || {
    echo "error: failed to create workspace" >&2
    echo "$ws_output" >&2
    exit 1
  }
  local ws_id
  ws_id=$(echo "$ws_output" | jq -r '.result.workspace.workspace_id') || {
    echo "error: could not parse workspace ID from herdr output" >&2
    echo "$ws_output" >&2
    exit 1
  }
  if [[ -z "$ws_id" || "$ws_id" == "null" ]]; then
    echo "error: workspace creation returned no ID" >&2
    echo "$ws_output" >&2
    exit 1
  fi
  local pane_id
  pane_id=$(echo "$ws_output" | jq -r '.result.root_pane.pane_id')
  echo "workspace created: $ws_id (pane $pane_id)" >&2

  # Initialize the project with the workspace ID
  eval "$(cmd_init "$name" "$ws_id")"

  # Wait for the pane shell to be ready, then start the agent
  local attempts=0
  while ! herdr agent start orchestrator --kind claude --pane "$pane_id" -- -n orchestrator 2>/dev/null | jq -e '.result' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 10 ]]; then
      echo "error: pane $pane_id not ready after 5s — failed to start orchestrator agent" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "orchestrator agent started in $pane_id" >&2

  # Register the orchestrator with the correct pane ID
  export HERDR_PROJECT="$name"
  cmd_register orchestrator "$pane_id"

  # Prompt the orchestrator to load the skill
  _prompt "$pane_id" "/start-project $name" >&2

  echo "project started: $name (workspace $ws_id, pane $pane_id)" >&2
}

cmd_register() {
  local role="${1:-}" pane_id="${2:-}" session_id="${3:-}"
  # Default pane_id from HERDR_PANE_ID so agents can self-register
  if [[ -z "$pane_id" ]]; then
    pane_id="${HERDR_PANE_ID:-}"
  fi
  if [[ -z "$role" ]]; then
    echo "usage: project register <role>" >&2
    exit 1
  fi
  if [[ -z "$pane_id" ]]; then
    echo "error: cannot detect pane ID — set \$HERDR_PANE_ID or pass it explicitly" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"

  # If no session_id provided, try to get it from herdr
  if [[ -z "$session_id" ]]; then
    session_id=$(herdr agent get "$pane_id" 2>/dev/null \
      | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true)
  fi

  # Re-registering a role (e.g. after DISTILL takeover) keeps the prior session ID
  # in previous_sessions so it can still be resumed later.
  local tmp="${f}.tmp.$$"
  jq --arg role "$role" --arg pane "$pane_id" --arg sid "$session_id" \
    '(.agents[$role] // {}) as $old
     | .agents[$role] = $old + {pane_id: $pane, session_id: $sid, registered_at: (now | todate)}
     | if ($old.session_id // "") != "" and $old.session_id != $sid
       then .agents[$role].previous_sessions = (($old.previous_sessions // []) | if index($old.session_id) then . else . + [$old.session_id] end)
       else . end
     | del(.agents[$role].stopped) | del(.agents[$role].stopped_at)' \
    "$f" > "$tmp" && mv "$tmp" "$f"

  # Signal the orchestrator that this agent is ready (unless we ARE the orchestrator)
  local is_spinoff
  is_spinoff=$(jq -r --arg role "$role" '.agents[$role].spinoff != null' "$f")
  if [[ "$role" != "orchestrator" && "$is_spinoff" != "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      _prompt "$orch_pane" "READY — $role" 2>/dev/null || true
      log_signal "$role" "orchestrator" "READY" "$role registered"
    fi
  fi

  echo "registered: $role → $pane_id"
}

cmd_next_worker() {
  local f
  f="$(ensure_state)"
  # Active = registered and not stopped. Stopped names are available for reuse.
  local active
  active=$(jq -r '.agents | to_entries[] | select(.value.stopped != true) | .key' "$f")
  for name in "${WORKER_NAMES[@]}"; do
    if ! echo "$active" | grep -qx "$name"; then
      echo "$name"
      return
    fi
  done
  echo "worker-$(date +%s)"
}

cmd_assign() {
  local role="${1:-}" ticket="${2:-}"
  if [[ -z "$role" || -z "$ticket" ]]; then
    echo "usage: project assign <role> <ticket-key>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local tmp="${f}.tmp.$$"
  jq --arg role "$role" --arg ticket "$ticket" \
    '.agents[$role].current_ticket = $ticket | .agents[$role].tickets = ((.agents[$role].tickets // []) + [$ticket] | unique)' \
    "$f" > "$tmp" && mv "$tmp" "$f"
  log_signal "orchestrator" "$role" "ASSIGN" "$ticket"
  echo "assigned: $role → $ticket"
}

cmd_stop() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project stop <role>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi

  # Capture session ID before stopping (it may not be in the state file yet)
  local sid
  sid=$(herdr agent get "$pane" 2>/dev/null \
    | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true)

  local tmp="${f}.tmp.$$"
  jq --arg role "$role" --arg sid "$sid" \
    '.agents[$role].stopped = true | if $sid != "" then .agents[$role].session_id = $sid else . end | .agents[$role].stopped_at = (now | todate)
     | del(.agents[$role].spinoff)' \
    "$f" > "$tmp" && mv "$tmp" "$f"
  log_signal "orchestrator" "$role" "STOP" "$role stopped"
  echo "stopped: $role (session preserved)"
}

cmd_prompt() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project prompt <role> <message> [--wait] [--timeout N]" >&2
    exit 1
  fi
  shift

  # Collect message (everything before -- flags)
  local message=""
  local wait_flag=""
  local timeout_flag=""
  local args=()
  local parsing_message=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait)
        parsing_message=false
        wait_flag="--wait"
        shift
        ;;
      --timeout)
        parsing_message=false
        timeout_flag="--timeout"
        shift
        if [[ $# -gt 0 ]]; then
          timeout_flag="--timeout $1"
          shift
        fi
        ;;
      *)
        if $parsing_message; then
          if [[ -n "$message" ]]; then
            message="$message $1"
          else
            message="$1"
          fi
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$message" ]]; then
    echo "usage: project prompt <role> <message> [--wait] [--timeout N]" >&2
    exit 1
  fi

  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered — run 'project register $role <pane-id>'" >&2
    jq -r '.agents | keys[]' "$f" >&2
    exit 1
  fi

  local caller
  caller="$(resolve_caller "$f")"

  local is_stopped
  is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
  if [[ "$is_stopped" == "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      _prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original message: $message" 2>/dev/null || true
      log_signal "${caller:-unknown}" "orchestrator" "NEED" "$role stopped — escalated. Original: $message"
      echo "escalated to orchestrator: $role is stopped" >&2
    else
      echo "error: $role is stopped and orchestrator is not reachable" >&2
    fi
    exit 1
  fi

  # Classify signal type from message prefix
  local signal_type="PROMPT"
  case "$message" in
    READY\ *|READY)           signal_type="READY" ;;
    STARTING\ *)              signal_type="STARTING" ;;
    DONE\ *)                  signal_type="DONE" ;;
    COMPLETE\ *)               signal_type="COMPLETE" ;;
    BLOCKED\ *)               signal_type="BLOCKED" ;;
    SCOPE\ *)                 signal_type="SCOPE" ;;
    NEED\ *)                  signal_type="NEED" ;;
    RESEARCH\ *)              signal_type="RESEARCH" ;;
    DISTILL\ *)               signal_type="DISTILL" ;;
    DISTILL_READY\ *)         signal_type="DISTILL_READY" ;;
    MERGED\ *)                signal_type="MERGED" ;;
    RESET\ *)                 signal_type="RESET" ;;
  esac

  log_signal "${caller:-unknown}" "$role" "$signal_type" "$message"

  # Prefix with sender so the recipient can distinguish cross-agent messages from direct instructions
  if [[ -n "$caller" ]]; then
    message="FROM($caller): $message"
  fi

  # shellcheck disable=SC2086
  _prompt "$pane" "$message" $wait_flag $timeout_flag
}

cmd_ask() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project ask <role> <question> [--timeout N] [--lines N]" >&2
    exit 1
  fi
  shift

  local message=""
  local timeout="120000"
  local lines="40"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        shift; timeout="${1:-120000}"; shift ;;
      --lines)
        shift; lines="${1:-40}"; shift ;;
      *)
        if [[ -n "$message" ]]; then
          message="$message $1"
        else
          message="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$message" ]]; then
    echo "usage: project ask <role> <question> [--timeout N] [--lines N]" >&2
    exit 1
  fi

  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi

  local caller
  caller="$(resolve_caller "$f")"

  local is_stopped
  is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
  if [[ "$is_stopped" == "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      _prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original question: $message" 2>/dev/null || true
      echo "escalated to orchestrator: $role is stopped" >&2
    else
      echo "error: $role is stopped and orchestrator is not reachable" >&2
    fi
    exit 1
  fi

  log_signal "${caller:-unknown}" "$role" "ASK" "$message"

  if [[ -n "$caller" ]]; then
    message="FROM($caller): $message"
  fi

  # Send the prompt and wait for the agent to finish
  local prompt_result
  prompt_result=$(_prompt "$pane" "$message" --wait --timeout "$timeout" 2>&1)
  local prompt_exit=$?

  if [[ $prompt_exit -ne 0 ]]; then
    echo "error: prompt failed — $prompt_result" >&2
    exit 1
  fi

  # Read the agent's response from its pane output (raw text, not JSON)
  herdr agent read "$pane" --source recent-unwrapped --lines "$lines" 2>/dev/null
}

cmd_read() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project read <role> [--lines N]" >&2
    exit 1
  fi
  shift

  local lines="40"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lines) shift; lines="${1:-40}"; shift ;;
      *) shift ;;
    esac
  done

  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi

  herdr agent read "$pane" --source recent-unwrapped --lines "$lines" 2>/dev/null
}

cmd_roster() {
  local f
  f="$(ensure_state)"
  local name
  name="$(read_field "$f" "project")"
  local ws
  ws="$(read_field "$f" "workspace_id")"
  echo "Project: $name${ws:+ (workspace $ws)}"
  echo "─────────────────────────────────"
  jq -r '.agents | to_entries[] |
    "  \(.key)\t\(.value.pane_id)\t\(.value.session_id // "-")\t\(
      [
        (if .value.stopped then "stopped" else null end),
        (.value.current_ticket // null)
      ] | map(select(. != null)) | join(", ") | if . == "" then "-" else . end
    )"' "$f" | column -t -s $'\t'
}

cmd_status() {
  local f
  f="$(ensure_state)"
  local name
  name="$(read_field "$f" "project")"
  echo "Project: $name"
  echo "─────────────────────────────────"

  local roles
  roles=$(jq -r '.agents | keys[]' "$f")
  for role in $roles; do
    local pane
    pane="$(read_pane "$f" "$role")"
    local is_stopped
    is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
    local status
    if [[ "$is_stopped" == "true" ]]; then
      status="stopped"
    else
      status=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unreachable")
    fi
    local ticket_info
    ticket_info=$(jq -r --arg role "$role" '
      .agents[$role] | select(.tickets) |
      (.current_ticket // "") as $cur |
      [.tickets[] | if . == $cur then . else . + " ✓" end] | join(", ")' "$f" 2>/dev/null || true)
    if [[ -n "$ticket_info" ]]; then
      printf "  %-12s %-10s %-10s %s\n" "$role" "$pane" "$status" "$ticket_info"
    else
      printf "  %-12s %-10s %s\n" "$role" "$pane" "$status"
    fi
  done
}

cmd_info() {
  local f
  f="$(ensure_state)"
  jq '{project, workspace_id, agent_count: (.agents | length)}' "$f"
}

# Route a research request: researcher if registered and not stopped, otherwise
# orchestrator. Prints "<target> <pane>"; exits if neither is reachable or the
# target is mid-turn.
_research_target() {
  local f="$1"
  local target="researcher" target_pane
  target_pane="$(read_pane "$f" "researcher")"
  local researcher_stopped
  researcher_stopped=$(jq -r '.agents.researcher.stopped // false' "$f")
  if [[ -z "$target_pane" || "$researcher_stopped" == "true" ]]; then
    target="orchestrator"
    target_pane="$(read_pane "$f" "orchestrator")"
  fi
  if [[ -z "$target_pane" ]]; then
    echo "error: neither researcher nor orchestrator is registered" >&2
    exit 1
  fi
  # Only "working" is busy — "done" means the agent finished its turn and is
  # waiting for input, same as idle.
  local status
  status=$(herdr agent get "$target_pane" 2>/dev/null \
    | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unknown")
  if [[ "$status" == "working" ]]; then
    echo "error: $target is busy ($status) — try again later" >&2
    exit 1
  fi
  echo "$target $target_pane"
}

# "I need to know this" — the answer comes back to the caller.
cmd_research() {
  local question="$*"
  if [[ -z "$question" ]]; then
    echo "usage: project research <question>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local my_role
  my_role="$(resolve_caller "$f")"
  local routed target target_pane
  routed="$(_research_target "$f")" || exit 1
  read -r target target_pane <<<"$routed"

  local prefix="" callback=""
  if [[ -n "$my_role" ]]; then
    prefix="FROM($my_role): "
    callback=" Reply with: project prompt $my_role '<your answer>'"
  fi

  _prompt "$target_pane" "${prefix}RESEARCH — $question${callback}" >/dev/null
  log_signal "${my_role:-unknown}" "$target" "RESEARCH" "$question"
  echo "sent to $target${my_role:+ (reply will come back to $my_role)}"
}

# "I think we have a problem here" — hand it off; the researcher owns the
# outcome and acts on it instead of reporting back to the caller.
cmd_punt() {
  local problem="$*"
  if [[ -z "$problem" ]]; then
    echo "usage: project punt \"<problem>\"" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local my_role
  my_role="$(resolve_caller "$f")"
  local routed target target_pane
  routed="$(_research_target "$f")" || exit 1
  read -r target target_pane <<<"$routed"

  local from="${my_role:-an agent}"
  _prompt "$target_pane" "FROM($from): PUNT — $problem
You own this — $from is not waiting on an answer. Investigate, decide what should happen, and act (create a ticket, flag the orchestrator, or ask the user). Only message $from if the outcome changes their current ticket, and then in one line." >/dev/null
  log_signal "$from" "$target" "PUNT" "$problem"
  echo "punted to $target — it owns this now; you'll only hear back if it affects your ticket"
}

# "Problem found, go fix it" — spawn a throwaway worker on a scoped one-off fix.
# The brief goes to a file the new worker reads itself, so it never passes
# through the orchestrator's context. Not orchestrator-gated and outside the
# wave cap, but capped at SPINOFF_MAX concurrent spinoffs.
SPINOFF_MAX=2

cmd_spinoff() {
  local title="" notify=false repo_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --notify) notify=true; shift ;;
      --repo) repo_path="${2:-}"; shift 2 ;;
      *) title="${title:+$title }$1"; shift ;;
    esac
  done
  if [[ -z "$title" ]]; then
    echo "usage: project spinoff \"<title>\" [--notify] [--repo <path>] <<'EOF'" >&2
    echo "Problem: / Why it matters: / Evidence: / Fix: / Don't touch: / Done when:" >&2
    echo "EOF" >&2
    exit 1
  fi
  if [[ -t 0 ]]; then
    echo "error: pass the brief on stdin (heredoc) — the spinoff worker reads it from a file" >&2
    exit 1
  fi
  local brief
  brief="$(cat)"
  if [[ -z "${brief//[[:space:]]/}" ]]; then
    echo "error: empty brief — the spinoff worker has no other context" >&2
    exit 1
  fi

  local f
  f="$(ensure_state)"
  local caller
  caller="$(resolve_caller "$f")"
  local from="${caller:-user}"

  local active
  active=$(jq '[.agents[] | select(.stopped != true and .spinoff != null)] | length' "$f")
  if [[ "$active" -ge "$SPINOFF_MAX" ]]; then
    echo "error: $active spinoffs already running (max $SPINOFF_MAX) — use 'project punt' instead" >&2
    exit 1
  fi

  # Default to the main checkout of the repo we're in (works from a worktree too)
  if [[ -z "$repo_path" ]]; then
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
      echo "error: not in a git repo — pass --repo <path>" >&2
      exit 1
    }
    repo_path="$(dirname "$common")"
  fi

  local ws
  ws="$(read_field "$f" "workspace_id")"
  if [[ -z "$ws" ]]; then
    echo "error: project has no workspace_id — can't open a tab" >&2
    exit 1
  fi

  local name id
  name="$(cmd_next_worker)"
  id="spinoff-$name"
  if [[ -e "$repo_path/.worktrees/$id" ]] || git -C "$repo_path" show-ref --quiet "refs/heads/$id"; then
    id="$id-$(date +%s)"
  fi

  local project epic
  project="$(read_field "$f" "project")"
  epic="$(echo "$project" | tr '[:lower:]' '[:upper:]')"

  local brief_file
  brief_file="$(project_dir)/spinoffs/$id.md"
  mkdir -p "$(dirname "$brief_file")"
  {
    echo "# Spinoff: $title"
    echo
    echo "- Requested by: $from"
    echo "- Project: $epic"
    echo "- Worktree: .worktrees/$id (branch $id)"
    echo "- Notify requester on finish: $notify"
    echo
    echo "## Brief"
    echo
    echo "$brief"
  } > "$brief_file"

  git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
  git -C "$repo_path" worktree add ".worktrees/$id" -b "$id" origin/main --quiet || {
    echo "error: failed to create worktree .worktrees/$id in $repo_path" >&2
    exit 1
  }

  local tab_out pane_id
  tab_out=$(herdr tab create --workspace "$ws" --cwd "$repo_path" --label "$name — spinoff" \
    --env "HERDR_PROJECT=$project" --no-focus 2>&1) || {
    echo "error: failed to create tab" >&2
    echo "$tab_out" >&2
    exit 1
  }
  pane_id=$(echo "$tab_out" | jq -r '.result.root_pane.pane_id // empty')
  if [[ -z "$pane_id" ]]; then
    echo "error: tab create returned no pane ID" >&2
    echo "$tab_out" >&2
    exit 1
  fi

  local short_title="$title"
  [[ ${#short_title} -gt 40 ]] && short_title="${short_title:0:37}..."
  local attempts=0
  while ! herdr agent start "$name" --kind claude --pane "$pane_id" -- -n "$name — spinoff: $short_title" 2>/dev/null \
      | jq -e '.result' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 10 ]]; then
      echo "error: pane $pane_id not ready after 5s — failed to start spinoff agent" >&2
      exit 1
    fi
    sleep 0.5
  done

  # Pre-register so the worker shows up in roster/status/cleanup immediately.
  # The worker's own 'project register' keeps these fields.
  local tmp="${f}.tmp.$$"
  jq --arg role "$name" --arg pane "$pane_id" --arg id "$id" --arg from "$from" \
     --arg title "$title" --arg brief "$brief_file" --argjson notify "$notify" \
    '.agents[$role] = ((.agents[$role] // {}) | del(.stopped, .stopped_at)) + {
       pane_id: $pane, current_ticket: $id,
       tickets: (((.agents[$role].tickets) // []) + [$id] | unique),
       spinoff: {from: $from, title: $title, brief: $brief, notify: $notify}
     }' "$f" > "$tmp" && mv "$tmp" "$f"

  _prompt "$pane_id" "Spinoff worker $name for project $epic — a throwaway worker on one scoped fix.
Your role is '$name'. Your worktree is .worktrees/$id/ (branch $id).
Your brief: $brief_file

Run /project-worker and follow § Spinoff mode." >/dev/null

  log_signal "$from" "$name" "SPINOFF" "$title"
  local orch_pane
  orch_pane="$(read_pane "$f" "orchestrator")"
  if [[ -n "$orch_pane" && "$from" != "orchestrator" ]]; then
    _prompt "$orch_pane" "SPINOFF — $from spun off \"$title\" to $name. FYI only — it reports through the librarian like any worker; no action needed." >/dev/null 2>&1 || true
  fi

  echo "spun off to $name (pane $pane_id, worktree .worktrees/$id)"
  if $notify; then
    echo "you'll get one line back when it's finished"
  else
    echo "fire-and-forget — you won't hear back"
  fi
}

# Spinoff worker's last command: notify the requester (if asked), mark itself
# stopped, and close its own tab. Worktree is left for 'project cleanup'.
cmd_spinoff_done() {
  local outcome="$*"
  if [[ -z "$outcome" ]]; then
    echo "usage: project spinoff-done \"<one-line outcome>\"" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local me
  me="$(resolve_caller "$f")"
  if [[ -z "$me" ]] || [[ "$(jq -r --arg r "$me" '.agents[$r].spinoff // empty' "$f")" == "" ]]; then
    echo "error: spinoff-done is only for spinoff workers (caller: ${me:-unregistered})" >&2
    exit 1
  fi
  local from title notify
  from=$(jq -r --arg r "$me" '.agents[$r].spinoff.from' "$f")
  title=$(jq -r --arg r "$me" '.agents[$r].spinoff.title' "$f")
  notify=$(jq -r --arg r "$me" '.agents[$r].spinoff.notify' "$f")

  if [[ "$notify" == "true" ]]; then
    local from_pane from_stopped
    from_pane="$(read_pane "$f" "$from")"
    from_stopped=$(jq -r --arg r "$from" '.agents[$r].stopped // false' "$f")
    if [[ -n "$from_pane" && "$from_stopped" != "true" ]]; then
      _prompt "$from_pane" "FROM($me): SPINOFF_DONE — \"$title\": $outcome" >/dev/null 2>&1 || true
    fi
  fi
  log_signal "$me" "${from}" "SPINOFF_DONE" "$title: $outcome"

  cmd_stop "$me" >/dev/null
  echo "spinoff finished — closing this tab"
  local tab
  tab=$(herdr pane get "${HERDR_PANE_ID:-}" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)
  [[ -n "$tab" ]] && herdr tab close "$tab" >/dev/null 2>&1 || true
}

cmd_log() {
  local tail_n="50"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail) shift; tail_n="${1:-50}"; shift ;;
      *) shift ;;
    esac
  done
  local lf
  lf="$(signals_file)"
  if [[ ! -f "$lf" ]]; then
    echo "no signals logged yet" >&2
    return
  fi
  printf '%-20s %-14s %-14s %-10s %s\n' "TIMESTAMP" "SENDER" "RECEIVER" "TYPE" "PAYLOAD"
  echo "────────────────────────────────────────────────────────────────────────────────"
  tail -n "$tail_n" "$lf" | while IFS=$'\t' read -r ts sender receiver sig_type payload; do
    printf '%-20s %-14s %-14s %-10s %s\n' "$ts" "$sender" "$receiver" "$sig_type" "$payload"
  done
}

cmd_log_decision() {
  local decision_type="${1:-}"
  shift || true
  local payload="$*"
  if [[ -z "$decision_type" || -z "$payload" ]]; then
    echo "usage: project log-decision <decision-type> <payload>" >&2
    echo "  types: wave-transition, spawn, assign, reuse, escalate" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local caller
  caller="$(resolve_caller "$f")"
  log_signal "${caller:-orchestrator}" "-" "DECISION:${decision_type}" "$payload"
  echo "logged: DECISION:${decision_type}"
}

feedback_file() {
  echo "$(project_dir)/feedback.md"
}

classify_role() {
  local role="$1"
  case "$role" in
    orchestrator) echo "orchestrator" ;;
    librarian|dog-librarian) echo "librarian" ;;
    watcher|dog-watcher) echo "watcher" ;;
    researcher|dog-researcher) echo "researcher" ;;
    tester-*) echo "tester" ;;
    *) echo "worker" ;;
  esac
}

cmd_feedback() {
  local observation="$*"
  if [[ -z "$observation" ]]; then
    echo "usage: project feedback \"<observation>\"" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local caller
  caller="$(resolve_caller "$f")"
  if [[ -z "$caller" ]]; then
    echo "error: cannot identify caller — are you registered?" >&2
    exit 1
  fi
  local role_type
  role_type="$(classify_role "$caller")"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local fb
  fb="$(feedback_file)"
  printf '\n## %s — %s (%s)\n%s\n' "$ts" "$caller" "$role_type" "$observation" >> "$fb"
  log_signal "$caller" "-" "FEEDBACK" "$observation"
  echo "logged feedback to $fb"
}

cmd_recover() {
  local f
  f="$(ensure_state)"
  local name
  name="$(read_field "$f" "project")"
  local ws
  ws="$(read_field "$f" "workspace_id")"

  echo "Recovery report for project: $name"
  echo "═══════════════════════════════════════"
  echo ""

  # 1. Check workspace
  echo "## Workspace"
  if [[ -n "$ws" ]]; then
    local ws_status
    ws_status=$(herdr workspace get "$ws" 2>/dev/null | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true)
    if [[ -n "$ws_status" ]]; then
      echo "  workspace $ws: reachable"
    else
      echo "  workspace $ws: STALE (not found — needs new workspace)"
    fi
  else
    echo "  no workspace ID recorded"
  fi
  echo ""

  # 2. Check each agent: pane reachability, session availability
  echo "## Agents"
  printf '  %-16s %-10s %-10s %-10s %-12s %s\n' "ROLE" "PANE" "PANE_OK" "SESSION" "STATE" "TICKET"
  echo "  ────────────────────────────────────────────────────────────────────────────"

  local roles
  roles=$(jq -r '.agents | keys[]' "$f")
  local resumable_count=0
  local stale_count=0

  for role in $roles; do
    local pane session is_stopped ticket
    pane="$(read_pane "$f" "$role")"
    session="$(read_session "$f" "$role")"
    is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
    ticket=$(jq -r --arg role "$role" '.agents[$role].current_ticket // "-"' "$f")

    local pane_ok="?"
    local state_label

    if [[ "$is_stopped" == "true" ]]; then
      state_label="stopped"
      pane_ok="-"
    else
      # Check if the pane is still reachable
      local agent_state
      agent_state=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
      if [[ -n "$agent_state" ]]; then
        pane_ok="yes"
        state_label="$agent_state"
      else
        pane_ok="STALE"
        stale_count=$((stale_count + 1))
        if [[ -n "$session" ]]; then
          state_label="resumable"
          resumable_count=$((resumable_count + 1))
        else
          state_label="lost"
        fi
      fi
    fi

    local session_short
    if [[ -n "$session" ]]; then
      session_short="${session:0:8}…"
    else
      session_short="-"
    fi

    printf '  %-16s %-10s %-10s %-10s %-12s %s\n' "$role" "$pane" "$pane_ok" "$session_short" "$state_label" "$ticket"
  done
  echo ""

  # 3. Worktree status
  echo "## Worktrees"
  local repo_root
  repo_root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||' || true)
  if [[ -z "$repo_root" ]]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  fi

  if [[ -d "$repo_root/.worktrees" ]]; then
    for wt in "$repo_root"/.worktrees/*/; do
      local wt_name
      wt_name=$(basename "$wt")
      local branch
      branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "detached/missing")
      local ahead
      ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
      local dirty=""
      if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        dirty=" (dirty)"
      fi
      echo "  $wt_name: branch=$branch, $ahead commits ahead of main${dirty}"
    done
  else
    echo "  no .worktrees/ directory found"
  fi
  echo ""

  # 4. Recent signal activity (last 10 entries by timestamp lines)
  echo "## Last signals"
  local lf
  lf="$(signals_file)"
  if [[ -f "$lf" ]]; then
    printf '  %-20s %-14s %-14s %-10s %s\n' "TIMESTAMP" "SENDER" "RECEIVER" "TYPE" "PAYLOAD"
    # Entries start with a timestamp (YYYY-MM-DD); extract only those lines
    grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "$lf" | tail -n 10 | while IFS=$'\t' read -r ts sender receiver sig_type payload; do
      # Truncate long payloads to first line
      payload="${payload%%$'\n'*}"
      if [[ ${#payload} -gt 80 ]]; then
        payload="${payload:0:77}..."
      fi
      printf '  %-20s %-14s %-14s %-10s %s\n' "$ts" "$sender" "$receiver" "$sig_type" "$payload"
    done
  else
    echo "  no signal log found"
  fi
  echo ""

  # 5. Recovery summary
  echo "## Summary"
  if [[ $stale_count -gt 0 ]]; then
    echo "  $stale_count agent(s) have stale panes (restart/terminal closed)."
    if [[ $resumable_count -gt 0 ]]; then
      echo "  $resumable_count of those have session IDs and can be resumed with --resume."
    fi
    echo ""
    echo "  Recovery steps:"
    echo "    1. project register orchestrator"
    echo "    2. For each resumable agent, create a new tab and resume:"
    echo "       herdr tab create --workspace <ws> --cwd \"\$PWD\" --label \"<role>\" --env HERDR_PROJECT=$name --no-focus"
    echo "       herdr agent start <role> --kind claude --pane <new-pane> -- --resume <session-id> -n <role>"
    echo "    3. Ask the librarian for ticket status once it's back"
  else
    echo "  All active agents are reachable. No recovery needed."
  fi
}

cmd_checkin() {
  local since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) shift; since="${1:-}"; shift ;;
      *) shift ;;
    esac
  done

  local f
  f="$(ensure_state)"
  local name
  name="$(read_field "$f" "project")"

  # Determine cutoff: explicit --since > last check-in timestamp > beginning of time
  local cutoff=""
  if [[ -n "$since" ]]; then
    cutoff="$since"
  else
    cutoff=$(jq -r '.last_checkin // empty' "$f")
  fi

  # Update last check-in timestamp
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp="${f}.tmp.$$"
  jq --arg ts "$now" '.last_checkin = $ts' "$f" > "$tmp" && mv "$tmp" "$f"

  echo "═══════════════════════════════════════════════════"
  echo "  Project check-in: $name"
  if [[ -n "$cutoff" ]]; then
    echo "  Since: $cutoff"
  else
    echo "  Since: project start (first check-in)"
  fi
  echo "═══════════════════════════════════════════════════"
  echo

  # --- Agent status ---
  echo "▸ Agent Status"
  echo "────────────────────────────────────────────────"
  local roles
  roles=$(jq -r '.agents | keys[]' "$f")
  local idle_agents=""
  local blocked_agents=""
  local working_agents=""
  for role in $roles; do
    local pane
    pane="$(read_pane "$f" "$role")"
    local is_stopped
    is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
    local ticket
    ticket=$(jq -r --arg role "$role" '.agents[$role].current_ticket // "-"' "$f")
    local status
    if [[ "$is_stopped" == "true" ]]; then
      status="stopped"
    else
      status=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unreachable")
    fi
    printf "  %-16s %-12s ticket: %s\n" "$role" "[$status]" "$ticket"
    case "$status" in
      idle|done) idle_agents="${idle_agents:+$idle_agents }$role" ;;
      working)   working_agents="${working_agents:+$working_agents }$role" ;;
    esac
  done
  echo

  # --- Signal activity ---
  echo "▸ Recent Activity"
  echo "────────────────────────────────────────────────"
  local lf
  lf="$(signals_file)"
  if [[ -f "$lf" ]]; then
    local signal_count=0
    local blocked_signals=""
    local done_signals=""
    local scope_signals=""
    while IFS=$'\t' read -r ts sender receiver sig_type payload; do
      # Skip malformed lines (no valid timestamp)
      [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || continue
      if [[ -n "$cutoff" ]] && [[ "$ts" < "$cutoff" ]]; then
        continue
      fi
      signal_count=$((signal_count + 1))
      case "$sig_type" in
        BLOCKED) blocked_signals="${blocked_signals}  ⚠ $sender: $payload\n" ; blocked_agents="${blocked_agents:+$blocked_agents }$sender" ;;
        DONE|COMPLETE) done_signals="${done_signals}  ✓ $sender: $payload\n" ;;
        SCOPE) scope_signals="${scope_signals}  ↗ $sender: $payload\n" ;;
      esac
    done < "$lf"

    if [[ $signal_count -eq 0 ]]; then
      echo "  No signals since last check-in."
    else
      echo "  $signal_count signal(s) since last check-in."
      if [[ -n "$done_signals" ]]; then
        echo
        echo "  Completed:"
        printf '%b' "$done_signals"
      fi
      if [[ -n "$blocked_signals" ]]; then
        echo
        echo "  Blocked:"
        printf '%b' "$blocked_signals"
      fi
      if [[ -n "$scope_signals" ]]; then
        echo
        echo "  Scope changes:"
        printf '%b' "$scope_signals"
      fi
    fi
  else
    echo "  No signal log found."
  fi
  echo

  # --- Feedback ---
  local proj_dir="$PROJECTS_DIR/$(resolve_project)"
  local fb="$proj_dir/feedback.md"
  if [[ -f "$fb" ]]; then
    echo "▸ Feedback"
    echo "────────────────────────────────────────────────"
    if [[ -n "$cutoff" ]]; then
      local fb_count=0
      local fb_entries=""
      local current_header="" current_body=""
      while IFS= read -r line; do
        if [[ "$line" =~ ^##\  ]]; then
          if [[ -n "$current_header" && -n "$current_body" ]]; then
            local header_ts
            header_ts=$(echo "$current_header" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' || true)
            if [[ -z "$header_ts" || "$header_ts" > "$cutoff" || "$header_ts" == "$cutoff" ]]; then
              fb_entries="${fb_entries}  ${current_header}\n    ${current_body}\n"
              fb_count=$((fb_count + 1))
            fi
          fi
          current_header="${line## }"
          current_body=""
        elif [[ -n "$current_header" && -n "$line" ]]; then
          current_body="$line"
        fi
      done < "$fb"
      # Flush last entry
      if [[ -n "$current_header" && -n "$current_body" ]]; then
        local header_ts
        header_ts=$(echo "$current_header" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' || true)
        if [[ -z "$header_ts" || "$header_ts" > "$cutoff" || "$header_ts" == "$cutoff" ]]; then
          fb_entries="${fb_entries}  ${current_header}\n    ${current_body}\n"
          fb_count=$((fb_count + 1))
        fi
      fi
      if [[ $fb_count -eq 0 ]]; then
        echo "  No new feedback since last check-in."
      else
        echo "  $fb_count feedback entry/entries:"
        printf '%b' "$fb_entries"
      fi
    else
      local total
      total=$(grep -c '^## ' "$fb" 2>/dev/null || echo "0")
      echo "  $total total feedback entries. Use --since to filter."
    fi
    echo
  fi

  # --- Recommendations ---
  echo "▸ Recommendations"
  echo "────────────────────────────────────────────────"
  local has_rec=false

  # Deduplicate blocked agents
  local unique_blocked=""
  if [[ -n "$blocked_agents" ]]; then
    unique_blocked=$(echo "$blocked_agents" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  fi

  if [[ -n "$unique_blocked" ]]; then
    has_rec=true
    echo "  ⚠ Blocked agents need attention: $unique_blocked"
  fi

  if [[ -n "$idle_agents" ]]; then
    for agent in $idle_agents; do
      local agent_ticket
      agent_ticket=$(jq -r --arg role "$agent" '.agents[$role].current_ticket // ""' "$f")
      local agent_stopped
      agent_stopped=$(jq -r --arg role "$agent" '.agents[$role].stopped // false' "$f")
      if [[ "$agent_stopped" == "true" ]]; then
        continue
      fi
      has_rec=true
      if [[ -n "$agent_ticket" && "$agent_ticket" != "-" ]]; then
        echo "  ⏸ $agent is idle but assigned to $agent_ticket — may need a kick or exit"
      else
        echo "  ⏹ $agent is idle with no ticket — consider stopping it"
      fi
    done
  fi

  if [[ "$has_rec" == false ]]; then
    echo "  Nothing needs immediate attention."
  fi
  echo
}

cmd_observe() {
  local f
  f="$(ensure_state)"
  local name
  name="$(read_field "$f" "project")"
  local ws
  ws="$(read_field "$f" "workspace_id")"

  echo "═══════════════════════════════════════════════════"
  echo "  $name${ws:+ [$ws]}"
  echo "═══════════════════════════════════════════════════"
  echo

  # --- Collect agent data (one herdr call per live agent, cached in temp file) ---
  local roles
  roles=$(jq -r '.agents | keys[]' "$f")

  local cache_file="${f}.observe.$$"
  trap 'rm -f "$cache_file"' RETURN

  for role in $roles; do
    local pane is_stopped ticket status
    pane="$(read_pane "$f" "$role")"
    is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
    ticket=$(jq -r --arg role "$role" '.agents[$role].current_ticket // ""' "$f")

    if [[ "$is_stopped" == "true" ]]; then
      status="stopped"
    else
      status=$(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unreachable")
    fi
    printf '%s\t%s\t%s\n' "$role" "$status" "$ticket" >> "$cache_file"
  done

  # --- Agents ---
  echo "▸ Agents"
  echo "────────────────────────────────────────────────────"
  local working_count=0 idle_count=0 stopped_count=0

  while IFS=$'\t' read -r role status ticket; do
    case "$status" in
      working) working_count=$((working_count + 1)) ;;
      idle|done) idle_count=$((idle_count + 1)) ;;
      stopped) stopped_count=$((stopped_count + 1)) ;;
    esac

    local icon
    case "$status" in
      working)     icon="●" ;;
      idle|done)   icon="○" ;;
      stopped)     icon="□" ;;
      unreachable) icon="✗" ;;
      *)           icon="?" ;;
    esac

    local ticket_str=""
    if [[ -n "$ticket" && "$ticket" != "-" ]]; then
      ticket_str="  $ticket"
    fi

    printf "  %s %-18s %-12s%s\n" "$icon" "$role" "$status" "$ticket_str"
  done < "$cache_file"

  echo
  printf "  %d working · %d idle · %d stopped\n" "$working_count" "$idle_count" "$stopped_count"
  echo

  # --- Recent signals (last 15) ---
  echo "▸ Recent Signals"
  echo "────────────────────────────────────────────────────"
  local lf
  lf="$(signals_file)"
  if [[ -f "$lf" ]]; then
    # Show only substantive signals (skip READY, ASSIGN, ASK which are routine)
    local shown=0
    local blocked_entries=""
    tac "$lf" | while IFS=$'\t' read -r ts sender receiver sig_type payload; do
      [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || continue
      case "$sig_type" in
        READY|ASSIGN|ASK|"") continue ;;
      esac
      [[ $shown -ge 15 ]] && break
      shown=$((shown + 1))

      local time_part="${ts#*T}"
      time_part="${time_part%Z}"

      # Truncate payload
      payload="${payload%%$'\n'*}"
      if [[ ${#payload} -gt 60 ]]; then
        payload="${payload:0:57}..."
      fi

      local sig_icon
      case "$sig_type" in
        DONE|COMPLETE) sig_icon="✓" ;;
        BLOCKED)       sig_icon="⚠" ;;
        STARTING)      sig_icon="→" ;;
        SCOPE)         sig_icon="↗" ;;
        FEEDBACK)      sig_icon="✎" ;;
        RESEARCH)      sig_icon="◇" ;;
        SPINOFF|SPINOFF_DONE) sig_icon="⤳" ;;
        STOP)          sig_icon="□" ;;
        *)             sig_icon="·" ;;
      esac

      printf "  %s %s  %-10s %s→%s  %s\n" "$sig_icon" "$time_part" "$sig_type" "$sender" "$receiver" "$payload"
    done
  else
    echo "  No signal log."
  fi
  echo

  # --- Blockers ---
  echo "▸ Blockers"
  echo "────────────────────────────────────────────────────"
  local has_blockers=false
  if [[ -f "$lf" ]]; then
    # Find unresolved BLOCKED signals: a BLOCKED not followed by DONE/STARTING from same sender
    local blocked_senders=""
    while IFS=$'\t' read -r ts sender receiver sig_type payload; do
      [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || continue
      case "$sig_type" in
        BLOCKED)
          blocked_senders="${blocked_senders:+$blocked_senders }$sender"
          ;;
        DONE|COMPLETE|STARTING)
          # Remove this sender from blocked list
          blocked_senders=$(echo "$blocked_senders" | tr ' ' '\n' | grep -v "^${sender}$" | tr '\n' ' ')
          ;;
      esac
    done < "$lf"

    blocked_senders=$(echo "$blocked_senders" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
    if [[ -n "$blocked_senders" ]]; then
      for agent in $blocked_senders; do
        has_blockers=true
        # Find the last BLOCKED message from this agent
        local block_msg
        block_msg=$(grep -E "	${agent}	.*	BLOCKED	" "$lf" | tail -1 | cut -f5)
        block_msg="${block_msg:0:80}"
        echo "  ⚠ $agent: $block_msg"
      done
    fi
  fi

  # Check for stalled agents (idle with a ticket assigned, not stopped)
  while IFS=$'\t' read -r role status ticket; do
    [[ "$status" == "stopped" ]] && continue
    [[ -z "$ticket" || "$ticket" == "-" ]] && continue

    if [[ "$status" == "idle" || "$status" == "done" ]]; then
      has_blockers=true
      echo "  ⏸ $role idle on $ticket — may be stalled or finished"
    elif [[ "$status" == "unreachable" ]]; then
      has_blockers=true
      local pane
      pane="$(read_pane "$f" "$role")"
      echo "  ✗ $role unreachable (pane $pane) — assigned to $ticket"
    fi
  done < "$cache_file"

  if [[ "$has_blockers" == false ]]; then
    echo "  None."
  fi
  echo

  # --- Worktrees ---
  echo "▸ Worktrees"
  echo "────────────────────────────────────────────────────"
  local repo_root
  repo_root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||' || true)
  if [[ -z "$repo_root" ]]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  fi

  if [[ -d "$repo_root/.worktrees" ]]; then
    for wt in "$repo_root"/.worktrees/*/; do
      [[ -d "$wt" ]] || continue
      local wt_name branch ahead dirty_flag
      wt_name=$(basename "$wt")
      branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "?")
      ahead=$(git -C "$wt" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
      dirty_flag=""
      if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
        dirty_flag=" ✎"
      fi
      printf "  %-16s %s commits%s\n" "$wt_name" "$ahead" "$dirty_flag"
    done
  else
    echo "  No worktrees."
  fi
  echo
}

cmd_resolve() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project resolve <role>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    exit 1
  fi
  echo "$pane"
}

cmd_session() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project session <role>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local sid
  sid="$(read_session "$f" "$role")"
  if [[ -z "$sid" ]]; then
    exit 1
  fi
  echo "$sid"
}

cmd_file() {
  state_file
}

cmd_dir() {
  project_dir
}

# Shut down a predecessor agent after a DISTILL takeover. Run by the NEW agent
# once it has registered and finished ramping up (asked the old pane anything it
# needed). Closes the old agent's tab; its session ID is already preserved in
# previous_sessions by register.
# --- Pause / reset ---
# Ask every live agent except the caller to write its unreported state to
# $(project dir)/<role>.final.md, wait for all of them in parallel, then stop
# them (session preserved) and close their panes. An agent that times out or
# hits a permission prompt is left running so nothing is lost; re-running skips
# agents that are already stopped, so a retry only touches the stragglers.
DUMP_TIMEOUT_DEFAULT=300

# Usage: _dump_agents <verb> <timeout-secs>. Returns 1 if any agent was left running.
_dump_agents() {
  local verb="$1" timeout="$2"
  local f
  f="$(ensure_state)"
  local dir
  dir="$(project_dir)"
  local caller
  caller="$(resolve_caller "$f")"

  local targets=() role pane
  while IFS=$'\t' read -r role pane; do
    [[ -z "$role" || "$pane" == "${HERDR_PANE_ID:-}" ]] && continue
    targets+=("$role")
  done < <(jq -r '.agents | to_entries[] | select(.value.stopped != true) | [.key, .value.pane_id // ""] | @tsv' "$f")

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "no live agents to dump"
    return 0
  fi

  local tmpd stamp
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/project-dump.XXXXXX")"
  stamp="$(date +%Y%m%dT%H%M%S)"
  echo "dumping ${#targets[@]} agent(s): ${targets[*]} (timeout ${timeout}s)"

  for role in "${targets[@]}"; do
    pane="$(read_pane "$f" "$role")"
    local final="$dir/$role.final.md"
    # Archive a previous dump so "file exists" means "written this time"
    [[ -f "$final" ]] && mv "$final" "$dir/$role.final.$stamp.md"
    if [[ -z "$pane" ]] || ! herdr agent get "$pane" >/dev/null 2>&1; then
      echo "gone" > "$tmpd/$role.status"
      continue
    fi
    local msg="DUMP — the project is $verb. This session will be stopped once you go idle.
If you hold state that isn't already durable (tracker, PR, pushed commits, project dir) — in-flight work, decisions not written down, open questions, something you were about to tell another agent — commit and push any WIP, then write it to $final. Keep it short; link instead of restating.
If there's nothing, write no file.
Don't signal or prompt other agents. Reply with one line: 'dumped' or 'nothing to dump'."
    log_signal "${caller:-user}" "$role" "DUMP" "project $verb"
    (
      if out=$(_prompt "$pane" "$msg" --wait --until idle --until done --timeout $((timeout * 1000)) 2>&1); then
        echo "ok" > "$tmpd/$role.status"
      elif [[ "$out" == *agent_blocked* ]]; then
        echo "blocked" > "$tmpd/$role.status"
      elif [[ "$out" == *timeout* ]]; then
        echo "timeout" > "$tmpd/$role.status"
      else
        echo "error: ${out%%$'\n'*}" > "$tmpd/$role.status"
      fi
    ) &
  done
  wait

  local left=0 status result
  printf '  %-16s %s\n' "ROLE" "RESULT"
  for role in "${targets[@]}"; do
    status="$(cat "$tmpd/$role.status" 2>/dev/null || echo "error: no result")"
    pane="$(read_pane "$f" "$role")"
    local final="$dir/$role.final.md"
    case "$status" in
      ok|gone)
        if [[ -f "$final" ]]; then
          result="dumped → $final"
        elif [[ "$status" == "gone" ]]; then
          result="pane already gone — marked stopped"
        else
          result="nothing to dump"
        fi
        cmd_stop "$role" >/dev/null
        [[ "$status" == "ok" ]] && herdr pane close "$pane" >/dev/null 2>&1 || true
        [[ "$status" == "ok" ]] && result="$result (stopped, pane closed)"
        ;;
      blocked) result="LEFT RUNNING — blocked on a prompt in $pane; answer it, then re-run"; left=$((left + 1)) ;;
      timeout) result="LEFT RUNNING — still working after ${timeout}s; re-run to retry"; left=$((left + 1)) ;;
      *)       result="LEFT RUNNING — $status"; left=$((left + 1)) ;;
    esac
    printf '  %-16s %s\n' "$role" "$result"
  done
  rm -rf "$tmpd"
  [[ $left -eq 0 ]]
}

cmd_dump() {
  local timeout="$DUMP_TIMEOUT_DEFAULT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      *) echo "usage: project dump [--timeout SECS]" >&2; exit 1 ;;
    esac
  done
  local f
  f="$(ensure_state)"
  local caller
  caller="$(resolve_caller "$f")"
  local rc=0
  _dump_agents "pausing" "$timeout" || rc=1
  echo ""
  if [[ $rc -ne 0 ]]; then
    echo "some agents were left running — re-run 'project dump' once they're idle"
  fi
  if [[ -n "$caller" ]]; then
    echo "you ($caller) are still running: write your own unreported state to $(project_dir)/$caller.final.md"
  fi
  echo "paused. To pick it up later: project recover (sessions are preserved and resumable)"
  return $rc
}

cmd_reset() {
  local timeout="$DUMP_TIMEOUT_DEFAULT" handoff=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      --handoff) handoff=true; shift ;;
      *) echo "usage: project reset [--timeout SECS] | project reset --handoff" >&2; exit 1 ;;
    esac
  done
  local f
  f="$(ensure_state)"
  local caller
  caller="$(resolve_caller "$f")"
  local name
  name="$(read_field "$f" "project")"
  local reset_file
  reset_file="$(project_dir)/orchestrator.reset.md"

  # Only the orchestrator can write the master distill — anyone else hands the
  # request to it rather than tearing the project down from outside.
  if [[ "$caller" != "orchestrator" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    local orch_stopped
    orch_stopped=$(jq -r '.agents.orchestrator.stopped // false' "$f")
    if $handoff || [[ -z "$orch_pane" || "$orch_stopped" == "true" ]] || ! herdr agent get "$orch_pane" >/dev/null 2>&1; then
      echo "error: project reset runs in the orchestrator's pane, and no live orchestrator was found" >&2
      echo "  to pause everything instead: project --project $name dump" >&2
      exit 1
    fi
    _prompt "$orch_pane" "RESET — ${caller:-the user} asked for a full project reset. Follow the skill's § Resetting the project: run 'project reset'." >/dev/null
    log_signal "${caller:-user}" "orchestrator" "RESET" "reset requested"
    echo "asked the orchestrator ($orch_pane) to run the reset"
    return 0
  fi

  if $handoff; then
    _reset_handoff "$f" "$name" "$reset_file"
    return
  fi

  local rc=0
  _dump_agents "resetting" "$timeout" || rc=1

  [[ -f "$reset_file" ]] && mv "$reset_file" "${reset_file%.md}.$(date +%Y%m%dT%H%M%S).md"
  {
    echo "# Project reset — $name"
    echo ""
    echo "Master distill from the outgoing orchestrator ($(date -u +%Y-%m-%dT%H:%MZ)). The successor boots from this file."
    echo "Keep it short: link PRs, tickets, and files instead of restating them. Delete a section rather than leave TODO."
    echo ""
    echo "## Shipped"
    echo "TODO — merged PRs / closed tickets, one line each."
    echo ""
    echo "## In flight"
    echo "TODO — open PRs, pushed branches, half-done tickets: state and next step for each."
    echo ""
    echo "## Decisions"
    echo "TODO — decisions that shaped the work and must survive the reset, with the why. Skip what the tracker already records."
    echo ""
    echo "## Remaining work"
    echo "TODO — tickets not started, in dependency order, plus anything the tracker doesn't show."
    echo ""
    echo "## Waiting on the user"
    echo "TODO — open questions, reviews, approvals."
    echo ""
    echo "## Notes for the successor"
    echo "TODO — what to do first, what to avoid, what wasted time."
    echo ""
    echo "## Agent dumps"
    echo "Read one only when you touch that agent's area."
    # Current dumps only — archived ones are <role>.final.<timestamp>.md
    local d any=false
    for d in "$(project_dir)"/*.final.md; do
      [[ -f "$d" ]] || continue
      echo "- $d"; any=true
    done
    $any || echo "- (none — no agent had unreported state)"
  } > "$reset_file"

  echo ""
  if [[ $rc -ne 0 ]]; then
    echo "some agents were left running — resolve them and re-run 'project reset' before handing off"
    echo "(re-running only prompts the agents still live; it re-creates the template)"
    return 1
  fi
  echo "next: fill in $reset_file (every TODO), then run: project reset --handoff"
}

_reset_handoff() {
  local f="$1" name="$2" reset_file="$3"
  if [[ ! -f "$reset_file" ]]; then
    echo "error: no $reset_file — run 'project reset' first" >&2
    exit 1
  fi
  if grep -q '^TODO' "$reset_file"; then
    echo "error: $reset_file still has TODO sections — fill them in or delete them" >&2
    exit 1
  fi
  local live
  live=$(jq -r '[.agents | to_entries[] | select(.key != "orchestrator" and .value.stopped != true) | .key] | join(" ")' "$f")
  if [[ -n "$live" ]]; then
    echo "error: agents still live: $live — run 'project reset' again to dump and stop them" >&2
    exit 1
  fi
  local ws
  ws="$(read_field "$f" "workspace_id")"
  if [[ -z "$ws" ]]; then
    echo "error: project has no workspace_id — can't open a tab" >&2
    exit 1
  fi
  local old_pane="${HERDR_PANE_ID:-}"
  local epic
  epic="$(echo "$name" | tr '[:lower:]' '[:upper:]')"

  local tab_out pane_id
  tab_out=$(herdr tab create --workspace "$ws" --cwd "$PWD" --label "orchestrator" \
    --env "HERDR_PROJECT=$name" --no-focus 2>&1) || {
    echo "error: failed to create tab" >&2
    echo "$tab_out" >&2
    exit 1
  }
  pane_id=$(echo "$tab_out" | jq -r '.result.root_pane.pane_id // empty')
  if [[ -z "$pane_id" ]]; then
    echo "error: tab create returned no pane ID" >&2
    echo "$tab_out" >&2
    exit 1
  fi
  local attempts=0
  while ! herdr agent start orchestrator --kind claude --pane "$pane_id" -- -n orchestrator 2>/dev/null \
      | jq -e '.result' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 10 ]]; then
      echo "error: pane $pane_id not ready after 5s — failed to start successor" >&2
      exit 1
    fi
    sleep 0.5
  done

  _prompt "$pane_id" "/start-project $epic

You are a fresh orchestrator taking over after a project RESET. Before Step 1:
1. Run: project register orchestrator
2. Read $reset_file — your predecessor's master distill. Trust it; check an item against the tracker only when you act on it. Read the agent dump files it lists only when you touch that area.
3. Your predecessor is still live in pane $old_pane. If anything is unclear, ask it: herdr agent prompt $old_pane '<question>' --wait, then herdr agent read $old_pane. When you have no more questions, run: project retire $old_pane
4. Every other agent from the previous run is stopped. Don't resume their sessions — spawn fresh agents as the skill describes, and give the new librarian the path to librarian.final.md if one is listed.
Then continue from Step 1, building the plan from the tracker plus the distill." >/dev/null

  log_signal "orchestrator" "orchestrator" "RESET" "successor spawned in $pane_id"
  echo "successor orchestrator started in $pane_id — it will retire this pane ($old_pane) when it's done asking questions"
}

cmd_retire() {
  local old_pane="${1:-}"
  if [[ -z "$old_pane" ]]; then
    echo "usage: project retire <old-pane-id>" >&2
    exit 1
  fi
  if [[ "$old_pane" == "${HERDR_PANE_ID:-}" ]]; then
    echo "error: refusing to retire your own pane" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local owner
  owner=$(jq -r --arg p "$old_pane" '.agents | to_entries[] | select(.value.pane_id == $p) | .key' "$f")
  if [[ -n "$owner" ]]; then
    echo "error: $old_pane is still registered to '$owner' — register the new agent first" >&2
    exit 1
  fi
  local tab
  tab=$(herdr pane get "$old_pane" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)
  if [[ -z "$tab" ]]; then
    echo "pane $old_pane not found — already closed"
    return 0
  fi
  herdr tab close "$tab" >/dev/null
  local caller
  caller="$(resolve_caller "$f")"
  log_signal "${caller:-unknown}" "-" "SHUTDOWN" "retired predecessor pane $old_pane"
  echo "retired: $old_pane (tab $tab closed)"
}

cmd_cleanup() {
  local dry_run=false
  local repo_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      --repo) shift; repo_path="${1:-}"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -z "$repo_path" ]]; then
    # Use git-common-dir to find the main repo (works from inside a worktree)
    local git_common
    git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$git_common" && "$git_common" == */.git ]]; then
      repo_path="${git_common%/.git}"
    else
      repo_path="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -z "$repo_path" ]]; then
      echo "error: not in a git repo and --repo not specified" >&2
      exit 1
    fi
  fi

  local worktrees_dir="$repo_path/.worktrees"
  if [[ ! -d "$worktrees_dir" ]]; then
    echo "no .worktrees/ directory at $repo_path"
    return
  fi

  local f
  f="$(ensure_state)"

  # Collect active ticket assignments (non-stopped agents with current_ticket)
  local active_tickets
  active_tickets=$(jq -r '
    .agents | to_entries[]
    | select(.value.stopped != true)
    | .value.current_ticket // empty
  ' "$f" | tr '[:upper:]' '[:lower:]')

  local orphan_count=0
  local kept_count=0

  echo "Scanning $worktrees_dir..."
  echo "─────────────────────────────────"

  for dir in "$worktrees_dir"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"

    if echo "$active_tickets" | grep -qx "$name"; then
      printf "  %-20s active\n" "$name"
      kept_count=$((kept_count + 1))
    else
      printf "  %-20s orphan\n" "$name"
      orphan_count=$((orphan_count + 1))
      if ! $dry_run; then
        git -C "$repo_path" worktree remove ".worktrees/$name" --force 2>/dev/null \
          || rm -rf "$dir"
        echo "    → removed"
      fi
    fi
  done

  # Also prune git's worktree bookkeeping for any that point to missing dirs
  if ! $dry_run; then
    git -C "$repo_path" worktree prune 2>/dev/null || true
  fi

  echo "─────────────────────────────────"
  echo "$kept_count active, $orphan_count orphan$(if $dry_run; then echo ' (dry run — nothing removed)'; fi)"
}

# Parse global flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      shift
      export HERDR_PROJECT="${1:-}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
done

# Sessions resumed after a reboot come back without the --env flags their tab
# was created with, but HERDR_PANE_ID/HERDR_WORKSPACE_ID are still set — recover
# the project name from the state file that claims this pane or workspace.
if [[ -z "${HERDR_PROJECT:-}" ]]; then
  _recovered="$(_project_from_state_files)"
  [[ -n "$_recovered" ]] && export HERDR_PROJECT="$_recovered"
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  start)      cmd_start "$@" ;;
  init)       cmd_init "$@" ;;
  register)    cmd_register "$@" ;;
  stop)        cmd_stop "$@" ;;
  next-worker) cmd_next_worker ;;
  assign)      cmd_assign "$@" ;;
  prompt)     cmd_prompt "$@" ;;
  ask)        cmd_ask "$@" ;;
  read)       cmd_read "$@" ;;
  roster)     cmd_roster ;;
  status)     cmd_status ;;
  info)       cmd_info ;;
  research)   cmd_research "$@" ;;
  punt)       cmd_punt "$@" ;;
  spinoff)    cmd_spinoff "$@" ;;
  spinoff-done) cmd_spinoff_done "$@" ;;
  resolve)    cmd_resolve "$@" ;;
  session)    cmd_session "$@" ;;
  file)       cmd_file ;;
  dir)        cmd_dir ;;
  retire)     cmd_retire "$@" ;;
  dump)       cmd_dump "$@" ;;
  reset)      cmd_reset "$@" ;;
  log)        cmd_log "$@" ;;
  log-decision) cmd_log_decision "$@" ;;
  feedback)   cmd_feedback "$@" ;;
  cleanup)     cmd_cleanup "$@" ;;
  recover)    cmd_recover "$@" ;;
  check-in)   cmd_checkin "$@" ;;
  observe)    cmd_observe ;;
  *)          usage ;;
esac
