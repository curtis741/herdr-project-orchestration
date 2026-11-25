#!/usr/bin/env bash
# project-orchestration mod-setup — run by the mod's init(); safe to run by hand.
#
# Brings the share clone (~/.local/share/project-orchestration) forward to the newest release
# tag (clones it if missing; fetches at most once a day; never moves backwards), copies the
# clone's newer mod files over this folder, then runs the clone's scripts/setup.sh, which
# links the `project` CLI, skills, guide and context-guard hook from the clone.
#
# Last line of output, for the mod: `dev` | `current <version>` | `installed <old|none> <new>`.
# It lives inside the mod folder because a herdr.dev install copies only that folder.
set -euo pipefail

main() {
  local here share repo cfg stamp vf
  here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  share="${PROJECT_ORCH_SHARE:-$HOME/.local/share/project-orchestration}"
  repo="${PROJECT_ORCH_REPO:-https://github.com/curtis741/herdr-project-orchestration}"
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/herdr-plugins.project-orchestration"
  vf="$cfg/.installed-version"
  stamp="$cfg/.last-fetch"

  # A mod folder inside a git work tree is a development copy: leave everything alone.
  if git -C "$here" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "dev mode: $here is in a git work tree — skipping setup"
    echo "dev"
    return 0
  fi

  toml_version() { grep '^version' "$1/herdr-plugin.toml" 2>/dev/null | sed 's/.*"\(.*\)"/\1/'; }
  ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

  mkdir -p "$cfg"
  local old=""
  [[ -f "$vf" ]] && old="$(cat "$vf")"

  local fresh=0
  if [[ ! -e "$share/.git" ]]; then
    if [[ -e "$share" ]] && [[ -n "$(ls -A "$share" 2>/dev/null)" ]]; then
      echo "mod-setup: $share exists and is not a git clone; move it aside and re-run." >&2
      return 1
    fi
    mkdir -p "$(dirname "$share")"
    echo "Cloning $repo → $share"
    git clone --quiet "$repo" "$share"
    fresh=1
    date +%s > "$stamp"
  elif [[ ! -f "$stamp" ]] || (( $(date +%s) - $(cat "$stamp" 2>/dev/null || echo 0) > 86400 )); then
    if git -C "$share" fetch --quiet --tags origin; then
      date +%s > "$stamp"
    else
      echo "mod-setup: fetch failed (offline?) — using the clone as it is" >&2
    fi
  fi

  # Newest release tag; move only forward.
  local cur tag tagver
  cur="$(toml_version "$share")"
  tag="$(git -C "$share" tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
  if [[ -n "$tag" ]]; then
    tagver="${tag#v}"
    if [[ -z "$cur" ]] || ver_gt "$tagver" "$cur"; then
      echo "Moving share clone ${cur:+v$cur }→ $tag"
      git -C "$share" checkout --quiet --detach "$tag"
    fi
  elif (( fresh )); then
    echo "No release tags yet — staying on the clone's default branch"
  fi
  [[ -f "$share/scripts/setup.sh" ]] || { echo "mod-setup: $share has no scripts/setup.sh" >&2; return 1; }

  # Clone's mod files newer than ours: copy them over this folder. mod-setup.sh itself is
  # replaced last, by rename, so this running copy isn't rewritten under bash.
  local src="$share/mods/project-orchestration" f rel self="" changed=0
  if [[ -d "$src" ]]; then
    while IFS= read -r f; do
      rel="${f#"$src"/}"
      if [[ "$rel" == "mod-setup.sh" ]]; then self="$f"; continue; fi
      if ! cmp -s "$f" "$here/$rel"; then
        mkdir -p "$here/$(dirname "$rel")"; cp "$f" "$here/$rel"; changed=1
      fi
    done < <(git -C "$share" ls-files --full-name -- mods/project-orchestration | sed "s|^|$share/|")
    if [[ -n "$self" ]] && ! cmp -s "$self" "$here/mod-setup.sh"; then
      cp "$self" "$here/.mod-setup.new" && mv "$here/.mod-setup.new" "$here/mod-setup.sh"; changed=1
    fi
    (( changed )) && echo "✓ Updated mod files in $here from the share clone"
  fi

  bash "$share/scripts/setup.sh"

  local new
  new="$(cat "$vf" 2>/dev/null || toml_version "$share")"
  if [[ "$old" == "$new" ]]; then echo "current $new"; else echo "installed ${old:-none} $new"; fi
}

main "$@"
exit $?
