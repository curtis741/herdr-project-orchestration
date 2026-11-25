# Herdr Project Orchestration

## The problem

When one coding agent handles an entire epic, its context window fills up. By the third ticket it's slower, less accurate, and losing track of earlier work. The context that made it effective on ticket one becomes noise by ticket four.

## What you get

Focused agents, each with its own context window:

- **Orchestrator** — reads the project's tickets, builds a dependency graph, spawns workers wave by wave. Never touches code.
- **Workers** — each gets one ticket, one git worktree, one clean context. Implements, tests, pushes, opens a draft PR, and shuts down.
- **Librarian** — sits on main, ingests merged diffs, answers cross-worker questions, manages ticket transitions. Long-lived.
- **Researcher** (optional) — investigates domain questions so workers don't have to. Accumulates context across the project.
- **Watcher** (optional) — monitors CI on open PRs, reports failures back to workers.

The result is consistent quality from the first ticket to the last. Works with any tracker that has parent/child tickets and status transitions (Jira, Linear, GitHub Issues, etc.).

## How you use it

### Prerequisites

- [Herdr](https://herdr.dev) 0.7.5+
- [Claude Code](https://claude.com/claude-code) with a tracker MCP and GitHub MCP configured
- `jq` on PATH
- `~/.local/bin` on your PATH

### Install

Two ways in, one result: the code lives in a single git clone, `~/.local/share/project-orchestration`, and every link (the `project` command, skills, guide, context-guard hook) points into it.

**Classic Herdr (plugin):**

```bash
herdr plugin install curtis741/herdr-project-orchestration
```

The build step brings the clone forward to this plugin's version (never backwards) and links everything. `herdr plugin update` upgrades it.

**Herdr app (mod):** ask the app to add `https://github.com/curtis741/herdr-project-orchestration` (it reads `RECIPE.md`, which lists what the mod does up front). On each app start the mod moves the clone to the newest release tag (checking at most once a day) and relinks. Without the add flow:

```bash
git clone https://github.com/curtis741/herdr-project-orchestration ~/.local/share/project-orchestration
git -C ~/.local/share/project-orchestration checkout --quiet --detach "$(git -C ~/.local/share/project-orchestration tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
bash ~/.local/share/project-orchestration/scripts/setup.sh
cp -R ~/.local/share/project-orchestration/mods/project-orchestration ~/.config/herdr-app/mods/   # the panel; optional
```

Installing both is fine: whichever is newer wins, and an older install never rolls the clone back. Links that used to point at another checkout are reported and repointed.

### Run a project

**From inside Claude Code:**

```
/start-project <epic-key>
```

The orchestrator runs in your current session — reads the tickets, shows you the plan (waves, dependencies, blockers), and starts spawning agents once you confirm.

**From the terminal:**

```bash
project start <epic-key> "Project Label"
```

Creates a Herdr workspace with a dedicated orchestrator agent and kicks off `/start-project` automatically. The orchestrator gets its own workspace so it doesn't share your session's context.

### Try the demo first

```bash
project start DEMO-001 "Guided Tour"
```

A 5-minute interactive walkthrough that spawns a researcher, librarian, and one worker on a trivial task. You drive each step by talking to agents in their panes — one automatic signal chain fires so you can see the handoff machinery. After one run, you'll understand the roles, signals, and how to participate.

## Collaborative orchestration, not autonomous execution

This is not "give it an epic and walk away." You're expected to jump into workers, feed the researcher, redirect agents, and keep things on track.

The system is designed for an active developer who participates, not a passive one who supervises. Agents are told to ask you rather than guess — a wrong guess costs tokens across every agent that receives the signal, so your input is cheaper than their confidence gaps.

What that looks like in practice:

- **Review the plan** before the orchestrator starts spawning — confirm waves make sense, flag missing dependencies
- **Jump into a worker** when it's stuck or going in the wrong direction
- **Feed domain knowledge** to the researcher when agents hit questions you know the answer to
- **Watch the wave transitions** — the orchestrator will pause between waves for your sign-off

## Advanced

The `project` CLI handles all inter-agent communication and state management. See [`docs/cli.md`](docs/cli.md) for the full command reference.

For system internals — state file format, signal protocol, role resolution, agent topology — see [`docs/design.md`](docs/design.md).

To test the signal protocol without a tracker or code changes, use the dry-run skill (`/dry-run-project`).

## License

MIT
