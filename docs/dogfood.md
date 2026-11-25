# Dogfood Mode

**The point is to exercise agent orchestration** — spawning workers, wave sequencing, librarian handoffs, merge coordination, signal flow. Everything unique to real projects (ticket trackers, dependency DAGs, CI monitoring) is stripped away. What's left is the multi-agent machinery itself.

Tasks live on disk, waves merge through a review branch, and the orchestrator uses this file as the "tracker adapter." Prefix the epic key with `DOG-` and the orchestrator loads this mode.

## When to use

- Testing orchestration skill changes by running them
- Exercising the full agent lifecycle without project overhead
- Batching improvements when a tracker isn't worth the setup

## Task files

Each run's tasks live in their own folder, `docs/dogfood/tasks/<project-key>/` (gitignored: they're ephemeral). Read only that folder. Files from other runs and agents' notes sit elsewhere under `docs/dogfood/tasks/` and are not this run's tasks. Each task is a markdown file:

```
docs/dogfood/tasks/DOG-500/DOG-501.md
docs/dogfood/tasks/DOG-500/DOG-502.md
```

Format:

```markdown
---
id: DOG-001
title: Short description
status: todo
wave: 1
blocked-by: []
---

What needs to happen and why. Enough context for a worker to implement without asking questions.
```

Status values: `todo`, `in-progress`, `done`

## Research phase

**If the run's task folder already has tasks, skip this phase.** The orchestrator plans from the files. Otherwise there are no tasks, so the researcher gets its own agent right away (start-project's no-tasks rule). The user dumps raw ideas/feedback to it, and the researcher:

1. Organizes ideas into discrete tasks
2. Writes task files to `docs/dogfood/tasks/<project-key>/`
3. Assigns wave numbers and blocked-by relationships
4. Tells the librarian role the dependency summary directly. The librarian does NOT read task files (saves tokens).
5. Reports the task list and DAG to the orchestrator

The researcher decides what's a task vs. what's noise. Not every idea becomes a task.

## Orchestrator behavior in dogfood mode

When the epic key starts with `DOG-`:

- **Read tasks** from `docs/dogfood/tasks/` instead of a tracker MCP
- **No ticket transitions** — workers update `status:` in task files directly
- **No PRs** — workers commit to their worktree branch but don't open draft PRs
- **Wave merge** replaces PR-per-ticket (see below)
- **No real DAG.** The task files group tasks into waves for logical ordering, but there are no blocking dependencies to enforce. The waves are just batches of concurrent work.

Workers still use worktrees, still signal the librarian, still follow the worker skill. The difference is: no PR to open, no tracker to transition. When a worker finishes, it signals `DONE` to the librarian with a summary of what changed.

## Wave merge flow

Instead of individual PRs reviewed and merged one at a time, a wave's changes merge together:

1. **All workers in the wave finish** — each has committed changes on their worktree branch
2. **Orchestrator spawns a merge-reviewer** — a regular worker with a special brief (below)
3. **Merge-reviewer creates a review branch** from main, merges each worker's branch into it
4. **Reviews the combined diff** — do the changes make sense together? Conflicts? Regressions?
5. **Merges the review branch to main** (fast-forward or merge commit, reviewer's judgment)
6. **Signals the orchestrator:** `"Wave N merged to main. Ready for wave N+1."`
7. **Librarian ingest:** if the librarian has its own agent, the orchestrator tells it to ingest the wave diff (one ingest per wave, not per task). While the orchestrator hosts the librarian, it doesn't read the diff. It records one line per wave (what merged, what changed for later tasks), and proposes promoting the librarian if waves pile up.
8. **Orchestrator cleans up** worktrees for the completed wave and spawns wave N+1

## Merge-reviewer brief

The merge-reviewer is a regular worker tab. Send it this assignment:

```
You are reviewing wave N for project DOG-XXXX.

Worker branches to merge:
  - dog-001 (worker alpha): <one-line summary>
  - dog-002 (worker bravo): <one-line summary>

Steps:
1. git checkout -b wave-N-review origin/main
2. For each branch: git merge <branch> (resolve conflicts if any)
3. Review the combined diff: git diff main..HEAD
4. Check: do the changes cohere? Any obvious conflicts or regressions?
5. If good: git checkout main && git merge wave-N-review --ff-only
6. Signal the orchestrator: "Wave N merged to main. Summary: <what changed>"

If there are problems, signal the orchestrator with what's wrong and which worker needs to fix it.
```

## Librarian behavior in dogfood mode

Whoever holds the librarian role (its own agent, or the orchestrator while hosting it, per § Wave merge flow step 7) works the same as normal mode, with two differences:

- **No ticket transitions** — skip MCP calls to transition tickets. The task file's `status:` field is the source of truth, but the librarian doesn't need to update it.
- **Wave-level ingestion** — instead of ingesting per-PR, the librarian ingests one combined diff per wave after the merge-reviewer merges to main.

Everything else is the same: store summaries, answer worker questions, detect unblocked tasks, advise on worker reuse.

## Signal differences from normal mode

| Normal mode | Dogfood mode |
|-------------|-------------|
| Worker → librarian: `COMPLETE` | Worker → librarian: `DONE — DOG-XXX. <summary of changes>` |
| Librarian → watcher: `WATCH PR #N` | No watcher needed (no CI to monitor) |
| Librarian transitions ticket | Worker updates task file status |
| Orchestrator merges PR | Merge-reviewer merges wave branch |
| Librarian ingests per-PR | Librarian ingests per-wave |
