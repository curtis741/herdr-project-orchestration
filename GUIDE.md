# Project Orchestration Guide

## The problem

When one coding agent handles an entire epic, its context window fills up. By the third ticket it's slower, less accurate, and losing track of earlier work. The context that made it effective on ticket one becomes noise by ticket four.

## What you get

Focused agents, each with its own context window:

- **Orchestrator** — reads the project's tickets, builds a dependency graph, spawns workers wave by wave. Never touches code. Stays lightweight so it can run for the life of the project.
- **Workers** — each gets one ticket, one git worktree, one clean context. Implements, tests, pushes, opens a draft PR, and shuts down. Fresh workers get what they need from the librarian.
- **Librarian** — sits on main, ingests merged diffs, answers cross-worker questions, manages ticket transitions. Long-lived.
- **Researcher** (optional) — investigates domain questions so workers don't have to research independently. Accumulated context is the value.
- **Watcher** (optional) — monitors CI on open PRs, reports failures back to workers.

## How agents communicate

All communication goes through the `project` CLI:

- **`project prompt <role> <message>`** — fire-and-forget signal (STARTING, COMPLETE, DONE, BLOCKED, UNBLOCKED)
- **`project ask <role> <question>`** — blocking question, prints the reply to stdout
- **`project research <question>`** — async domain question routed to the researcher

Messages are automatically prefixed with `FROM(<sender>):` so every agent knows who's talking. Messages without a prefix came from a human.

When an agent messages a stopped agent, the CLI auto-escalates to the orchestrator with a `NEED` signal — the orchestrator decides whether to bring it back.

## Getting started

**Jump in.** If you have a project ready (a Jira epic, Linear project, or group of tickets with dependencies):

```
/start-project <epic-key>
```

The orchestrator reads the tickets, shows you the plan, and starts spawning agents once you confirm.

**Option 2: Guided tour.** An interactive walkthrough that spawns a small set of agents and walks you through the signal flow step by step, with pauses to explain what's happening and prompts for you to try messaging agents yourself:

```
/guided-tour
```

Takes about 5 minutes. After one run, you'll understand the roles, how signals flow, and how to participate.

**Option 3: Dry run.** Test the signal protocol without touching a tracker or code:

```
/dry-run-project
```

Spawns a librarian, watcher, and two fake workers in a test workspace, walks through the full signal cycle, and scores which signals landed.

## Reference

- [CLI reference](docs/cli.md) — full `project` command documentation
- [System design](docs/design.md) — role boundaries, state file format, signal protocol, agent topology
