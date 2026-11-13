# Herdr Project Orchestration Plugin

Multi-agent project orchestration for Jira epics, packaged as a Herdr plugin.

## Repo layout

```
herdr-plugin.toml          # Herdr plugin manifest (actions + build hook + version)
GUIDE.md                   # New user guide (symlinked to ~/.claude/skills/PROJECT_GUIDE.md)
CHANGELOG.md               # User-facing changes per version (fed to running orchestrators on upgrade)
scripts/
  project.sh               # The project CLI (symlinked to ~/.local/bin/project)
  setup.sh                  # Build hook: creates symlinks for CLI + skills
skills/
  start-project/SKILL.md    # Orchestrator skill
  start-project/DESIGN.md   # System design (role boundaries, constraints, known gaps)
  start-project/librarian.md # Librarian role definition (read by agents, not a skill)
  start-project/researcher.md # Researcher role definition (read by agents, not a skill)
  project-worker/SKILL.md   # Worker skill
  dry-run-project/SKILL.md  # Signal protocol test harness
docs/
  design.md                 # What the system is and how it works
  decisions.md              # Why: key decisions, open questions, feedback log
```

## How to refine skills

1. **Run an epic** with `/start-project` — observe what breaks, what's awkward, what's missing
2. **Log findings** as bullets in the "Feedback — New" section of `docs/decisions.md`
3. **In a separate session** in this repo, route each finding:
   - Behavioral rule for a role → that role's `SKILL.md`
   - System-level design decision → `skills/start-project/DESIGN.md`
   - Key decision that shapes the whole system → `docs/decisions.md` § Key decisions
   - Not durable / ephemeral → nowhere
4. **Review** all skill files for coherence after a batch of changes — catches signal mismatches, stale instructions, role overlaps
5. Move applied findings from "New" to "Applied" with a `→ <destination>` annotation
6. Commit and push — `herdr plugin update` pulls changes through the symlinks

**Don't refine skills in the same session that's running the epic** — context bloat from reading/editing skills degrades the orchestrator.

## Prompting running agents

When the user asks you to message a running agent (e.g. "ask pane wF:p4W about X"), you're outside the project — no `$HERDR_PROJECT`, not a registered agent. Use `herdr agent prompt` directly, and prefix with `FEEDBACK (from project maintainer):` so the agent knows it's a meta question about the system, not a task instruction.

## Upstream dependencies

- [herdrdev/herdr-core#259](https://github.com/herdrdev/herdr-core/issues/259) — plugin subcommand registration. Would let us drop the `~/.local/bin/project` symlink in favor of `herdr project <args>`.

## Content guidelines

Skills must not contain organization-specific or user-specific references — no company names, internal repo paths, internal URLs, product names, or team-specific tooling. Use generic placeholders. This plugin is meant to work for any Jira epic in any codebase.

## Releasing

- Version lives in `herdr-plugin.toml` (single source of truth)
- `CHANGELOG.md` entries are sent to running orchestrators on `herdr plugin update` — only include changes that affect behavior of running agents (new commands, changed signals, skill changes). Internal cleanup, repo structure, or dev tooling changes don't belong.
- After any batch of changes, run a fresh subagent to audit for identifiable information (company names, internal URLs, repo paths, product names). Repeat until it comes back clean. The audit agent should have no prior context about what was there.
