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

```bash
herdr plugin install curtis741/herdr-project-orchestration
```

The build step symlinks the `project` CLI and all skills automatically. Updates propagate through the symlinks — `herdr plugin update` is all you need.

### Run a project

```
/start-project <epic-key>
```

The orchestrator reads the tickets, shows you the plan (waves, dependencies, blockers), and starts spawning agents once you confirm. That's it.

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
