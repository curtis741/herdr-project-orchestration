#!/usr/bin/env bash
# Normalizes an install: links the CLI, skills, guide and context-guard hook from the share
# clone, reports any link that pointed somewhere else before repointing it, and sends the
# upgrade notice on a version change. Run by plugin-setup.sh and the mod's mod-setup.sh only —
# it refuses to run from anywhere but the share clone, so every link ends up in one place.
set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)"
SHARE="${PROJECT_ORCH_SHARE:-$HOME/.local/share/project-orchestration}"
SHARE_REAL="$(cd -P "$SHARE" 2>/dev/null && pwd -P || true)"
if [[ -z "$SHARE_REAL" || "$PLUGIN_DIR" != "$SHARE_REAL" ]]; then
  echo "setup.sh must run from the share clone ($SHARE), not $PLUGIN_DIR." >&2
  echo "Install with the plugin (herdr plugin install) or the mod (RECIPE.md), or run:" >&2
  echo "  bash scripts/plugin-setup.sh   # from a plugin checkout" >&2
  exit 1
fi

# Same version-file location as before, so existing installs keep one history.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/herdr-plugins.project-orchestration"
VERSION_FILE="$CONFIG_DIR/.installed-version"
PROJECTS_DIR="$HOME/.herdr/projects"

new_version=$(grep '^version' "$PLUGIN_DIR/herdr-plugin.toml" | sed 's/.*"\(.*\)"/\1/')
old_version=""
if [[ -f "$VERSION_FILE" ]]; then
  old_version=$(cat "$VERSION_FILE")
fi

# link <target> <link> <label>: symlink, reporting a link that pointed elsewhere first.
link() {
  local target="$1" dest="$2" label="$3" cur
  if [[ -L "$dest" ]]; then
    cur="$(readlink "$dest")"
    if [[ "$cur" == "$target" ]]; then
      echo "✓ Linked: $label"
      return
    fi
    echo "↻ $label pointed at $cur — repointing to $target"
    ln -sfn "$target" "$dest"
  elif [[ -e "$dest" ]]; then
    echo "⚠ $dest exists and is not a symlink — left alone ($label not linked)"
    return
  else
    ln -sfn "$target" "$dest"
    echo "✓ Linked: $label"
  fi
}

# CLI symlink
mkdir -p "$HOME/.local/bin"
chmod +x "$PLUGIN_DIR/scripts/context-guard.sh" "$PLUGIN_DIR/scripts/project.sh"
link "$PLUGIN_DIR/scripts/project.sh" "$HOME/.local/bin/project" "project → $HOME/.local/bin/project"

# Skill symlinks
mkdir -p "$HOME/.claude/skills"
for skill in start-project project-worker guided-tour; do
  link "$PLUGIN_DIR/skills/$skill" "$HOME/.claude/skills/$skill" "~/.claude/skills/$skill"
done

# Context guard hook — global Claude Code hooks that nudge project agents to
# DISTILL before auto-compaction, and re-orient them if compaction happens.
# No-op for any session that isn't a registered project agent.
link "$PLUGIN_DIR/scripts/context-guard.sh" "$HOME/.local/bin/project-context-guard" "project-context-guard"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
GUARD_CMD="$HOME/.local/bin/project-context-guard"
if command -v jq &>/dev/null; then
  [[ -f "$CLAUDE_SETTINGS" ]] || echo '{}' > "$CLAUDE_SETTINGS"
  if jq -e --arg c "$GUARD_CMD" '[.hooks // {} | .[][]?.hooks[]?.command] | index($c)' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    echo "✓ Context guard hooks already installed"
  else
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak-project-orchestration"
    tmp="$CLAUDE_SETTINGS.tmp.$$"
    jq --arg c "$GUARD_CMD" '
      .hooks = (.hooks // {})
      | .hooks.Stop = ((.hooks.Stop // []) + [{hooks: [{type: "command", command: $c}]}])
      | .hooks.SessionStart = ((.hooks.SessionStart // []) + [{matcher: "compact", hooks: [{type: "command", command: $c}]}])
    ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    echo "✓ Installed context guard hooks in $CLAUDE_SETTINGS (backup: settings.json.bak-project-orchestration)"
  fi
else
  echo "⚠ jq not found — skipped context guard hook install"
fi

# Guide symlink
link "$PLUGIN_DIR/GUIDE.md" "$HOME/.claude/skills/PROJECT_GUIDE.md" "~/.claude/skills/PROJECT_GUIDE.md"

# PATH check
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  echo ""
  echo "⚠ ~/.local/bin is not in your PATH. Add this to your shell profile:"
  echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

# Version tracking and upgrade notification
mkdir -p "$CONFIG_DIR"

if [[ -z "$old_version" ]]; then
  cat <<'WELCOME'

  ╔═══════════════════════════════════════════════════════╗
  ║                                                       ║
  ║   🐑  Project Orchestration                           ║
  ║                                                       ║
  ║   Turn an epic into a team of coding agents.          ║
  ║   One orchestrator. One librarian. N workers.         ║
  ║   Each ticket gets its own worktree and agent.        ║
  ║                                                       ║
  ╚═══════════════════════════════════════════════════════╝

WELCOME
  echo "  Getting started:"
  echo ""
  echo "    First time? Take the guided tour (~5 min):"
  echo "      /guided-tour"
  echo ""
  echo "    If you have an epic ready:"
  echo "      /start-project"
  echo ""
  echo "  ✓ Installed v$new_version"
  echo ""
elif [[ "$old_version" != "$new_version" ]]; then
  echo "✓ Upgraded v$old_version → v$new_version"

  # Notify running orchestrators (through the project CLI — no direct herdr calls)
  if [[ -d "$PROJECTS_DIR" ]]; then
    for state_file in "$PROJECTS_DIR"/*.json; do
      [[ -f "$state_file" ]] || continue
      project_name=$(jq -r '.project // empty' "$state_file" 2>/dev/null || true)
      [[ -n "$project_name" ]] || continue

      # Only notify an orchestrator that is actually alive
      orch_status=$("$PLUGIN_DIR/scripts/project.sh" --project "$project_name" status orchestrator 2>/dev/null || true)
      case "$orch_status" in ""|stopped|unreachable|unknown) continue ;; esac

      "$PLUGIN_DIR/scripts/project.sh" --project "$project_name" prompt orchestrator \
        "PLUGIN UPGRADE — project-orchestration v$old_version → v$new_version. Reload /start-project and tell your agents to reload their skills (/project-worker, /project-librarian)." \
        >/dev/null 2>&1 && \
        echo "✓ Notified orchestrator for $project_name" || true
    done
  fi
fi

echo "$new_version" > "$VERSION_FILE"
