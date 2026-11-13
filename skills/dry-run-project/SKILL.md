---
name: dry-run-project
description: "Dry-run the project orchestration signal protocol without a tracker, code changes, or PRs. Spawns a librarian, watcher, and two workers in a test workspace, walks through the full signal cycle (READY → STARTING → PR_OPEN → unblock → second worker), and reports which signals landed and which didn't. Use when refining project-orchestration skills. Requires Herdr."
---

# dry-run-project — Signal Protocol Test

Tests the messaging choreography between orchestrator, librarian, watcher, and workers. No tracker, no code changes, no worktrees, no PRs — pure signals.

## Prerequisites

```bash
test "${HERDR_ENV:-}" = 1
which project
```

## The test plan

Two fake tickets with a dependency:

```
FAKE-001: "Add widget column" (no dependencies — wave 1)
FAKE-002: "Backfill widget column" (depends on FAKE-001 — wave 2)
```

The DAG:
```
FAKE-001 → FAKE-002
```

## Step 1: Create the test workspace and init the project

```bash
herdr workspace create --cwd "$PWD" --label "Dry Run — Signal Test" --focus
```

Note the workspace ID. Initialize the project and register yourself:

```bash
project init DRY-RUN <workspace-id>
project register orchestrator
```

## Step 2: Spawn the librarian

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "librarian" --env HERDR_PROJECT=DRY-RUN --no-focus
herdr agent start librarian --kind claude --pane <pane_id>
project register librarian <pane_id>
```

Boot prompt — tell it this is a dry run with a canned DAG:

```bash
herdr agent prompt <pane_id> "DRY RUN — You are the project librarian for a signal protocol test. No real tracker, no real code.

Your job: receive signals, confirm you got them, and check the DAG for unblocks.

The DAG:
  FAKE-001: no dependencies (wave 1)
  FAKE-002: depends on FAKE-001 (wave 2)

Signal protocol — when you receive each signal, respond with exactly this format:
  [librarian] ACK <signal> — <action taken>

Signals you'll receive:
  STARTING — FAKE-001  →  respond: [librarian] ACK STARTING — FAKE-001 transitioned to In Progress
  PR_OPEN — PR #1 for FAKE-001  →  respond: [librarian] ACK PR_OPEN — FAKE-001 transitioned to In Code Review. Then:
    project prompt watcher 'WATCH — PR #1 for FAKE-001, report failures to fake-001'
    project prompt orchestrator 'PR_OPEN — PR #1 for FAKE-001.'
  PR #1 merged for FAKE-001  →  respond: [librarian] ACK MERGED — FAKE-001 transitioned to Done. Then check the DAG: FAKE-002 is now unblocked. Message the orchestrator:
    project prompt orchestrator 'UNBLOCKED — FAKE-002 is now unblocked (blocker FAKE-001 merged). Ready for a worker.'

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.
Do NOT load /project-librarian. Just follow the signal protocol above.
Do NOT run herdr agent list. The project CLI handles addressing.

Reply 'ready' when understood." --wait --timeout 60000
```

Read the response. Confirm the librarian replied 'ready'. If not, diagnose.

## Step 2a: Spawn the watcher

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "watcher" --env HERDR_PROJECT=DRY-RUN --no-focus
herdr agent start watcher --kind claude --pane <pane_id>
project register watcher <pane_id>
```

Boot prompt:

```bash
herdr agent prompt <pane_id> "DRY RUN — You are the CI watcher for a signal protocol test. No real CI checks.

Your job: receive WATCH assignments from the librarian and confirm you got them.

Signal protocol — when you receive a signal, respond with exactly this format:
  [watcher] ACK <signal>

Example:
  WATCH — PR #1 for FAKE-001, report failures to fake-001  →  respond: [watcher] ACK WATCH — PR #1 for FAKE-001 added to watch list

All agents use 'project prompt <role> <message>' to communicate. Your role is 'watcher'.
Do NOT run herdr agent list. The project CLI handles addressing.

Reply 'ready' when understood." --wait --timeout 60000
```

Read the response. Confirm the watcher replied 'ready'. If not, diagnose.

## Step 3: Spawn worker-a (FAKE-001)

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "FAKE-001" --no-focus
herdr agent start fake-001 --kind claude --pane <pane_id>
project register fake-001 <pane_id>
```

Boot prompt:

```bash
herdr agent prompt <pane_id> "DRY RUN — You are project worker fake-001. No real code, no worktree.
This prompt was sent by the orchestrator. Follow it directly.

Signal protocol — send these signals in order, waiting 5 seconds between each:

1. project prompt orchestrator 'READY — FAKE-001'
2. Wait for the orchestrator to send your assignment.
3. When you receive the assignment: project prompt librarian 'STARTING — FAKE-001'
4. Wait 5 seconds (simulating work).
5. project prompt librarian 'PR_OPEN — PR #1 for FAKE-001. No operational notes (dry run).'
6. Stop completely. Do not invent additional steps or repeat the protocol.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'fake-001'.
Do NOT run herdr agent list. Do NOT load /project-worker.

