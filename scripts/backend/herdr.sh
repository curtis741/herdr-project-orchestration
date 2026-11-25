#!/usr/bin/env bash
# Backend: classic Herdr (the `herdr` CLI). Sourced by project.sh — never run directly.
#
# This file is the only place that calls `herdr`. project.sh owns CLI parsing,
# state files and signal logging, and talks to the terminal layer only through
# the be_* functions below. A second backend (backend/hc.sh) must define the same
# functions with the same arguments and output.
#
# Contract (ids are opaque strings; "pane" is the handle stored in the state file):
#   be_available                                   0 if the backend CLI is usable
#   be_workspace_create <cwd> <label> <project> <focus:true|false>
#                                                  prints "<workspace_id> <root_pane_id>"
#   be_workspace_exists <workspace_id>             0 if the workspace is reachable
#   be_workspace_close <workspace_id>
#   be_tab_create <workspace_id> <cwd> <label> <project>
#                                                  prints "<pane_id> <tab_id>"
#   be_agent_start <pane> <name> [claude args...]  start claude in a fresh pane (retries while it boots)
#   be_spawn [--wait] [--timeout MS] [--root <pane>] [--echo] <workspace_id> <cwd> <label> <project> <role> <message> [claude args...]
#                                                  create a tab (or, with --root, reuse that pane), start claude, deliver
#                                                  <message> (may be empty) as its first task. Prints "<pane> <tab>" BEFORE
#                                                  delivering/waiting, so the caller can still register the agent when
#                                                  delivery fails (non-zero exit). --wait blocks until the first turn ends.
#                                                  --echo sends the delivery result to stderr instead of discarding it.
#                                                  --pre-task FN calls "FN <pane> <tab> <session>" (stdout discarded; non-zero
#                                                  aborts) after the agent exists but BEFORE it can run anything, so the caller
#                                                  can register the role first. Classic: between agent start and the prompt
#                                                  (session empty; <tab> known). hc: before launch, with the deterministic name
#                                                  (tab empty, session known); the caller patches the tab in from the output.
#                                                  Backends that can't send a task after launch (hc) put it in the launch.
#   be_self                                        this agent's own handle, comparable to the stored one (empty if unknown)
#   be_self_workspace                              workspace id this agent lives in (empty if unknown)
#   be_self_project                                project key recorded on this agent at spawn (empty if none; classic uses $HERDR_PROJECT)
#   be_prompt <pane> <message> [--wait] [--until S]... [--timeout MS]
#                                                  deliver a message, never clobbering a human draft
#   be_read <pane> <lines>                         recent unwrapped pane text
#   be_session <pane>                              agent session id (empty if unknown)
#   be_state <pane>                                working|idle|blocked|done|unknown; empty if unreachable
#   be_alive <pane>                                0 if the agent/pane is reachable
#   be_close_pane <pane>                           close one pane (errors ignored)
#   be_tab_of <pane>                               tab id containing the pane (empty if gone)
#   be_tab_close <tab>
#   be_tab_rename <tab> <label>
#   be_update_check <result-file>                  background: write a message to the file if an update exists

be_available() {
  command -v herdr &>/dev/null
}

# Create a workspace. Prints "<workspace_id> <root_pane_id>".
be_workspace_create() {
  local cwd="$1" label="$2" project="$3" focus="$4" flag="--no-focus" out ws pane
  [[ "$focus" == "true" ]] && flag="--focus"
  out=$(herdr workspace create --cwd "$cwd" --label "$label" --env "HERDR_PROJECT=$project" "$flag" 2>&1) || {
    echo "error: failed to create workspace" >&2
    echo "$out" >&2
    return 1
  }
  ws=$(echo "$out" | jq -r '.result.workspace.workspace_id // empty')
  if [[ -z "$ws" ]]; then
    echo "error: workspace creation returned no ID" >&2
    echo "$out" >&2
    return 1
  fi
  pane=$(echo "$out" | jq -r '.result.root_pane.pane_id // empty')
  echo "$ws $pane"
}

be_workspace_exists() {
  local id
  id=$(herdr workspace get "$1" 2>/dev/null | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true)
  [[ -n "$id" ]]
}

be_workspace_close() {
  herdr workspace close "$1" >/dev/null
}

