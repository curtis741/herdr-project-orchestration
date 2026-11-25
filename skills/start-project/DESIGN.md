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

Every project starts small: the orchestrator hosts the librarian and researcher, the watcher is unassigned (workers watch their own CI), and workers are the only other agents. A role gets its own agent by promotion, when the project needs it (below). The diagram is the full split, with every role promoted.

```
Project Workspace (one workspace per project, all agents as tabs)
  ├── Orchestrator tab (repo root; hosts every role until it is promoted)
  ├── Librarian tab (repo root, stays on main; once promoted)
  ├── Watcher tab (repo root, stays on main; once promoted)
  ├── Researcher tab (repo root, stays on main; once promoted)
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

### Small by default, promotion by need

A role is an address and an agent is a host; one agent can host several roles (details in `docs/mode.md`). Senders never change: workers always signal `librarian` or `researcher`, and the CLI resolves the role to its current host. `project register orchestrator` makes the orchestrator host librarian and researcher, so nothing is spawned for them at startup.

- **Hosting.** A message for a hosted role arrives as `[to <role>] FROM(<sender>): …`. The first time one arrives, the orchestrator reads that role's **When hosted** section (in `librarian.md` / `watcher.md` / `researcher.md`), a condensed rule set, not the full role file. Hand-offs between hosted roles are the orchestrator's own steps; the CLI refuses a host messaging its own role, so no signal is ever sent to itself. In the diagram above, a hosted librarian's relay to the orchestrator is not a message.
- **Unassigned watcher.** No agent holds the watcher at boot: `project status watcher` prints `unassigned` and `project prompt watcher` fails at once (`has no agent — do it yourself`), with no NEED escalation. Until the watcher has its own agent, each worker watches its own PR's CI and the librarian sends no WATCH. Spawning it assigns the role; then it watches every PR as before.
- **Promotion is proposed, never automatic.** The orchestrator asks with `AskUserQuestion` when its context guard nudges it, when 3 or more workers run at once or merged diffs pile up (librarian), on CI churn (watcher), or on a research question it can't answer cheaply (researcher). On yes it writes `$(project dir)/<role>.handoff.md` (what it knows as that role, apart from its orchestrator state), runs `project promote <role> --task …` with a boot task that points at the file, and stops acting as that role. A promoted role is not moved back automatically.
- **Exception: no tasks.** An epic with no child tickets promotes a researcher immediately to fill them in.

Why: a small project doesn't pay for three idle long-lived agents, and a large one doesn't overload the orchestrator. Promotion by need sizes the staffing to the load instead of guessing at the start. The procedure is in `start-project/SKILL.md` § Promotion.

## Communication protocol

Two commands via the `project` CLI (`~/.local/bin/project`), which resolves roles to terminals from a shared state file. Agents address each other by role only: no agent names to hallucinate, no pane IDs or agent lists to parse.

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
| Merged diff summaries, answering cross-worker questions | Librarian | Single source of truth (hosted by the orchestrator until promoted) |
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

Standalone shell script. State file at `~/.herdr/projects/<project-name>.json`. Single writer (orchestrator), many readers (all agents). Agents get the project name from `project name` (exits 1 if none); on classic herdr it comes from the `HERDR_PROJECT` env var that `project spawn` sets, on the hc backend from the terminal's `project` label.

Everything an agent needs from the terminal layer goes through these subcommands, addressed by role. No agent ever handles a pane ID, workspace ID, tab ID or terminal name.

- `project open <project-name> [--label TEXT] [--focus]` — create the project's workspace and state file, print `export HERDR_PROJECT=<name>` (used with `eval`)
- `project close` — close the project's workspace (all tabs)
- `project spawn <role> [--cwd DIR] [--label TEXT] [--title TEXT] (--task "<boot>" | --task - | --task-file PATH) [--wait --timeout MS] [--resume] [--takeover]` — open a tab, start the agent and deliver its first task in the launch itself (a later prompt to a booting agent can be dropped). Pre-registers the role. `--resume` reuses the stored session; `--takeover` starts a successor while the old agent keeps the role until the successor registers
- `project next-worker` — print the next unused worker name (NATO phonetic alphabet: alpha, bravo, charlie... then alpha2, bravo2...). Names are never reused within a project
- `project register <role>` — an agent's boot step: confirms the roster entry, signals READY, records its session
- `project assign <role> <ticket-key>` — track a ticket assignment to a worker (supports multiple tickets per worker)
- `project prompt <role> <message> [--wait --timeout MS]` — fire-and-forget signal
- `project ask <role> <question>` — send, wait for idle, read and print the reply to stdout
- `project read <role> [--lines N]` — read an agent's recent output (non-blocking)
- `project roster` — print the project's roles
- `project status [<role>]` — one word per role: working/idle/blocked/done/stopped/unreachable (no argument: whole roster)
- `project stop <role> [--close]` — mark an agent stopped, optionally closing its tab
- `project rename <role> "<label>"` — relabel a role's tab
- `project retire <role>` — a successor shuts down its predecessor (see distill)
- `project session <role>` — print session ID (for `--resume` or `SendMessage`)

`<role>@prev` addresses a role's predecessor (`project ask`, `prompt`, `read`); it exists only after the successor has registered.

### Transport

The terminal layer (workspaces, tabs, agent launch, prompt delivery, reads, state polling, closing) lives entirely in `scripts/project.sh`. Today it drives classic Herdr. An `hc` backend (Herdr app) is planned (see `docs/dual-mode.md`) behind the same subcommands, so skills and this document don't change when the transport does.

### Git

- `git worktree add <repo>/.worktrees/<ticket> -b <branch> origin/main` — worktree inside repo dir

### Researcher can create tickets for scope gaps

When the researcher discovers missing work, it creates child tickets under the project with dependency links, then reports new tickets to the librarian (for tracking) and orchestrator (for DAG update and worker spawning). This applies at two points:
- **Fresh project with no scope:** researcher creates the initial ticket set from discovery, orchestrator takes over with the DAG.
- **Mid-project gaps:** researcher finds missing work, creates tickets, reports them. Orchestrator updates the DAG and spawns workers when dependencies are met.

The researcher has access to the ticket tracker's MCP tools and permission to create tickets.

### One-off fixes are spun off, not routed through the orchestrator

When any agent (or the user) has a scoped, self-contained fix that isn't worth a ticket, it runs `project spinoff "<title>"` with the brief on stdin. The script writes the brief to `$(project dir)/spinoffs/<id>.md`, creates a `spinoff-<name>` worktree off origin/main, opens a tab and boots a worker in spinoff mode. The worker reads the brief file itself. The orchestrator gets a one-line FYI and takes no action.

This replaced "researcher cannot spawn workers for trivial fixes". That rule cost three messages per fix (requester → orchestrator, orchestrator spawns, requester briefs the worker), and the orchestrator ended up relaying context instead of dispatching. Spawning in the CLI keeps role boundaries intact: agents still don't spin up sub-agents on their own, and the researcher still never edits code.

- **Outside the wave cap.** A one-off usually blocks something or is a problem in general, so it shouldn't wait behind wave work. A separate cap (2 concurrent spinoffs) stops runaway spawning. Past that, the requester punts instead.
- **No ticket.** The PR references the epic. The librarian handles `spinoff-*` keys without transitions or DAG checks.
- **Fire-and-forget.** The requester handed it off so it wouldn't have to carry it. `--notify` returns one `SPINOFF_DONE` line for requesters who are blocked on the fix.
- **Self-closing.** After merge (or a no-op), the worker runs `project spinoff-done`, which stops it and closes its tab. `project cleanup` removes the worktree.
- **Fixes only, not research.** Investigations still go to the researcher (`research` / `punt`), because the researcher's accumulated context is the value.

### DAG ownership is shared: orchestrator builds, librarian monitors

The orchestrator builds the initial DAG from the ticket tracker and spawns workers. The librarian tracks the DAG alongside its PR summaries and auto-detects unblocked tickets when dependencies are merged. The librarian signals the orchestrator when tickets are unblocked; the orchestrator spawns workers. Neither role does both — the librarian monitors, the orchestrator acts.

### Orchestrator does not research

The orchestrator stays lightweight: it reads the ticket tracker, manages the DAG, and spawns agents. It never greps the codebase, reads implementation files, or verifies whether work is done by inspecting code. When it needs that information, it asks the librarian (for merged work) or the researcher (for domain questions). For a role it hosts, it answers only as far as that role's When hosted section goes and proposes promotion beyond that. On restart, it asks the librarian for ticket/PR status rather than querying GitHub directly.

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

The researcher operates in two phases: Discovery (front-loaded, high-context) maps the system end-to-end and writes findings to `$(project dir)/research.md`. Ongoing (lighter, queryable) answers questions from the existing map and only investigates when the map is incomplete.

The durable artifact (research.md) serves two purposes: it lets the researcher answer questions without re-investigating, and it survives context restarts. When the researcher's context degrades, the orchestrator can restart it cleanly — the new instance loads research.md and resumes in Phase 2 without losing prior work. This is the distill/restart pattern: the artifact captures the value, the context window is disposable.

Sections (Current Model, Subtask Notes, Open Questions, Rejected Hypotheses, Evidence) are designed so the researcher and workers can find what they need without reading the whole file. Rejected Hypotheses prevents re-investigation of dead ends across restarts.

### Researcher requests: ask vs. punt

Workers hit two different situations. "I need to know this" (`project research`) is a question — the answer comes back to the asker. "I think we have a problem here" (`project punt`) is a handoff — the researcher owns the outcome and acts (ticket, orchestrator, user), and the sender hears nothing unless their ticket is affected. Without the split, a punted problem came back to the worker as a findings dump, and the worker relayed it to the user — two agents' context burned on something neither needed to hold.

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

When the user updates the plugin (or mod), the CHANGELOG diff goes to the orchestrator — not to every agent. The orchestrator tells the user what changed and they decide whether any running agent needs a recycle.

Workers are short-lived — most finish before an update matters, and recycled/restarted workers load updated skills automatically. Long-lived agents (librarian, watcher, researcher) idle most of the time; injecting behavioral changes mid-session is more likely to confuse than help. The orchestrator surfaces the decision to the user, who can recycle specific agents if the update warrants it.

This follows signal economy: fanning the same CHANGELOG to N agents burns tokens in every context for information most can't act on mid-task. One routing point (the orchestrator) is enough.

### Project working dir

`~/.herdr/projects/<project>/` (printed by `project dir`) is the shared, uncommitted working directory for every agent in the project: research.md, feedback.md, distill files, test plans, context notes, cross-agent learnings, reusable test scripts. It lives exactly as long as the project. This replaces session scratchpads (which vanish between sessions and are invisible to other agents) and worktree-local files (which pollute git and die with the worktree). Files are role-prefixed to avoid collisions. Durable shared files are also a token-quality tool: pass a path instead of pasting content through signals.

### State recovery via project state file

The `project` CLI maintains a state file at `~/.herdr/projects/<project-name>.json` mapping role → terminal + session ID (the CLI's own bookkeeping; agents never read it). Agents self-register via `project register <role>` during boot (auto-detects terminal and session ID). The state file is never deleted — `project stop` marks agents as stopped but preserves all data. The project name is injected as `HERDR_PROJECT` by `project spawn`. Sessions resumed after a reboot lose that env var, so when it's unset the CLI falls back to the state file whose agents claim the current terminal (or whose workspace matches the current one).

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
  Orchestrator runs `project recycle <role>`:
    → agent: DISTILL_ACK — commit WIP, write $(project dir)/<role>.distill.md (no DISTILL_READY; the command waits for idle, bounded timeout)
    → a blocked/stuck agent, or no file written: left running, exit 1, re-run later
    → `project spawn <role> --takeover …` → successor in a NEW tab (fresh, not --resume), same label/title/cwd (recorded at spawn),
       boot prompt = original boot task (<role>.boot.md) + takeover steps pointing at the distill file
  Successor runs `project register <role>` (signals now route to it), reads the distill file
  Successor optionally questions the old agent with `project ask <role>@prev "<q>"`
  Successor runs `project retire <role>` → old tab closed, SHUTDOWN logged
If defer:
  Orchestrator → agent: DISTILL_DEFER — finish current step first
```

