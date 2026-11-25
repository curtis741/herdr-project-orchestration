#!/usr/bin/env bash
# The plugin's build hook. Every install ends up as one git clone in the share folder; this
# brings that clone forward to at least this plugin checkout's version (never backwards),
# then runs the clone's setup.sh, which links the CLI, skills and guide from the clone.
set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
SHARE="${PROJECT_ORCH_SHARE:-$HOME/.local/share/project-orchestration}"
REPO="${PROJECT_ORCH_REPO:-https://github.com/curtis741/herdr-project-orchestration}"

toml_version() { grep '^version' "$1/herdr-plugin.toml" 2>/dev/null | sed 's/.*"\(.*\)"/\1/'; }
# true when $1 >= $2 as versions
ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }

want="$(toml_version "$PLUGIN_DIR")"
[[ -n "$want" ]] || { echo "plugin-setup: no version in $PLUGIN_DIR/herdr-plugin.toml" >&2; exit 1; }

# This checkout's commit, if it is a git checkout: the fallback when the tag isn't published.
head_commit=""
if git -C "$PLUGIN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  head_commit="$(git -C "$PLUGIN_DIR" rev-parse HEAD 2>/dev/null || true)"
fi

if [[ ! -e "$SHARE/.git" ]]; then
  if [[ -e "$SHARE" ]] && [[ -n "$(ls -A "$SHARE" 2>/dev/null)" ]]; then
    echo "plugin-setup: $SHARE exists and is not a git clone; move it aside and re-run." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SHARE")"
  echo "Cloning $REPO → $SHARE"
  git clone --quiet "$REPO" "$SHARE"
  cur=""
else
  cur="$(toml_version "$SHARE")"
fi

if [[ -n "$cur" ]] && ver_ge "$cur" "$want"; then
  echo "✓ Share clone at v$cur (plugin checkout is v$want) — not moving it"
else
  echo "Moving share clone ${cur:+v$cur }→ v$want"
  git -C "$SHARE" fetch --quiet --tags origin
  if git -C "$SHARE" rev-parse -q --verify "refs/tags/v$want^{commit}" >/dev/null; then
    git -C "$SHARE" checkout --quiet --detach "v$want"
  elif [[ -n "$head_commit" ]] && git -C "$SHARE" cat-file -e "$head_commit^{commit}" 2>/dev/null; then
    echo "  (tag v$want not published; using this checkout's commit ${head_commit:0:9})"
    git -C "$SHARE" checkout --quiet --detach "$head_commit"
  else
    echo "plugin-setup: neither tag v$want nor this checkout's commit exists in $REPO." >&2
    exit 1
  fi
  now="$(toml_version "$SHARE")"
  ver_ge "$now" "$want" || { echo "plugin-setup: clone is at v$now after checkout, expected v$want" >&2; exit 1; }
fi

exec bash "$SHARE/scripts/setup.sh"
