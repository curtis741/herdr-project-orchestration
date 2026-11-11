# System Design

Multi-agent system for working through Jira epics with separated context windows.

## Problem

A 10-ticket epic doesn't fit in one agent's context. Loading full codebase context + implementation details for all tickets bloats the window and degrades quality. Subagents lose context entirely. We need agents that stay focused on their role.

## Three roles, three context profiles

| Role | Skill | Context profile | Lifetime |
|------|-------|-----------------|----------|
| **Orchestrator** | `start-project` | Lightweight: ticket list, DAG, status | Full epic |
| **Worker** | `project-worker` | Heavy: full CLAUDE.md chain, pack context, one ticket | One ticket or one sequential chain |
| **Librarian** | `project-librarian` | Medium: summaries of merged changes | Full epic |

The orchestrator never writes code. Workers never manage other workers. The librarian never implements — it just knows what was merged and answers questions.

## How it flows

1. Orchestrator reads the epic from Jira, builds a dependency DAG from "depends on" links
2. Presents the work plan (waves, sequential chains, repo mapping) for confirmation
3. Spawns the librarian on main (no worktree — reads merged code only)
4. Spawns wave 1 workers via `herdr worktree create` (one worktree per ticket, max 3 concurrent)
5. Workers implement, test, push, open draft PRs, signal `DONE`
6. After a PR is merged, orchestrator tells the librarian to ingest the diff
7. Orchestrator checks which wave 2+ tickets are unblocked, spawns workers for them
8. Wave 2+ workers can `project ask librarian "..."` to ask about earlier work

## Agent topology

```
Orchestrator (any session — creates and manages the workspace)
  │
  └── Epic Workspace (one Herdr workspace)
        ├── Librarian tab (repo root, stays on main)
        ├── Researcher tab (optional, repo root)
        ├── Worker alpha tab (repo root, cds into .worktrees/<ticket-a>/)
        ├── Worker bravo tab (repo root, cds into .worktrees/<ticket-b>/)
        └── Worker charlie tab (repo root, cds into .worktrees/<ticket-c>/)
```

Workers start scoped to the repo root (shared memory, session list) and `cd` into their worktree subdirectory for branch isolation.

## Communication protocol

Two commands via the `project` CLI, which resolves roles to pane IDs from a shared state file. No agent names to hallucinate, no `herdr agent list` to parse.

- **`project prompt`** — fire a signal, don't need the reply (STARTING, DONE, BLOCKED, SCOPE, assignments, merge notifications)
- **`project ask`** — send a question, wait for the agent to finish, print its pane output to stdout so the caller gets the answer in context

### Signal protocol

| Signal | From → To | Purpose |
|--------|-----------|---------|
| `READY` | Worker → Orchestrator | Worker booted, waiting for assignment |
| `STARTING` | Worker → Librarian | Triggers Jira transition to In Progress |
| `DONE` | Worker → Librarian + Orchestrator | PR opened, triggers Code Review transition and wave check |
| `BLOCKED` | Worker → Orchestrator | Escalates to user |
| `UNBLOCKED` | Librarian → Orchestrator | Dependency cleared, ready for next worker |
| `SCOPE` | Worker → Orchestrator | Found work outside ticket scope |

## Responsibility boundaries

| Concern | Owner | Why |
|---------|-------|-----|
| DAG building, wave sequencing, spawning | Orchestrator | Lightweight coordination |
| Implementation, tests, PRs | Workers | Full codebase context |
| Merged diff summaries, answering cross-worker questions | Librarian | Single source of truth |
| Jira ticket transitions | Librarian | Receives lifecycle signals, knows when work starts/completes |
| DAG monitoring, auto-unblock detection | Librarian | Sees merged signals, checks dependency graph, signals orchestrator |
| PR/ticket status queries | Librarian | Tracks all state; orchestrator asks rather than querying GitHub |
| Research findings (traffic, data shape, dependencies) | Librarian | Stores findings alongside merged diffs so workers can query both |
| Scope gap tickets | Researcher | Creates Jira tickets, reports to librarian + orchestrator |
| Out-of-scope work flagging | Researcher | Flags to orchestrator immediately, doesn't solve |

The librarian manages the full Jira lifecycle via signals from workers and the orchestrator:

| Signal | From | Librarian transitions to |
|--------|------|--------------------------|
| `STARTING — APP-XXXX` | Worker | In Progress |
| `DONE — PR #N for APP-XXXX` | Worker | In Code Review |
| `PR #N merged for APP-XXXX` | Orchestrator | Acceptance Test / Done |
| Research complete | Research agent | Closes spike ticket |

## Primitives

### `project` CLI

Installed as a Herdr plugin. The `[[build]]` hook symlinks the CLI to `~/.local/bin/project` and all skills to `~/.claude/skills/`. `herdr plugin update` pulls new commits; symlinks pick up changes automatically.

State file at `~/.herdr/projects/<project-name>.json`. Single writer (orchestrator), many readers (all agents). Project name is injected via `HERDR_PROJECT` env var (orchestrator passes `--env HERDR_PROJECT=<name>` on every `herdr tab create`).

- `project init <project-name> [workspace-id]` — create state file, print `export HERDR_PROJECT=<name>`
- `project next-worker` — print the next available worker name (NATO phonetic alphabet: alpha, bravo, charlie...)
- `project register <role> <pane-id>` — add agent to roster after spawn
- `project assign <role> <ticket-key>` — track a ticket assignment to a worker (supports multiple tickets per worker)
- `project prompt <role> <message>` — fire-and-forget signal (resolve role → pane ID, run `herdr agent prompt`)
- `project ask <role> <question>` — send, wait for idle, read and print the reply to stdout
- `project read <role> [--lines N]` — read an agent's recent pane output (non-blocking)
- `project roster` — print role → pane ID map
- `project status` — show agent states (idle/working/done/blocked) for all roles
- `project resolve <role>` — print pane ID (for scripting)
- `project session <role>` — print session ID (for `--resume` or `SendMessage`)

### Herdr

- `herdr workspace create` — one workspace per epic (all roles as tabs)
- `herdr tab create --workspace <id>` — one tab per role (librarian, researcher, workers)
- `herdr agent start <name> --kind claude --pane <id>` — start agent in a pane
- `herdr agent read <pane_id>` — read agent output
- `herdr agent get <pane_id>` — poll agent state
- `git worktree add <repo>/.worktrees/<ticket> -b <branch> origin/main` — worktree inside repo dir

## Constraints

- Max 3 concurrent workers
- Workers don't spawn sub-agents — escalate to orchestrator
- Librarian and researcher are on-demand — prompt when there's work, don't keep polling
- Librarian ingests merged PRs and research findings
- All PRs opened as drafts
- Never force-push
- Workers share project memory — worktrees live inside the repo dir (`.worktrees/<ticket>/`), and each Claude session starts scoped to the repo root
