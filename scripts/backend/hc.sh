#!/usr/bin/env bash
# Backend: Herdr app (herdr-core `hc` for terminals, `herdr-app do` for the window).
# Sourced by project.sh — never run directly. Same be_* contract as backend/herdr.sh
# (see the header there); this file lists only where hc differs.
#
# Handles: a "pane" is the hc terminal NAME (stable; ids like t7 work too). A
# "workspace" is a Herdr app space id, a "tab" an app tab id.
#
# Conventions (docs/dual-mode.md § Decisions):
#   - every terminal is started with --no-parent (no hierarchy, no auto-kill, no auto notes)
#   - terminal name = <project>-<role>, lowercase a-z0-9-_, max 32 chars (_hc_name)
#   - labels project=<key> role=<role>, plus herdr.space=<space id> so the app shows it
#     in a new tab of that space; session=<id> so be_session works (hc has no session API)
#   - the first task goes in the launch (a send to a booting agent can be dropped)
#   - hc send already waits out a human's half-typed draft, so no ctrl+s stash
#   - HERDR_PROJECT can't be injected (hc has no --env); be_self_project reads the project label

be_available() {
  command -v hc &>/dev/null && command -v herdr-app &>/dev/null && command -v jq &>/dev/null
}

# --- helpers ---------------------------------------------------------------

