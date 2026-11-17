# Project Orchestration — Current State

## Design principle

Minimize context collapse by maximizing token quality with minimal extra token consumption. Every design choice — signal routing, role boundaries, durable artifacts, distill/restart — is evaluated against this.

## System overview

Three skills, global (`~/.claude/skills/`):

| Skill | File | Role |
|-------|------|------|
| `start-project` | `start-project/SKILL.md` | Orchestrator — project tickets → DAG → workers |
| `project-worker` | `project-worker/SKILL.md` | Implementer — one ticket, full context |
| `librarian` | `start-project/librarian.md` | Knowledge base — merged diffs, ticket transitions, answers questions |
| `researcher` | `start-project/researcher.md` | Two-phase domain researcher — discovery then queryable, findings in research.md |
| `project-tester` | `project-tester/SKILL.md` | Ephemeral API tester — fresh context, talks directly to worker |

## Agent interaction model

```
Project Workspace (one Herdr workspace, all roles as tabs)
  ├── Orchestrator tab (repo root)
  ├── Librarian tab (repo root, stays on main)
  ├── Watcher tab (repo root, stays on main)
  ├── Researcher tab (repo root, stays on main, optional)
  ├── Worker A tab (repo root, cds into .worktrees/<ticket-a>/)
  ├── Worker B tab (repo root, cds into .worktrees/<ticket-b>/)
  └── Worker C tab (repo root, cds into .worktrees/<ticket-c>/)

Workers ──STARTING/COMPLETE──> Librarian (ticket transitions + operational notes)
Workers ──DONE──> Librarian (post-merge verification only)
Librarian ──COMPLETE relay──> Orchestrator (compact: PR#, ticket, test brief)
Librarian ──UNBLOCKED──> Orchestrator (dependency cleared, ready for worker)
Librarian ──PROJECT_COMPLETE──> Orchestrator (last ticket done)
Librarian ──WATCH──> Watcher (PR# + worker role to report to)
Watcher ──CI failures──> Worker (direct, structured failure reports)
Watcher ──CI GREEN──> Librarian (PR passed CI)
Workers ──BLOCKED/SCOPE──> Orchestrator (escalation)
Workers ──domain questions──> Librarian or Researcher
Orchestrator ──"PR merged, ingest"──> Librarian
Librarian ──"UNBLOCKED — APP-XXXX"──> Orchestrator (auto-detects cleared deps)
Researcher ──findings──> Librarian (stored alongside diffs)
Researcher ──new tickets──> Tracker + Librarian + Orchestrator (scope gaps)
Researcher ──out-of-scope work──> Orchestrator (flags, doesn't solve)
Orchestrator ──"status?"──> Librarian (PR/ticket state, esp. on restart)
Orchestrator ──spawns──> Tester (when worker provides test brief)
Tester ──findings──> Orchestrator ──"fix these"──> Worker
```

## Communication protocol

Two commands via the `project` CLI (`~/.local/bin/project`), which resolves roles to pane IDs from a shared state file. No agent names to hallucinate, no `herdr agent list` to parse.

- **`project prompt`** — fire a signal, don't need the reply (STARTING, COMPLETE, DONE, BLOCKED, SCOPE, DISTILL, assignments, merge notifications)
- **`project ask`** — send a question, wait for the agent to finish, print its pane output to stdout so the caller gets the answer in context

Examples:

- **Worker → Librarian:** `project prompt librarian "COMPLETE — PR #N for APP-XXXX. <operational notes>"`
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
| Ticket transitions | Librarian | Receives lifecycle signals, knows when work starts/completes |
| DAG monitoring, auto-unblock detection | Librarian | Sees merged signals, checks dependency graph, signals orchestrator |
| PR/ticket status queries | Librarian | Tracks all state; orchestrator asks rather than querying GitHub |
| Research findings (traffic, data shape, dependencies) | Librarian | Stores findings alongside merged diffs so workers can query both |
| CI monitoring, failure reporting | Watcher | Polls CI, reports failures directly to workers, reports green to librarian |
| Scope gap tickets | Researcher | Creates tickets in the tracker, reports to librarian + orchestrator |
| Out-of-scope work flagging | Researcher | Flags to orchestrator immediately, doesn't solve |

