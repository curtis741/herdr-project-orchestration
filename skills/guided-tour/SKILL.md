---
name: guided-tour
description: "Interactive guided tour of project orchestration. Spawns a librarian and one worker on a trivial task, pauses at each signal to explain what's happening, and prompts the developer to message agents themselves. After one run, the developer understands roles, signals, and how to participate. Requires Herdr."
---

# guided-tour — Learn by Doing

An interactive walkthrough of multi-agent project orchestration. You (the tour guide) spawn a small set of agents, pause at each stage to explain what's happening and why, and invite the developer to try things themselves.

**Audience:** someone who just installed the plugin and wants to understand the system before running a real project.

**Goal:** after one guided tour, the developer understands:
- The roles (orchestrator, librarian, worker) and why they're separated
- How signals flow and why there's a single routing point
- How to message agents and ask questions
- When to jump in vs. let the system run

## Prerequisites

```bash
test "${HERDR_ENV:-}" = 1
which project
```

If either fails, tell the developer what's missing and stop.

## Tone

Conversational, not scripted. Explain concepts in your own words as you go — don't dump a wall of text. Each explanation should be 2-4 sentences, max. The agents doing things is the lesson; your narration connects the dots.

## Overview for the developer

Before starting, give the developer a brief overview:

> We're going to spin up a small project with three agents — an orchestrator (that's me), a librarian, and one worker — on a fake ticket. I'll pause at each step to explain what's happening and why. At a few points I'll ask you to try things yourself — message an agent, ask the librarian a question. The whole thing takes about 5 minutes.

## Step 1: Create the workspace and initialize

```bash
herdr workspace create --cwd "$PWD" --label "Guided Tour" --focus
```

Note the workspace ID. Initialize the project:

```bash
project init TOUR <workspace-id>
project register orchestrator
```

**Explain to the developer:**
> Every project gets a workspace — a container for all the agent tabs. The `project` CLI tracks which agents are alive and routes messages between them by role name. I just registered myself as the orchestrator.

## Step 2: Spawn the librarian

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "librarian" --env HERDR_PROJECT=TOUR --no-focus
herdr agent start tour-librarian --kind claude --pane <pane_id>
project register librarian <pane_id>
```

Boot the librarian with a simplified role for the tour:

```bash
herdr agent prompt <pane_id> "GUIDED TOUR — You are the project librarian. This is a guided tour, not a real project.

Your job: receive signals from the worker and relay them to the orchestrator. You also answer questions about the project.

The project has one ticket:
  TOUR-001: 'Add a greeting endpoint' (no dependencies)

Signal protocol:
  STARTING — TOUR-001  →  respond: [librarian] ACK STARTING — TOUR-001 transitioned to In Progress
  COMPLETE — PR #1 for TOUR-001  →  respond: [librarian] ACK COMPLETE — TOUR-001 transitioned to In Code Review. Then:
    project prompt orchestrator 'COMPLETE — PR #1 for TOUR-001.'
  PR #1 merged for TOUR-001  →  respond: [librarian] ACK MERGED — TOUR-001 transitioned to Done. No more tickets — DAG complete.

When anyone asks you a question, answer helpfully. You know:
  - TOUR-001 is about adding a GET /hello endpoint that returns { 'message': 'Hello, world!' }
  - The project uses a standard REST pattern
  - No database changes needed

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.
Do NOT load /project-librarian. Just follow the protocol above and answer questions naturally.

Reply 'ready' when understood." --wait --timeout 60000
```

Confirm the librarian replied 'ready'.

**Explain to the developer:**
> The librarian is the knowledge base. In a real project, it ingests merged PRs and answers questions like "what interface did ticket X create?" It also manages ticket transitions — when a worker says STARTING, the librarian moves the ticket to In Progress. Workers never talk to the orchestrator about lifecycle events — everything routes through the librarian. This keeps the orchestrator lightweight and gives the librarian a complete picture of project state.

## Step 3: Spawn the worker

```bash
herdr tab create --workspace <workspace-id> --cwd "$PWD" --label "TOUR-001" --env HERDR_PROJECT=TOUR --no-focus
herdr agent start tour-001 --kind claude --pane <pane_id>
project register tour-001 <pane_id>
```

Boot the worker:

```bash
herdr agent prompt <pane_id> "GUIDED TOUR — You are project worker tour-001. This is a guided tour, not a real project.

Your job: follow the signal protocol to simulate working on a ticket. Wait for instructions at each step.

Step 1: Send your READY signal now:
  project prompt orchestrator 'READY — TOUR-001'

Then wait for your assignment from the orchestrator. Do not proceed until you receive it.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'tour-001'.
Do NOT load /project-worker.

