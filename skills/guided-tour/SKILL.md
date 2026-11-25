---
name: guided-tour
description: "Interactive guided tour of project orchestration. Starts small (a worker on one demo task, the orchestrator hosting the other roles), then offers to scale up: promotes the librarian and researcher to their own agents and runs a second task through one automatic signal chain. Whoever needs the user asks them directly in its own pane with AskUserQuestion; the orchestrator asks only orchestration questions. Use when the user says 'start project DEMO-001' or any DEMO- prefix. Requires Herdr."
---

# guided-tour — DEMO Mode

A scripted walkthrough of multi-agent orchestration. **Whoever needs the user asks the user, in its own pane, with `AskUserQuestion`.** The orchestrator (you) asks only orchestration questions; workers and roles ask their own ("ready to see me go?"). The user finds the next step by seeing which agent is waiting (blocked) in the Agents/Projects panel — the same "agent needs me" feel as a live project.

**Audience:** someone who just installed the plugin and wants to understand roles, signals, and how to participate before running a real project.

**Goal:** after one tour, the user understands:
- A small project needs only workers; the orchestrator hosts the other roles
- Senders never change: signals go to a role, hosting decides who receives them
- A role can be promoted to its own agent when the project grows
- The agent that needs you asks you, in its own tab

## Shape of the tour

1. **Small:** one worker, one task. You host librarian and researcher; the watcher is unassigned (workers watch their own CI).
2. **Scale up (optional):** promote librarian and researcher, then research → `TASK_READY` → automatic worker spawn → done, with a second task.
3. **Wrap-up.**

## Rules

- Your questions: `AskUserQuestion`, header like `Tour`, ≤ 2 lines of lead text, one short question, 2–4 options. Orchestration questions only (scale up, shut down). Never ask the user to go to a tab and type something.
- Standard options, adapt per question: the affirmative (advance) · **What happens next?** / **What changes?** (explain in 2 lines, re-ask) · **Show me where** (fallback only: name the tab to look at, re-ask) · **Skip ahead** (do the step yourself via `project prompt <role> '<line>'`, say so in one line, continue).
- Role blurbs (table below) are given only when the user asks — agents say theirs on request. Don't print concept explanations upfront.
- **Never hold a question open while waiting for a signal.** Between your own questions you just wait; signals arrive on their own. That's what makes the automatic hop real.
- **After any answer or arriving signal, check what actually happened** (`project log --tail`, `project status`) rather than assuming order, and narrate from that in one line. If something expected hasn't arrived and the user prompts you, say so and point them at the waiting agent.
- If the user does nothing, nothing advances.
- Boot text for spawned agents must not send its own `READY` — `project register` already does.

## Role blurbs (on request only)

| Role | Blurb |
|---|---|
| orchestrator | I only start and sequence agents — I don't research or implement. On a small project I also host the other roles. |
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

Check if a project exists:

```bash
project name
```

**If it prints a name** (`project start` already created it), do NOT create another workspace:

```bash
project info
project register orchestrator
```

Say "Using the project Start created (`<name>`)." — never "reuse" or "already initialized".

**If it exits non-zero**, create the workspace and initialize the project in one step:

```bash
eval "$(project open demo --label "Guided Tour (DEMO)" --focus)"
project register orchestrator
```

`project register orchestrator` makes you host librarian and researcher. The watcher stays unassigned.

## Stage 1: Start small

Lead text, one or two lines: "Welcome — a short tour. We start small, like a typical 2–4 ticket project: only workers. I host the librarian and researcher roles myself, and workers watch their own CI, so my context stays light. When an agent needs you, it asks in its own tab."

Spawn the worker for DEMO-TASK-001 right away:

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
1. Run: project register demo-worker   (this already signals READY — do not send your own)
2. Ask the user:
   Question: "I'll do DEMO-TASK-001 (add a greeting to TOUR_NOTES.md). Ready to see me go?"
   Options: "Go" · "What will you do?" (answer: write one line to TOUR_NOTES.md, then signal the librarian) · "What are you for?" (give your blurb)

On "Go":
1. Create the file (this is the trivial demo work):
   echo 'Hello from the guided tour!' > TOUR_NOTES.md
