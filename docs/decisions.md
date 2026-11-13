# Decisions & Feedback

Key decisions with reasoning, open questions, and the feedback log from real epic runs.

## Key decisions

- **All agents communicate via `project` CLI** — `project prompt <role>` (fire-and-forget signals) and `project ask <role>` (questions that return the reply to stdout). The CLI resolves roles to pane IDs from `~/.herdr/projects/<project-name>.json`. The orchestrator writes the state file; agents read it. The project name is injected as `HERDR_PROJECT` via `herdr tab create --env`, so every agent resolves the same state file without flags. Session IDs are stored alongside pane IDs for cross-time queries (`--resume` a finished worker's session). **Why:** The dry-run test (2026-11-10) showed agent names collide across workspaces (`orchestrator` matched agents from other epics), and agents that ran `herdr agent list` hallucinated targets or refused to act. Pane IDs are unambiguous; the state file maps human-readable roles to them.
- **Librarian and researcher are on-demand, not always-on** — prompt them when there's work (merged diff to ingest, domain question to answer, lifecycle signal to process). Their value is accumulated context, not uptime. Both are reconstructable from Jira + git if the session dies, just slower.
- **Librarian ingests after merge only** — WIP diffs are noise. Librarian sits on main, no worktree.
- **Librarian owns Jira transitions** — receives lifecycle signals (STARTING, DONE, merged) and transitions tickets. Keeps ticket management off the orchestrator and workers.
- **Researcher is long-lived, one per epic** — accumulates domain knowledge (data schemas, traffic patterns, external API details). Workers and the orchestrator ask it questions. Don't spin up throwaway research agents — the accumulated context is the value.
- **Workers implement, researcher investigates** — when the orchestrator needs context from a worker's domain, ask the worker for a brief summary, then hand it to the researcher. Don't send workers off to investigate data schemas.
- **Max 3 concurrent workers** — starting guess, tunable.
- **Cross-repo** — orchestrator maps tickets to repos by Jira labels/components. Most land in the primary repo, some in `frontend/`, `pipelines/`, etc.
- **One workspace per epic** — all roles (orchestrator, librarian, researcher, workers) are tabs in a single Herdr workspace. Workers use git worktrees inside the repo dir (`.worktrees/<ticket>/`) for branch isolation, but their Claude sessions start scoped to the repo root for shared memory and session visibility.
- **Worker reuse is librarian-advised** — the librarian proactively recommends reuse or fresh worker in its UNBLOCKED signal, based on the coupling between tickets. Reuse when the next ticket builds on internals; fresh when it only needs the interface. No hardcoded chain-length rule.
- **Orchestrator does not research** — it reads Jira, manages the DAG, and spawns agents. It never greps the codebase or reads implementation files. When it needs that information, it asks the librarian or researcher. On restart, it asks the librarian for ticket/PR status rather than querying GitHub directly.
- **Researcher cannot spawn workers** — when the researcher finds a small fix, it flags to the orchestrator, which decides how to handle it. Accepted trade-off: latency over role confusion.
- **Tester agent** — an independent tester with fresh context catches bugs the implementer misses (no implementation assumptions). Spawned by the orchestrator when a worker's DONE signal includes a test brief. Ephemeral — one per API ticket.
- **DAG ownership is shared** — orchestrator builds the initial DAG from Jira. Librarian monitors it alongside PR summaries and auto-detects unblocked tickets when dependencies merge. Librarian signals; orchestrator acts.
- **PR_OPEN / DONE signal split** — `PR_OPEN` means "implementation complete, PR is up" (transitions to In Code Review). `DONE` is optional, only for post-merge verification work (data migration verified, production checks passed — transitions to Done). Most tickets only send `PR_OPEN`.
- **Lifecycle signals flow through the librarian** — workers send `PR_OPEN` and `DONE` to the librarian only. The librarian transitions Jira, stores operational notes, routes to the watcher (CI monitoring) and orchestrator (wave advancement). One routing point, one signal path. Reduces duplicate token burn from workers fanning out the same event to multiple agents.
- **Watcher agent** — long-lived CI monitor, one per epic. Receives watch assignments from the librarian, polls CI status, reports failures directly to workers, reports green to the librarian. Doesn't fix code, doesn't mark PRs ready, doesn't talk to the orchestrator. Context stays lean because it only reads CI output, not implementation code.

## Evaluated and kept

- **`project` CLI vs herdr native agent commands** (2026-11-13) — audited every `project` subcommand against herdr 0.9.5 capabilities. herdr's `agent start <name>` + `agent prompt <name>` could replace our role→pane resolution, but `project prompt` adds FROM prefixes, NEED escalation for stopped agents, and ticket tracking — all of which we use. The resolution cost is one `jq` read of a tiny JSON file. `hc` (herdr-core's parent/child agent model) is not available locally. Conclusion: the project CLI is a thin semantic layer on herdr plumbing, not a reimplementation. Not worth refactoring.

## Open questions

