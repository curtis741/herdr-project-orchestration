#!/usr/bin/env bash
set -euo pipefail

# project — agent roster for multi-agent project orchestration
#
# Every agent in a project can address any other agent by role.
# The orchestrator registers agents as it spawns them; workers just use them.
#
# State file: ~/.herdr/projects/<project-name>.json
# Signal log: ~/.herdr/projects/<project-name>.signals.log
# Project name comes from: HERDR_PROJECT env var (injected into every spawned tab/workspace)

PROJECTS_DIR="$HOME/.herdr/projects"
mkdir -p "$PROJECTS_DIR"

# --- Backend ---
# All terminal/agent transport lives in backend/<name>.sh (be_* functions).
# Resolve this script's real path (it is installed as a symlink) to find it.
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
PROJECT_SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
# Backend choice, from the environment: HC_TERMINAL_ID (Herdr app terminal) -> hc,
# HERDR_ENV (classic herdr pane) -> herdr. Classic stays the default when both or
# neither is set. PROJECT_BACKEND=hc|herdr overrides.
_be="${PROJECT_BACKEND:-}"
if [[ -z "$_be" ]]; then
  if [[ -n "${HC_TERMINAL_ID:-}" && -z "${HERDR_ENV:-}" ]]; then _be=hc; else _be=herdr; fi
fi
case "$_be" in
  hc|herdr) ;;
  *) echo "error: unknown PROJECT_BACKEND '$_be' (use hc or herdr)" >&2; exit 1 ;;
esac
# shellcheck source=backend/herdr.sh
source "$PROJECT_SCRIPT_DIR/backend/$_be.sh"
PROJECT_BACKEND="$_be"
unset _be

# Spawn an agent through the backend. Same arguments as be_spawn. Sets pane_id and
# tab_id in the caller's scope (declare them local) and SPAWN_RC to the delivery
# status: be_spawn prints the handle before it delivers the first task, so the
# caller can register the agent even when delivery failed, then exit "$SPAWN_RC".
# Exits if no agent was created.
_spawn_agent() {
  local out
  SPAWN_RC=0
  out="$(be_spawn "$@")" || SPAWN_RC=$?
  read -r pane_id tab_id <<<"$out"
  [[ -n "${pane_id:-}" ]] || exit 1
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

  # Background: compare the share clone's version with the newest release tag upstream
  (_newer_release > "$cache") &>/dev/null &
  disown
}

PROJECT_SHARE="${PROJECT_ORCH_SHARE:-$HOME/.local/share/project-orchestration}"
_toml_version() { grep '^version' "$1/herdr-plugin.toml" 2>/dev/null | sed 's/.*"\(.*\)"/\1/'; }

# Print "project: vX is out — run 'project update'" when origin has a newer release tag.
_newer_release() {
  local cur newest
  cur="$(_toml_version "$PROJECT_SHARE")"
  [[ -n "$cur" ]] || return 0
  newest="$(git -C "$PROJECT_SHARE" ls-remote --tags --refs origin 'v[0-9]*' 2>/dev/null \
    | sed 's|.*refs/tags/v||' | sort -V | tail -n1)"
  [[ -n "$newest" && "$newest" != "$cur" ]] || return 0
  [[ "$(printf '%s\n%s\n' "$cur" "$newest" | sort -V | tail -n1)" == "$newest" ]] || return 0
  echo "project: v$newest is out (you have v$cur) — run 'project update'"
}


# NATO phonetic alphabet for worker names
WORKER_NAMES=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu)

usage() {
  cat <<'EOF'
Usage: project <command> [args...]

Commands:
  start [<epic-key>] [workspace-label]
                                   Create workspace, start orchestrator, run /start-project.
                                   Empty key ("") = ticketless project (work-NNN); the label is its goal
  open <project-name> [--label TEXT] [--focus]
                                   Create a workspace + project state (test harnesses; prints the HERDR_PROJECT export)
  close                            Close the project's workspace (all tabs)
  init <project-name> [workspace-id]  Create a project state file (orchestrator only)
  spawn <role> [--cwd DIR] [--label TEXT] [--title TEXT] [--resume] [--takeover]
        [--task TEXT | --task-file PATH | --task -] [--wait [--timeout MS]]
                                   Open a tab, start an agent with its first task, register the role
  host <role>                      Take on a role yourself (registry points it at your terminal)
  promote <role> [spawn options] --task-file PATH
                                   Give a hosted role its own agent; the host is never stopped
  rename <role> <label>            Rename a role's tab
  register <role>                   Register this agent and signal READY to orchestrator
  stop <role> [--close]            Stop an agent (preserves session ID); --close also closes its pane.
                                   A hosted role is just un-hosted (unassigned); the host is never stopped or closed
  next-worker                      Print the next unused worker name (NATO alphabet, then alpha2...)
  assign <role> <ticket-key>       Track a ticket assignment to a worker
  prompt <role> <message>          Send a message (fire-and-forget)
  prompt <role> <message> --wait [--timeout N]
                                   Send and wait for completion
  ask <role> <question> [--timeout N] [--lines N]
                                   Send, wait, read and print the reply (blocking)
  read <role> [--lines N]          Read an agent's recent pane output (non-blocking)
  roster                           Print the current role → pane ID map
  status [role]                    Agent states for all roles, or one word (working|idle|blocked|done|stopped|unassigned|unreachable) for a role
  info                             Print epic key and workspace ID (JSON)
  name                             Print the current project's key; exit 1 if there is none
  research <question>               Ask a research question (async, answer comes back via prompt)
  punt "<problem>"                 Hand a suspected problem to the researcher to own (no answer comes back)
  spinoff "<title>" [--notify] [--repo <path>] <<brief
                                   Spawn a throwaway worker on a scoped one-off fix (brief on stdin)
  spinoff-done "<outcome>"         Spinoff worker's last command: notify requester, stop, close tab
  resolve <role>                   Print the pane ID for a role (for scripting)
  session <role>                   Print the session ID for a role
  file                             Print the path to the state file
  dir                              Print the project working dir (shared, uncommitted scratch space)
  retire <role>                    Close a role's predecessor after a DISTILL takeover (new agent runs this)
                                   Address a live predecessor as <role>@prev in prompt/read/ask
  dump [--timeout SECS]            Pause: every other live agent writes unreported state to
                                   <role>.final.md, then is stopped and its pane closed
  recycle <role> [--timeout SECS]  Fresh context, same role: the agent writes <role>.distill.md,
                                   then a takeover successor reads it and retires the old agent
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
  update                           Move the install to the newest release now: fetch, relink, refresh the
                                   app panel's files, tell running orchestrators what changed

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
  local pane ws
  pane="$(be_self)"; ws="$(be_self_workspace)"
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
  if [[ "$role" == *@prev ]]; then
    jq -r --arg role "${role%@prev}" '.agents[$role].predecessor_pane // empty' "$f"
    return
  fi
  jq -r ".agents.\"$role\".pane_id // empty" "$f"
}