Start with step 1 now." --wait --timeout 60000
```

**Explain to the developer (before the READY signal arrives):**
> I just started a worker. In a real project, each worker gets its own git worktree — an isolated copy of the repo — and works on one ticket. The first thing every worker does is send a READY signal to the orchestrator. Watch for it...

Wait for the `READY — TOUR-001` signal.

**When it arrives, explain:**
> There it is — the worker is ready for its assignment. In a real project, I'd send a ticket description, dependencies, and any context from the librarian. Let me send the assignment now.

## Step 4: Send the assignment

```bash
project prompt tour-001 "Your assignment:

Ticket: TOUR-001
Summary: Add a greeting endpoint
Description: Add a GET /hello endpoint that returns { 'message': 'Hello, world!' }. This is a guided tour — don't write real code. Just follow the signal protocol.

Next steps:
1. Send: project prompt librarian 'STARTING — TOUR-001'
2. Wait 10 seconds (simulating implementation work).
3. Send: project prompt librarian 'COMPLETE — PR #1 for TOUR-001. No operational notes (tour).'
4. Stop completely." --wait --timeout 120000
```

**Explain to the developer:**
> The worker now has its assignment. Watch what happens next — the worker will signal the librarian (not me) that it's starting work. This is a key design choice: workers talk to the librarian for lifecycle events, and the librarian relays a compact summary to the orchestrator. This keeps my context clean — I don't need to see every detail of every worker's progress.

## Step 5: Watch the signal cascade

The expected sequence:
1. **tour-001 → librarian:** `STARTING — TOUR-001`
2. **librarian ACKs** the STARTING signal
3. **tour-001 → librarian:** `COMPLETE — PR #1 for TOUR-001`
4. **librarian → orchestrator:** `COMPLETE — PR #1 for TOUR-001.` (relay)

As each signal arrives, narrate briefly:

- On STARTING relay: "The librarian just acknowledged the worker started — in a real project, it would also transition the ticket to In Progress in the tracker."
- On COMPLETE relay: "The worker finished and told the librarian. The librarian transitioned the ticket to In Code Review and relayed a compact summary to me. Notice the worker never messaged me directly — everything went through the librarian."

## Step 6: Interactive — the developer tries messaging

**Now pause and invite the developer to participate:**

> Your turn. The agents are still running — you can talk to them. Try these:
>
> 1. **Ask the librarian a question:** Type this in your terminal:
>    ```
>    project ask librarian "What does TOUR-001 do?"
>    ```
>    The librarian will answer based on what it knows about the project.
>
> 2. **Check the project status:**
>    ```
>    project status
>    ```
>    This shows all registered agents and their current state.
>
> 3. **Read the worker's output:**
>    ```
>    project read tour-001 --lines 20
>    ```
>    This shows what the worker has been doing without interrupting it.
>
> Try at least one of these, then tell me when you're ready to continue.

Wait for the developer to try things and say they're ready. Answer any questions they have about what they see.

## Step 7: Simulate merge and wrap up

```bash
project prompt librarian "PR #1 merged for TOUR-001" --wait --timeout 60000
```

**Explain:**
> I just told the librarian the PR was merged. In a real project, this happens after code review. The librarian transitions the ticket to Done and checks whether any downstream tickets are now unblocked. Since TOUR-001 has no dependents, the project is complete.

## Step 8: Summary — what the developer learned

Present a recap:

> **What you just saw:**
>
> - **Three roles, three context windows.** The orchestrator coordinates, the librarian tracks knowledge and state, workers implement. Each agent only carries the context it needs.
>
> - **Single routing point.** Workers send lifecycle signals (STARTING, COMPLETE) to the librarian, not the orchestrator. The librarian relays a compact summary. This keeps the orchestrator's context clean for decision-making.
>
> - **The `project` CLI.** All communication goes through `project prompt` (fire-and-forget) and `project ask` (blocking question). Roles are resolved automatically — no pane IDs to remember.
>
> - **You can jump in anytime.** You saw this when you messaged the librarian yourself. In a real project, you can ask the librarian questions, check on workers, or message the orchestrator to change priorities.
>
> **In a real project, you'd also see:**
> - Multiple workers running in parallel on independent tickets
> - Dependency tracking — the librarian detects when tickets are unblocked and signals the orchestrator to spawn the next wave
> - A watcher monitoring CI and reporting failures directly to workers
> - A researcher investigating domain questions so workers don't have to
>
> **Ready to try for real?** Run `/start-project` with an epic key to orchestrate a real project.

## Step 9: Clean up

```bash
herdr workspace close <workspace-id>
```

## What this teaches

- The three core roles and their boundaries
- Why lifecycle signals route through the librarian
- How `project prompt` and `project ask` work
- That the developer can participate — messaging agents, reading output, asking questions
- The building blocks that scale to multi-wave, multi-worker projects

## What this does NOT teach

- Dependency DAGs and wave sequencing (use a real project or the dry run for that)
- Worktree management
- The watcher and CI monitoring
- The researcher role
- Distill/restart for context pressure
- Recovery after a crash
