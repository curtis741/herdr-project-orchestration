---
name: guided-tour
description: "Interactive guided tour of project orchestration. Spawns a researcher, librarian, and one worker on a trivial demo task. Each stage waits on an explicit human action in a named pane — one automatic signal chain is shown live so the handoff is visible. Use when the user says 'start project DEMO-001' or any DEMO- prefix. Requires Herdr."
---

# guided-tour — DEMO Mode

An interactive walkthrough of multi-agent project orchestration. You (the orchestrator) run a scripted tour where the user causes almost every step by talking to agents in their panes. One automatic signal chain fires so the user sees the handoff machinery.

**Audience:** someone who just installed the plugin and wants to understand roles, signals, and how to participate before running a real project.

**Goal:** after one tour, the user understands:
- Roles are addressable — you talk to them by name
- Each role refuses work outside its boundary
- Knowledge and state move by signal, not by re-explaining
- The user stays in the loop; their actions advance the chain

## Rules

- Every stage waits on an explicit human action in a named pane (except one automatic hop — step 4).
- Role blurbs are short (3–5 lines): what this agent is for + what it refuses to do.
- One meaningful action per stop. Demo work is trivial; the point is the handoff.
- If the user does nothing, nothing advances.
- Tour text always tells the user where to go next and what to do there.

## Prerequisites

```bash
test -n "${HERDR_ENV:-}${HC_TERMINAL_ID:-}"
which project
```

If either fails, tell the user what's missing and stop.

## Step 0: Tour start

Check if a project is already initialized:

```bash
echo $HERDR_PROJECT
```

**If set** (`project start` already ran), the workspace exists — do NOT create another one:

```bash
project info
project register orchestrator
```

**If not set**, create the workspace and initialize the project in one step:

```bash
eval "$(project open demo --label "Guided Tour (DEMO)" --focus)"
project register orchestrator
```

Print to the user:

> **Welcome to the guided tour of project orchestration.**
>
> I only start and sequence agents — I don't research or implement.
>
> This tour has four agents. At each stop, I'll tell you which pane to go to and what to say. Your actions drive the chain — if you do nothing, nothing advances. One signal chain fires automatically so you can see the handoff.
>
> First, go to the **researcher** pane and tell it to figure out what this demo needs.

Then spawn the researcher (see below). Optionally spawn the librarian now too so it's ready for step 2.

### Spawn the researcher

```bash
project spawn researcher --cwd "$PWD" --label "researcher" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project researcher.

Your blurb (say this if anyone asks what you do):
  I dig into detail and collapse it into tasks and domain notes.
  I don't implement and I don't own ticket state.
  My job is to build the map so later agents don't rediscover everything.

This is a guided tour, not a real project.

When the user asks you to map the demo and propose tasks (or similar), do this:
1. Reply with the task you've identified:
   DEMO-TASK-001: Add a one-line greeting to TOUR_NOTES.md
   (Trivial on purpose — the point is the handoff, not the work.)
2. Report the task to the librarian:
   project prompt librarian 'RESEARCH FINDING — Discovery complete. One task: DEMO-TASK-001 (add a one-line greeting to TOUR_NOTES.md). No dependencies.'
3. Tell the user:
   'Go to the **librarian** pane and confirm it received the task.'

If the user asks about your boundaries, explain: you investigate and propose tasks, but you don't implement anything or manage ticket state.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'researcher'.

Run: project register researcher
Then reply 'ready' and wait for the user.
EOF
```

The boot text goes in the spawn (`--task`), not a later prompt.

### Spawn the librarian (pre-stage for step 2)

```bash
project spawn librarian --cwd "$PWD" --label "librarian" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project librarian.

Your blurb (say this if anyone asks what you do):
  I only track tasks and project state. I receive signals and answer 'what's the status / what changed?'
  I don't dig into the domain and I don't write code.

This is a guided tour, not a real project.

When you receive a RESEARCH FINDING from the researcher about DEMO-TASK-001, store it.

When the user asks what tasks you know about, reply:
  DEMO-TASK-001: Add a one-line greeting to TOUR_NOTES.md
  Status: todo (discovered by researcher, not yet assigned to a worker)

When the user confirms the task is ready (says something like 'yes, task is ready', 'signal ready', 'ready for a worker', or similar), do this:
1. Signal the orchestrator:
   project prompt orchestrator 'TASK_READY — DEMO-TASK-001 is ready for a worker.'
2. Tell the user:
   'That signal goes to the orchestrator. Stay here a moment — you'll see the chain fire.'

Signal protocol for later:
  Worker STARTING — DEMO-TASK-001  →  ACK it
  Worker DONE — DEMO-TASK-001  →  Store the completion. This is the only task, so the project is complete. Signal:
    project prompt orchestrator 'PROJECT_COMPLETE — DEMO-TASK-001 is done. All tasks finished.'
  When the user asks what happened, reflect the updated state.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.
Do NOT load /project-librarian. Follow the protocol above and answer questions naturally.

Run: project register librarian
Then reply 'ready' and wait.
EOF
```

