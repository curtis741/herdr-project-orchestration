# Project Orchestration — Current State

## System overview

Three skills, global (`~/.claude/skills/`):

| Skill | File | Role |
|-------|------|------|
| `start-project` | `start-project/SKILL.md` | Orchestrator — Jira epic → DAG → workers |
| `project-worker` | `project-worker/SKILL.md` | Implementer — one ticket, full context |
| `librarian` | `start-project/librarian.md` | Knowledge base — merged diffs, Jira transitions, answers questions |
| *(project-researcher)* | *(not yet a skill)* | Long-lived domain researcher — answers questions, accumulates context |
| `project-tester` | `project-tester/SKILL.md` | Ephemeral API tester — fresh context, talks directly to worker |

## Agent interaction model

```
Epic Workspace (one Herdr workspace, all roles as tabs)
  ├── Orchestrator tab (repo root)
  ├── Librarian tab (repo root, stays on main)
  ├── Researcher tab (repo root, stays on main, optional)
  ├── Worker A tab (repo root, cds into .worktrees/<ticket-a>/)
  ├── Worker B tab (repo root, cds into .worktrees/<ticket-b>/)
  └── Worker C tab (repo root, cds into .worktrees/<ticket-c>/)

Workers ──STARTING/DONE──> Librarian (Jira transitions)
Workers ──DONE/BLOCKED/SCOPE──> Orchestrator (wave advancement)
Workers ──domain questions──> Librarian or Researcher
Orchestrator ──"PR merged, ingest"──> Librarian
Librarian ──"UNBLOCKED — APP-XXXX"──> Orchestrator (auto-detects cleared deps)
Researcher ──findings──> Librarian (stored alongside diffs)
Researcher ──new tickets──> Jira + Librarian + Orchestrator (scope gaps)
Researcher ──out-of-scope work──> Orchestrator (flags, doesn't solve)
Orchestrator ──"status?"──> Librarian (PR/ticket state, esp. on restart)
Orchestrator ──spawns──> Tester (when worker provides test brief)
Tester ──findings──> Orchestrator ──"fix these"──> Worker
```

## Communication protocol

Two commands via the `project` CLI (`~/.local/bin/project`), which resolves roles to pane IDs from a shared state file. No agent names to hallucinate, no `herdr agent list` to parse.

- **`project prompt`** — fire a signal, don't need the reply (STARTING, DONE, BLOCKED, SCOPE, assignments, merge notifications)
- **`project ask`** — send a question, wait for the agent to finish, print its pane output to stdout so the caller gets the answer in context

Examples:

- **Worker → Orchestrator:** `project prompt orchestrator "DONE — PR #N opened for APP-XXXX"`
- **Worker → Orchestrator:** `project prompt orchestrator "BLOCKED — <reason>"`
- **Orchestrator → Librarian:** `project prompt librarian "APP-XXXX PR #N was just merged. Ingest the diff."`
- **Worker → Librarian (needs answer):** `project ask librarian "What interfaces did APP-YYYY introduce?"`
- **Orchestrator → Librarian (needs answer):** `project ask librarian "What's the current state of all tickets?"`
- **Orchestrator → Worker:** `project prompt app-1001 "Your assignment: ..."`

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

This keeps ticket management off the orchestrator (stays lightweight) and off workers (stay focused on code).

## Primitives used

### `project` CLI (`~/.local/bin/project`)

Standalone shell script. State file at `~/.herdr/projects/<project-name>.json`. Single writer (orchestrator), many readers (all agents). Project name is injected via `HERDR_PROJECT` env var (orchestrator passes `--env HERDR_PROJECT=<name>` on every `herdr tab create`).

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

### Researcher can create Jira tickets for scope gaps

When the researcher discovers missing work, it creates child tickets under the epic with dependency links, then reports new tickets to the librarian (for tracking) and orchestrator (for DAG update and worker spawning). This applies at two points:
- **Fresh epic with no scope:** researcher creates the initial ticket set from discovery, orchestrator takes over with the DAG.
- **Mid-epic gaps:** researcher finds missing work, creates tickets, reports them. Orchestrator updates the DAG and spawns workers when dependencies are met.

The researcher has Jira MCP access and permission to create tickets.

### Researcher cannot spawn workers for trivial fixes

When the researcher finds a small, self-contained fix (a doc typo, a missing config line), it cannot create a worker on its own. It must flag it to the orchestrator, which decides whether to spawn a worker or handle it differently. The overhead of orchestrator → worker spawning is disproportionate for one-line fixes, but letting the researcher make changes directly risks scope creep and branch confusion (the researcher sits on main). Accepted trade-off: the latency of going through the orchestrator is worth the clean role separation.

### DAG ownership is shared: orchestrator builds, librarian monitors

The orchestrator builds the initial DAG from Jira and spawns workers. The librarian tracks the DAG alongside its PR summaries and auto-detects unblocked tickets when dependencies are merged. The librarian signals the orchestrator when tickets are unblocked; the orchestrator spawns workers. Neither role does both — the librarian monitors, the orchestrator acts.

