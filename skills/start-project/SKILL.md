---
name: start-project
description: "Orchestrate a project across multiple Herdr worker agents. Reads the project's tickets, builds a dependency DAG, spawns worker agents in tabs (one per ticket, worktree inside repo dir), and tracks progress wave by wave. Also spawns a librarian agent that ingests merged diffs so later workers can ask about earlier work. Use when the user says 'start project', 'start epic', 'work on epic APP-XXXX', 'orchestrate this epic', or 'spin up workers for this epic'. Requires Herdr."
---

# start-project — Project Orchestrator

You are the orchestrator for a multi-ticket project (an epic, a group of linked tickets, or any set of tasks with dependencies). Your job is to stay lightweight, track progress, and coordinate workers. You never write implementation code yourself.

## Prerequisites

Verify the `project` CLI is available:

```bash
which project
```

If it fails, stop — this skill requires the project-orchestration plugin (`herdr plugin install curtis741/herdr-project-orchestration`).

## Step 1: Load the project

Parse the project key from the user's message (e.g. `APP-1234`). Use the ticket tracker's MCP tools to:

1. Fetch the project and its child tickets
2. For each ticket, read its summary, description, and **depends-on links** (`is blocked by` / `depends on`)
3. Build a dependency DAG — tickets with no unfinished dependencies are wave 1
4. Suggest a session rename: `Rename this session: /rename APP-XXXX <epic summary>`

Present the work plan to the user:

```
[start-project] Epic APP-XXXX — N tickets

Wave 1 (no dependencies):
  - APP-1001: Add new column to transactions table
  - APP-1002: Create withdrawal activity handler

Wave 2 (depends on wave 1):
  - APP-1003: Backfill new column (depends on APP-1001)

Wave 3 (depends on wave 2):
  - APP-1004: Update reporting views (depends on APP-1003)

Sequential chains:
  APP-1001 → APP-1003 → APP-1004

Repo mapping:
  APP-1001..1004: core/ (default)
  APP-1005: frontend/
```

**Spikes / research tickets:** If the project already has populated child tickets (descriptions, dependency links), skip the research phase — the spike is done. Exclude spike tickets from the DAG and note them as already resolved in the plan. If the project has open discovery questions (listed in the description or spike comments), spawn a lightweight research agent alongside wave 1. The research agent closes its own spike ticket when its work is done — the orchestrator doesn't manage that transition.

Wait for the user to confirm or adjust before proceeding.

## Step 2: Determine repo mapping

Check each ticket's labels, components, or description for which repo it targets. If the epic spans multiple repos, map each ticket to its repo path based on the labels. Example:

| Label/component | Repo path |
|----------------|-----------|
| `frontend` | `~/repos/<project>/frontend/` |
| `backend`, `api` | `~/repos/<project>/core/` |
| (default) | `~/repos/<project>/core/` |

If you can't determine the repo from labels, ask the user.

## Step 3: Create the project workspace and initialize

One workspace holds everything for this project — orchestrator tab, librarian tab, and worker tabs:

```bash
herdr workspace create --cwd "$PWD" --label "<epic human name> (APP-XXXX)" --focus
```

Use the project's human-readable name as the label — e.g. `"User Auth Migration (APP-1234)"`, not just the ticket key or a role name. The user sees this in their workspace list and needs to know which project it belongs to.

Note the workspace ID from the response. Pick a project name — lowercase project key (e.g. `app-1234`) or ask the user if ambiguous. Initialize the project and export the env var:

```bash
eval "$(project init <project-name> <workspace-id>)"
```

This creates the state file and exports `HERDR_PROJECT` in your shell.

Register yourself (the orchestrator):

```bash
project register orchestrator
```

All tabs you create below get `--env HERDR_PROJECT=<project-name>` so every agent resolves the same state file automatically. Communication uses `project prompt <role>` (fire-and-forget signals) or `project ask <role>` (questions that need an answer back).

### Spawn the librarian

Create a tab for the librarian in the project workspace:

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "librarian" --env HERDR_PROJECT=<project-name> --no-focus
```

Read the pane ID from the response. Start a claude agent:

```bash
herdr agent start librarian --kind claude --pane <pane_id>
```

Boot the librarian with a minimal identity prompt. `project register` writes the state file and signals READY to you automatically:

```bash
herdr agent prompt <pane_id> "<epic-summary> — librarian.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.

