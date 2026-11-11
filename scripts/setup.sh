#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/herdr-plugins.project-orchestration"
VERSION_FILE="$CONFIG_DIR/.installed-version"
PROJECTS_DIR="$HOME/.herdr/projects"

new_version=$(grep '^version' "$PLUGIN_DIR/herdr-plugin.toml" | sed 's/.*"\(.*\)"/\1/')
old_version=""
if [[ -f "$VERSION_FILE" ]]; then
  old_version=$(cat "$VERSION_FILE")
fi

# CLI symlink
mkdir -p "$HOME/.local/bin"
ln -sf "$PLUGIN_DIR/scripts/project.sh" "$HOME/.local/bin/project"
echo "✓ Linked: project → $HOME/.local/bin/project"

# Skill symlinks
mkdir -p "$HOME/.claude/skills"
for skill in start-project project-worker; do
  ln -sfn "$PLUGIN_DIR/skills/$skill" "$HOME/.claude/skills/$skill"
  echo "✓ Linked: ~/.claude/skills/$skill"
done

# Guide symlink
ln -sf "$PLUGIN_DIR/GUIDE.md" "$HOME/.claude/skills/PROJECT_GUIDE.md"
echo "✓ Linked: ~/.claude/skills/PROJECT_GUIDE.md"

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
  ║   Turn a Jira epic into a team of coding agents.      ║
  ║   One orchestrator. One librarian. N workers.         ║
  ║   Each ticket gets its own worktree and agent.        ║
  ║                                                       ║
  ╚═══════════════════════════════════════════════════════╝

WELCOME
  echo "  Getting started:"
  echo ""
  echo "    If you have an epic ready:"
  echo "      /start-project"
  echo ""
  echo "    Or paste this into a new session in your project directory"
  echo "    for a guided walkthrough:"
  echo ""
  echo "      \"Read ~/.claude/skills/PROJECT_GUIDE.md and walk me through how project"
  echo '       orchestration works. Explain the roles, how agents communicate,'
  echo '       and why context window separation matters. Then offer to do a'
  echo '       dry run or start a real project."'
  echo ""
  echo "  ✓ Installed v$new_version"
  echo ""
elif [[ "$old_version" != "$new_version" ]]; then
  echo "✓ Upgraded v$old_version → v$new_version"

  # Notify running orchestrators
  if [[ -d "$PROJECTS_DIR" ]] && command -v herdr &>/dev/null; then
    for state_file in "$PROJECTS_DIR"/*.json; do
      [[ -f "$state_file" ]] || continue
      orch_pane=$(jq -r '.agents.orchestrator.pane_id // empty' "$state_file" 2>/dev/null || true)
      [[ -n "$orch_pane" ]] || continue

      # Check the orchestrator is actually alive
      orch_status=$(herdr agent get "$orch_pane" 2>/dev/null \
        | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || echo "unknown")
      [[ "$orch_status" != "unknown" ]] || continue

      project_name=$(jq -r '.project // empty' "$state_file" 2>/dev/null)
      herdr agent prompt "$orch_pane" \
        "PLUGIN UPGRADE — project-orchestration v$old_version → v$new_version. Reload /start-project and tell your agents to reload their skills (/project-worker, /project-librarian)." \
        2>/dev/null && \
        echo "✓ Notified orchestrator for $project_name" || true
    done
  fi
fi

echo "$new_version" > "$VERSION_FILE"
