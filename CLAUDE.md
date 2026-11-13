# Herdr Project Orchestration Plugin

Multi-agent project orchestration, packaged as a Herdr plugin. Works with any tracker that has parent/child tickets and status transitions (Jira, Linear, GitHub Issues, etc.).

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
  start-project/watcher.md   # Watcher role definition (CI monitor, read by agents, not a skill)
  start-project/researcher.md # Researcher role definition (read by agents, not a skill)
  project-worker/SKILL.md   # Worker skill
  dry-run-project/SKILL.md  # Signal protocol test harness
docs/
  design.md                 # What the system is and how it works
  decisions.md              # Why: key decisions, open questions, feedback log
  roadmap.md                # What's next, short/medium term, ideas
```

## How to refine skills

1. **Run a project** with `/start-project` — observe what breaks, what's awkward, what's missing
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

## Signal economy

Minimize inter-agent chatter. Every signal burns tokens in both the sender's and receiver's context. Design signal flows so each event has **one routing point** — don't fan out the same information to multiple agents when one can relay a compact summary. The librarian is the routing point for worker lifecycle signals; the orchestrator gets only what it needs to act.

When refining skills, watch for duplicate signals (same event sent to multiple agents) and ask: can one agent relay a summary instead?

## Content guidelines

Skills must not contain organization-specific or user-specific references — no company names, internal repo paths, internal URLs, product names, or team-specific tooling. Use generic placeholders. This plugin is meant to work for any project in any codebase.

Skills must also be **tracker-agnostic**. Don't reference specific tools (e.g. "Jira MCP", "Linear MCP") or assume which tracker the user has. Describe *what* to do ("read the project's tickets", "transition the ticket to In Progress"), not *which tool to call*. The agent figures out the tracker from its available MCP tools and the repo's project memory/CLAUDE.md. The repo — not the plugin — tells agents how to do ticket management.

## Releasing

- Version lives in `herdr-plugin.toml` (single source of truth)
- `CHANGELOG.md` entries are sent to running orchestrators on `herdr plugin update` — only include changes that affect behavior of running agents (new commands, changed signals, skill changes). Internal cleanup, repo structure, or dev tooling changes don't belong.
- After any batch of changes, run a fresh subagent to audit for identifiable information (company names, internal URLs, repo paths, product names). Repeat until it comes back clean. The audit agent should have no prior context about what was there.