Boot sequence:
1. Run: project register librarian
2. Wait for your assignment." --wait --timeout 60000
```

When the librarian reports READY, send its full role payload:

```bash
project prompt librarian "Your assignment:

Epic: APP-XXXX
Summary: <epic summary>

Dependency DAG:
  APP-1001, APP-1002 (wave 1, no blockers)
  APP-1003 (wave 2, blocked by APP-1001)
  APP-1004 (wave 3, blocked by APP-1003)

Your role is defined in ~/.claude/skills/start-project/librarian.md — read it now and follow it." --wait --timeout 120000
```

### Spawn watcher

The watcher monitors CI on all worker PRs and reports failures directly to workers. Spawn it alongside the librarian — it's long-lived, one per project.

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "watcher" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start watcher --kind claude --pane <pane_id>
```

Boot the watcher:

```bash
herdr agent prompt <pane_id> "<epic-summary> — watcher.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'watcher'.

Boot sequence:
1. Run: project register watcher
2. Wait for your assignment." --wait --timeout 60000
```

When the watcher reports READY, send its role payload:

```bash
project prompt watcher "Your assignment:

Epic: APP-XXXX
Repo: <owner/repo>

Your role is defined in ~/.claude/skills/start-project/watcher.md — read it now and follow it." --wait --timeout 60000
```

### Spawn researcher (if needed)

If the project has open discovery questions (noted in the description, spike comments, or your own judgment), spawn a long-lived researcher alongside wave 1. Skip this if the project is well-understood.

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "researcher" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start researcher --kind claude --pane <pane_id>
```

Boot the researcher with a minimal identity prompt:

```bash
herdr agent prompt <pane_id> "<epic-summary> — researcher.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'researcher'.

Boot sequence:
1. Run: project register researcher
2. Wait for your assignment." --wait --timeout 60000
```

When the researcher reports READY, send its full role payload:

```bash
project prompt researcher "Your assignment:

Epic: APP-XXXX
Summary: <epic summary>

Open questions to investigate:
<list open discovery questions from the epic description or spike comments>

Your role is defined in ~/.claude/skills/start-project/researcher.md — read it now and follow it." --wait --timeout 120000
```

## Step 4: Spawn wave 1 workers

For each ticket in wave 1, create a worktree inside the repo, then spawn a worker in a tab scoped to the repo root:

### 4a. Create the worktree

```bash
git -C <repo_path> worktree add .worktrees/<ticket-key-lowercase> -b <ticket-key-lowercase> origin/main
```

This puts the worktree at `<repo>/.worktrees/<ticket>/` — already gitignored, and inside the repo dir so the Claude session can access it.

### 4b. Name the worker and create its tab

Pick the next available worker name:

```bash
worker_name=$(project next-worker)
```

This returns NATO phonetic names in order: alpha, bravo, charlie, etc.

```bash
herdr tab create --workspace <workspace-id> --cwd <repo_path> --label "$worker_name — <ticket-key>" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start "$worker_name" --kind claude --pane <pane_id>
project assign "$worker_name" <ticket-key>
```

The Claude session starts scoped to `<repo_path>` — it shares memory, `/resume`, and session list with the primary checkout.

### 4c. Boot the worker

Send a minimal boot prompt. The worker cds into its worktree, registers itself (which writes the state file and signals READY to you), then waits for assignment:

```bash
herdr agent prompt <pane_id> "<ticket-summary> — worker $worker_name.
Your worktree is at .worktrees/<ticket-key-lowercase>/.

All agents use 'project prompt <role> <message>' to communicate. Your role is '$worker_name'.

Boot sequence:
1. cd .worktrees/<ticket-key-lowercase>/
2. Run: pwd && git branch --show-current
3. Run: project register $worker_name
4. Wait for your assignment." --wait --timeout 60000
```

### 4d. Send the assignment

When the worker reports READY, send the ticket details:

```bash
project prompt $worker_name "Your assignment:

Ticket: <ticket-key>
Summary: <ticket summary>
Description: <ticket description>

Dependencies: <list any prior tickets this depends on, or 'none'>

Run /project-worker to load your skill. It will guide you through implementation." --wait --timeout 300000
```

**Limit concurrency.** Start at most 3 workers simultaneously. Additional wave-1 tickets queue behind them — start the next queued ticket when a running worker completes.

## Step 5: Monitor and advance

Workers message you directly when they finish, hit a blocker, or find scope creep. As a fallback, check on quiet workers:

```bash
project status
```

When the librarian relays a `PR_OPEN` signal for a worker (or the worker reaches `idle`):

1. Verify a draft PR was opened (check via GitHub MCP)
2. Notify the user: `[start-project] APP-1001 — PR #XXXX opened`
3. **If the librarian's relay includes a test brief** (API or parity migration work), spawn a tester — see Step 5a

