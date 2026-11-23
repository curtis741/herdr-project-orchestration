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

## Mode detection

Parse the project key from the user's message (e.g. `APP-1234`).

- **`DEMO-` prefix** → guided tour mode. Run `/guided-tour` and stop — the tour skill handles everything.
- **`DOG-` prefix** → dogfood mode. See `docs/dogfood.md`.
- **Anything else** → normal mode (continue below).

## Step 1: Load the project

Use the ticket tracker's MCP tools to:

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

Use `AskUserQuestion` to confirm the plan — present the key decisions (wave grouping, dependency order, repo mapping) as concrete options the user can approve or redirect. Don't present a wall of text and ask "looks good?" — structure the decision points.

## Step 2: Determine repo mapping

Check each ticket's labels, components, or description for which repo it targets. If the epic spans multiple repos, map each ticket to its repo path based on the labels. Example:

| Label/component | Repo path |
|----------------|-----------|
| `frontend` | `~/repos/<project>/frontend/` |
| `backend`, `api` | `~/repos/<project>/core/` |
| (default) | `~/repos/<project>/core/` |

If you can't determine the repo from labels, ask the user.

## Step 3: Create the project workspace and initialize

One workspace holds everything for this project — orchestrator tab, librarian tab, and worker tabs.

First, check if a project is already initialized:

```bash
echo $HERDR_PROJECT
```

**If set** (`project start` already ran), the workspace and state file exist — do NOT create another workspace. Verify with `project info` and register if needed:

```bash
project info
project register orchestrator
```

Read the workspace ID from `project info` and use it for all tab creation below.

**If not set**, create everything from scratch:

```bash
eval "$(project start <project-name> "<epic human name> (APP-XXXX)")"
```

The project name should be the lowercase project key (e.g. `app-1234`). The workspace label should be the project's human-readable name — e.g. `"User Auth Migration (APP-1234)"`, not just the ticket key or a role name. The user sees this in their workspace list and needs to know which project it belongs to.

All tabs you create below get `--env HERDR_PROJECT=<project-name>` so every agent resolves the same state file automatically.

### Communication commands

Three commands, each with different blocking behavior:

| Command | Blocks? | Use for |
|---------|---------|---------|
| `project prompt <role> <msg>` | No | Task assignments, merge notifications, lifecycle signals — anything where you don't need the response to proceed |
| `project prompt --wait <role> <msg>` | Yes, until response or timeout | Boot prompts where you need READY confirmation before sending the assignment |
| `project ask <role> <question>` | Yes, returns answer to stdout | Questions where you need the answer to make a decision |

**Stay responsive.** The orchestrator must be available for incoming signals, user messages, and status checks at all times. Every `--wait` or `ask` blocks your context until the target responds or the timeout expires — use them only when you genuinely can't proceed without the response.

- **Boot prompts** use `--wait` because the assignment must not arrive before the agent is listening. These are short waits (READY comes in seconds).
- **Assignments and lifecycle signals** use plain `prompt` — the worker signals back (STARTING, COMPLETE, BLOCKED) when it has something to report.
- **Librarian/researcher queries** use `ask` when you need the answer to choose the next action (worker reuse, unblock decisions).

**Anti-pattern: blocking on worker execution.** Never `--wait` on a worker assignment. The worker may take 10+ minutes to implement its ticket — during that time you can't respond to other workers, the user, or the librarian. Send the assignment with plain `prompt` and move on to the next worker or back to monitoring.

Setup-phase `--wait` on support agent assignments (librarian, watcher, researcher) is fine — it's sequential initialization before the orchestrator enters its monitoring loop.

### Spawn the librarian

Create a tab for the librarian in the project workspace:

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "librarian" --env HERDR_PROJECT=<project-name> --no-focus
```

Read the pane ID from the response. Start a claude agent:

```bash
herdr agent start librarian --kind claude --pane <pane_id> -- -n librarian
```

Boot the librarian with a minimal identity prompt. `project register` writes the state file and signals READY to you automatically:

```bash
herdr agent prompt <pane_id> "Project librarian.

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
herdr agent start watcher --kind claude --pane <pane_id> -- -n watcher
```

Boot the watcher:

```bash
herdr agent prompt <pane_id> "Project watcher.

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
herdr agent start researcher --kind claude --pane <pane_id> -- -n researcher
```

Boot the researcher with a minimal identity prompt:

```bash
herdr agent prompt <pane_id> "Project researcher.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'researcher'.

