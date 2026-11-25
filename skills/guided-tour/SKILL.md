---
name: guided-tour
description: "Interactive guided tour of project orchestration. Spawns a researcher, librarian, and one worker on a trivial demo task. Whoever needs the user asks them directly in its own pane with AskUserQuestion; the orchestrator asks only orchestration questions. One automatic signal chain is shown live so the handoff is visible. Use when the user says 'start project DEMO-001' or any DEMO- prefix. Requires Herdr."
---

# guided-tour — DEMO Mode

A scripted walkthrough of multi-agent orchestration. **Whoever needs the user asks the user, in its own pane, with `AskUserQuestion`.** The orchestrator (you) asks only orchestration questions; each role asks its own ("ready for me to map tasks?", "ready for me to start?"). The user finds the next step by seeing which agent is waiting (blocked) in the Agents/Projects panel — the same "agent needs me" feel as a live project.

**Audience:** someone who just installed the plugin and wants to understand roles, signals, and how to participate before running a real project.

**Goal:** after one tour, the user understands:
- Roles are addressable and each refuses work outside its boundary
- Knowledge and state move by signal, not by re-explaining
- The agent that needs you asks you, in its own tab
- The user stays in the loop; their answers advance the chain

## Rules

- Your questions: `AskUserQuestion`, header like `Tour`, ≤ 2 lines of lead text, one short question, 2–4 options. Orchestration questions only (start research, shut down). Never ask the user to go to a tab and type something.
- Standard options, adapt per question: the affirmative (advance) · **What happens next?** (explain in 2 lines, re-ask) · **Show me where** (fallback only: name the tab to look at, re-ask) · **Skip ahead** (do the step yourself via `project prompt <role> '<line>'`, say so in one line, continue).
- Role blurbs (table below) are given only when the user asks — agents say theirs on request. Don't print concept explanations upfront.
- **Never hold a question open while waiting for a signal.** Between your own questions you just wait; signals arrive on their own. That's what makes the automatic hop real.
- **After any answer or arriving signal, check what actually happened** (`project log --tail`, `project status`) rather than assuming order, and narrate from that in one line. If something expected hasn't arrived and the user prompts you, say so and point them at the waiting agent.
- If the user does nothing, nothing advances.

## Role blurbs (on request only)

| Role | Blurb |
|---|---|
| orchestrator | I only start and sequence agents — I don't research or implement. |
| researcher | I dig into detail and collapse it into tasks and domain notes. I don't implement or own ticket state. |
| librarian | I track tasks and project state, receive signals, and answer "what's the status / what changed?". I don't dig into the domain or write code. |
| worker | One ticket, one clean context. I implement, signal completion, and usually shut down. I don't manage other agents or own the plan. |

## Prerequisites

```bash
test -n "${HERDR_ENV:-}${HC_TERMINAL_ID:-}"
which project
```

If either fails, tell the user what's missing and stop.

## Setup

Check if a project is already initialized:

```bash
project name
```

**If it prints a name** (`project start` already ran), the workspace exists — do NOT create another one:

```bash
project info
project register orchestrator
```

**If it exits non-zero**, create the workspace and initialize the project in one step:

```bash
eval "$(project open demo --label "Guided Tour (DEMO)" --focus)"
project register orchestrator
```

Then spawn the researcher and librarian (below). Lead text before the first question, one or two lines: "Welcome — a short tour. When an agent needs you, it'll ask in its own tab — watch for the one that's waiting."

### Spawn the researcher

```bash
project spawn researcher --cwd "$PWD" --label "researcher" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project researcher.

Your blurb (say this if anyone asks what you do):
  I dig into detail and collapse it into tasks and domain notes.
  I don't implement and I don't own ticket state.
  My job is to build the map so later agents don't rediscover everything.

This is a guided tour, not a real project.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Boot: run 'project register researcher', then reply 'ready' and wait. Do nothing else until prompted.

When you receive a prompt from the orchestrator that the user is ready for research, ask the user:
  Question: "I'm ready to map the demo into tasks — go ahead?"
  Options: "Go ahead" · "I have questions about what you'll research first" · (optionally) "What are you for?"
Answer questions briefly (what you'll look at, your boundaries: you investigate and propose tasks, you don't implement or manage ticket state), then re-ask.

On "Go ahead":
1. Show the task you've identified:
   DEMO-TASK-001: Add a one-line greeting to TOUR_NOTES.md
   (Trivial on purpose — the point is the handoff, not the work.)
2. Report it to the librarian:
   project prompt librarian 'RESEARCH FINDING — Discovery complete. One task: DEMO-TASK-001 (add a one-line greeting to TOUR_NOTES.md). No dependencies.'
3. Tell the user in one line that the task went to the librarian, who will ask them about it next.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'researcher'.
EOF
```

The boot text goes in the spawn (`--task`), not a later prompt.

### Spawn the librarian