2. Signal completion to the librarian:
   project prompt librarian 'DONE — DEMO-TASK-001. Added greeting to TOUR_NOTES.md.'
3. Tell the user in one line that you're done and the signal went to 'librarian'.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'demo-worker'.
Do NOT load /project-worker.

Start with the boot sequence now.
EOF
```

Then `project log --tail` and say in one line that the worker is waiting on the user in its tab. **No open question** — wait for its signal.

## Stage 2: The signal lands with you

The worker's signal arrives as `[to librarian] FROM(demo-worker): DONE — DEMO-TASK-001 …`. Show that in one line: the worker sent it to `librarian`, and it landed here because I host that role — senders don't change, hosting decides where it lands.

Then:
1. Ack it as librarian: note DEMO-TASK-001 done (you hold this in your own context; don't message yourself — a host messaging its own role is refused).
2. Stop the worker: `project stop demo-worker --close`
3. Explain in two lines: the worker did the heavy lifting in its own context, which is now gone; mine stayed small.

AskUserQuestion: "Mid-effort it turns out bigger, or another epic blocks us. Want to see scaling up?"
Options: **Yes, scale up** · **What changes?** (explain: the librarian and researcher get their own agents, seeded from what I know; workers keep sending to the same role names; re-ask) · **Finish here** (go to Stage 4).

## Stage 3: Scale up

On yes, promote the librarian and researcher. Each is a `project promote` with its boot text as `--task`; the host (you) is not stopped. Say in one line that you're giving them their own agents, seeded from your handoff.

```bash
project promote researcher --cwd "$PWD" --label "researcher" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project researcher (promoted from the orchestrator, which hosted your role until now).

Your blurb (say this if anyone asks what you do):
  I dig into detail and collapse it into tasks and domain notes.
  I don't implement and I don't own ticket state.
  My job is to build the map so later agents don't rediscover everything.

This is a guided tour, not a real project. DEMO-TASK-001 is already done.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Boot: run 'project register researcher', then reply 'ready' and wait. Do nothing else until prompted.

When you receive a prompt from the orchestrator that the user is ready for research, ask the user:
  Question: "The project grew. Ready for me to map the next task?"
  Options: "Go ahead" · "I have questions about what you'll research first" · (optionally) "What are you for?"
Answer questions briefly (what you'll look at, your boundaries: you investigate and propose tasks, you don't implement or manage ticket state), then re-ask.

On "Go ahead":
1. Show the task you've identified:
   DEMO-TASK-002: Add a one-line farewell to TOUR_NOTES.md
   (Trivial on purpose — the point is the handoff, not the work.)
2. Report it to the librarian:
   project prompt librarian 'RESEARCH FINDING — One new task: DEMO-TASK-002 (add a one-line farewell to TOUR_NOTES.md). No dependencies. DEMO-TASK-001 is already done.'
3. Tell the user in one line that the task went to the librarian, who will ask them about it next.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'researcher'.
EOF
```

```bash
project promote librarian --cwd "$PWD" --label "librarian" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project librarian (promoted from the orchestrator, which hosted your role until now).

Your blurb (say this if anyone asks what you do):
  I only track tasks and project state. I receive signals and answer 'what's the status / what changed?'
  I don't dig into the domain and I don't write code.

This is a guided tour, not a real project.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Handoff from the orchestrator:
  DEMO-TASK-001: Add a one-line greeting to TOUR_NOTES.md — Status: done (worker finished; its context is gone).

Boot: run 'project register librarian', then reply 'ready' and wait.

When you receive a RESEARCH FINDING from the researcher about DEMO-TASK-002, store it:
  DEMO-TASK-002: Add a one-line farewell to TOUR_NOTES.md
  Status: todo (discovered by researcher, not yet assigned to a worker)