- **Concurrency limit** — is 3 right? Depends on machine resources and task size.
- **Worker-to-worker direct chat** — currently routed through the librarian. Tightly coupled tickets might want a shortcut.
- **Ingestion depth** — diffs alone, or also PR descriptions for business context?
- **Project researcher skill** — a long-lived agent that answers domain questions. Not yet formalized as a skill.
- **Librarian advising on splits** — orchestrator asks librarian how to decompose a large ticket based on codebase knowledge.
- **Release detection** — orchestrator or a hook detects a release containing epic work and tells the librarian to transition tickets from Acceptance Test to Done. Today this is manual.
- **Tester beyond API parity** — could the tester generalize to non-API work (data migration verification, background job output checks)?

## Feedback — Applied

Findings from real epic runs that have been worked into skills or DESIGN.md.

- **Scope creep judgment call** → `project-worker/SKILL.md`: small fixes that unblock the ticket, just do it; separate units of work, signal SCOPE.
- **Back-channel to orchestrator** → `project-worker/SKILL.md` + `start-project/SKILL.md`: workers message orchestrator directly via `herdr agent prompt`, orchestrator name included in worker prompt.
- **Worktree cleanup after merge** → `start-project/SKILL.md` Step 5: remove worktree after merge unless sequential chain continues.
- **Worker must branch from main** → `project-worker/SKILL.md` Step 2b: `git log --oneline main..HEAD` check + rebase if needed.
- **No shared memory in worktrees** → RESOLVED: workers now start scoped to the repo root and cd into `.worktrees/<ticket>/`. They share project memory, `/resume`, and session list with the primary checkout.
- **Worker → librarian lifecycle signals** → `start-project/librarian.md`: STARTING → In Progress, DONE → In Code Review, merged → Done. Workers message librarian directly; orchestrator stays lightweight.
- **Researcher is long-lived** → key decisions above + `start-project/DESIGN.md`: one researcher per epic, accumulates domain knowledge, don't spin up throwaway agents.
- **Don't make workers research** → key decisions above: workers summarize what they know, researcher investigates.
- **Researcher not planner** → key decisions + open questions above: after initial slicing it's a knowledge service, not a driver.
- **Spike closure** → `start-project/SKILL.md`: skip research if epic already has populated children; research agent closes its own spike via librarian.
- **Research reporting** → `start-project/librarian.md`: librarian stores research findings alongside merged diffs.
- **On-demand librarian/researcher** → key decisions above + `start-project/DESIGN.md` constraints: prompt when there's work, don't keep polling.
- **Release detection** → `start-project/DESIGN.md` design decisions: not yet implemented, noted as future automation.
- **Orchestrator restart mid-epic** → `start-project/DESIGN.md` design decisions: operational pattern, Herdr agents survive across sessions.
- **Tester agent pattern** → `project-worker/SKILL.md` Step 8 (test brief output), `start-project/SKILL.md` Step 5a (tester spawning), `start-project/DESIGN.md` (tester role, interaction model, API parity playbook).
- **State persistence** → `start-project/SKILL.md` § Restart recovery (procedure), `start-project/DESIGN.md` § State recovery.
- **All agents need collaborator names** → `start-project/SKILL.md` Step 3: researcher boot prompt now includes orchestrator + librarian agent names.
- **Workers need worktree escape hatch** → `project-worker/SKILL.md` § Worktree escape: user-initiated procedure to move from worktree to primary checkout.
- **Librarian should track DAG and auto-unblock** → `start-project/librarian.md` § DAG tracking: librarian monitors dependency graph, signals orchestrator when tickets are unblocked.
- **Researcher should request small workers** → `start-project/DESIGN.md`: researcher cannot spawn workers. Flags to orchestrator.
- **Researcher should flag out-of-scope work** → `start-project/SKILL.md` Step 3: researcher boot prompt includes instruction to flag out-of-scope work immediately.
- **Orchestrator should not do research** → `start-project/SKILL.md` § What you do NOT do + § Restart recovery.
- **Researcher boot prompt must include agent names** → `start-project/SKILL.md` Step 3.
- **Researcher should create Jira tickets** → `start-project/SKILL.md` Step 3 + `start-project/DESIGN.md`.
- **Orchestrator should name workspace descriptively** → `start-project/SKILL.md` Step 3.
- **Orchestrator should delegate PR/merge status to librarian** → `start-project/SKILL.md` § Reboot recovery + `start-project/librarian.md` § PR and ticket status queries.
- **Researcher is long-lived, not idle-shutdown** → `start-project/SKILL.md` Step 6a + `start-project/DESIGN.md` constraints: researcher stays up for the epic like the librarian. Idle is its correct steady state — it accumulates domain context (data shapes, API details, feasibility findings) that's expensive to rebuild. The v0.3.0 "shut down idle agents" rule applies to workers and testers only.
- **`project stop` replaces `unregister`** → `scripts/project.sh` + `start-project/SKILL.md` Step 6a: stopping an agent marks it `stopped: true` in the state file but preserves session_id, pane_id, tickets, and worktree path. `project register` clears the stopped flag on re-register. `project status` shows stopped agents without querying herdr. `project prompt`/`project ask` refuse to message stopped agents with a clear error. `project next-worker` reuses stopped worker names. No data is ever deleted from the state file.

## Feedback — New

Findings not yet worked into skills. Move to "Applied" after routing.

(None pending.)