Boot sequence:
1. Run: project register researcher
2. Wait for your assignment." --wait --timeout 60000
```

When the researcher reports READY, send its full role payload. Include the research.md path and whether to start with discovery or resume from existing findings:

```bash
project prompt researcher "Your assignment:

Epic: APP-XXXX
Summary: <epic summary>

Research artifact: ~/.herdr/projects/<project-name>/research.md

Open questions to investigate:
<list open discovery questions from the epic description or spike comments>

Phase: discovery (no prior research.md exists)

Your role is defined in ~/.claude/skills/start-project/researcher.md — read it now and follow it." --wait --timeout 120000
```

If research.md already exists (e.g. after a researcher restart), tell the researcher to resume:

```bash
project prompt researcher "Your assignment:

Epic: APP-XXXX
Summary: <epic summary>

Research artifact: ~/.herdr/projects/<project-name>/research.md (exists — load it)

Phase: ongoing (resume from existing research.md)

Your role is defined in ~/.claude/skills/start-project/researcher.md — read it now and follow it." --wait --timeout 120000
```

### Restart the researcher

When the researcher's context is degraded (slow responses, losing track of findings, deep in a rabbit hole), restart it cleanly. The durable research.md means no findings are lost:

```bash
project stop researcher
herdr pane close <pane_id>
herdr agent start researcher --kind claude --pane <pane_id> -- -n researcher
project register researcher <pane_id>
```

Boot with the resume payload above (Phase: ongoing). The researcher loads research.md and picks up where it left off. Don't use `--resume` for a degraded researcher — the point of restarting is to shed the bloated context.

## Step 3a: Clean up stale worktrees

Before spawning workers, remove any orphan worktrees left from previous runs (crashes, reboots, aborted projects):

```bash
project cleanup
```

This cross-references `.worktrees/` directories with the project state file. Worktrees with no active agent are removed, and git's internal worktree bookkeeping is pruned. Use `--dry-run` first if you want to inspect before removing.

## Step 4: Spawn wave 1 workers

For each ticket in wave 1, create a worktree inside the repo, then spawn a worker in a tab scoped to the repo root:

### 4a. Create the worktree

```bash
git -C <repo_path> worktree add .worktrees/<ticket-key-lowercase> -b <ticket-key-lowercase> origin/main
```

Branch name matches the directory name — always lowercase ticket key, no prefixes. This puts the worktree at `<repo>/.worktrees/<ticket>/` — already gitignored, and inside the repo dir so the Claude session can access it.

### 4b. Name the worker and create its tab

Pick the next available worker name:

```bash
worker_name=$(project next-worker)
```

This returns NATO phonetic names in order: alpha, bravo, charlie, etc., wrapping to alpha2 after zulu. Names are never reused within a project.

```bash
herdr tab create --workspace <workspace-id> --cwd <repo_path> --label "$worker_name — <ticket-key>" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start "$worker_name" --kind claude --pane <pane_id> -- -n "$worker_name — <focus>"
project assign "$worker_name" <ticket-key>
```

`-n` sets the session name shown in the terminal title. `<focus>` is 2–4 words from the ticket summary describing what this worker is doing (e.g. `charlie — fee column backfill`), so the user can tell workers apart at a glance. Reuse the same name whenever you restart or resume this worker.

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

Run /project-worker to load your skill. It will guide you through implementation."
```

**Limit concurrency.** Start at most 3 workers simultaneously. Additional wave-1 tickets queue behind them — start the next queued ticket when a running worker completes.

## Step 5: Monitor and advance

Workers message you directly when they finish, hit a blocker, or find scope creep. As a fallback, check on quiet workers:

```bash
project status
```

When the librarian relays a `COMPLETE` signal for a worker (or the worker reaches `idle`):

1. Verify a draft PR was opened (check via GitHub MCP)
2. Notify the user: `[start-project] APP-1001 — PR #XXXX opened`
3. **If the librarian's relay includes a test brief** (API or parity migration work), spawn a tester — see Step 5a

The watcher handles CI monitoring — the librarian already told it to watch the PR. You don't need to manage CI checks.