The librarian manages the full ticket lifecycle via signals from workers and the orchestrator:

| Signal | From | Librarian transitions to |
|--------|------|--------------------------|
| `STARTING — APP-XXXX` | Worker | In Progress |
| `COMPLETE — PR #N for APP-XXXX` | Worker | In Code Review |
| `DONE — APP-XXXX verified` | Worker | Done (post-merge verification) |
| `PR #N merged for APP-XXXX` | Orchestrator | Acceptance Test or Done |
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

- `herdr workspace create` — one workspace per project (all roles as tabs)
- `herdr tab create --workspace <id>` — one tab per role (librarian, researcher, workers)
- `herdr agent start <name> --kind claude --pane <id>` — start agent in a pane
- `herdr agent read <pane_id>` — read agent output
- `herdr agent get <pane_id>` — poll agent state
- `git worktree add <repo>/.worktrees/<ticket> -b <branch> origin/main` — worktree inside repo dir

### Researcher can create tickets for scope gaps

When the researcher discovers missing work, it creates child tickets under the project with dependency links, then reports new tickets to the librarian (for tracking) and orchestrator (for DAG update and worker spawning). This applies at two points:
- **Fresh project with no scope:** researcher creates the initial ticket set from discovery, orchestrator takes over with the DAG.
- **Mid-project gaps:** researcher finds missing work, creates tickets, reports them. Orchestrator updates the DAG and spawns workers when dependencies are met.

The researcher has access to the ticket tracker's MCP tools and permission to create tickets.

### Researcher cannot spawn workers for trivial fixes

When the researcher finds a small, self-contained fix (a doc typo, a missing config line), it cannot create a worker on its own. It must flag it to the orchestrator, which decides whether to spawn a worker or handle it differently. The overhead of orchestrator → worker spawning is disproportionate for one-line fixes, but letting the researcher make changes directly risks scope creep and branch confusion (the researcher sits on main). Accepted trade-off: the latency of going through the orchestrator is worth the clean role separation.

### DAG ownership is shared: orchestrator builds, librarian monitors

The orchestrator builds the initial DAG from the ticket tracker and spawns workers. The librarian tracks the DAG alongside its PR summaries and auto-detects unblocked tickets when dependencies are merged. The librarian signals the orchestrator when tickets are unblocked; the orchestrator spawns workers. Neither role does both — the librarian monitors, the orchestrator acts.

### Orchestrator does not research

The orchestrator stays lightweight: it reads the ticket tracker, manages the DAG, and spawns agents. It never greps the codebase, reads implementation files, or verifies whether work is done by inspecting code. When it needs that information, it asks the librarian (for merged work) or the researcher (for domain questions). On restart, it asks the librarian for ticket/PR status rather than querying GitHub directly.

## Known gaps

## Design decisions

### Worker reuse is librarian-advised

The librarian proactively recommends reuse or fresh worker in its UNBLOCKED signal, based on the coupling between tickets. Reuse when the next ticket builds on internals (same handler, same service); fresh when it only needs the interface (column names, method signatures). The orchestrator follows the advice or asks the librarian if it's not obvious. No hardcoded chain-length rule.

### Worktree lifecycle

Worktrees are the isolation mechanism for concurrent workers. Clear lifecycle rules prevent drift — stale worktrees accumulating, branches colliding, dirty state from previous tasks.

**Creation:**
- The orchestrator creates worktrees, never workers. One worktree per ticket, always from `origin/main`.
- Path convention: `<repo>/.worktrees/<ticket-key-lowercase>/` (already gitignored).
- Branch naming: `<ticket-key-lowercase>` — matches the directory name. No prefixes, no worker names in the branch.
- Command: `git -C <repo> worktree add .worktrees/<ticket> -b <ticket> origin/main`
- Never reuse an existing worktree for a different ticket. When a worker gets a follow-up ticket in a sequential chain, it stays in the same worktree but checks out a new branch (`git checkout -b <new-ticket> origin/main`).

