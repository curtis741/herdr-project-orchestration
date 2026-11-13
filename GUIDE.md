# Project Orchestration Guide

## The problem

When one Claude session handles an entire epic — reading tickets, implementing code, managing branches, tracking dependencies — its context window fills up fast. By the third or fourth ticket, the agent is slower, makes more mistakes, and loses track of earlier work. The context that made it effective early becomes the noise that degrades it later.

## The solution

Split the work across agents with separated context windows. Each agent has a focused role and only carries the context it needs:

### Orchestrator

The coordinator. Reads the Jira epic, builds a dependency graph, and spawns agents wave by wave. It never reads code or implements anything — it manages the DAG and makes decisions (spawn fresh worker vs reuse, when to stop an agent, how to handle blockers). Stays lightweight so it can run for the life of the epic without context degradation.

### Librarian

The knowledge base. Sits on main, ingests diffs after each PR merges, and answers questions from other agents about what changed. Also manages Jira ticket transitions (In Progress, In Code Review, Done) based on lifecycle signals from workers. Tracks the dependency graph and signals the orchestrator when tickets are unblocked. Long-lived — stays up for the entire epic.

### Researcher (optional)

The domain expert. Investigates open questions — data schemas, API contracts, traffic patterns, protocol mechanics. Accumulates domain knowledge across the epic so workers don't have to research independently. Long-lived — the accumulated context is the value.

### Workers

The implementers. Each worker gets one ticket, one git worktree, and one focused context window. It implements, tests, pushes a branch, and opens a draft PR. When it's done, it signals the orchestrator and shuts down. Fresh workers start with a clean context and get what they need from the librarian.

### Tester (optional)

An independent agent with fresh context that tests an endpoint after a worker finishes. Catches bugs the implementer misses because it has no implementation assumptions — it tests like a real consumer.

## How agents communicate

All communication goes through the `project` CLI:

- **`project prompt <role> <message>`** — fire-and-forget signal (STARTING, PR_OPEN, DONE, BLOCKED, UNBLOCKED)
- **`project ask <role> <question>`** — blocking question, prints the reply to stdout
- **`project research <question>`** — async domain question routed to the researcher

Messages are automatically prefixed with `FROM(<sender>):` so every agent knows who's talking. Messages without a prefix came from a human.

When an agent messages a stopped agent, the CLI auto-escalates to the orchestrator with a `NEED` signal — the orchestrator decides whether to bring it back.

## The state file

Each project gets a state file at `~/.herdr/projects/<name>.json`. It maps roles to pane IDs and session IDs. Agents self-register during boot (`project register <role>`), which writes the state file and signals READY to the orchestrator. Entries are never deleted — `project stop` marks an agent as stopped but preserves everything for resume.

## Getting started

**Option 1: Jump in.** If you have a Jira epic ready:

```
/start-project
```

The orchestrator reads the epic, builds the DAG, and starts spawning agents.

**Option 2: Dry run.** Test the signal protocol without touching Jira or code. The dry-run script lives in the plugin directory alongside this guide:

```bash
# Resolve the plugin directory from this guide's symlink
plugin_dir=$(dirname "$(readlink ~/.claude/skills/PROJECT_GUIDE.md)")
# The dry-run skill is at:
# $plugin_dir/skills/dry-run-project/SKILL.md
```

Read that file and follow it step by step. It spawns a librarian, watcher, and two fake workers in a test workspace, walks through the full signal cycle (READY → STARTING → PR_OPEN → unblock → second worker), and scores which signals landed.