```bash
project spawn librarian --cwd "$PWD" --label "librarian" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project librarian.

Your blurb (say this if anyone asks what you do):
  I only track tasks and project state. I receive signals and answer 'what's the status / what changed?'
  I don't dig into the domain and I don't write code.

This is a guided tour, not a real project.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Boot: run 'project register librarian', then reply 'ready' and wait.

When you receive a RESEARCH FINDING from the researcher about DEMO-TASK-001, store it:
  DEMO-TASK-001: Add a one-line greeting to TOUR_NOTES.md
  Status: todo (discovered by researcher, not yet assigned to a worker)
Then ask the user:
  Question: "The researcher found DEMO-TASK-001. Is it ready for a worker?"
  Options: "Yes, it's ready — signal the orchestrator" · "What tasks do you know about?" · "Not yet"
Answer status questions from what you've stored, then re-ask. On "Yes":
1. Signal the orchestrator:
   project prompt orchestrator 'TASK_READY — DEMO-TASK-001 is ready for a worker.'
2. Tell the user in one line that the signal went to the orchestrator, who will spin up a worker on its own.

Signal protocol for later:
  Worker STARTING — DEMO-TASK-001  →  ACK it
  Worker DONE — DEMO-TASK-001  →  Store the completion. This is the only task, so the project is complete. Signal:
    project prompt orchestrator 'PROJECT_COMPLETE — DEMO-TASK-001 is done. All tasks finished.'
  When the user asks what happened, reflect the updated state.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.
Do NOT load /project-librarian. Follow the protocol above and answer questions naturally.
EOF
```

## Stage 1: Start research (your question)

AskUserQuestion: "Ready to start research?"
Options: **Yes, start it** · **What happens next?** (explain: I'll tell the researcher; it asks you directly before it maps tasks) · **Show me where** (name the researcher tab, re-ask).

On yes: `project prompt researcher 'The user is ready for research. Ask them if they want you to map the demo into tasks.'`, then say in one line: "The researcher is now waiting on you — go answer it in its tab." (Naming it once here is fine; after that the panel does the work.) Then **wait — no open question.**

## Stage 2: The automatic hop

Wait for the librarian's `TASK_READY — DEMO-TASK-001 is ready for a worker.` (The chain: researcher maps → librarian asks the user → user confirms → signal.) Sources of truth are `project log --tail` / `project status`; check them whenever the user speaks to you or a signal lands. Do not open a question while waiting.

When `TASK_READY` arrives, say in two lines that the signal landed and you're spawning a worker now **without being asked** — the one automatic step in the tour. Spawn:

```bash
project spawn demo-worker --cwd "$PWD" --label "worker — DEMO-TASK-001" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project worker for DEMO-TASK-001.

Your blurb (say this if anyone asks what you do):
  I get one ticket, one worktree, one clean context.
  I implement, signal completion, and usually shut down.
  I don't manage other agents or own the project plan.

This is a guided tour, not a real project.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Boot sequence:
1. Run: project register demo-worker
2. Signal READY:
   project prompt orchestrator 'READY — demo-worker for DEMO-TASK-001'
3. Ask the user:
   Question: "Ready for me to start DEMO-TASK-001?"
   Options: "Start it" · "What will you do?" (answer: add a one-line greeting to TOUR_NOTES.md, and signal the librarian) · "What are you for?" (give your blurb)

On "Start it":
1. Signal the librarian:
   project prompt librarian 'STARTING — DEMO-TASK-001'
2. Create the file (this is the trivial demo work):
   echo 'Hello from the guided tour!' > TOUR_NOTES.md
3. Signal completion to the librarian:
   project prompt librarian 'DONE — DEMO-TASK-001. Added greeting to TOUR_NOTES.md.'
4. Tell the user in one line that you're done.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'demo-worker'.
Do NOT load /project-worker.

Start with the boot sequence now.
EOF
```

Then `project log --tail` (expect the worker's `READY`) and say in one line that the worker is now waiting on the user. **Still no open question** — wait for `PROJECT_COMPLETE`.

## Stage 3: Completion and wrap-up

On the librarian's `PROJECT_COMPLETE`, check `project log --tail` and summarize from what actually landed (worker `STARTING`/`DONE` to the librarian, `PROJECT_COMPLETE` to you); if the chain is incomplete, say what's missing.

Print a short close (≤ 5 lines): the researcher mapped the work, the librarian tracked state and routed signals, the worker implemented one thing and reported done, each asked you itself when it needed you, and I only started things and reacted to signals. Pointer: `project observe` / `project log` to see it under the hood; `/start-project <epic-key>` for a real project.

Clean up the demo file:

```bash
rm -f TOUR_NOTES.md
```

**Do NOT close the workspace automatically.** AskUserQuestion: "Tour complete. Shut down the demo workspace?"
Options: Close it · Keep it open (I want to poke around) · Show the project log first.
Only on **Close it**:

```bash
project close
```

## What this teaches

- Four roles and their boundaries (orchestrator, researcher, librarian, worker)
- The agent that needs you asks you, in its own tab — look for the one that's waiting
- Signals flow through the librarian, not directly to the orchestrator
- One automatic hop shows what the machinery does on its own
- `project prompt` / `project ask` for communication

## What this does NOT teach

- Dependency DAGs and wave sequencing (use a real project or `/dry-run-project`)
- Worktree management and git isolation
- The watcher and CI monitoring
- Distill/restart for context pressure
- Recovery after a crash
- Concurrent workers