# Deterministic terminal name for <project> <role>: sanitized, <= 32 chars.
# Too long -> first 21 chars + "-" + 10-digit cksum of the full name (stable).
# Taken by a LIVE terminal -> "-2", "-3", ... (base trimmed to fit).
_hc_name() {
  local base n cand suffix live
  base=$(printf '%s-%s' "$1" "$2" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')
  if [[ ${#base} -gt 32 ]]; then
    n=$(printf '%s' "$base" | cksum | awk '{printf "%010d", $1}')
    base="${base:0:21}-$n"
  fi
  live=$(hc ls --json 2>/dev/null | jq -r '.terminals[]?.name // empty' 2>/dev/null || true)
  cand="$base"
  n=1
  while grep -qxF -- "$cand" <<<"$live"; do
    n=$((n + 1))
    suffix="-$n"
    cand="${base:0:$((32 - ${#suffix}))}$suffix"
    [[ $n -gt 99 ]] && { echo "error: no free terminal name for $base" >&2; return 1; }
  done
  echo "$cand"
}

# Tab id (app) containing a terminal name/id; empty if none.
_hc_tab_of() {
  herdr-app ls 2>/dev/null | jq -r --arg h "$1" \
    '[.spaces[]?.tabs[]? | select(any(.terminals[]?; .name == $h or .terminal == $h)) | .id][0] // empty' \
    2>/dev/null || true
}

# --- workspaces (app spaces) -------------------------------------------------

# Prints "<space_id> <root_terminal_id>". The root is an unnamed shell; be_spawn --root
# replaces it (closes it once the agent's own tab exists).
be_workspace_create() {
  local cwd="$1" label="$2" project="$3" focus="$4" out ws term
  out=$(herdr-app do space.new --name "$label" --folder "$cwd" --focus "$focus" 2>&1) || {
    echo "error: failed to create space" >&2
    echo "$out" >&2
    return 1
  }
  ws=$(echo "$out" | jq -r '.space // empty' 2>/dev/null)
  if [[ -z "$ws" ]]; then
    echo "error: space creation returned no ID" >&2
    echo "$out" >&2
    return 1
  fi
  term=$(echo "$out" | jq -r '.terminal // empty' 2>/dev/null)
  # space.new always makes a root shell. Mark it so the first be_spawn into this space
  # (without --root) retires it.
  [[ -n "$term" ]] && hc label "$term" "herdr.root=$ws" >/dev/null 2>&1 || true
  echo "$ws $term"
}

be_workspace_exists() {
  herdr-app ls 2>/dev/null | jq -e --arg id "$1" 'any(.spaces[]?; .id == $id)' >/dev/null 2>&1
}

be_workspace_close() {
  herdr-app do space.close --id "$1" --confirmed true >/dev/null
}

# Wait for <pane>'s turn to end, until absolute deadline <SECONDS value>. <reason> is the
# reason of a wait that already returned ("" = none yet, wait first). hc wait also returns
# early with reason "message" (the target messaged us while still working); that is not the
# end of the turn, so wait again with the time left. Prints the last wait JSON (or the hc
# error text). Returns 0 turn ended, 1 deadline passed, 2 hc error.
_hc_wait_turn() {
  local pane="$1" deadline="$2" reason="${3:-}" remaining res=""
  while [[ -z "$reason" || "$reason" == "message" ]]; do
    remaining=$(( deadline - SECONDS ))
    [[ $remaining -le 0 ]] && return 1
    res=$(hc wait --json --timeout "$remaining" "$pane" 2>&1) || { echo "$res"; return 2; }
    reason=$(echo "$res" | jq -r '.reason // empty' 2>/dev/null)
    [[ -n "$reason" ]] || { echo "$res"; return 0; }   # unparseable: don't spin
  done
  [[ "$reason" == "timeout" ]] && return 1
  echo "$res"
  return 0
}

# --- creating agents ---------------------------------------------------------

# Create a tab with a plain shell. Prints "<terminal_id> <tab_id>". Only here for
# contract completeness: project.sh creates agents through be_spawn.
be_tab_create() {
  local ws="$1" cwd="$2" label="$3" project="$4" out term tab
  out=$(herdr-app do tab.new --space "$ws" --name "$label" --folder "$cwd" --focus false 2>&1) || {
    echo "error: failed to create tab" >&2
    echo "$out" >&2
    return 1
  }
  term=$(echo "$out" | jq -r '.terminal // empty' 2>/dev/null)
  tab=$(echo "$out" | jq -r '.tab // empty' 2>/dev/null)
  if [[ -z "$term" ]]; then
    echo "error: tab create returned no terminal ID" >&2
    echo "$out" >&2
    return 1
  fi
  echo "$term $tab"
}

# Not used on hc: an agent can't be started in a pane and sent its task separately
# without risking a dropped first message. Use be_spawn.
be_agent_start() {
  echo "error: be_agent_start is not supported on the hc backend — use be_spawn" >&2
  return 1
}

# See the contract in backend/herdr.sh. Launches `claude <args> <message>` with hc.
# Prints "<terminal name> <tab id>" as soon as the terminal exists.
be_spawn() {
  local do_wait=false timeout_ms="" root="" echo_out=false pre=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pre-task) pre="${2:?--pre-task needs a function}"; shift 2 ;;
      --wait)    do_wait=true; shift ;;
      --timeout) timeout_ms="${2:?--timeout needs a value}"; shift 2 ;;
      --root)    root="${2:?--root needs a value}"; shift 2 ;;
      --echo)    echo_out=true; shift ;;
      *) break ;;
    esac
  done
  local ws="$1" cwd="$2" label="$3" project="$4" role="$5" message="$6"
  shift 6

  local name
  name="$(_hc_name "$project" "$role")" || return 1

  # Session id: fresh launches get one we choose (hc can't report claude's), a resume
  # keeps the one being resumed. Stored as a label for be_session.
  local sid="" a prev="" args=()
  for a in "$@"; do
    [[ "$prev" == "--resume" ]] && sid="$a"
    args+=("$a")
    prev="$a"
  done
  if [[ -z "$sid" ]]; then
    sid="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [[ -n "$sid" ]] && args=(--session-id "$sid" ${args[@]+"${args[@]}"})
  fi
  [[ -n "$message" ]] && args+=("$message")

  local labels=(--label "project=$project" --label "role=$role" --label "herdr.space=$ws")
  [[ -n "$sid" ]] && labels+=(--label "session=$sid")

  # The name is deterministic, so the caller can register the role before the agent exists
  # (its first signal can't be logged as 'unknown'). The tab isn't known yet; the caller
  # patches it in from be_spawn's output.
  [[ -z "$pre" ]] || "$pre" "$name" "" "$sid" >/dev/null || return 1

  local out
  out=$(hc run --bg --no-parent --name "$name" --cwd "$cwd" "${labels[@]}" --json -- claude ${args[@]+"${args[@]}"} 2>&1) || {
    echo "error: failed to start $name" >&2
    echo "$out" >&2
    return 1
  }
  # Launch tasks are placed in the claude argv, but if hc reports one it never sent, say so.
  if [[ "$(echo "$out" | jq -r '.first_message.sent // empty' 2>/dev/null)" == "false" ]]; then
    echo "error: $name started but its first task was NOT sent: $(echo "$out" | jq -r '.first_message.reason // "unknown"')" >&2
    echo "  read it with: hc read $name" >&2
    return 1
  fi

  # The app puts the terminal in a new tab of the space; find it, name it, retire the placeholder.
  local tab="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    tab="$(_hc_tab_of "$name")"
    [[ -n "$tab" ]] && break
    sleep 0.3
  done
  [[ -n "$tab" ]] && herdr-app do tab.rename --id "$tab" --name "$label" >/dev/null 2>&1 || true
  if [[ -z "$root" ]]; then
    # `project open` leaves a marked root shell; the first agent into the space replaces it.
    root="$(hc ls --json --label "herdr.root=$ws" 2>/dev/null | jq -r '.terminals[0].address // empty' 2>/dev/null)" || root=""
  fi
  [[ -n "$root" ]] && { hc kill "$root" >/dev/null 2>&1 || true; hc rm "$root" >/dev/null 2>&1 || true; }

  echo "$name $tab"

  if $do_wait && [[ -n "$message" ]]; then
    local res wrc=0 timeout_s=180
    [[ -n "$timeout_ms" ]] && timeout_s=$(( (timeout_ms + 999) / 1000 ))
    res=$(_hc_wait_turn "$name" $(( SECONDS + timeout_s ))) || wrc=$?
    if [[ $wrc -eq 1 ]]; then
      echo "timeout: $name still working" >&2
      return 1
    elif [[ $wrc -ne 0 ]]; then
      echo "$res" >&2
      return 1
    fi
    if $echo_out; then echo "$res" >&2; fi
  fi
}