The watcher handles CI monitoring — the librarian already told it to watch the PR. You don't need to manage CI checks.

When the librarian relays a `DONE` signal (post-merge verification complete), notify the user: `[start-project] APP-1001 verified in production — done.`

## Step 5a: Spawn tester (API / parity work only)

When a worker's DONE signal includes a test brief, spawn an independent tester agent. The tester and worker talk directly — you just set up the introduction.

```bash
herdr tab create --workspace <workspace-id> --cwd <repo_path> --label "tester-<ticket-key>" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start tester-<ticket-key> --kind claude --pane <pane_id>
```

The tester needs to cd into the worker's worktree to test against the worker's branch:

```bash
herdr agent prompt <pane_id> "You are an independent API tester for <ticket-key>.

Boot:
1. cd .worktrees/<ticket-key-lowercase>/ && pwd && git branch --show-current
2. project register tester-<ticket-key>

<paste the worker's test brief here>

All agents use 'project prompt <role> <message>' to communicate. Your role is 'tester-<ticket-key>'.
The worker's role is '<ticket-key-lowercase>'.

Run /project-tester to load your skill.

Reply 'ready' when understood." --wait --timeout 60000
```

Tell the worker about the tester:

```bash
project prompt <ticket-key-lowercase> "A tester agent (role 'tester-<ticket-key>') is testing your endpoint. It will message you directly with findings. Fix blocking issues and tell it when to re-verify."
```