### Orchestrator does not research

The orchestrator stays lightweight: it reads Jira, manages the DAG, and spawns agents. It never greps the codebase, reads implementation files, or verifies whether work is done by inspecting code. When it needs that information, it asks the librarian (for merged work) or the researcher (for domain questions). On restart, it asks the librarian for ticket/PR status rather than querying GitHub directly.

## Known gaps

### No research phase

The orchestrator assumes an epic already has child tickets with descriptions and dependency links. When an epic has no children — or the children lack enough detail for a worker to implement — the orchestrator can't run.

Today this is handled by an interactive session before `/start-project`: read the epic, read cross-repo code, ask the user to resolve open items, then create child tickets with `Blocks` links. A dedicated `project-researcher` skill would formalize this.

First observed in practice: an epic was well-scoped but had zero children and several open items. Cross-repo code reading revealed implementation details the epic didn't cover, and the user corrected data-source assumptions the code alone couldn't settle.

## Design decisions

### Worker reuse is librarian-advised

The librarian proactively recommends reuse or fresh worker in its UNBLOCKED signal, based on the coupling between tickets. Reuse when the next ticket builds on internals (same handler, same service); fresh when it only needs the interface (column names, method signatures). The orchestrator follows the advice or asks the librarian if it's not obvious. No hardcoded chain-length rule.

### Worktree cleanup

After a PR merges and the librarian ingests: remove the worktree (`herdr worktree remove --workspace <id>`) unless the worker has a next ticket in a sequential chain. The orchestrator handles this in Step 5.

### Orchestrator reboot mid-epic

Herdr agents (librarian, researcher, workers) survive across orchestrator sessions — they're independent processes. A fresh orchestrator rebuilds state from the project state file (`project roster`, `project status`) and the librarian. The state file persists agent entries even after `project stop`, so all pane IDs and session IDs are recoverable. See `start-project/SKILL.md` § Restart recovery for the procedure.

### Release detection (not yet implemented)

Workers don't know when their PRs get released. The orchestrator (or a release hook) should detect a release containing epic work and tell the librarian to transition tickets Acceptance Test → Done. Today this is manual.

### Tester agent pattern

An independent tester agent with fresh context catches bugs the implementer misses — it has no implementation assumptions and tests like a real consumer. In practice, a tester found 5 bugs across two rounds that the worker's own tests didn't cover (empty array 500s, missing params causing unbounded queries, wrong null handling, missing rollup data, silently dropped params).

The tester is an optional fourth role, spawned by the orchestrator when a worker's DONE signal includes a test brief. It's ephemeral — one per API ticket, not long-lived like the librarian or researcher.

Interaction model:
```
Worker ──DONE + test brief──> Orchestrator
Orchestrator ──spawns──> Tester (fresh context, no implementation knowledge)
Tester ──findings──> Orchestrator
Orchestrator ──"fix these"──> Worker
Worker ──fixes──> Orchestrator ──"re-verify"──> Tester
```

The test brief is the critical handoff artifact — without it, the tester has no spec to test against. Workers output it as part of Step 8 in the worker skill (API/parity work only).

**API parity testing playbook** (reusable for any migration):
1. Data parity — same inputs → same field values (match on primary key)
2. Filter combinations — all filter params solo and combined, plus empty/missing
3. Pagination — navigation, no duplicates/gaps, counts match
4. Error format — consistent structure across all error paths
5. Edge cases — boundary values, missing required params, empty arrays, invalid inputs
6. Performance — response time comparison between backends
7. Real usage — query access logs for actual request patterns

### State recovery via project state file

The `project` CLI maintains a state file at `~/.herdr/projects/<project-name>.json` mapping role → pane ID + session ID. Agents self-register via `project register <role>` during boot (auto-detects pane ID and session ID). The state file is never deleted — `project stop` marks agents as stopped but preserves all data. The project name is injected as `HERDR_PROJECT` via `herdr tab create --env`.

On restart, `project roster` and `project status` show all agents (including stopped ones) and their current state. The orchestrator asks the librarian for ticket/PR status rather than querying GitHub.

Session IDs in the state file enable cross-time queries: a wave-2 worker can `--resume` or `SendMessage` a finished wave-1 worker's session when the librarian's summary isn't enough.

The orchestrator's reboot-recovery procedure is in `start-project/SKILL.md` § Reboot recovery.

## Constraints

- Max 3 concurrent workers
- Workers don't spawn sub-agents — escalate to orchestrator
- Librarian and researcher are long-lived and on-demand — prompt when there's work, don't keep polling. Both stay up for the life of the epic; idle is their correct steady state between queries, not a signal to shut down
- Librarian ingests merged PRs and research findings
- All PRs opened as drafts
- Never force-push
- **Workers share project memory** — worktrees live inside the repo dir (`.worktrees/<ticket>/`), and each Claude session starts scoped to the repo root. This means workers see the same MEMORY.md, show up in `/resume`, and appear in the same session list as the primary checkout. The worker's first action is to cd into its worktree subdirectory.