# --- talking to agents -------------------------------------------------------

# --- blocked targets: per-target delivery queue -----------------------------
# `hc send` refuses a blocked terminal (a person must answer a question or permission
# prompt) unless --force, and --force could answer that prompt. The queue itself is shared
# with the classic backend (backend/queue.sh); this section is the hc side of its hooks.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue.sh"

# A failed send worth retrying: target blocked, or hc says nothing was typed yet
# (still starting / settling). Both leave the message untyped.
_be_q_retryable() {
  [[ "$1" == *blocked* || "$1" == *'"kind":"unavailable"'* ]]
}

# A refused/failed `hc send` (<json-or-text> <exit code>) -> 0 if it failed.
_hc_send_failed() {
  [[ "$2" -ne 0 ]] || echo "$1" | jq -e '.error' >/dev/null 2>&1
}

_be_q_live() {
  [[ "$(hc get "$1" --json 2>/dev/null | jq -r '.state // empty' 2>/dev/null)" == "live" ]]
}

_be_q_send() {
  local out rc=0
  out=$(hc send --json "$1" "$2" 2>&1) || rc=$?
  echo "$out"
  ! _hc_send_failed "$out" "$rc"
}

# The deliverer runs as its own hc terminal (not a child of whatever process ran
# `project prompt`, which a tool runner may kill when its call ends). Name is stable per
# target, so a collision with a live one just means it is already draining.
_hc_dname() {
  local base n
  base=$(printf 'dlv-%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')
  if [[ ${#base} -gt 32 ]]; then
    n=$(printf '%s' "$base" | cksum | awk '{printf "%010d", $1}')
    base="${base:0:21}-$n"
  fi
  printf '%s' "$base"
}

_be_q_launch() {
  local proj
  proj=$(resolve_project 2>/dev/null || true); [[ -n "$proj" ]] || proj=_noproject
  hc run --bg --no-parent --rm --no-notify --name "$(_hc_dname "$1")" \
    --label "project=$proj" --label role=deliver --cwd "$2" -- \
    env "HC_QUEUE_POLL=${HC_QUEUE_POLL:-3}" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hc.sh" --deliver "$1" "$2" \
    </dev/null >/dev/null 2>&1
}

# Deliver a message. Args after the message: --wait, --until S (ignored: hc waits for the
# turn the send started), --timeout MS (hc takes seconds). hc holds the send while a person
# is typing, so there is no draft stash.
# A blocked target (hc refuses without --force, which could answer its prompt) never loses
# the message:
#   - fire-and-forget: queued (see above) and delivered by a detached deliverer as soon as
#     the target accepts input; returns 0 at once. Earlier queued messages for the same
#     target also force queueing, so order from a sender is kept.
#   - --wait: waits for the unblock (and for earlier queued messages to drain) within the
#     deadline, then delivers and waits for the turn. On deadline prints a line containing
#     "agent_blocked" (target still blocked) or "timeout", like the classic backend.
# With --wait, returns only when the target's turn has ended or the timeout (counted from
# the start, default 180s) expires: hc wait also returns early with reason "message" (the
# target messaged us while still working) — that is not the end of the turn, so wait again.
be_prompt() {
  local pane="$1" message="$2"; shift 2
  local do_wait=false timeout_s=180
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait)    do_wait=true; shift ;;
      --until)   shift 2 ;;
      --timeout) timeout_s="$(( ($2 + 999) / 1000 ))"; shift 2 ;;
      *) shift ;;
    esac
  done
  local deadline=$(( SECONDS + timeout_s ))
  local out rc reason wres dir remaining args
  dir=$(_q_dir "$pane")

  while true; do
    if [[ -d "$dir" ]] && _q_pending "$dir"; then
      # earlier messages are still queued: keep order
      if ! $do_wait; then
        _q_enqueue "$pane" "$message" && echo '{"queued":true}'
        return 0
      fi
      if (( SECONDS >= deadline )); then
        if [[ "$(hc get "$pane" --json 2>/dev/null | jq -r '.status.state // empty' 2>/dev/null)" == "blocked" ]]; then
          echo "agent_blocked: $pane is blocked and has earlier queued messages not yet delivered"
        else
          echo "timeout: $pane has earlier queued messages not yet delivered"
        fi
        return 1
      fi
      sleep 2
      continue
    fi
    args=(--json)
    remaining=$(( deadline - SECONDS ))
    [[ $remaining -lt 1 ]] && remaining=1
    $do_wait && args+=(--wait --timeout "$remaining")
    rc=0
    out=$(hc send "${args[@]}" "$pane" "$message" 2>&1) || rc=$?
    _hc_send_failed "$out" "$rc" || break
    if _be_q_retryable "$out"; then
      if ! $do_wait; then
        _q_enqueue "$pane" "$message" && echo '{"queued":true}'
        return 0
      fi
      if (( SECONDS >= deadline )); then
        if [[ "$out" == *blocked* ]]; then echo "agent_blocked: $out"; else echo "timeout: $pane not ready: $out"; fi
        return 1
      fi
      sleep 2
      continue
    fi
    echo "$out"
    return 1
  done

  reason=""
  if $do_wait; then
    reason=$(echo "$out" | jq -r '.wait.reason // empty' 2>/dev/null)
    if [[ "$reason" == "message" ]]; then
      local wrc=0
      wres=$(_hc_wait_turn "$pane" "$deadline" message) || wrc=$?
      if [[ $wrc -eq 1 ]]; then reason=timeout
      elif [[ $wrc -ne 0 ]]; then echo "$wres"; return 1
      else out=$(echo "$out" | jq -c --argjson w "$wres" '.wait = $w' 2>/dev/null || echo "$out"); reason=""
      fi
    fi
  fi
  if [[ "$reason" == "timeout" ]]; then
    echo "timeout: $pane still working"
    return 1
  fi
  echo "$out"
}