When the librarian relays a `DONE` signal (post-merge verification complete), notify the user: `[start-project] APP-1001 verified in production — done.`

### Spinoffs

Any agent (or the user) can run `project spinoff` to put a throwaway worker on a scoped one-off fix. The script spawns the worker itself, and you get a one-line `SPINOFF — <from> spun off "<title>" to <name>` FYI. **Don't act on it.** Don't brief the worker, don't assign it, and don't count it against the wave cap.

- A relayed `COMPLETE — PR #N for spinoff-<name>`: tell the user a PR needs review (`[start-project] spinoff "<title>" — PR #N opened`). Nothing else.
- When it merges: tell the librarian as with any merge. Skip worktree cleanup, reuse evaluation and DAG checks. The librarian tells the worker, which closes its own tab, and `project cleanup` removes the worktree.
- If the user asks you to "spin this off", run `project spinoff` yourself with a full brief (the format is in the worker skill § Spinning off a fix).

### DISTILL requests

Any agent can send `DISTILL — <reason>` when its context is getting noisy and output quality is degrading. When you receive one, decide:

**Defer** — if the agent was rotated in the last ~15 minutes (a successor asking to distill again means its boot work is the problem, not noise — tell it to stop re-verifying and carry on), or if it is close to finishing (e.g. worker has opened a PR and is just waiting on CI), tell it to finish first:

```bash
project prompt <role> "DISTILL_DEFER — finish your current step, then re-request if needed"
```

**Approve** — if the agent has significant work remaining and context pressure is real:

```bash
project prompt <role> "DISTILL_ACK — commit any WIP, write your state to $(project dir)/<role>.distill.md, then signal DISTILL_READY"
```

When you receive `DISTILL_READY`, spawn the successor in a **new tab**, leaving the old agent alive so the successor can question it. Don't read the distill file yourself — the successor reads it directly, so its contents never pass through your context.

1. Note the old agent's pane: `old_pane=$(project resolve <role>)`
2. Create a new tab with the same label and cwd as the original, and start a fresh agent (not `--resume` — the whole point is clean context):
   ```bash
   herdr tab create --workspace <workspace-id> --cwd <same-cwd-as-original> --label "<same-label-as-original>" --env HERDR_PROJECT=<project-name> --no-focus
   herdr agent start <role> --kind claude --pane <new_pane_id> -- -n "<same session name as before>"
   ```
3. Boot the successor with its original boot steps, plus the takeover instructions:
   ```bash
   herdr agent prompt <new_pane_id> "<original boot prompt for this role — worktree cd, etc.>

   You are taking over as <role> after a distill. Before waiting for anything:
   1. Run: project register <role>
   2. Read $(project dir)/<role>.distill.md — your predecessor's state. Trust it; don't re-verify everything against the tracker or GitHub (that refills your context immediately). Check a specific item only when you act on it.
   3. Your predecessor is still live in pane $old_pane. If anything in the distill file is unclear, ask it directly: herdr agent prompt $old_pane '<question>' --wait, then herdr agent read $old_pane.
   4. When you have no more questions (or none at all), run: project retire $old_pane
   5. Continue the work. Your original assignment:
   <original ticket/role assignment>" --wait --timeout 60000
   ```

The successor owns the old agent's shutdown — it registers first (so signals route to it immediately), asks whatever it needs, then runs `project retire`, which closes the old tab. The old session ID is kept in the state file's `previous_sessions` in case it's needed later. You don't need to track the handoff further.

The distill file is the agent's own summary of where it left off — what's done, what's left, current approach, decisions made. It lives in the project dir (not the worktree), so it never shows up in `git status`.

### Pausing and resetting the project

Two commands wind the project down. Run them only when the user asks for it, or when you send a `RESET —` signal yourself.

**Pause** (end of day, or switching to another epic): `project dump`. Every other live agent writes its unreported state to `$(project dir)/<role>.final.md`, or writes nothing. All prompts go out in parallel. Each agent is then stopped with its session preserved, and its pane is closed. Then write your own `orchestrator.final.md`. To pick the project back up, follow § Reboot recovery.