**Project-wide reset:** `project reset` is distill applied to the whole project at once. A dump runs in parallel (`DUMP` → each agent writes `<role>.final.md` or nothing, then is stopped and its tab closed), the orchestrator writes a master distill (`orchestrator.reset.md`), and `reset --handoff` boots a fresh orchestrator from it the same way a distill successor boots. The successor spawns fresh agents instead of resuming old sessions, for the same reason distill restarts fresh. `project dump` alone is the pause variant: the same dump, no successor, and sessions stay resumable. Agents that don't finish in time are left running, never killed mid-write.

**Key design choices:**
- DISTILL goes directly to the orchestrator, not through the librarian. It's an operational signal about agent health, not a lifecycle event. The librarian doesn't need to know or act on it.
- Restart is fresh, not `--resume`. The point is clean context — `--resume` would carry the noise forward.
- The agent writes its own state summary. It knows what matters from its context.
- The orchestrator never reads the distill file — it passes the path. The successor reads it directly, so the state never burns orchestrator tokens.
- Distill files live in the project dir, not the worktree — they don't pollute `git status`, and the successor always knows where to look.
- The successor owns the predecessor's shutdown. Either it has questions or it doesn't; once it's ramped, it retires the old agent itself. No extra signal to the orchestrator — `SHUTDOWN` is logged only. Re-registering keeps the old session ID in `previous_sessions`.
- Workers commit WIP before distilling so no code is lost. The fresh session picks up from the committed state.
- **Distill beats compaction.** Auto-compaction is lossy and uncontrolled — one worker lost the fact that it was in a project at all and fell back to a generic subagent instead of `project research`. A distill is written by the agent for its role; a compaction summary is generic.