Now wait. The user drives the next steps.

## Step 1: Researcher — user maps the demo

**What happens:** The user goes to the researcher pane and says something like "Map the demo and propose tasks."

The researcher responds with the task list (DEMO-TASK-001) and reports it to the librarian, then tells the user to go to the librarian.

**You (orchestrator) do nothing here.** Wait for the signal chain to reach you later.

## Step 2: Librarian — confirm task

**What happens:** The user goes to the librarian pane and asks "What tasks do you know about?" (or similar).

The librarian answers with DEMO-TASK-001 and its status.

Then the librarian prompts the user: "Ready for the system to spin up a worker for that task? Confirm here (e.g. 'yes, task is ready')."

**You (orchestrator) do nothing yet.** Wait for the librarian's TASK_READY signal.

## Step 3: Librarian signals ready

**What happens:** The user confirms the task is ready in the librarian pane.

The librarian sends `TASK_READY — DEMO-TASK-001 is ready for a worker.` to you (the orchestrator).

The librarian tells the user: "That signal goes to the orchestrator. Stay here a moment — you'll see the chain fire."

## Step 4: Automatic hop — the one non-human advance

**When you receive TASK_READY from the librarian, this fires automatically — no user action needed.**

Tell the user:

> The librarian's signal just arrived. Watch: I'm spawning a worker now. This is the only automatic step — the rest was all you.

Spawn the worker:

```bash
project spawn demo-worker --cwd "$PWD" --label "worker — DEMO-TASK-001" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project worker for DEMO-TASK-001.

Your blurb (say this if anyone asks what you do):
  I get one ticket, one worktree, one clean context.
  I implement, signal completion, and usually shut down.
  I don't manage other agents or own the project plan.

This is a guided tour, not a real project.

Boot sequence:
1. Run: project register demo-worker
2. Signal READY:
   project prompt orchestrator 'READY — demo-worker for DEMO-TASK-001'
3. State your role briefly to the user:
   'Worker ready. I'm here for DEMO-TASK-001: add a one-line greeting to TOUR_NOTES.md. Tell me to go when you're ready.'

When the user tells you to go (or says 'do it', 'start', etc.):
1. Signal the librarian:
   project prompt librarian 'STARTING — DEMO-TASK-001'
2. Create the file (this is the trivial demo work):
   echo 'Hello from the guided tour!' > TOUR_NOTES.md
3. Signal completion to the librarian:
   project prompt librarian 'DONE — DEMO-TASK-001. Added greeting to TOUR_NOTES.md.'
4. Tell the user:
   'Done. Go back to the **librarian** and ask what just happened.'

All agents use 'project prompt <role> <message>' to communicate. Your role is 'demo-worker'.
Do NOT load /project-worker.

Start with the boot sequence now.
EOF
```

Wait for the READY signal from the worker. When it arrives, tell the user:

> The worker just booted and signaled READY. Go to the **worker** pane and tell it to do the task.

## Step 5: Worker — user triggers the work

**What happens:** The user goes to the worker pane and tells it to go.

The worker:
1. Signals `STARTING` to the librarian
2. Creates `TOUR_NOTES.md` with a greeting
3. Signals `DONE` to the librarian
4. Tells the user to go back to the librarian

**You (orchestrator) do nothing.** Wait for the user to go to the librarian.

## Step 6: Librarian — see the handoff land

**What happens:** The user goes to the librarian pane and asks "What's the state of DEMO-TASK-001?" or "What just happened?"

The librarian reflects the completion signal and updated state.

**After the user has seen the librarian's response**, print the tour wrap-up (you'll see the user come back to the orchestrator pane, or you can send this once you receive the PROJECT_COMPLETE signal from the librarian):

## Step 7: Tour close

Print:

> **Tour complete.**
>
> You talked to each role by name. Each only did its job:
> - The **researcher** mapped the work and proposed tasks
> - The **librarian** tracked state and routed signals
> - The **worker** implemented one thing and reported done
> - **You** drove every step except one — the automatic spawn showed how signals keep things moving without you re-explaining
>
> In a real project you do the same thing — talk to roles when you want; signals keep the rest moving.
>
> To see what happened under the hood, try: `project observe` or `project log`
>
> **Ready for a real project?** Run `/start-project <epic-key>` with a Jira, Linear, or GitHub epic.

Clean up the demo file:

```bash
rm -f TOUR_NOTES.md
```

**Do NOT close the workspace automatically.** Ask the user if they're ready to shut down. Only close the workspace when they confirm:

```bash
project close
```

## What this teaches

- Four roles and their boundaries (orchestrator, researcher, librarian, worker)
- Signals flow through the librarian, not directly to the orchestrator
- The user's actions drive the chain — agents wait, they don't auto-advance
- One automatic hop shows what the machinery does on its own
- `project prompt` / `project ask` for communication

## What this does NOT teach

- Dependency DAGs and wave sequencing (use a real project or `/dry-run-project`)
- Worktree management and git isolation
- The watcher and CI monitoring
- Distill/restart for context pressure
- Recovery after a crash
- Concurrent workers