**Reset** (context has collapsed across the project and a clean start beats carrying it forward): `project reset`. If the user runs it from outside, you get `RESET — ...` and run it yourself. It does the same dump, then writes a master-distill template to `$(project dir)/orchestrator.reset.md`.
1. Fill in every TODO: shipped, in flight, decisions, remaining work, waiting on the user, notes for the successor. Link PRs, tickets and files instead of restating them. You may read the agent dump files it lists; this is the one time you read them, because you are writing the summary.
2. Run `project reset --handoff`. It spawns a fresh orchestrator in a new tab, which registers, reads the distill, can question you, and then retires your pane. Don't do anything else after the handoff.

Either command leaves running any agent that times out or is stuck on a permission prompt, so nothing is lost. Deal with that agent, then re-run the command. A re-run only prompts agents that are still live. `--handoff` refuses to run while any agent is live or any TODO is left.

## Step 5a: Spawn tester (API / parity work only)

When a worker's DONE signal includes a test brief, spawn an independent tester agent. The tester and worker talk directly — you just set up the introduction.

```bash
herdr tab create --workspace <workspace-id> --cwd <repo_path> --label "tester-<ticket-key>" --env HERDR_PROJECT=<project-name> --no-focus
herdr agent start tester-<ticket-key> --kind claude --pane <pane_id> -- -n "tester-<ticket-key> — <focus>"
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
2. Clean up the worktree (orchestrator's responsibility, not the worker's):
   ```bash
   git -C <repo_path> worktree remove .worktrees/<ticket-key-lowercase>
   ```
   Skip cleanup if the worker has a next ticket in a sequential chain — it stays in the same worktree but checks out a new branch (see Step 6).
3. Check if any wave 2+ tickets are now unblocked (all dependencies merged)
4. Spawn workers for newly unblocked tickets (repeat Step 4)

When a worker is `blocked`:

1. Read its state: `herdr agent read <pane_id> --source recent-unwrapped --lines 40`
2. If it's a permission prompt or question, escalate to the user
3. If it's a technical blocker, report it

## Step 6: Worker finished

When a worker signals COMPLETE or DONE, decide its fate in one pass: reuse or shut down.

### 6a. Evaluate reuse

**Default to a fresh worker.** Worker reuse is a context-window optimization, not a way to avoid spawning agents. A fresh worker with a librarian summary is almost always better than a worker carrying stale context from a different ticket.

The librarian may advise unprompted after ingesting a merge: `"Worker alpha finished APP-1001 and I see APP-1003 is unblocked. APP-1003 builds directly on the handler internals — reuse the worker."` Follow that advice.

If the librarian hasn't weighed in and it's not obvious, ask:

```bash
project ask librarian "APP-1003 depends on APP-1001. Does APP-1003 need the implementation details from APP-1001's worker, or is the interface summary enough for a fresh worker?"
```

**Reuse only when** the next ticket extends the same internals — validation edge cases, factory setup, schema nuances that the librarian's summary won't capture. The worker must have context that's genuinely hard to transfer.

**Don't reuse just because a worker is free.** "Charlie knows the context" or "delta worked on something nearby" aren't reasons — the librarian's summary gives a fresh worker everything it needs.

**Force a fresh worker** when the current worker's context is visibly degraded (slow responses, repeated mistakes, deep in a debugging hole).

### 6b. If reuse — assign the next ticket

Track the new assignment, update the tab label, and reset the branch:

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

### 6c. If no reuse — full shutdown

No next ticket, or a fresh worker is better. Shut down completely:

```bash
project stop <worker-name>
herdr pane close <pane_id>
```

`project stop` marks the agent as stopped in the state file but preserves its session ID, pane ID, tickets, and worktree path. If you later need that worker's context (rare — the librarian should have what matters), resume it:

```bash
session_id=$(project session <worker-name>)
herdr agent start <worker-name> --kind claude --pane <pane_id> -- --resume "$session_id" -n "<worker-name> — <focus>"
project register <worker-name> <pane_id>
```

This applies to workers and testers. The librarian and researcher stay up for the life of the epic — both accumulate context that's expensive to rebuild (merged diffs for the librarian, domain knowledge for the researcher). An idle researcher is in its correct steady state, not a candidate for shutdown.

## Step 7: Completion

When the librarian sends `PROJECT_COMPLETE` (all tickets done, all PRs merged):

1. Ask the librarian for a final summary:
   ```bash
   project ask librarian "Summarize the full scope of changes across all PRs for the project."
   ```
2. Clean up remaining worktrees (catches sequential-chain worktrees and any missed during wave transitions):
   ```bash
   project cleanup
   ```
3. Report to the user:
   ```
   [start-project] Project APP-XXXX complete.
   - N tickets implemented
   - N PRs merged
   - Worktrees cleaned up
   - Librarian has the full change summary if you need it
   ```

**Do NOT close the workspace or shut down agents automatically.** The user may want to ask the librarian questions, review summaries, or inspect the state. Ask the user if they're ready to shut down. Only close the workspace when they confirm.

## Reboot recovery

If you're a fresh orchestrator session picking up a project after a reboot (computer restart, terminal closed), the system is designed to be resumable from durable state. All pane IDs are stale but everything needed to reconstruct the project lives on disk.

### Minimal state for recovery

Four sources, all durable:

| Source | What it tells you |
|--------|-------------------|
| State file (`~/.herdr/projects/<name>.json`) | Agent roster, session IDs, ticket assignments, stopped/active flags |
| Signal log (`~/.herdr/projects/<name>.signals.log`) | Full event sequence — who signaled what, when, in what order |
| Git (branches + worktrees) | Work-in-progress code, which branches exist, what's committed |
| Ticket tracker (or dogfood task files) | Ticket statuses — done, in-progress, todo |

From these four sources, reconstruct: which wave, which tasks done/in-progress/blocked, which worktrees exist, and what the librarian knows.

### Recovery procedure

1. **Diagnose** — run `project recover` to get a structured report:
   - Which agents are reachable vs. stale
   - Which have session IDs (resumable) vs. not (need fresh start)
   - Worktree status (branch, commits ahead, dirty state)
   - Last 10 signals (what was happening when the system went down)

2. **Register yourself:** `project register orchestrator`

3. **Resume agents with session IDs** — priority order: librarian first (it has accumulated knowledge), then active workers:
   ```bash
   herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "<role>" --env HERDR_PROJECT=<project-name> --no-focus
   herdr agent start <role> --kind claude --pane <new_pane_id> -- --resume <session-id> -n "<role>, or <role> — <focus> for workers"
   ```
   Each agent self-registers on boot, which updates its pane ID in the state file.

4. **Reconstruct project state** — once the librarian is back:
   ```bash
   project ask librarian "Orchestrator rebooted. What's the current state of all tickets?"
   ```

5. **Rebuild the DAG** — fetch tickets from the tracker (same as Step 1) and cross-reference with the librarian's state

6. **Resume or spawn workers** based on ticket states:
   - In-progress tickets with resumable workers → resume with `--resume`
   - In-progress tickets with lost workers → spawn fresh, send assignment + librarian context
   - Unblocked tickets → spawn new workers

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

## Project working dir

`project dir` (`~/.herdr/projects/<project>/`) is the shared working directory for all agents — test plans, context files, cross-agent learnings, reusable test scripts, distill files, research.md, feedback.md. Anything that isn't committed and only lives for the project's lifecycle goes here, not in session scratchpads or worktrees. When briefing an agent on something larger than a few lines, write it there and send the path instead of pasting it into a prompt.

## Logging feedback

When you observe something that should change in the skills (a gap, a broken signal, an awkward handoff), **log it — don't fix it**:

```bash
project feedback "Worker alpha sent COMPLETE but librarian didn't relay to watcher for 3 minutes. Signal routing gap?"
```

This appends a timestamped, role-attributed entry to the project's feedback file (`~/.herdr/projects/<project>/feedback.md`). A separate session reviews and routes findings to skills later.

Editing skill files mid-epic bloats your context and risks inconsistency across running agents who loaded the old version.

## What you do NOT do

- Write implementation code
- Research the codebase — delegate to the researcher or librarian. Don't grep code, read files, or verify scope yourself. If a worker or the user asks something outside your scope, forward it: `project prompt researcher` for domain questions, `project prompt librarian` for questions about merged work. Tell the asker you've forwarded it.
- Make architectural decisions — workers and the user handle those
- Merge PRs — the user reviews and merges
- Force-push or rewrite history
- Edit skill files (SKILL.md, DESIGN.md) — log feedback instead