**Cleanup after merge:**
- After a PR merges and the librarian ingests the diff, the orchestrator removes the worktree: `git -C <repo> worktree remove .worktrees/<ticket>/`
- Exception: skip cleanup if the worker has a next ticket in a sequential chain (it reuses the worktree with a new branch).

**Cleanup after project completion:**
- When all tickets are done, the orchestrator runs `project cleanup` to remove any remaining worktrees. This catches worktrees from sequential chains and any that were missed during wave transitions.

**Orphan detection:**
- Crashes, terminal closes, or orchestrator reboots can leave worktrees behind with no active agent.
- `project cleanup --dry-run` lists worktrees and marks each as active (has a non-stopped agent assigned) or orphan (no matching agent).
- `project cleanup` removes orphans and runs `git worktree prune` to clean up git's internal bookkeeping.
- The orchestrator should run cleanup at project start (before spawning wave 1) to clear debris from previous runs, and at project end.

**What workers must not do:**
- Create or remove worktrees — that's the orchestrator's job.
- Switch to a different worktree — stay in the one you were assigned.
- The "worktree escape" in the worker skill is user-initiated only (e.g. for console tasks that need the primary checkout).

### Recovery after restart

The system is resumable from four durable sources: the project state file (agent roster, session IDs, ticket assignments), the signal log (full event sequence), git (branches + worktrees), and the ticket tracker. A fresh orchestrator runs `project recover` to diagnose what's reachable vs. stale, then resumes agents with `--resume <session-id>` from the state file. Agents resumed this way retain their full context — no re-assignment needed.

Recovery priority: librarian first (accumulated knowledge is expensive to rebuild), then active workers. Workers with lost sessions get a fresh start with their assignment plus librarian context about prior work. See `start-project/SKILL.md` § Reboot recovery for the full procedure.

### Researcher two-phase model with durable artifact

The researcher operates in two phases: Discovery (front-loaded, high-context) maps the system end-to-end and writes findings to `~/.herdr/projects/<project>/research.md`. Ongoing (lighter, queryable) answers questions from the existing map and only investigates when the map is incomplete.

The durable artifact (research.md) serves two purposes: it lets the researcher answer questions without re-investigating, and it survives context restarts. When the researcher's context degrades, the orchestrator can restart it cleanly — the new instance loads research.md and resumes in Phase 2 without losing prior work. This is the distill/restart pattern: the artifact captures the value, the context window is disposable.

Sections (Current Model, Subtask Notes, Open Questions, Rejected Hypotheses, Evidence) are designed so the researcher and workers can find what they need without reading the whole file. Rejected Hypotheses prevents re-investigation of dead ends across restarts.

### Release detection (not yet implemented)

Workers don't know when their PRs get released. The orchestrator (or a release hook) should detect a release containing epic work and tell the librarian to transition tickets Acceptance Test → Done. Today this is manual.

### Tester agent pattern

An independent tester agent with fresh context catches bugs the implementer misses — it has no implementation assumptions and tests like a real consumer. In practice, a tester found 5 bugs across two rounds that the worker's own tests didn't cover (empty array 500s, missing params causing unbounded queries, wrong null handling, missing rollup data, silently dropped params).

The tester is an optional fourth role, spawned by the orchestrator when a worker's DONE signal includes a test brief. It's ephemeral — one per API ticket, not long-lived like the librarian or researcher.

