#!/usr/bin/env bash
# Shared delivery queue for a target that is not accepting input (blocked on a question or
# permission prompt). Sourced by backend/hc.sh and backend/herdr.sh — never run directly.
#
# A blocked agent can't take a message, and forcing one could answer its prompt. So a
# message is never dropped and never forced: a fire-and-forget prompt that finds the target
# blocked (or finds earlier queued messages, to keep order) is written to a per-target queue
# under the project dir, and a detached deliverer sends it once the target accepts input.
#   <project dir>/queue/<target>/NNNNNNNN.msg   one message each, sorted = send order
#   <project dir>/queue/<target>/.deliverer/     lock (mkdir) holding the deliverer pid
#   <project dir>/queue/<target>/.mx/            short lock for sequence allocation
# QUEUED / DELIVERED / DROPPED entries go to the project signal log.
#
# The sourcing backend must define:
#   _be_q_send <pane> <message>   deliver one message. Prints the raw result; returns 0 only
#                                 if it was accepted. Must never force or answer a prompt.
#   _be_q_retryable <output>      0 if a failed send left nothing typed and is worth retrying
#                                 (target blocked, still starting)
#   _be_q_live <pane>             0 while the target exists and can still receive messages
#   _be_q_launch <pane> <dir>     start `_q_deliver <pane> <dir>` detached, surviving the
#                                 caller exiting. Non-zero if it could not start (or a
#                                 deliverer of that name is already running).
# and route its own `--deliver` entry point to _q_deliver_loop.

_q_dir() {
  local proj root t
  proj=$(resolve_project 2>/dev/null) || proj=_noproject
  [[ -n "$proj" ]] || proj=_noproject
  root="${PROJECTS_DIR:-$HOME/.herdr/projects}/$proj/queue"
  t=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
  echo "$root/$t"
}

_q_pending() {
  compgen -G "$1/*.msg" >/dev/null 2>&1
}

# <sigfile> <sender> <receiver> <type> <payload>  (same columns as log_signal)
_q_log() {
  local sig="$1" payload
  [[ -n "$sig" ]] || return 0
  payload=$(printf '%s' "$5" | tr '\n\t' '  ' | cut -c1-200)
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$payload" \
    >> "$sig" 2>/dev/null || true
}

# Append <message> for <pane> to its queue and make sure a deliverer is running.
_q_enqueue() {
  local pane="$1" message="$2" dir n i sig sender
  dir=$(_q_dir "$pane")
  mkdir -p "$dir" || return 1
  sig=$(signals_file 2>/dev/null || true)
  [[ -n "$sig" ]] && printf '%s' "$sig" > "$dir/.sig"
  # allocate the next sequence number under a short lock (stale after ~10s)
  for i in $(seq 1 100); do
    mkdir "$dir/.mx" 2>/dev/null && break
    [[ $i -eq 100 ]] && { rm -rf "$dir/.mx"; mkdir "$dir/.mx" 2>/dev/null || true; }
    sleep 0.1
  done
  n=$(( 10#$(cat "$dir/.seq" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$dir/.seq"
  printf '%s' "$message" > "$dir/.tmp.$n"
  mv "$dir/.tmp.$n" "$dir/$(printf '%08d' "$n").msg"
  rmdir "$dir/.mx" 2>/dev/null || true
  sender=$(be_self 2>/dev/null || true)
  _q_log "$sig" "${sender:-unknown}" "$pane" "QUEUED" "target not accepting input, queued #$n: $message"
  _q_ensure_deliverer "$pane" "$dir"
}

_q_ensure_deliverer() {
  local pane="$1" dir="$2" i pid
  for i in 1 2 3; do
    if mkdir "$dir/.deliverer" 2>/dev/null; then
      if _be_q_launch "$pane" "$dir"; then
        return 0   # the deliverer writes its own pid into the lock
      fi
      rm -rf "$dir/.deliverer"   # name taken (live one draining/exiting) or launch failed: retry
      sleep 0.5
      continue
    fi
    pid=$(cat "$dir/.deliverer/pid" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then sleep 0.5; pid=$(cat "$dir/.deliverer/pid" 2>/dev/null || true); fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -rf "$dir/.deliverer"   # dead deliverer: take over
  done
  return 0
}

# The deliverer: sends queued messages in order, retrying while the target is blocked.
# Gives up (logging each dropped message) when the target is gone or finished, or after
# ~12h. Exits when the queue is empty.
_q_deliver_loop() {
  local pane="$1" dir="$2" sig mypid="" f msg out rc tries started=$SECONDS left
  sig=$(cat "$dir/.sig" 2>/dev/null || true)
  mypid=$$
  echo "$mypid" > "$dir/.deliverer/pid" 2>/dev/null || exit 0
  while true; do
    [[ -d "$dir" ]] || exit 0
    f=$(ls "$dir"/*.msg 2>/dev/null | head -1)
    if [[ -z "$f" ]]; then
      rm -rf "$dir/.deliverer"                        # release, then re-check for a late enqueue
      _q_pending "$dir" || exit 0
      mkdir "$dir/.deliverer" 2>/dev/null || exit 0   # someone else took over
      echo "$mypid" > "$dir/.deliverer/pid"
      continue
    fi
    msg=$(cat "$f")
    tries=0
    while true; do
      [[ -d "$dir" ]] || exit 0
      rc=0
      out=$(_be_q_send "$pane" "$msg" 2>&1) || rc=$?
      if [[ $rc -eq 0 ]]; then
        rm -f "$f"
        _q_log "$sig" queue "$pane" "DELIVERED" "queued message delivered: $msg"
        break
      fi
      left=""
      if ! _be_q_live "$pane"; then left="target gone or finished"
      elif (( SECONDS - started > 43200 )); then left="gave up after 12h"
      elif ! _be_q_retryable "$out" && (( ++tries >= 10 )); then left="send keeps failing: $(echo "$out" | head -c 120)"
      fi
      if [[ -n "$left" ]]; then
        for f in "$dir"/*.msg; do
          [[ -f "$f" ]] || continue
          _q_log "$sig" queue "$pane" "DROPPED" "$left: $(cat "$f")"
          rm -f "$f"
        done
        break
      fi
      sleep "${HC_QUEUE_POLL:-3}"
    done
  done
}
