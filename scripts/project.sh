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

# NATO phonetic alphabet for worker names
WORKER_NAMES=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu)

usage() {
  cat <<'EOF'
Usage: project <command> [args...]

Commands:
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
  resolve <role>                   Print the pane ID for a role (for scripting)
  session <role>                   Print the session ID for a role
  file                             Print the path to the state file
  log [--tail N]                   Print the signal log (default: last 50 entries)
  log-decision <decision-type> <payload>
                                   Log an orchestrator decision (wave transition, spawn, etc.)
  check-in [--since <timestamp>]   Developer summary: what happened, what needs you

Project name is auto-detected from $HERDR_PROJECT.
Override with --project <name>.
EOF
  exit 1
}

# Resolve project name: explicit flag > env var
resolve_project() {
  local name="${HERDR_PROJECT:-}"
  if [[ -z "$name" ]]; then
    echo "error: no project name — set HERDR_PROJECT or pass --project <name>" >&2
    exit 1
  fi
  echo "$name"
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

  local tmp="${f}.tmp.$$"
  jq --arg role "$role" --arg pane "$pane_id" --arg sid "$session_id" \
    '.agents[$role] = (.agents[$role] // {}) + {pane_id: $pane, session_id: $sid, registered_at: (now | todate)} | del(.agents[$role].stopped) | del(.agents[$role].stopped_at)' \
    "$f" > "$tmp" && mv "$tmp" "$f"

  # Signal the orchestrator that this agent is ready (unless we ARE the orchestrator)
  if [[ "$role" != "orchestrator" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      herdr agent prompt "$orch_pane" "READY — $role" 2>/dev/null || true
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
    '.agents[$role].stopped = true | if $sid != "" then .agents[$role].session_id = $sid else . end | .agents[$role].stopped_at = (now | todate)' \
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
      herdr agent prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original message: $message" 2>/dev/null || true
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
  esac

  log_signal "${caller:-unknown}" "$role" "$signal_type" "$message"

  # Prefix with sender so the recipient can distinguish cross-agent messages from direct instructions
  if [[ -n "$caller" ]]; then
    message="FROM($caller): $message"
  fi

  # shellcheck disable=SC2086
  herdr agent prompt "$pane" "$message" $wait_flag $timeout_flag
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
      herdr agent prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original question: $message" 2>/dev/null || true
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
  prompt_result=$(herdr agent prompt "$pane" "$message" --wait --timeout "$timeout" 2>&1)
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

  # Route: researcher if registered and not stopped, otherwise orchestrator
  local target="researcher"
  local target_pane
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

  # Check if the target is busy
  local status
  status=$(herdr agent get "$target_pane" 2>/dev/null \
    | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unknown")
  if [[ "$status" != "idle" && "$status" != "unknown" ]]; then
    echo "error: $target is busy ($status) — try again later" >&2
    exit 1
  fi

  local prefix=""
  if [[ -n "$my_role" ]]; then
    prefix="FROM($my_role): "
  fi

  local callback=""
  if [[ -n "$my_role" ]]; then
    callback=" Reply with: project prompt $my_role '<your answer>'"
  fi

  herdr agent prompt "$target_pane" "${prefix}RESEARCH — $question${callback}"
  echo "sent to $target${my_role:+ (reply will come back to $my_role)}"
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

cmd="${1:-}"
shift || true

case "$cmd" in
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
  resolve)    cmd_resolve "$@" ;;
  session)    cmd_session "$@" ;;
  file)       cmd_file ;;
  log)        cmd_log "$@" ;;
  log-decision) cmd_log_decision "$@" ;;
  check-in)   cmd_checkin "$@" ;;
  *)          usage ;;
esac