Interaction model:
```
Worker ──COMPLETE + test brief──> Librarian
Librarian ──COMPLETE relay + test brief──> Orchestrator
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

### Plugin updates are orchestrator-only

When the user runs `herdr plugin update`, the CHANGELOG diff goes to the orchestrator — not to every agent. The orchestrator tells the user what changed and they decide whether any running agent needs a recycle.

Workers are short-lived — most finish before an update matters, and recycled/restarted workers load updated skills automatically. Long-lived agents (librarian, watcher, researcher) idle most of the time; injecting behavioral changes mid-session is more likely to confuse than help. The orchestrator surfaces the decision to the user, who can recycle specific agents if the update warrants it.

This follows signal economy: fanning the same CHANGELOG to N agents burns tokens in every context for information most can't act on mid-task. One routing point (the orchestrator) is enough.

### State recovery via project state file

The `project` CLI maintains a state file at `~/.herdr/projects/<project-name>.json` mapping role → pane ID + session ID. Agents self-register via `project register <role>` during boot (auto-detects pane ID and session ID). The state file is never deleted — `project stop` marks agents as stopped but preserves all data. The project name is injected as `HERDR_PROJECT` via `herdr tab create --env`.

On restart, `project roster` and `project status` show all agents (including stopped ones) and their current state. The orchestrator asks the librarian for ticket/PR status rather than querying GitHub.

Session IDs in the state file enable cross-time queries: a wave-2 worker can `--resume` or `SendMessage` a finished wave-1 worker's session when the librarian's summary isn't enough.

The orchestrator's reboot-recovery procedure is in `start-project/SKILL.md` § Reboot recovery.

### Knowledge pressure and distill

Agents degrade silently as their context fills with tool output, dead-end debugging, and accumulated noise. The distill mechanism lets any agent self-report context pressure before quality drops.

**Signal flow:**
```
Agent → orchestrator: DISTILL — <reason>
Orchestrator decides: approve or defer
If approve:
  Orchestrator → agent: DISTILL_ACK — write state, signal DISTILL_READY
  Agent commits WIP (if applicable), writes DISTILL.md with current state
  Agent → orchestrator: DISTILL_READY
  Orchestrator stops agent, restarts fresh (not --resume), sends original assignment + distill state
If defer:
  Orchestrator → agent: DISTILL_DEFER — finish current step first
```

**Key design choices:**
- DISTILL goes directly to the orchestrator, not through the librarian. It's an operational signal about agent health, not a lifecycle event. The librarian doesn't need to know or act on it.
- Restart is fresh, not `--resume`. The point is clean context — `--resume` would carry the noise forward.
- The agent writes its own state summary. It knows what matters from its context; the orchestrator just shuttles it to the fresh session.
- Workers commit WIP before distilling so no code is lost. The fresh session picks up from the committed state.

**When agents should request distill:**
- Context is noticeably full (responses getting slower, tool output accumulating)
- Repeated mistakes or going in circles on something that was clear earlier
- Large volume of noise from debugging, failed approaches, or verbose tool output

**When agents should NOT request distill:**
- Close to finishing (one or two steps left)
- The noise is from useful context they'll need again (e.g. a librarian's merged diff summaries)

## Constraints

- **Surface uncertainty, don't resolve it** — agents have a baseline drive to produce an answer rather than ask. In a single-agent session that's fine; in this system a wrong guess propagates through signals and burns tokens in every agent that receives it. When an agent is uncertain about scope, intent, or approach, it must use `AskUserQuestion` with concrete options rather than guessing. The structured dialog forces the agent to articulate the actual choices (which is itself useful reasoning) and gives the user a low-friction way to steer. A question is cheaper than a correction rippling through the system.
- **Signal economy** — every signal burns tokens in both sender and receiver. Route lifecycle events through one agent (the librarian) rather than fanning out. The orchestrator gets compact relays, not raw detail. The librarian only signals the orchestrator when it needs to act: `UNBLOCKED` (spawn workers) or `PROJECT_COMPLETE` (wrap up). Routine `DONE` signals are stored without relay.
- Max 3 concurrent workers
- Workers don't spawn sub-agents — escalate to orchestrator
- Librarian, watcher, and researcher are long-lived — all stay up for the life of the project. Librarian and researcher are on-demand (idle is their correct steady state). The researcher can be cleanly restarted when context degrades — research.md carries forward. The watcher self-paces with `ScheduleWakeup` to poll CI on its watch list
- Librarian ingests merged PRs and research findings
- All PRs opened as drafts
- Never force-push
- **Workers share project memory** — worktrees live inside the repo dir (`.worktrees/<ticket>/`), and each Claude session starts scoped to the repo root. This means workers see the same MEMORY.md, show up in `/resume`, and appear in the same session list as the primary checkout. The worker's first action is to cd into its worktree subdirectory.