# Create a tab in a workspace. Prints "<pane_id> <tab_id>".
be_tab_create() {
  local ws="$1" cwd="$2" label="$3" project="$4" out pane tab
  out=$(herdr tab create --workspace "$ws" --cwd "$cwd" --label "$label" \
    --env "HERDR_PROJECT=$project" --no-focus 2>&1) || {
    echo "error: failed to create tab" >&2
    echo "$out" >&2
    return 1
  }
  pane=$(echo "$out" | jq -r '.result.root_pane.pane_id // empty')
  tab=$(echo "$out" | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty')
  if [[ -z "$pane" ]]; then
    echo "error: tab create returned no pane ID" >&2
    echo "$out" >&2
    return 1
  fi
  echo "$pane $tab"
}

# Start a claude agent in a pane, retrying while the pane shell boots.
be_agent_start() {
  local pane="$1" name="$2"; shift 2
  local attempts=0
  while ! herdr agent start "$name" --kind claude --pane "$pane" -- "$@" 2>/dev/null \
      | jq -e '.result' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 10 ]]; then
      echo "error: pane $pane not ready after 5s — failed to start agent $name" >&2
      return 1
    fi
    sleep 0.5
  done
}

# One call that does tab_create + agent_start + first prompt. See contract above.
be_spawn() {
  local wait_args=() root="" echo_out=false pre=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pre-task) pre="${2:?--pre-task needs a function}"; shift 2 ;;
      --wait)    wait_args+=(--wait); shift ;;
      --timeout) wait_args+=(--timeout "${2:?--timeout needs a value}"); shift 2 ;;
      --root)    root="${2:?--root needs a value}"; shift 2 ;;
      --echo)    echo_out=true; shift ;;
      *) break ;;
    esac
  done
  local ws="$1" cwd="$2" label="$3" project="$4" role="$5" message="$6"
  shift 6
  local pane tab=""
  if [[ -n "$root" ]]; then
    pane="$root"
  else
    read -r pane tab < <(be_tab_create "$ws" "$cwd" "$label" "$project") || true
    [[ -n "$pane" ]] || return 1
  fi
  be_agent_start "$pane" "$role" "$@" || return 1
  [[ -z "$pre" ]] || "$pre" "$pane" "$tab" "" >/dev/null || return 1
  echo "$pane $tab"
  if [[ -n "$message" ]]; then
    if $echo_out; then
      be_prompt "$pane" "$message" ${wait_args[@]+"${wait_args[@]}"} >&2
    else
      be_prompt "$pane" "$message" ${wait_args[@]+"${wait_args[@]}"} >/dev/null
    fi
  fi
}

be_self() { echo "${HERDR_PANE_ID:-}"; }
be_self_workspace() { echo "${HERDR_WORKSPACE_ID:-}"; }
be_self_project() { :; }

# Deliver a prompt to an agent pane without clobbering a human's half-typed draft.
# `herdr agent prompt` types into the input box, so any draft gets concatenated
# with the incoming message. Ctrl+S is Claude Code's stash: it parks the draft,
# and Claude Code restores it automatically after the next submit. On an empty
# input it's a no-op. Extra args (--wait, --until, --timeout) pass through to
# `herdr agent prompt`.
be_prompt() {
  herdr agent send-keys "$1" ctrl+s >/dev/null 2>&1 || true
  herdr agent prompt "$@"
}

be_read() {
  herdr agent read "$1" --source recent-unwrapped --lines "$2" 2>/dev/null
}

# Session ID of the agent in a pane (empty if unknown).
be_session() {
  herdr agent get "$1" 2>/dev/null \
    | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null || true
}

# Agent state of a pane: working|idle|blocked|done|unknown (empty if unreachable).
be_state() {
  herdr agent get "$1" 2>/dev/null \
    | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || true
}

be_alive() {
  herdr agent get "$1" >/dev/null 2>&1
}

be_close_pane() {
  herdr pane close "$1" >/dev/null 2>&1 || true
}

be_tab_of() {
  herdr pane get "$1" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true
}

be_tab_close() {
  herdr tab close "$1" >/dev/null
}

be_tab_rename() {
  herdr tab rename "$1" "$2" >/dev/null
}

# Background-safe: compare the installed plugin SHA with the remote HEAD and, if
# they differ, write a one-line message to the result file. Silent on any failure.
be_update_check() {
  local cache="$1" plugin_info entry installed_sha repo_ref owner repo remote_sha
  plugin_info=$(herdr plugin list 2>/dev/null) || return 0
  entry=$(echo "$plugin_info" | grep 'project-orchestration' | grep 'github:') || return 0
  installed_sha=$(echo "$entry" | grep -oE '@[0-9a-f]+' | tr -d '@') || return 0
  repo_ref=$(echo "$entry" | grep -oE 'github:[^@]+' | sed 's/github://') || return 0
  owner="${repo_ref%%/*}"
  repo="${repo_ref#*/}"

  remote_sha=$(git ls-remote "https://github.com/$owner/$repo.git" HEAD 2>/dev/null \
    | awk '{print $1}') || return 0

  if [[ -n "$remote_sha" && -n "$installed_sha" && "$remote_sha" != "$installed_sha" ]]; then
    echo "project: plugin update available — run 'herdr plugin update' to get the latest" > "$cache"
  fi
}
