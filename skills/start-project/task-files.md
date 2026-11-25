# Task files — projects without a tracker

Some projects have no tracker: a **ticketless** project (`WORK-` key, or started with an empty key) or a **dogfood** run (`DOG-` key). Task files on disk stand in for the tracker. Everything else works as in normal mode unless the mode says otherwise.

Check the mode with `project name` (case-insensitive prefix):

- `work-…` → ticketless. Workers open PRs and CI runs, exactly as in normal mode.
- `dog-…` → dogfood. Task files as below, plus no PRs and wave merges (the plugin repo's `docs/dogfood.md`).

## Where tasks live

`$(project dir)/tasks/`, one markdown file per task. Never write task files into the repo.

```
$(project dir)/tasks/work-001-1.md
$(project dir)/tasks/work-001-2.md
```

Task IDs are `<project-key>-<n>` and are used wherever a ticket key would be (assignments, signals, branch names, PR titles).

## Format

```markdown
---
id: work-001-1
title: Short description
status: todo
wave: 1
blocked-by: []
---

What needs to happen and why. Enough context for a worker to implement without asking questions.
```

Status values: `todo`, `in-progress`, `done`.

## The goal

There's no epic description. The goal is the text after the key in `/start-project <key> <goal>` (the label from `project start`). If there's no goal, the orchestrator asks the user what they're working on, in one question, before anything else.

## Per role

**Orchestrator**
- Step 1 reads `$(project dir)/tasks/` instead of the tracker. No task files yet means no tasks: take the no-tasks path (promote the researcher now) and put the goal in its payload instead of an epic.
- When confirming the plan of a ticketless project, offer once: "Stay ticketless, or create an epic and tickets in the tracker now?" If the user picks the tracker, have the researcher create them from the task files, then continue in normal mode with the new epic key. The project key doesn't change.
- Recovery reads task statuses from the files instead of the tracker.

**Researcher**
- Turns the goal (or the user's raw ideas) into tasks: writes task files with wave numbers and `blocked-by`, wherever normal mode says to create tickets. Not every idea becomes a task.
- Tells the librarian the dependency summary directly. Then reports the task list and waves to the orchestrator.

**Librarian**
- Never reads task files; the researcher's summary is its DAG.
- No ticket transitions. Lifecycle signals and DAG checks are otherwise unchanged.

**Worker**
- Updates `status:` in its own task file (`in-progress` at start, `done` when finished) instead of the librarian transitioning a ticket. Still signals STARTING, COMPLETE and DONE as usual.
- The PR title and description reference the task ID.