read_session() {
  local f="$1" role="$2"
  jq -r ".agents.\"$role\".session_id // empty" "$f"
}

# The caller's own role: the entry registered to its terminal that is not merely
# hosted there (a host's terminal also appears under every role it hosts). A live
# entry wins over a stopped one that still points at the same terminal.
resolve_caller() {
  local f="$1"
  local me
  me="$(be_self)"
  if [[ -n "$me" ]]; then
    jq -r --arg pane "$me" \
      '[.agents | to_entries[] | select(.value.pane_id == $pane and (.value.hosted_by // "") == "")]
       | sort_by(.value.stopped == true) | .[0].key // empty' "$f" 2>/dev/null || true
  fi
}

# Who hosts <role> ("" if it has its own agent or is unregistered).
read_host() {
  jq -r --arg r "$1" '.agents[$r].hosted_by // empty' "$2"
}

# "[to <role>] " when <role> is hosted (the receiving agent must know which role's
# rules apply to this message); empty when the role is the receiver's own.
to_prefix() {
  local f="$1" role="$2"
  [[ -n "$(read_host "$role" "$f")" ]] && printf '[to %s] ' "$role"
  return 0
}

# Refuse to message a role the caller itself hosts: nothing to route, it is the role.
refuse_self_hosted() {
  local f="$1" role="$2" pane="$3" me
  me="$(be_self)"
  if [[ -n "$me" && "$pane" == "$me" ]] && [[ -n "$(read_host "$role" "$f")" ]]; then
    echo "error: you host '$role' yourself — handle it directly, nothing was sent" >&2
    return 1
  fi
  return 0
}

HOSTABLE_ROLES=(librarian researcher watcher)
# Hosted by the orchestrator at register time. The watcher is left out: it starts unassigned.
DEFAULT_HOSTED_ROLES=(librarian researcher)
# Roles that always exist as names, even with no state-file entry.
KNOWN_ROLES=(librarian researcher watcher)

# "Unassigned": a known role (fixed name, or one the state file has seen) with no agent
# and no host. Represented as no state-file entry — un-hosting deletes the entry.
is_unassigned() {
  local f="$1" role="$2" r
  [[ -n "$(read_pane "$f" "$role")" ]] && return 1
  for r in "${KNOWN_ROLES[@]}"; do [[ "$r" == "$role" ]] && return 0; done
  return 1
}

# Refuse (exit 1, nothing queued, no NEED) to message an unassigned role.
refuse_unassigned() {
  local f="$1" role="$2" caller="$3" detail="$4"
  is_unassigned "$f" "$role" || return 0
  echo "$role has no agent — do it yourself" >&2
  log_signal "${caller:-unknown}" "$role" "UNASSIGNED" "$role has no agent — not sent. $detail"
  exit 1
}

