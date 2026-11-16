# Roadmap Items

Input hopper for the next dogfood run. The researcher reads this plus any `~/.herdr/projects/<project>/feedback.md` files from real sessions, then scopes tasks from them.

## From DOG-001 dogfood (2026-11-15)

### Signal flow
- Orchestrator should acknowledge UNBLOCKED signals — librarian needs confirmation its unblock was received and acted on
- Wave merge ingestion needs a consistent signal format (not ad-hoc "ingest the diff: git diff X..Y")
- Researcher adding tasks mid-wave should route through orchestrator for DAG placement, not just announce to librarian
- DOG-307 bypassed the researcher→librarian pipeline — tasks must always flow through the researcher so the librarian has them in the DAG

### Researcher role
- Researcher must never edit tracked files — only task files and signals. Edits to DESIGN.md etc. got clobbered by wave merges
- Target "next wave" not specific wave numbers — researcher doesn't always know what wave is current
- Need a "task list locked" boundary — stop adding tasks indefinitely. Research phase ends, new ideas go to backlog
- Findings route to orchestrator + librarian only — workers get answers to their specific questions, not full research dumps
- FROM() prefix doubling — don't manually type what the CLI adds

### Task scoping
- DOG-202 (researcher redesign) was too big — should split durable artifact from lifecycle changes
- DOG-303 (failure taxonomy) was too lightweight for a worker — could be researcher output instead
- DOG-305 (check-in) went through 3 scope revisions — researcher should nail a one-liner, get buy-in, then expand

### Agent lifecycle
- Any non-librarian/non-researcher agent is a worker — registers, signals, follows the protocol. No "utility agent" exceptions (merge-reviewers, coherence auditors, etc.)
- Coherence audit skipped registration because the skill doesn't cover utility workers — fix the skill to say all agents register

### Orchestrator behavior
- Orchestrator was blocking on `project prompt --wait` for assignments — should be fire-and-forget (DOG-306 fixed guidance but verify it sticks in practice)
- Orchestrator jumped to wave 2 without verifying wave 1 was installed/working — need a verification checkpoint between waves
- Worker DONE vs COMPLETE confusion in dogfood mode — dogfood protocol now uses COMPLETE but verify it works in practice