**Context guard (enforcement):** agents can't reliably sense their own context size, so a global Claude Code hook (`scripts/context-guard.sh`, installed by `setup.sh`) does it for them. It's a no-op unless the session's terminal is a registered, non-stopped agent in a project state file.
- **Stop hook** — after each turn, reads the transcript's last assistant `usage` (input + cache tokens) as the current context size. Once that passes `PROJECT_DISTILL_PCT` (default 60%) of the context window, it injects a one-time nudge telling the agent to request DISTILL. The orchestrator is told to write `orchestrator.distill.md` and ask the user for a fresh session instead.
- **SessionStart `compact` hook** — the backstop. If compaction happens anyway, it re-injects identity (role, project, project dir, `project` CLI), which instructions to re-read, and a push to DISTILL.
- **Percent of window, not a fixed token count.** Every session starts with a fixed baseline (system prompt, tool/MCP definitions, CLAUDE.md, memory) that can exceed 80k tokens and is identical in a fresh successor. The first version used an absolute 150k threshold: a librarian on a 1M window was nudged, distilled, and its successor — 86k at boot, then a re-verification sweep — was nudged again within 3 minutes. At 60% of a 1M window the baseline is noise. Successors are also told to trust the distill file rather than re-verify it.
- **Window size.** Hooks aren't told the window and the transcript's model ID doesn't encode it; only the statusline receives `context_window.context_window_size`. The hook reads it from `~/.herdr/projects/.ctx-window/<session_id>` if a statusline writes it, else `PROJECT_CONTEXT_WINDOW`, else assumes 1M. Erring large is the safe failure: on a smaller window the nudge never fires and the compaction backstop still catches the agent. Statusline snippet:
  ```sh
  sid=$(echo "$input" | jq -r '.session_id // empty'); win=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
  [ -n "$sid" ] && [ -n "$win" ] && mkdir -p "$HOME/.herdr/projects/.ctx-window" && echo "$win" > "$HOME/.herdr/projects/.ctx-window/$sid"
  ```
- Auto-compaction stays enabled as the safety net. Blocking it with a PreCompact hook was rejected: a blocked compaction doesn't restart anything, and if context is already full the request just fails.
- The transcript usage format isn't a documented contract; if it changes, the Stop hook silently stops nudging (it never fails the session).

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
- The librarian and researcher are hosted by the orchestrator until promoted; the watcher is unassigned until spawned. Once a role has its own agent it is long-lived and stays up for the life of the project. Librarian and researcher are on-demand (idle is their correct steady state). The researcher can be cleanly restarted when context degrades — research.md carries forward. The watcher self-paces with `ScheduleWakeup` to poll CI on its watch list
- Librarian ingests merged PRs and research findings
- All PRs opened as drafts
- Never force-push
- **Workers share project memory** — worktrees live inside the repo dir (`.worktrees/<ticket>/`), and each Claude session starts scoped to the repo root. This means workers see the same MEMORY.md, show up in `/resume`, and appear in the same session list as the primary checkout. The worker's first action is to cd into its worktree subdirectory.