# Make <host> (at <pane>) host every default role that has no live agent of its own.
# Roles already hosted by <host> follow it to <pane>. Roles with their own live agent,
# or hosted by someone else, are left alone. History keys (session ids etc.) stay.
_host_defaults() {
  local f="$1" host="$2" pane="$3" r tmp
  for r in "${DEFAULT_HOSTED_ROLES[@]}"; do
    tmp="${f}.tmp.$$"
    jq --arg r "$r" --arg host "$host" --arg pane "$pane" \
      '(.agents[$r] // {}) as $e
       | if ($e == {}) or ($e.stopped == true) or (($e.hosted_by // "") == $host)
         then .agents[$r] = ($e | del(.stopped, .stopped_at, .predecessor_pane))
                            + {pane_id: $pane, hosted_by: $host, hosted_at: ($e.hosted_at // (now | todate))}
         else . end' "$f" > "$tmp" && mv "$tmp" "$f"
  done
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

# Next free key for a ticketless project: work-001, work-002, ...
next_work_key() {
  local n=1
  while [[ -e "$PROJECTS_DIR/$(printf 'work-%03d' "$n").json" ]]; do n=$((n + 1)); done
  printf 'work-%03d\n' "$n"
}

# True when the current directory is inside a checkout of this plugin's repo.
# Dogfood (DOG-) runs only there: its wave-merge flow lives in docs/dogfood.md.
in_plugin_repo() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -f "$top/docs/dogfood.md" ]] && grep -q 'herdr-plugins.project-orchestration' "$top/herdr-plugin.toml" 2>/dev/null
}

cmd_start() {
  local name="${1:-}"
  local label="${2:-}"
  # No key: a ticketless project. Take the next free work-NNN.
  if [[ -z "$name" ]]; then
    name="$(next_work_key)"
    echo "no epic key: ticketless project $name" >&2
  fi
  if [[ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" == dog-* ]] && ! in_plugin_repo; then
    echo "error: DOG- (dogfood) projects only run inside a checkout of the project-orchestration plugin repo" >&2
    echo "  For a project without a tracker, leave the key empty or use WORK-<n>." >&2
    exit 1
  fi

  if ! be_available; then
    echo "error: terminal backend CLI not found ($PROJECT_BACKEND)" >&2
    exit 1
  fi

  # Default workspace label to the project name
  if [[ -z "$label" ]]; then
    label="$name"
  fi

  # Create the workspace
  local ws_id pane_id
  read -r ws_id pane_id < <(be_workspace_create "$PWD" "$label" "$name" false) || exit 1
  echo "workspace created: $ws_id (pane $pane_id)" >&2

  # Initialize the project with the workspace ID
  eval "$(cmd_init "$name" "$ws_id")"

  # Start the agent in the workspace's root pane and hand it the skill as its first task.
  # The orchestrator is registered (under the right pane) before it can run anything.
  local root_pane="$pane_id"
  export HERDR_PROJECT="$name"
  _pre_start() { cmd_register orchestrator "$1" "$3"; }
  # A ticketless project's goal is its label; pass it along so the orchestrator starts from it.
  local task="/start-project $name"
  if [[ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" == work-* && "$label" != "$name" ]]; then
    task="$task $label"
  fi
  _spawn_agent --pre-task _pre_start --root "$root_pane" --echo "$ws_id" "$PWD" "orchestrator" "$name" orchestrator "$task" -n orchestrator
  echo "orchestrator agent started in $pane_id" >&2
  [[ "$SPAWN_RC" -eq 0 ]] || exit "$SPAWN_RC"

  echo "project started: $name (workspace $ws_id, pane $pane_id)" >&2
}

cmd_register() {
  local role="${1:-}" pane_id="${2:-}" session_id="${3:-}"
  # Default pane_id to this agent's own handle so agents can self-register
  if [[ -z "$pane_id" ]]; then
    pane_id="$(be_self)"
  fi
  if [[ -z "$role" ]]; then
    echo "usage: project register <role>" >&2
    exit 1
  fi
  if [[ -z "$pane_id" ]]; then
    echo "error: cannot detect this agent's pane — pass it explicitly (project register <role> <pane>)" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"

  # If no session_id provided, ask the backend
  if [[ -z "$session_id" ]]; then
    session_id="$(be_session "$pane_id")"
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
     | if ($old.pane_id // "") != "" and $old.pane_id != $pane and ($old.stopped != true) and (($old.hosted_by // "") == "")
       then .agents[$role].predecessor_pane = $old.pane_id else . end
     | del(.agents[$role].stopped) | del(.agents[$role].stopped_at)
     | del(.agents[$role].hosted_by) | del(.agents[$role].hosted_at)
     | del(.paused_at)
     # roles this agent hosts follow it when it moves to a new terminal (takeover)
     | if ($old.pane_id // "") != "" and $old.pane_id != $pane
       then .agents |= with_entries(if (.value.hosted_by // "") == $role and .value.pane_id == $old.pane_id
                                    then .value.pane_id = $pane else . end)
       else . end' \
    "$f" > "$tmp" && mv "$tmp" "$f"

  # The orchestrator hosts the support roles that have no agent of their own
  [[ "$role" == "orchestrator" ]] && _host_defaults "$f" orchestrator "$pane_id"

  # Signal the orchestrator that this agent is ready (unless we ARE the orchestrator)
  local is_spinoff
  is_spinoff=$(jq -r --arg role "$role" '.agents[$role].spinoff != null' "$f")
  if [[ "$role" != "orchestrator" && "$is_spinoff" != "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      be_prompt "$orch_pane" "READY — $role" 2>/dev/null || true
      log_signal "$role" "orchestrator" "READY" "$role registered"
    fi
  fi

  echo "registered: $role → $pane_id"
}

cmd_next_worker() {
  local f
  f="$(ensure_state)"
  # Never reuse a name within a project — a stopped worker's entry holds its
  # session/ticket history. After zulu, wrap to alpha2, bravo2, ...
  local used
  used=$(jq -r '.agents | keys[]' "$f")
  local round=1 suffix name
  while true; do
    if [[ $round -eq 1 ]]; then suffix=""; else suffix="$round"; fi
    for name in "${WORKER_NAMES[@]}"; do
      if ! echo "$used" | grep -qx "$name$suffix"; then
        echo "$name$suffix"
        return
      fi
    done
    round=$((round + 1))
  done
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
  local role="${1:-}" close=false
  if [[ -z "$role" ]]; then
    echo "usage: project stop <role> [--close]" >&2
    exit 1
  fi
  shift
  [[ "${1:-}" == "--close" ]] && close=true
  local f
  f="$(ensure_state)"
  local pane
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi

  # A hosted role has no agent of its own: stopping it un-hosts it. The host's
  # terminal is never closed and its session is not the role's session.
  local host tmp
  host="$(read_host "$role" "$f")"
  tmp="${f}.tmp.$$"
  if [[ -n "$host" ]]; then
    jq --arg role "$role" 'del(.agents[$role])' "$f" > "$tmp" && mv "$tmp" "$f"
    log_signal "orchestrator" "$role" "STOP" "$role un-hosted (was hosted by $host) — now unassigned"
    echo "stopped: $role (was hosted by $host; now unassigned, the host keeps running)"
    return 0
  fi

  # Capture session ID before stopping (it may not be in the state file yet)
  local sid
  sid="$(be_session "$pane")"

  jq --arg role "$role" --arg sid "$sid" \
    '.agents[$role].stopped = true | if $sid != "" then .agents[$role].session_id = $sid else . end | .agents[$role].stopped_at = (now | todate)
     | del(.agents[$role].spinoff)
     # roles this agent hosted lose their host with it: they become unassigned
     | .agents |= with_entries(select((.value.hosted_by // "") != $role))' \
    "$f" > "$tmp" && mv "$tmp" "$f"
  log_signal "orchestrator" "$role" "STOP" "$role stopped"
  if $close; then
    be_close_pane "$pane"
    echo "stopped: $role (session preserved, pane closed)"
  else
    echo "stopped: $role (session preserved)"
  fi
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
  local caller
  caller="$(resolve_caller "$f")"
  refuse_unassigned "$f" "$role" "$caller" "Original: $message"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered — run 'project register $role <pane-id>'" >&2
    jq -r '.agents | keys[]' "$f" >&2
    exit 1
  fi

  local is_stopped
  is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
  if [[ "$is_stopped" == "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      be_prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original message: $message" 2>/dev/null || true
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
    UNBLOCKED\ *|UNBLOCKED)   signal_type="UNBLOCKED" ;;
    WATCH\ *)                 signal_type="WATCH" ;;
    PROJECT_COMPLETE\ *|PROJECT_COMPLETE) signal_type="PROJECT_COMPLETE" ;;
    DISTILL_DEFER\ *|DISTILL_DEFER) signal_type="DISTILL_DEFER" ;;
    DISTILL_ACK\ *|DISTILL_ACK) signal_type="DISTILL_ACK" ;;
    CORRECTION\ *)            signal_type="CORRECTION" ;;
  esac

  refuse_self_hosted "$f" "$role" "$pane" || exit 1

  log_signal "${caller:-unknown}" "$role" "$signal_type" "$message"

  # Prefix with sender so the recipient can distinguish cross-agent messages from direct instructions
  if [[ -n "$caller" ]]; then
    message="FROM($caller): $message"
  fi
  # A host is told which of its roles this is for
  message="$(to_prefix "$f" "$role")$message"

  # With --wait the backend prints its raw JSON result: noise in an agent's
  # context. Swallow it on success; keep error text and the exit code.
  if [[ -n "$wait_flag" ]]; then
    local wait_out wait_rc=0
    # shellcheck disable=SC2086
    wait_out=$(be_prompt "$pane" "$message" $wait_flag $timeout_flag 2>&1) || wait_rc=$?
    if [[ $wait_rc -ne 0 ]]; then
      [[ -n "$wait_out" ]] && echo "$wait_out"
      return $wait_rc
    fi
    return 0
  fi
  # shellcheck disable=SC2086
  be_prompt "$pane" "$message" $wait_flag $timeout_flag
}

# Read the last N lines of real content from a pane. Fresh agent screens are
# mostly blank padding plus input-box chrome, so a plain N-line read can return
# nothing useful. Over-fetch, drop trailing blank/chrome lines, keep the last N.
read_trimmed() {
  local pane="$1" n="$2" fetch raw out
  [[ "$n" =~ ^[0-9]+$ ]] || n=40
  for fetch in "$n" $((n * 2 + 60)) $((n * 4 + 200)); do
    raw="$(be_read "$pane" "$fetch")" || true
    out="$(printf '%s\n' "$raw" | awk '
      { l[NR] = $0 }
      END {
        e = NR
        while (e > 0) {
          t = l[e]
          # blank, box-drawing borders, or a bare prompt marker; no letters/digits
          chrome = (t !~ /[A-Za-z0-9]/) && (t ~ /^[ \t]*$/ || t ~ /^[ \t>|]*$/ ||
                    index(t, "─") || index(t, "━") || index(t, "═") || index(t, "│") ||
                    index(t, "╭") || index(t, "╰") || index(t, "❯"))
          # Claude Code footer: "↳ … | 11% ctx | …" status line, "⏵⏵ auto mode on (shift+tab to cycle)"
          footer = (t ~ /[0-9]+% ctx/) || index(t, "⏵⏵") || (t ~ /shift\+tab to cycle/) ||
                   (t ~ /^[ \t]*↳/ && index(t, "|"))
          if (chrome || footer || t ~ /\? for shortcuts|esc to interrupt|bypass permissions|accept edits on/) { e--; continue }
          break
        }
        for (i = 1; i <= e; i++) print l[i]
      }')"
    # enough real content, or the screen is exhausted (fetch returned less than asked)
    if [[ "$(printf '%s\n' "$out" | grep -c .)" -ge "$n" ]] || [[ "$(printf '%s\n' "$raw" | wc -l)" -lt "$fetch" ]]; then
      break
    fi
  done
  [[ -n "$out" ]] && printf '%s\n' "$out" | tail -n "$n"
  return 0
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
  local caller
  caller="$(resolve_caller "$f")"
  refuse_unassigned "$f" "$role" "$caller" "Original question: $message"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi

  local is_stopped
  is_stopped=$(jq -r --arg role "$role" '.agents[$role].stopped // false' "$f")
  if [[ "$is_stopped" == "true" ]]; then
    local orch_pane
    orch_pane="$(read_pane "$f" "orchestrator")"
    if [[ -n "$orch_pane" ]]; then
      be_prompt "$orch_pane" "NEED — ${caller:+$caller needs }$role (stopped). Original question: $message" 2>/dev/null || true
      echo "escalated to orchestrator: $role is stopped" >&2
    else
      echo "error: $role is stopped and orchestrator is not reachable" >&2
    fi
    exit 1
  fi

  refuse_self_hosted "$f" "$role" "$pane" || exit 1

  log_signal "${caller:-unknown}" "$role" "ASK" "$message"

  if [[ -n "$caller" ]]; then
    message="FROM($caller): $message"
  fi
  message="$(to_prefix "$f" "$role")$message"

  # Send the prompt and wait for the agent to finish
  local prompt_result
  prompt_result=$(be_prompt "$pane" "$message" --wait --timeout "$timeout" 2>&1)
  local prompt_exit=$?

  if [[ $prompt_exit -ne 0 ]]; then
    echo "error: prompt failed — $prompt_result" >&2
    exit 1
  fi

  # Read the agent's response from its pane output (raw text, not JSON)
  read_trimmed "$pane" "$lines"
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

  read_trimmed "$pane" "$lines"
}

# One row per known role with no agent and no host.
_print_unassigned() {
  local f="$1" r
  for r in "${KNOWN_ROLES[@]}"; do
    is_unassigned "$f" "$r" && printf "  %-12s %-10s %s\n" "$r" "-" "unassigned"
  done
  return 0
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
        (if (.value.hosted_by // "") != "" then "hosted by \(.value.hosted_by)" else null end),
        (.value.current_ticket // null)
      ] | map(select(. != null)) | join(", ") | if . == "" then "-" else . end
    )"' "$f" | column -t -s $'\t'
  _print_unassigned "$f"
}

cmd_status() {
  local f
  f="$(ensure_state)"
  if [[ -n "${1:-}" ]]; then
    # Single-role form: one state word, for scripts and for blocked-worker checks.
    local one="$1" one_pane
    if [[ "$(jq -r --arg r "$one" '.agents[$r].stopped // false' "$f")" == "true" ]]; then
      echo "stopped"; return 0
    fi
    one_pane="$(read_pane "$f" "$one")"
    if is_unassigned "$f" "$one"; then
      echo "unassigned"; return 0
    fi
    if [[ -z "$one_pane" ]]; then
      echo "error: role '$one' not registered" >&2
      exit 1
    fi
    local st
    st="$(be_state "$one_pane")"
    echo "${st:-unreachable}"
    return 0
  fi
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
      status="$(be_state "$pane")"; status="${status:-unreachable}"
    fi
    local ticket_info
    ticket_info=$(jq -r --arg role "$role" '
      .agents[$role] | select(.tickets) |
      (.current_ticket // "") as $cur |
      [.tickets[] | if . == $cur then . else . + " ✓" end] | join(", ")' "$f" 2>/dev/null || true)
    local hosted_note
    hosted_note="$(read_host "$role" "$f")"
    [[ -n "$hosted_note" ]] && ticket_info="hosted by $hosted_note${ticket_info:+, $ticket_info}"
    if [[ -n "$ticket_info" ]]; then
      printf "  %-12s %-10s %-10s %s\n" "$role" "$pane" "$status" "$ticket_info"
    else
      printf "  %-12s %-10s %s\n" "$role" "$pane" "$status"
    fi
  done
  _print_unassigned "$f"
}

cmd_info() {
  local f
  f="$(ensure_state)"
  jq '{project, workspace_id, agent_count: (.agents | length)}' "$f"
}

# The current project's key (backend-neutral; skills use this instead of reading env vars).
cmd_name() {
  [[ -n "${HERDR_PROJECT:-}" ]] || exit 1
  echo "$HERDR_PROJECT"
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
  status=$(be_state "$target_pane")
  status="${status:-unknown}"
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

  refuse_self_hosted "$f" "$target" "$target_pane" || exit 1

  local prefix="" callback=""
  if [[ -n "$my_role" ]]; then
    prefix="FROM($my_role): "
    callback=" Reply with: project prompt $my_role '<your answer>'"
  fi
  prefix="$(to_prefix "$f" "$target")$prefix"

  be_prompt "$target_pane" "${prefix}RESEARCH — $question${callback}" >/dev/null
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

  refuse_self_hosted "$f" "$target" "$target_pane" || exit 1

  local from="${my_role:-an agent}"
  be_prompt "$target_pane" "$(to_prefix "$f" "$target")FROM($from): PUNT — $problem
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

  local short_title="$title"
  [[ ${#short_title} -gt 40 ]] && short_title="${short_title:0:37}..."
  # Pre-register (before the worker can run anything) so it shows up in roster/status/cleanup
  # immediately. The worker's own 'project register' keeps these fields.
  _pre_spinoff() {
    local tmp="${f}.tmp.$$"
    jq --arg role "$name" --arg pane "$1" --arg id "$id" --arg from "$from" \
       --arg title "$title" --arg brief "$brief_file" --argjson notify "$notify" \
      '.agents[$role] = ((.agents[$role] // {}) | del(.stopped, .stopped_at)) + {
         pane_id: $pane, current_ticket: $id,
         tickets: (((.agents[$role].tickets) // []) + [$id] | unique),
         spinoff: {from: $from, title: $title, brief: $brief, notify: $notify}
       }' "$f" > "$tmp" && mv "$tmp" "$f"
  }
  local pane_id tab_id
  _spawn_agent --pre-task _pre_spinoff "$ws" "$repo_path" "$name — spinoff" "$project" "$name" "Spinoff worker $name for project $epic — a throwaway worker on one scoped fix.
Your role is '$name'. Your worktree is .worktrees/$id/ (branch $id).
Your brief: $brief_file

Run /project-worker and follow § Spinoff mode." -n "$name — spinoff: $short_title"

  [[ "$SPAWN_RC" -eq 0 ]] || exit "$SPAWN_RC"

  log_signal "$from" "$name" "SPINOFF" "$title"
  local orch_pane
  orch_pane="$(read_pane "$f" "orchestrator")"
  if [[ -n "$orch_pane" && "$from" != "orchestrator" ]]; then
    be_prompt "$orch_pane" "SPINOFF — $from spun off \"$title\" to $name. FYI only — it reports through the librarian like any worker; no action needed." >/dev/null 2>&1 || true
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
      be_prompt "$from_pane" "$(to_prefix "$f" "$from")FROM($me): SPINOFF_DONE — \"$title\": $outcome" >/dev/null 2>&1 || true
    fi
  fi
  log_signal "$me" "${from}" "SPINOFF_DONE" "$title: $outcome"

  cmd_stop "$me" >/dev/null
  echo "spinoff finished — closing this tab"
  local tab
  tab=$(be_tab_of "$(be_self)")
  [[ -n "$tab" ]] && be_tab_close "$tab" 2>/dev/null || true
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
    if be_workspace_exists "$ws"; then
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
    elif [[ -n "$(read_host "$role" "$f")" ]]; then
      state_label="hosted by $(read_host "$role" "$f")"
      pane_ok="-"
    else
      # Check if the pane is still reachable
      local agent_state
      agent_state=$(be_state "$pane")
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
    echo "    2. For each resumable agent, resume it in a new tab:"
    echo "       project spawn <role> --resume --task \"<boot prompt>\""
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
    local status host_of
    host_of="$(read_host "$role" "$f")"
    if [[ -n "$host_of" ]]; then
      printf "  %-16s %-12s hosted by %s\n" "$role" "[hosted]" "$host_of"
      continue
    fi
    if [[ "$is_stopped" == "true" ]]; then
      status="stopped"
    else
      status=$(be_state "$pane"); status="${status:-unreachable}"
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

  # --- Collect agent data (one backend call per live agent, cached in temp file) ---
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
    elif [[ -n "$(read_host "$role" "$f")" ]]; then
      status="hosted"
    else
      status=$(be_state "$pane"); status="${status:-unreachable}"
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
      hosted)      icon="◦" ;;
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

  local targets=() role pane self_pane
  self_pane="$(be_self)"
  while IFS=$'\t' read -r role pane; do
    [[ -z "$role" || "$pane" == "$self_pane" ]] && continue
    targets+=("$role")
  done < <(jq -r '.agents | to_entries[] | select(.value.stopped != true and (.value.hosted_by // "") == "") | [.key, .value.pane_id // ""] | @tsv' "$f")

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
    if [[ -z "$pane" ]] || ! be_alive "$pane"; then
      echo "gone" > "$tmpd/$role.status"
      continue
    fi
    local msg="DUMP — the project is $verb. This session will be stopped once you go idle.
If you hold state that isn't already durable (tracker, PR, pushed commits, project dir) — in-flight work, decisions not written down, open questions, something you were about to tell another agent — commit and push any WIP, then write it to $final. Keep it short; link instead of restating.
If there's nothing, write no file.
Don't signal or prompt other agents. Reply with one line: 'dumped' or 'nothing to dump'."
    log_signal "${caller:-user}" "$role" "DUMP" "project $verb"
    (
      if out=$(be_prompt "$pane" "$msg" --wait --until idle --until done --timeout $((timeout * 1000)) 2>&1); then
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
        [[ "$status" == "ok" ]] && be_close_pane "$pane"
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
  # Lifecycle marker for the mod's Paused list; any agent registering or spawning again clears it
  local tmp="${f}.tmp.$$"
  jq '.paused_at = (now | todate)' "$f" > "$tmp" && mv "$tmp" "$f"
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
    if $handoff || [[ -z "$orch_pane" || "$orch_stopped" == "true" ]] || ! be_alive "$orch_pane"; then
      echo "error: project reset runs in the orchestrator's pane, and no live orchestrator was found" >&2
      echo "  to pause everything instead: project --project $name dump" >&2
      exit 1
    fi
    be_prompt "$orch_pane" "RESET — ${caller:-the user} asked for a full project reset. Follow the skill's § Resetting the project: run 'project reset'." >/dev/null
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
  live=$(jq -r '[.agents | to_entries[] | select(.key != "orchestrator" and .value.stopped != true and (.value.hosted_by // "") == "") | .key] | join(" ")' "$f")
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
  local epic
  epic="$(echo "$name" | tr '[:lower:]' '[:upper:]')"

  local pane_id tab_id
  _spawn_agent "$ws" "$PWD" "orchestrator" "$name" orchestrator "/start-project $epic

You are a fresh orchestrator taking over after a project RESET. Before Step 1:
1. Run: project register orchestrator
2. Read $reset_file — your predecessor's master distill. Trust it; check an item against the tracker only when you act on it. Read the agent dump files it lists only when you touch that area.
3. Your predecessor is still live as orchestrator@prev. If anything is unclear, ask it: project ask orchestrator@prev '<question>'. When you have no more questions, run: project retire orchestrator
4. Every other agent from the previous run is stopped. Don't resume their sessions — spawn fresh agents as the skill describes, and give the new librarian the path to librarian.final.md if one is listed.
Then continue from Step 1, building the plan from the tracker plus the distill." -n orchestrator
  [[ "$SPAWN_RC" -eq 0 ]] || exit "$SPAWN_RC"

  log_signal "orchestrator" "orchestrator" "RESET" "successor spawned in $pane_id"
  echo "successor orchestrator started — it will retire this orchestrator when it's done asking questions"
}

cmd_retire() {
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    echo "usage: project retire <role>" >&2
    exit 1
  fi
  local f
  f="$(ensure_state)"
  local old_pane="$arg" by_role=false
  # <role> form: close that role's predecessor (recorded when the successor registered).
  if jq -e --arg r "$arg" '.agents[$r] != null' "$f" >/dev/null 2>&1; then
    by_role=true
    old_pane="$(jq -r --arg r "$arg" '.agents[$r].predecessor_pane // empty' "$f")"
    if [[ -z "$old_pane" ]]; then
      echo "no predecessor recorded for '$arg' — nothing to retire"
      return 0
    fi
  fi
  if [[ "$old_pane" == "$(be_self)" ]]; then
    echo "error: refusing to retire your own pane" >&2
    exit 1
  fi
  local owner
  owner=$(jq -r --arg p "$old_pane" '.agents | to_entries[] | select(.value.pane_id == $p and (.value.hosted_by // "") == "" and .value.stopped != true) | .key' "$f")
  if [[ -n "$owner" ]]; then
    echo "error: $old_pane is still registered to '$owner' — register the new agent first" >&2
    exit 1
  fi
  if $by_role; then
    local tmp="${f}.tmp.$$"
    jq --arg r "$arg" 'del(.agents[$r].predecessor_pane)' "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  local tab
  tab=$(be_tab_of "$old_pane")
  if [[ -z "$tab" ]]; then
    echo "predecessor already closed"
    return 0
  fi
  be_tab_close "$tab"
  local caller
  caller="$(resolve_caller "$f")"
  log_signal "${caller:-unknown}" "-" "SHUTDOWN" "retired predecessor of $arg ($old_pane)"
  echo "retired: predecessor of $arg (tab closed)"
}

# Create a workspace and initialise a project in it (test harnesses: the real
# orchestrator is already inside a project). Prints the HERDR_PROJECT export.
cmd_open() {
  local name="" label="" focus="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="${2:-}"; shift 2 ;;
      --focus) focus="true"; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  if [[ -z "$name" ]]; then
    echo "usage: project open <project-name> [--label TEXT] [--focus]" >&2
    exit 1
  fi
  local existing="$PROJECTS_DIR/$name.json" old_ws
  if [[ -f "$existing" ]]; then
    old_ws="$(read_field "$existing" "workspace_id")"
    if [[ -n "$old_ws" ]] && be_workspace_exists "$old_ws"; then
      echo "error: project '$name' already exists and its workspace ($old_ws) is still open — use a different name, or 'project close' it first" >&2
      exit 1
    fi
  fi
  local ws_id _pane
  read -r ws_id _pane < <(be_workspace_create "$PWD" "${label:-$name}" "$name" "$focus") || exit 1
  cmd_init "$name" "$ws_id"
}

# Close the project's workspace (every tab in it).
cmd_close() {
  local f ws
  f="$(ensure_state)"
  ws="$(read_field "$f" "workspace_id")"
  if [[ -z "$ws" ]]; then
    echo "error: project has no workspace_id" >&2
    exit 1
  fi
  # Lifecycle marker (written first: closing the workspace may end this very session)
  local tmp="${f}.tmp.$$"
  jq '.closed_at = (now | todate)' "$f" > "$tmp" && mv "$tmp" "$f"
  be_workspace_close "$ws" || {
    tmp="${f}.tmp.$$"
    jq 'del(.closed_at)' "$f" > "$tmp" && mv "$tmp" "$f"
    exit 1
  }
  echo "workspace closed: $(read_field "$f" "project")"
}

cmd_rename() {
  local role="${1:-}" label="${2:-}"
  if [[ -z "$role" || -z "$label" ]]; then
    echo "usage: project rename <role> <label>" >&2
    exit 1
  fi
  local f pane tab
  f="$(ensure_state)"
  pane="$(read_pane "$f" "$role")"
  if [[ -z "$pane" ]]; then
    echo "error: role '$role' not registered" >&2
    exit 1
  fi
  tab=$(be_tab_of "$pane")
  if [[ -z "$tab" ]]; then
    echo "error: could not find the tab for $role" >&2
    exit 1
  fi
  be_tab_rename "$tab" "$label"
  echo "renamed: $role → $label"
}

# Spawn a role: new tab in the project workspace, agent started, first task
# delivered, role registered. The only way skills create an agent.
#   --cwd DIR       working dir (default $PWD)
#   --label TEXT    tab label (default <role>)
#   --title TEXT    agent session name (default <role>), e.g. "alpha — widget column backfill"
#   --resume        resume the role's stored session instead of starting fresh
#   --takeover      the role is live and stays routed to the old agent until the
#                   successor runs 'project register'; reach the old one as <role>@prev
#   --task TEXT | --task-file PATH | --task -   first task (- = stdin)
#   --wait [--timeout MS]   block until the agent finishes its first turn
cmd_spawn() {
  local role="${1:-}"
  if [[ -z "$role" || "$role" == --* ]]; then
    echo "usage: project spawn <role> [--cwd DIR] [--label TEXT] [--title TEXT] [--resume] [--takeover]" >&2
    echo "                     [--task TEXT | --task-file PATH | --task -] [--wait [--timeout MS]]" >&2
    exit 1
  fi
  shift
  local cwd="$PWD" label="$role" title="$role" resume=false takeover=false
  local task="" have_task=false wait_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd)       cwd="${2:?--cwd needs a value}"; shift 2 ;;
      --label)     label="${2:?--label needs a value}"; shift 2 ;;
      --title)     title="${2:?--title needs a value}"; shift 2 ;;
      --resume)    resume=true; shift ;;
      --takeover)  takeover=true; shift ;;
      --task)
        have_task=true
        if [[ "${2:-}" == "-" ]]; then task="$(cat)"; else task="${2:?--task needs a value}"; fi
        shift 2 ;;
      --task-file) have_task=true; task="$(cat "${2:?--task-file needs a path}")"; shift 2 ;;
      --wait)      wait_args+=(--wait); shift ;;
      --timeout)   wait_args+=(--timeout "${2:?--timeout needs a value}"); shift 2 ;;
      *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
  done
  if $have_task && [[ -z "${task//[[:space:]]/}" ]]; then
    echo "error: empty task" >&2
    exit 1
  fi

  local f project ws
  f="$(ensure_state)"
  project="$(read_field "$f" "project")"
  ws="$(read_field "$f" "workspace_id")"
  if [[ -z "$ws" ]]; then
    echo "error: project has no workspace_id — can't open a tab" >&2
    exit 1
  fi

  # A hosted role has no agent of its own to replace: spawning for it is a promotion.
  # The host keeps its terminal; there is no predecessor to take over from or retire.
  local old_pane hosted_by
  hosted_by="$(read_host "$role" "$f")"
  [[ -n "$hosted_by" ]] && takeover=false
  old_pane="$(read_pane "$f" "$role")"
  if [[ -z "$hosted_by" && -n "$old_pane" ]] && [[ "$(jq -r --arg r "$role" '.agents[$r].stopped // false' "$f")" != "true" ]] && ! $takeover && [[ -n "$(be_state "$old_pane")" ]]; then
    echo "error: role '$role' is live in an existing pane — 'project stop $role --close' first, or pass --takeover" >&2
    exit 1
  fi

  local claude_args=(-n "$title") sid=""
  if $resume; then
    sid="$(read_session "$f" "$role")"
    if [[ -z "$sid" ]]; then
      echo "error: no stored session for '$role' — can't --resume" >&2
      exit 1
    fi
    claude_args=(--resume "$sid" -n "$title")
  fi

  # Pre-register (before the agent can run anything) so the role shows up in roster/status
  # immediately and its first signal has a sender. A takeover leaves routing on the old
  # agent until the successor registers itself. On hc <tab> is empty here; patched below.
  _pre_spawn() {
    local tmp="${f}.tmp.$$"
    jq --arg role "$role" --arg pane "$1" --arg tab "$2" --argjson tk "$takeover" \
       --arg cwd "$cwd" --arg label "$label" --arg title "$title" \
      '(if $tk then .
        else .agents[$role] = ((.agents[$role] // {}) | del(.stopped, .stopped_at, .predecessor_pane, .hosted_by, .hosted_at))
               + {pane_id: $pane, tab_id: $tab, spawned_at: (now | todate),
                  spawn: {cwd: $cwd, label: $label, title: $title}} end)
       | del(.paused_at)' \
      "$f" > "$tmp" && mv "$tmp" "$f"
    if [[ -n "$hosted_by" ]]; then
      log_signal "$hosted_by" "$role" "PROMOTE" "$role$($resume && echo ' (resume)') — was hosted by $hosted_by"
    fi
    log_signal "orchestrator" "$role" "SPAWN" "$role$($resume && echo ' (resume)')"
  }
  # Keep the boot task so `project recycle` can hand it to a successor.
  if $have_task && ! $takeover; then
    printf '%s\n' "$task" > "$(project_dir)/$role.boot.md"
  fi
  local pane_id tab_id
  _spawn_agent --pre-task _pre_spawn ${wait_args[@]+"${wait_args[@]}"} "$ws" "$cwd" "$label" "$project" "$role" "$task" "${claude_args[@]}"

  # hc only learns the tab after launch; patch it into the pre-registered entry.
  if [[ -n "$tab_id" ]] && ! $takeover; then
    local tmp="${f}.tmp.$$"
    jq --arg role "$role" --arg tab "$tab_id" '.agents[$role].tab_id = $tab' "$f" > "$tmp" && mv "$tmp" "$f"
  fi

  [[ "$SPAWN_RC" -eq 0 ]] || exit "$SPAWN_RC"
  if [[ -n "$hosted_by" ]]; then
    echo "spawned: $role (promoted — was hosted by $hosted_by, which keeps running)"
  else
    echo "spawned: $role"
  fi
}

# The caller takes on a role: the registry points <role> at the caller's terminal,
# marked hosted. Messages for it arrive prefixed '[to <role>] '.
cmd_host() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "usage: project host <role>" >&2
    exit 1
  fi
  local f caller pane
  f="$(ensure_state)"
  pane="$(be_self)"
  caller="$(resolve_caller "$f")"
  if [[ -z "$caller" || -z "$pane" ]]; then
    echo "error: only a registered agent can host a role — run 'project register <role>' first" >&2
    exit 1
  fi
  if [[ "$role" == "$caller" ]]; then
    echo "error: you are '$role' — can't host your own role" >&2
    exit 1
  fi
  local e_pane e_stopped e_host
  e_pane="$(read_pane "$f" "$role")"
  e_stopped="$(jq -r --arg r "$role" '.agents[$r].stopped // false' "$f")"
  e_host="$(read_host "$role" "$f")"
  if [[ -n "$e_pane" && "$e_stopped" != "true" && -z "$e_host" ]]; then
    echo "error: role '$role' has its own agent ($e_pane) — 'project stop $role --close' first" >&2
    exit 1
  fi
  local tmp="${f}.tmp.$$"
  jq --arg r "$role" --arg host "$caller" --arg pane "$pane" \
    '.agents[$r] = ((.agents[$r] // {}) | del(.stopped, .stopped_at, .predecessor_pane))
       + {pane_id: $pane, hosted_by: $host, hosted_at: (now | todate)}' \
    "$f" > "$tmp" && mv "$tmp" "$f"
  log_signal "$caller" "$role" "HOST" "$caller hosts $role"
  echo "hosted: $role by $caller — messages for it arrive prefixed '[to $role] '; don't message the role, you are it"
}

# Give a hosted role its own agent. A spawn that is seeded from a handoff the host
# wrote (--task / --task-file), or resumes the role's old session (--resume).
# The host is never stopped or closed; it just stops hosting the role.
cmd_promote() {
  local role="${1:-}"
  if [[ -z "$role" || "$role" == --* ]]; then
    echo "usage: project promote <role> [--cwd DIR] [--label TEXT] [--title TEXT] [--resume]" >&2
    echo "                       [--task TEXT | --task-file PATH | --task -] [--wait [--timeout MS]]" >&2
    exit 1
  fi
  local f host
  f="$(ensure_state)"
  host="$(read_host "$role" "$f")"
  # Unassigned: nothing to hand off; promoting just assigns it (a plain spawn).
  if [[ -z "$host" ]] && is_unassigned "$f" "$role"; then
    cmd_spawn "$@"
    return
  fi
  if [[ -z "$host" ]]; then
    echo "error: role '$role' is not hosted — nothing to promote (use 'project spawn $role')" >&2
    exit 1
  fi
  local a have_seed=false
  for a in "$@"; do
    case "$a" in --task|--task-file|--resume) have_seed=true ;; esac
  done
  if ! $have_seed; then
    echo "error: promote needs the role's handoff: --task-file <path> (or --task / --task -), or --resume" >&2
    exit 1
  fi
  cmd_spawn "$@"
}

# Fresh context, same role, in one command: the agent writes its distill file, then a
# takeover successor (same label/title/cwd, fresh session) reads it and retires the
# predecessor. A blocked or stuck agent is left running, never killed mid-write.
cmd_recycle() {
  local role="" timeout="$DUMP_TIMEOUT_DEFAULT" usage="usage: project recycle <role> [--timeout SECS]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:?--timeout needs a value}"; shift 2 ;;
      -*) echo "$usage" >&2; exit 1 ;;
      *) [[ -z "$role" ]] || { echo "$usage" >&2; exit 1; }; role="$1"; shift ;;
    esac
  done
  if [[ -z "$role" ]]; then
    echo "$usage" >&2
    exit 1
  fi
  local f caller pane host
  f="$(ensure_state)"
  caller="$(resolve_caller "$f")"
  pane="$(read_pane "$f" "$role")"
  host="$(read_host "$role" "$f")"
  if [[ -n "$host" ]]; then
    echo "error: '$role' is hosted by $host — no agent of its own to recycle" >&2
    exit 1
  fi
  if [[ -z "$pane" ]]; then
    echo "error: '$role' has no agent — nothing to recycle" >&2
    exit 1
  fi
  if [[ "$caller" == "$role" || "$pane" == "$(be_self)" ]]; then
    echo "error: refusing to recycle your own role — send DISTILL to the orchestrator instead" >&2
    exit 1
  fi
  if [[ "$(jq -r --arg r "$role" '.agents[$r].stopped // false' "$f")" == "true" ]] || ! be_alive "$pane"; then
    echo "error: '$role' is not running — use 'project spawn $role --resume' or a plain spawn" >&2
    exit 1
  fi

  local dir distill out why
  dir="$(project_dir)"
  distill="$dir/$role.distill.md"
  # Archive a previous distill so "file exists" means "written this time"
  [[ -f "$distill" ]] && mv "$distill" "$dir/$role.distill.$(date +%Y%m%dT%H%M%S).md"
  log_signal "${caller:-user}" "$role" "DISTILL_ACK" "project recycle"
  echo "recycling $role: asking it to write $distill (timeout ${timeout}s)"
  if ! out=$(be_prompt "$pane" "DISTILL_ACK — you are being recycled into a fresh session. Commit any WIP with a [WIP] prefix, then write your state to $distill: what's done (commits, files), what's left, current approach and key decisions, anything others don't know (local context, debugging findings). Keep it short; link instead of restating. Don't signal or prompt other agents. Reply with one line: 'written'." --wait --until idle --until done --timeout $((timeout * 1000)) 2>&1); then
    if [[ "$out" == *agent_blocked* ]]; then why="blocked on a prompt in $pane — answer it, then re-run"
    elif [[ "$out" == *timeout* ]]; then why="still working after ${timeout}s — re-run to retry"
    else why="error: ${out%%$'\n'*}"; fi
    echo "LEFT RUNNING — $role $why" >&2
    exit 1
  fi
  if [[ ! -s "$distill" ]]; then
    echo "LEFT RUNNING — $role went idle without writing $distill; re-run to retry" >&2
    exit 1
  fi

  local cwd label title
  cwd="$(jq -r --arg r "$role" '.agents[$r].spawn.cwd // empty' "$f")"
  label="$(jq -r --arg r "$role" '.agents[$r].spawn.label // empty' "$f")"
  title="$(jq -r --arg r "$role" '.agents[$r].spawn.title // empty' "$f")"
  if [[ -z "$cwd" ]]; then
    echo "note: no spawn settings recorded for '$role' (spawned by an older version) — using cwd=$PWD, label/title=$role" >&2
    cwd="$PWD"; label="$role"; title="$role"
  fi
  local original=""
  [[ -f "$dir/$role.boot.md" ]] && original="$(cat "$dir/$role.boot.md")"

  cmd_spawn "$role" --takeover --cwd "$cwd" --label "$label" --title "$title" --wait --timeout 60000 --task - <<EOF
${original:+$original

}You are taking over as $role after a recycle. Before waiting for anything:
1. Run: project register $role
2. Read $distill — your predecessor's state. Trust it; don't re-verify everything against the tracker or GitHub (that refills your context immediately). Check a specific item only when you act on it.
3. Your predecessor is still live as $role@prev. If anything in the distill file is unclear, ask it directly: project ask $role@prev '<question>'.
4. When you have no more questions (or none at all), run: project retire $role
5. Continue the work.
EOF
  echo "recycled: $role — the successor retires the predecessor after reading $distill"
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

# Bring the share clone forward to the newest release tag, now (the app does this at most
# daily on start; the plugin on `herdr plugin update`). With the app's mod installed, its
# mod-setup.sh does the work so the panel's files are refreshed too (the app hot-reloads them).
cmd_update() {
  [[ -e "$PROJECT_SHARE/.git" ]] || { echo "error: no install at $PROJECT_SHARE — install the plugin or the mod first" >&2; exit 1; }
  local before mod="" f
  before="$(_toml_version "$PROJECT_SHARE")"
  for f in "$HOME"/.config/herdr-app/mods/*/mod-setup.sh; do
    [[ -f "$f" ]] && grep -q 'project-orchestration mod-setup' "$f" || continue
    git -C "$(dirname "$f")" rev-parse --is-inside-work-tree >/dev/null 2>&1 && continue   # dev copy
    mod="$f"; break
  done
  if [[ -n "$mod" ]]; then
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/herdr-plugins.project-orchestration/.last-fetch"
    bash "$mod" | sed '$d'
  else
    git -C "$PROJECT_SHARE" fetch --quiet --tags origin || { echo "error: fetch failed (offline?)" >&2; exit 1; }
    local tag head tagc
    tag="$(git -C "$PROJECT_SHARE" tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
    if [[ -n "$tag" ]]; then
      head="$(git -C "$PROJECT_SHARE" rev-parse HEAD)"
      tagc="$(git -C "$PROJECT_SHARE" rev-parse "refs/tags/$tag^{commit}")"
      if [[ "$head" != "$tagc" ]] && git -C "$PROJECT_SHARE" merge-base --is-ancestor "$head" "$tagc"; then
        git -C "$PROJECT_SHARE" checkout --quiet --detach "$tag"
      fi
    fi
    bash "$PROJECT_SHARE/scripts/setup.sh"
  fi
  local after
  after="$(_toml_version "$PROJECT_SHARE")"
  if [[ "$before" == "$after" ]]; then echo "project: up to date (v$after)"; else echo "project: updated v$before → v$after"; fi
  rm -f "$PROJECTS_DIR/.update-check-result"
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
# was created with (and on the hc backend nothing is injected at all), but the
# terminal itself still knows who it is — recover the project name from its
# project label, else from the state file that claims this pane or workspace.
if [[ -z "${HERDR_PROJECT:-}" ]]; then
  _recovered="$(be_self_project)"
  [[ -n "$_recovered" ]] || _recovered="$(_project_from_state_files)"
  [[ -n "$_recovered" ]] && export HERDR_PROJECT="$_recovered"
fi

# Release notice for the person at a shell, not for project agents (they'd act on it mid-project).
[[ -n "${HERDR_PROJECT:-}" ]] || _update_check

cmd="${1:-}"
shift || true

case "$cmd" in
  start)      cmd_start "$@" ;;
  init)       cmd_init "$@" ;;
  register)    cmd_register "$@" ;;
  stop)        cmd_stop "$@" ;;
  spawn)       cmd_spawn "$@" ;;
  host)        cmd_host "$@" ;;
  promote)     cmd_promote "$@" ;;
  open)        cmd_open "$@" ;;
  close)       cmd_close ;;
  rename)      cmd_rename "$@" ;;
  next-worker) cmd_next_worker ;;
  assign)      cmd_assign "$@" ;;
  prompt)     cmd_prompt "$@" ;;
  ask)        cmd_ask "$@" ;;
  read)       cmd_read "$@" ;;
  roster)     cmd_roster ;;
  status)     cmd_status "$@" ;;
  info)       cmd_info ;;
  name)       cmd_name ;;
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
  recycle)    cmd_recycle "$@" ;;
  reset)      cmd_reset "$@" ;;
  log)        cmd_log "$@" ;;
  log-decision) cmd_log_decision "$@" ;;
  feedback)   cmd_feedback "$@" ;;
  cleanup)     cmd_cleanup "$@" ;;
  recover)    cmd_recover "$@" ;;
  check-in)   cmd_checkin "$@" ;;
  observe)    cmd_observe ;;
  update)     cmd_update ;;
  *)          usage ;;
esac
