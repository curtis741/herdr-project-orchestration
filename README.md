# Herdr Project Orchestration

When one coding agent handles an entire epic, its context window fills up. By the third ticket it's slower, less accurate, and losing track of earlier work. This plugin splits the work across focused agents — each with its own context window, its own worktree, and one job to do. The result is consistent quality from the first ticket to the last. Built on [Herdr](https://herdr.dev) and Claude Code skills.

## Install

### Prerequisites

- [Herdr](https://herdr.dev) 0.7.5+
- [Claude Code](https://claude.com/claude-code) with Jira MCP and GitHub MCP configured
- `jq` on PATH
- `~/.local/bin` on your PATH

### Steps

```bash
herdr plugin install curtis741/herdr-project-orchestration
```

That's it. The build step automatically:

1. Symlinks `project` into `~/.local/bin/`
2. Symlinks all four skills into `~/.claude/skills/`
3. Warns if `~/.local/bin` isn't in your PATH

When you run `herdr plugin update`, the plugin directory updates in place and all symlinks pick up the changes — no reinstall needed.

## Quick start

1. **Initialize a project** in an orchestrator session (inside Herdr):

   ```bash
   eval "$(project init app-1234 <workspace-id>)"
   project register orchestrator "$HERDR_PANE_ID"
   ```

2. **Register agents** as you spawn them:

   ```bash
   project register librarian <pane-id>
   project register alpha <pane-id>
   ```

3. **Communicate between agents:**

   ```bash
   # Fire-and-forget signal
   project prompt librarian "PR_OPEN — PR #42 for APP-1234"

   # Ask a question and get the reply in stdout
   project ask librarian "What interfaces did APP-1001 introduce?"

   # Read an agent's recent output
   project read alpha --lines 40
   ```

4. **Or use the orchestrator skill** — run `/start-project` in Claude Code with a Jira epic key and it handles the full lifecycle: DAG building, worker spawning, wave advancement, and completion.

## CLI reference

```
project init <project-name> [workspace-id]
```
Create a project state file. Prints `export HERDR_PROJECT=<name>` — wrap in `eval` to set the env var.

```
project register <role>
```
Register this agent and signal READY to the orchestrator. Pane ID and session ID are auto-detected. Pass explicit IDs only for crash recovery (`project register <role> <pane-id> [session-id]`).

```
project stop <role>
```
Stop an agent. Marks it as stopped in the state file but preserves its session ID, pane ID, and ticket history for later resume.

```
project next-worker
```
Print the next available worker name (NATO alphabet: alpha, bravo, charlie...).

```
project assign <role> <ticket-key>
```
Track a ticket assignment to a worker. Supports multiple tickets per worker.

```
project prompt <role> <message> [--wait] [--timeout N]
```
Send a message to an agent. Fire-and-forget by default. `--wait` blocks until the agent finishes processing.

```
project ask <role> <question> [--timeout N] [--lines N]
```
Send a question, wait for the agent to finish, and print its response to stdout. Blocking.

```
project read <role> [--lines N]
```
Read an agent's recent pane output. Non-blocking. Default: 40 lines.

```
project roster
```
Print the current role-to-pane-ID map.

```
project status
```
Show agent states (idle, working, blocked) for all registered roles.

```
project info
```
Print the project name, workspace ID, and agent count as JSON.

```
project resolve <role>
```
Print the pane ID for a role. For scripting.

```
project session <role>
```
Print the session ID for a role. For `--resume` or `SendMessage`.

```
project file
```
Print the path to the project state file.

**Global flags:**

- `--project <name>` — override `$HERDR_PROJECT`
- `-h`, `--help` — show usage

## Skills

Five Claude Code skills for the agent roles:

| File | Role |
|------|------|
| `skills/start-project/SKILL.md` | **Orchestrator** — reads Jira epic, builds DAG, spawns agents, tracks waves |
| `skills/project-worker/SKILL.md` | **Worker** — implements one ticket, tests, pushes, opens draft PR |
| `skills/start-project/librarian.md` | **Librarian** — tracks merged PRs, answers cross-worker questions, manages Jira transitions |
| `skills/start-project/researcher.md` | **Researcher** — investigates domain questions, accumulates context across the epic |
| `skills/dry-run-project/SKILL.md` | **Test harness** — validates the signal protocol without Jira or code changes |

The orchestrator and worker are installed as Claude Code skills (`/start-project`, `/project-worker`). The librarian and researcher are role definitions that agents read during boot — not standalone skills. `DESIGN.md` has the full system design, constraints, and known gaps.

## How it works

### State file

Each project stores its state at `~/.herdr/projects/<project-name>.json`. The file maps roles to pane IDs, session IDs, and ticket assignments. The orchestrator writes it; all agents read it.

```json
{
  "project": "app-1234",
  "workspace_id": "wW",
  "agents": {
    "orchestrator": { "pane_id": "pA", "session_id": "sA" },
    "librarian": { "pane_id": "pB", "session_id": "sB" },
    "alpha": { "pane_id": "pC", "session_id": "sC", "current_ticket": "APP-1001" }
  }
}
```

### HERDR_PROJECT env var

The orchestrator passes `--env HERDR_PROJECT=<name>` when creating tabs. Every agent resolves the same state file automatically — no flags needed.

### Role resolution

`project prompt alpha "..."` looks up alpha's pane ID in the state file and calls `herdr agent prompt <pane-id> "..."`. Agents address each other by role, never by pane ID.

### Agent topology

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

### Signal protocol

Workers and the librarian communicate through structured signals:

| Signal | From → To | Purpose |
|--------|-----------|---------|
| `READY` | Worker → Orchestrator | Worker booted, waiting for assignment |
| `STARTING` | Worker → Librarian | Triggers Jira transition to In Progress |
| `PR_OPEN` | Worker → Librarian | PR opened; librarian transitions to Code Review, tells watcher to monitor CI, relays to orchestrator |
| `DONE` | Worker → Librarian | Post-merge verification complete (optional); librarian transitions to Done |
| `BLOCKED` | Worker → Orchestrator | Escalates to user |
| `UNBLOCKED` | Librarian → Orchestrator | Dependency cleared, ready for next worker |
| `WATCH` | Librarian → Watcher | Start monitoring CI on a PR |
| `SCOPE` | Worker → Orchestrator | Found work outside ticket scope |

## Design

See [docs/design.md](docs/design.md) for the full system design: role boundaries, design decisions, known gaps, and the feedback log from real epic runs.

## License

MIT