Start with step 1 now." --wait --timeout 120000
```

## Step 4: Handle worker-a's READY signal

When worker-a messages you `READY — FAKE-001`, send the assignment:

```bash
project prompt fake-001 "Your assignment:

Ticket: FAKE-001
Summary: Add status column to transactions table
Description: This is a dry run. Don't write any code. Just follow the signal protocol from your boot prompt (steps 3-7)." --wait --timeout 120000
```

## Step 5: Watch the signal cascade

After sending the assignment, the expected sequence is:

1. **fake-001 → librarian:** `STARTING — FAKE-001`
2. **librarian → you:** `[librarian] ACK STARTING — FAKE-001 transitioned to In Progress`
3. **fake-001 → librarian:** `PR_OPEN — PR #1 for FAKE-001`
4. **librarian → watcher:** `WATCH — PR #1 for FAKE-001, report failures to fake-001`
5. **librarian → you:** `PR_OPEN — PR #1 for FAKE-001.` (librarian relay)
6. **librarian → you:** `[librarian] ACK PR_OPEN — FAKE-001 transitioned to In Code Review`

Verify with:

```bash
project status
herdr agent read "$(project resolve librarian)" --source recent-unwrapped --lines 40
herdr agent read "$(project resolve fake-001)" --source recent-unwrapped --lines 40
```

## Step 6: Simulate merge and test auto-unblock

Tell the librarian the PR was merged:

```bash
project prompt librarian "PR #1 merged for FAKE-001" --wait --timeout 60000
```

Expected: the librarian should:
1. ACK the merge signal
2. Check the DAG
3. Message you: `UNBLOCKED — FAKE-002 is now unblocked (blocker FAKE-001 merged). Ready for a worker.`

If the UNBLOCKED signal arrives, the auto-unblock detection works. If not, check what the librarian actually did:

```bash
herdr agent read "$(project resolve librarian)" --source recent-unwrapped --lines 40
```

## Step 7: Spawn worker-b (FAKE-002) — triggered by unblock

When you receive the UNBLOCKED signal from the librarian:

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "FAKE-002" --no-focus
herdr agent start fake-002 --kind claude --pane <pane_id>
project register fake-002 <pane_id>
```

```bash
herdr agent prompt <pane_id> "DRY RUN — You are project worker fake-002. No real code, no worktree.
This prompt was sent by the orchestrator. Follow it directly.

Same protocol as fake-001:
1. project prompt orchestrator 'READY — FAKE-002'
2. Wait for assignment.
3. On assignment: project prompt librarian 'STARTING — FAKE-002'
4. Wait 5 seconds.
5. project prompt librarian 'PR_OPEN — PR #2 for FAKE-002. No operational notes (dry run).'
6. Stop completely. Do not invent additional steps.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'fake-002'.
Do NOT run herdr agent list. Do NOT load /project-worker.

Start with step 1 now." --wait --timeout 120000
```

Send the assignment when READY arrives, then watch the same signal cascade as Step 5.

## Step 8: Final merge and completion

```bash
project prompt librarian "PR #2 merged for FAKE-002" --wait --timeout 60000
```

The librarian should ACK, find no more unblocked tickets, and report the DAG is complete.

## Step 9: Score the run

After the full cycle, report a scorecard:

```
Signal Protocol Dry Run — Results
──────────────────────────────────
  worker-a READY → orchestrator     [ PASS / FAIL ]
  worker-a STARTING → librarian     [ PASS / FAIL ]
  librarian ACK STARTING            [ PASS / FAIL ]
  worker-a PR_OPEN → librarian       [ PASS / FAIL ]
  librarian WATCH → watcher          [ PASS / FAIL ]
  librarian PR_OPEN relay → orchestrator [ PASS / FAIL ]
  merge signal → librarian           [ PASS / FAIL ]
  librarian UNBLOCKED → orchestrator [ PASS / FAIL ]
  worker-b READY → orchestrator     [ PASS / FAIL ]
  worker-b STARTING → librarian     [ PASS / FAIL ]
  worker-b PR_OPEN → librarian      [ PASS / FAIL ]
  librarian PR_OPEN relay → orchestrator [ PASS / FAIL ]
  final merge → librarian           [ PASS / FAIL ]
  DAG complete detection             [ PASS / FAIL ]

Failures: <describe what went wrong and which signal didn't land>
```

## Step 10: Clean up

```bash
herdr workspace close <workspace-id>
```

## What this tests

- Agent boot and READY handshake
- `project prompt` role resolution (no agent name hallucination)
- Worker → librarian lifecycle signals (STARTING, PR_OPEN)
- Librarian → watcher WATCH assignment
- Librarian → orchestrator PR_OPEN relay (workers don't signal orchestrator directly)
- Orchestrator → librarian merge notification
- Librarian DAG tracking and auto-unblock detection
- Librarian → orchestrator UNBLOCKED signal
- Wave advancement (spawning worker-b only after unblock)

## What this does NOT test

- Worktree creation/cleanup
- Ticket transitions
- Actual code implementation
- PR opening
- Sequential chain reuse
- Researcher interactions
- Tester spawning
- Cross-session `--resume` queries