be_read() {
  hc read "$1" --lines "$2" 2>/dev/null
}

# hc can't report claude's session id; be_spawn stores it as a label.
be_session() {
  hc get "$1" --json 2>/dev/null | jq -r '.labels.session // empty' 2>/dev/null || true
}

# working|idle|blocked|done|unknown; empty if unreachable (gone or finished). "error" maps
# to blocked (a person needs to look); plain programs report no status -> unknown.
be_state() {
  local out
  out=$(hc get "$1" --json 2>/dev/null) || return 0
  jq -r 'if .state != "live" then empty
         else (.status.state // "unknown") | if . == "error" then "blocked" else . end end' \
    <<<"$out" 2>/dev/null || true
}

be_alive() {
  [[ -n "$(be_state "$1")" ]]
}

be_close_pane() {
  hc kill "$1" >/dev/null 2>&1 || true
  hc rm "$1" >/dev/null 2>&1 || true
}

be_tab_of() {
  [[ -n "$1" ]] || return 0
  _hc_tab_of "$1"
}

be_tab_close() {
  herdr-app do tab.close --id "$1" --confirmed true >/dev/null
}

be_tab_rename() {
  herdr-app do tab.rename --id "$1" --name "$2" >/dev/null
}

# --- identity ----------------------------------------------------------------

# Own handle: the terminal's name if it has one (what be_spawn stores), else its id.
be_self() {
  [[ -n "${HC_TERMINAL_ID:-}" ]] || return 0
  hc get "$HC_TERMINAL_ID" --json 2>/dev/null \
    | jq -r --arg id "$HC_TERMINAL_ID" '.name // $id' 2>/dev/null || echo "$HC_TERMINAL_ID"
}

be_self_workspace() {
  [[ -n "${HC_TERMINAL_ID:-}" ]] || return 0
  hc get "$HC_TERMINAL_ID" --json 2>/dev/null | jq -r '.labels["herdr.space"] // empty' 2>/dev/null || true
}

be_self_project() {
  [[ -n "${HC_TERMINAL_ID:-}" ]] || return 0
  hc get "$HC_TERMINAL_ID" --json 2>/dev/null | jq -r '.labels.project // empty' 2>/dev/null || true
}

# The mod's init() owns install and upgrade; there is no plugin SHA to compare.
be_update_check() {
  return 0
}

# Entry point for the deliverer terminal: bash hc.sh --deliver <pane> <queue dir>
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == "--deliver" ]]; then
  set +e
  _q_deliver_loop "$2" "$3"
fi