Then ask the user:
  Question: "The researcher found DEMO-TASK-002. Is it ready for a worker?"
  Options: "Yes, it's ready — signal the orchestrator" · "What tasks do you know about?" (answer from what you've stored, including 001 done) · "Not yet"
Re-ask after answering questions. On "Yes":
1. Signal the orchestrator:
   project prompt orchestrator 'TASK_READY — DEMO-TASK-002 is ready for a worker.'
2. Tell the user in one line that the signal went to the orchestrator, who will spin up a worker on its own.

Signal protocol for later:
  Worker DONE — DEMO-TASK-002  →  Store the completion. Both tasks are done, so the project is complete. Signal:
    project prompt orchestrator 'PROJECT_COMPLETE — DEMO-TASK-001 and DEMO-TASK-002 are done. All tasks finished.'
  When the user asks what happened, reflect the updated state.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'librarian'.
Do NOT load /project-librarian. Follow the protocol above and answer questions naturally.
EOF
```

After both are up, `project prompt researcher 'The user is ready for research. Ask them if they want you to map the next task.'` and say in one line: the researcher is waiting on them. Then **wait — no open question.**

### The automatic hop

Wait for the librarian's `TASK_READY — DEMO-TASK-002 is ready for a worker.` (Chain: researcher maps → librarian asks the user → user confirms → signal.) Check `project log --tail` / `project status` whenever the user speaks to you or a signal lands. Do not open a question while waiting.

When `TASK_READY` arrives, say in two lines that the signal landed and you're spawning a worker now **without being asked** — the one automatic step in this half. Spawn:

```bash
project spawn demo-worker-2 --cwd "$PWD" --label "worker — DEMO-TASK-002" --wait --timeout 60000 --task - <<'EOF'
GUIDED TOUR — You are the project worker for DEMO-TASK-002.

Your blurb (say this if anyone asks what you do):
  I get one ticket, one worktree, one clean context.
  I implement, signal completion, and usually shut down.
  I don't manage other agents or own the project plan.

This is a guided tour, not a real project.
You ask the user directly whenever you need them: AskUserQuestion, one short question, 2-4 options, say what you'll do next.

Boot sequence:
1. Run: project register demo-worker-2   (this already signals READY — do not send your own)
2. Ask the user:
   Question: "I'll do DEMO-TASK-002 (add a farewell to TOUR_NOTES.md). Ready to see me go?"
   Options: "Go" · "What will you do?" (answer: append one line to TOUR_NOTES.md, then signal the librarian) · "What are you for?" (give your blurb)

On "Go":
1. Append the line (this is the trivial demo work):
   echo 'Goodbye from the guided tour!' >> TOUR_NOTES.md
2. Signal completion to the librarian:
   project prompt librarian 'DONE — DEMO-TASK-002. Added farewell to TOUR_NOTES.md.'
3. Tell the user in one line that you're done and the signal went to 'librarian'.

All agents use 'project prompt <role> <message>' to communicate. Your role is 'demo-worker-2'.
Do NOT load /project-worker.

Start with the boot sequence now.
EOF
```

Then `project log --tail` and say in one line the new worker is waiting on the user. Point out: this worker sends to `librarian` exactly like the first one did — nothing changed on its side — but the signal now lands with the dedicated librarian, not with me. **Still no open question** — wait for `PROJECT_COMPLETE`.

## Stage 4: Wrap-up

**After scale-up:** on the librarian's `PROJECT_COMPLETE`, check `project log --tail` and summarize from what actually landed (worker `DONE` to the librarian, `PROJECT_COMPLETE` to you); if the chain is incomplete, say what's missing. Stop the worker: `project stop demo-worker-2 --close`.

**After "Finish here":** nothing more to run.

Print a short close (≤ 5 lines): small projects need only workers, with the orchestrator hosting the other roles; roles are addresses, so senders never changed when hosting did; promotion gave the librarian and researcher their own agents when the project grew (omit if skipped); each agent asked you itself when it needed you. Pointer: `project observe` / `project log` to see it under the hood; `/start-project <epic-key>` for a real project.

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

- Small vs. scaled staffing: the orchestrator hosts roles until they're promoted
- Roles are addresses: `project prompt librarian …` works the same either way
- Role boundaries (orchestrator, researcher, librarian, worker)
- The agent that needs you asks you, in its own tab — look for the one that's waiting
- One automatic hop shows what the machinery does on its own

## What this does NOT teach

- Dependency DAGs and wave sequencing (use a real project or `/dry-run-project`)
- Worktree management and git isolation
- The watcher and CI monitoring
- Distill/restart for context pressure
- Recovery after a crash
- Concurrent workers