The tester and worker handle the fix-verify cycle between themselves. The tester messages you when all blocking findings are resolved (or if it's stuck).

When a worker's PR is **merged** (check via GitHub MCP — the user may merge manually or tell you):

1. Tell the librarian to ingest the diff:
   ```bash
   project prompt librarian "APP-1001 PR #XXXX was just merged to main. Read the diff and summarize what changed — focus on new interfaces, changed files, and patterns other workers need to know about." --wait --timeout 120000
   ```
2. Clean up the worktree:
   ```bash
   git -C <repo_path> worktree remove .worktrees/<ticket-key-lowercase>
   ```
   Skip cleanup if the worker has a next ticket in a sequential chain (it reuses the worktree — see Step 6).
3. Check if any wave 2+ tickets are now unblocked (all dependencies merged)
4. Spawn workers for newly unblocked tickets (repeat Step 4)

When a worker is `blocked`:

1. Read its state: `herdr agent read <pane_id> --source recent-unwrapped --lines 40`
2. If it's a permission prompt or question, escalate to the user
3. If it's a technical blocker, report it

## Step 6: Worker reuse decisions

**Default to a fresh worker.** Worker reuse is a context-window optimization, not a way to avoid spawning agents. A fresh worker with a librarian summary is almost always better than a worker carrying stale context from a different ticket.

When a ticket completes and the next ticket in the chain is unblocked, ask yourself: does the next ticket need implementation details that live only in this worker's context window — details the librarian can't summarize? If the answer isn't a clear yes, spawn fresh.

The librarian may message you unprompted after ingesting a merge: `"Worker alpha finished APP-1001 and I see APP-1003 is unblocked. APP-1003 builds directly on the handler internals — reuse the worker."` Follow that advice.

If the librarian hasn't weighed in and it's not obvious, ask:

```bash
project ask librarian "APP-1003 depends on APP-1001. Does APP-1003 need the implementation details from APP-1001's worker, or is the interface summary enough for a fresh worker?"
```

**Reuse only when** the next ticket extends the same internals — validation edge cases, factory setup, schema nuances that the librarian's summary won't capture. The worker must have context that's genuinely hard to transfer. Track the new assignment, update the tab label, and reset the branch:

```bash
project assign <worker-name> <new-ticket-key>
herdr tab rename <tab-id> "<worker-name> — <new-ticket-key>"
project prompt <worker-name> "Next ticket in chain. Reset your worktree:
git checkout -b <new-branch> origin/main

Your assignment:
Ticket: <ticket-key>
Summary: <ticket summary>
Description: <ticket description>"
```

**Don't reuse just because a worker is free.** "Charlie knows the context" or "delta worked on something nearby" aren't reasons — the librarian's summary gives a fresh worker everything it needs. Only reuse when the context window carries implementation details the librarian can't summarize.

**Force a fresh worker** when the current worker's context is visibly degraded (slow responses, repeated mistakes, deep in a debugging hole).

## Step 6a: Shut down idle workers

When a worker finishes and there's no immediate next ticket for it, **stop it**. Idle workers waste context on every incoming prompt and clutter `project status`. Don't leave workers running "in case we need them."

```bash
project stop <worker-name>
herdr agent send-keys <pane_id> /exit
```

`project stop` marks the agent as stopped in the state file but preserves its session ID, pane ID, tickets, and worktree path. If you later need that worker's context (rare — the librarian should have what matters), resume it:

```bash
session_id=$(project session <worker-name>)
herdr agent start <worker-name> --kind claude --pane <pane_id> -- --resume "$session_id"
project register <worker-name> <pane_id>
```

This applies to workers and testers. The librarian and researcher stay up for the life of the epic — both accumulate context that's expensive to rebuild (merged diffs for the librarian, domain knowledge for the researcher). An idle researcher is in its correct steady state, not a candidate for shutdown.

## Step 7: Completion

When all tickets are done and all PRs are merged:

1. Tell the librarian:
   ```bash
   project prompt librarian "All tickets in project APP-XXXX are complete. Transition the project to Done and summarize the full scope of changes across all PRs." --wait --timeout 120000
   ```
2. Report to the user:
   ```
   [start-project] Project APP-XXXX complete.
   - N tickets implemented
   - N PRs merged
   - Librarian has the full change summary if you need it
   ```

## Reboot recovery

If you're a fresh orchestrator session picking up a project after a reboot (computer restart, terminal closed), all pane IDs in the state file are stale but everything else is intact:

1. Register yourself: `project register orchestrator`
2. Run `project roster` — it shows every agent's session ID and last ticket, even stopped ones
3. Recreate tabs and restart agents using their saved session IDs:
   ```bash
   herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "librarian" --env HERDR_PROJECT=<project-name> --no-focus
   herdr agent start librarian --kind claude --pane <new_pane_id> -- --resume <session-id-from-roster>
   ```
   Each agent self-registers on boot, which updates its pane ID in the state file.
4. Once the librarian is back, ask it: `project ask librarian "Orchestrator rebooted. What's the current state of all tickets?"`
5. Fetch the project from the ticket tracker and rebuild the DAG (same as Step 1)
6. Resume or spawn workers as needed based on ticket states

Agents resumed with `--resume` retain their full context from the prior session — no need to re-send assignments.

## Status tracking

Use `project status` for the machine-readable view. Keep a mental ledger for the user:

```
APP-1001: [spawned | working | PR opened | merged | blocked]
APP-1002: [queued | spawned | working | PR opened | merged | blocked]
...
```

When the user asks for status, report this ledger. Use numbered lists per your working style preferences.

## Error recovery

- **NEED signal** — an agent tried to reach a stopped agent. The `project` CLI auto-escalates: you'll receive `NEED — <caller> needs <role> (stopped)` with the original message. Decide whether to restart the agent (`--resume` with its session ID from `project roster`) or handle the request another way.
- **Worker crashes** — read the pane output, diagnose, restart the agent in the same tab or create a fresh one. Re-register it: `project register <role> <new-pane-id>`
- **Merge conflict** — tell the worker to merge main into its branch (never force-push)
- **Flaky tests** — worker can use `/fix-flaky-test` if available
- **CI failures** — worker can use `/babysit-pr` after opening the PR

## Logging feedback

When you observe something that should change in the skills (a gap, a broken signal, an awkward handoff), **log it — don't fix it**. Append a bullet to the "Feedback — New" section in `~/.claude/context/project-orchestration.md`. A separate session applies the changes to skills later.

Editing skill files mid-epic bloats your context and risks inconsistency across running agents who loaded the old version.

## What you do NOT do

- Write implementation code
- Research the codebase — delegate to the researcher or librarian. Don't grep code, read files, or verify scope yourself. If a worker or the user asks something outside your scope, forward it: `project prompt researcher` for domain questions, `project prompt librarian` for questions about merged work. Tell the asker you've forwarded it.
- Make architectural decisions — workers and the user handle those
- Merge PRs — the user reviews and merges
- Force-push or rewrite history
- Edit skill files (SKILL.md, DESIGN.md) — log feedback instead
