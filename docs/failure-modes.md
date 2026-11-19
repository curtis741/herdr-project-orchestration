# Failure Modes

Catalog of known failure modes from real and dogfood runs. Each entry covers symptoms, detection, recovery, and whether recovery is manual or automated today.

Related work:
- **Distill hooks (DOG-203)** — the automated recovery path for context collapse; consult DESIGN.md § Knowledge pressure and distill for signal flow
- **Recovery after restart (DOG-302)** — the orchestrator's procedure for rebuilding state after a crash; uses the signal log and state file

## Librarian lag

The librarian falls behind on ingestion — merged PRs pile up before their diffs are summarized. Workers in later waves ask the librarian about earlier work and get incomplete or missing answers.

**Symptoms:**
- Worker asks the librarian about a merged PR and gets "I haven't ingested that yet" or an answer that doesn't reflect the merged code
- Orchestrator sends multiple "ingest this diff" signals before the librarian finishes the previous one
- Wave 2+ workers make assumptions about interfaces that don't match what was actually merged

**Detection:**
- Signal log shows a burst of ingest requests with no corresponding librarian activity between them (`project log --tail 20` — look for clustered orchestrator→librarian ingest signals)
- Worker reports a wrong answer from the librarian about recent work
- Manual: orchestrator notices slow wave transitions

**Recovery:**
1. Pause new worker spawns until the librarian catches up
2. Send ingest requests one at a time, waiting for each to complete before sending the next
3. If the librarian's context is too full to process the backlog, distill it first (DISTILL flow per DESIGN.md)

**Manual vs. automated:** Manual today. The orchestrator must notice the lag and throttle. Could be automated by having the librarian signal a backlog state, or by the orchestrator waiting for an ingest acknowledgment before sending the next.

---

## Signal loss

A signal is sent via `project prompt` but the recipient never acts on it. The signal was delivered (herdr returned success) but the agent didn't process it — it was busy, its context was full, or it interpreted the signal as noise.

**Symptoms:**
- A ticket stays in the wrong status longer than expected (e.g. stays "In Progress" after the worker sent COMPLETE)
- The orchestrator doesn't spawn the next wave even though dependencies are met
- A worker never receives its assignment after registration
- The watcher never starts monitoring a PR that the librarian should have handed off

**Detection:**
- Signal log shows the signal was sent but no follow-up action occurred (`project log` — look for a signal with no corresponding state change or relay within a reasonable window)
- `project status` shows an agent as idle when it should be working
- Manual: user notices a stalled project and checks the signal log

**Recovery:**
1. Re-send the signal: `project prompt <role> "<original signal>"`
2. If the agent's context is too noisy to process signals reliably, distill it
3. If the agent is stopped or dead, restart it and re-send
4. For critical lifecycle signals (COMPLETE, UNBLOCKED), the orchestrator should verify the downstream effect occurred

**Manual vs. automated:** Manual today. The signal log (DOG-101) provides the audit trail to diagnose, but nothing watches for signals that went unacknowledged. Could be automated with a signal acknowledgment protocol or a watchdog that checks for expected state transitions after signals.

---

## Worker scope creep

A worker drifts beyond its ticket's scope — refactoring adjacent code, fixing unrelated bugs, adding features not in the ticket. The PR grows, review takes longer, and the blast radius increases.

**Symptoms:**
- PR diff touches files unrelated to the ticket
- Worker sends SCOPE signal (good — it noticed) or doesn't (bad — it just did the work)
- PR review feedback flags out-of-scope changes
- Worker takes significantly longer than expected for what should be a focused ticket

**Detection:**
- PR diff review (manual or automated lint checking changed files against ticket scope)
- Worker's commit messages mention work not described in the ticket
- Manual: reviewer or orchestrator notices during PR review

**Recovery:**
1. If caught early: tell the worker to revert out-of-scope changes and open a separate ticket
2. If already committed: the worker splits the PR — one for the ticket, one for the extra work — or the orchestrator creates a follow-up ticket
3. If the scope creep revealed necessary work: the worker sends SCOPE to the orchestrator, which creates a new ticket and assigns it appropriately
4. Reinforce the boundary: the worker skill says small unblocking fixes are fine, separate units of work get SCOPE signals

**Manual vs. automated:** Manual today. The worker skill has guidance (small fixes OK, larger work → SCOPE signal), but enforcement is human review. Could be partially automated by diffing changed files against a ticket's expected file set, though this is fragile for cross-cutting work.

---

## Stale worktree

A worktree has dirty state from a previous run — uncommitted changes, wrong branch, conflicts from a failed merge. The worker starts implementing on top of garbage.

**Symptoms:**
- `git status` in the worktree shows unexpected changes or untracked files
- Worker's branch is behind main or has commits from a different ticket
- Merge conflicts appear immediately when the worker tries to sync
- Worker's PR includes changes from a previous ticket's abandoned work

**Detection:**
- Worker skill Step 2a (`git log --oneline main..HEAD`) catches unexpected commits
- `git status` during boot shows dirty state
- Manual: worker notices unexpected files or conflicts

**Recovery:**
1. If the worktree is from a previous ticket on the same branch: reset to main
   ```
   git fetch origin main
   git reset --hard origin/main
   ```
2. If the worktree has uncommitted work that might be valuable: stash it with a descriptive tag, then reset
3. If the worktree is too tangled: remove it and create a fresh one
   ```
   cd ..
   git worktree remove .worktrees/<ticket>/
   git worktree add .worktrees/<ticket> -b <branch> origin/main
   ```
4. The orchestrator should ensure worktree cleanup happens after each ticket completes (DESIGN.md § Worktree cleanup)

**Manual vs. automated:** Partially automated. The worker skill's branch-point check (Step 2a) catches the most common case (unexpected commits). Full cleanup after ticket completion is documented in the orchestrator skill but relies on the orchestrator remembering to do it. Could be fully automated with a pre-boot hook that validates worktree state.

---

## Context collapse

An agent's context fills with noise — verbose tool output, failed debugging attempts, accumulated signal traffic — and response quality degrades silently. The agent doesn't error out; it just gets worse.

**Symptoms:**
- Agent starts making mistakes it didn't make earlier (wrong file paths, forgotten conventions, repeated approaches)
- Responses get slower or more generic
- Agent goes in circles on something it handled correctly before
- Agent stops following its skill instructions reliably

**Detection:**
- The agent itself notices (ideally) and sends DISTILL to the orchestrator
- Other agents notice degraded answers (e.g. librarian gives wrong summaries, worker asks the same question twice)
- Manual: user reads agent output and notices quality drop
- Heuristic: agent has been running for a long time or has processed many signals without a restart

**Recovery:**
1. The distill/restart flow (DOG-203, DESIGN.md § Knowledge pressure and distill):
   - Agent sends `DISTILL — <reason>` to orchestrator
   - Orchestrator approves: `DISTILL_ACK`
   - Agent commits WIP (workers), writes `$(project dir)/<role>.distill.md`
   - Agent sends `DISTILL_READY`
   - Orchestrator spawns a fresh successor in a new tab with the original assignment + distill file path
   - Successor registers, reads the file, optionally questions the old agent, then `project retire <old-pane>`
2. If the agent doesn't self-detect: the orchestrator or user triggers a manual distill
3. For the librarian specifically: its value is accumulated knowledge, so the distill artifact must capture all ingested summaries and research findings — losing those means re-ingesting from scratch

**Manual vs. automated:** Partially automated via the distill protocol (DOG-203). Detection is still mostly manual — no automated quality monitoring. The agent is expected to self-report, which requires it to still have enough context quality to notice the problem. Could be improved with token-count heuristics or periodic quality checks.

---

## Orchestrator single point of failure

The orchestrator session dies (crash, network disconnect, user closes terminal). All coordination stops — no new workers spawn, no wave transitions happen, no signals get routed. Workers and the librarian keep running but have no coordinator.

**Symptoms:**
- No new workers spawn after dependencies are met
- UNBLOCKED signals from the librarian go unacknowledged
- Workers finish and send COMPLETE but nothing happens next
- `project status` shows the orchestrator as stopped or unreachable

**Detection:**
- Librarian notices: it sends UNBLOCKED but no worker spawns follow
- Workers notice: they finish but receive no next assignment
- Manual: user checks the workspace and sees the orchestrator pane is dead
- Signal log shows signals sent to the orchestrator with no outbound signals following

**Recovery:**
1. Start a new orchestrator session in the same workspace
2. The orchestrator runs its reboot-recovery procedure (start-project/SKILL.md § Reboot recovery):
   - `project roster` and `project status` to see all agents and their state
   - Ask the librarian for current ticket/PR status
   - Reconstruct which wave is active, which tickets are done, which are blocked
   - Resume wave management from where it left off
3. The state file and signal log (DOG-101) persist across sessions, so no coordination state is truly lost — just delayed
4. For workers that finished while the orchestrator was down: the librarian has their COMPLETE signals queued; the new orchestrator processes them

**Manual vs. automated:** Manual today. The user must notice the orchestrator is down and restart it. The recovery procedure itself is documented and mostly mechanical. Could be automated with a heartbeat mechanism — the orchestrator periodically writes a timestamp, and a watchdog (or the librarian) escalates if the heartbeat goes stale. Herdr's agent supervision could also help if it gains auto-restart capabilities.

---

## Bonus: Compound failures

The modes above interact. Common compounds observed or anticipated:

| Compound | What happens | Key risk |
|----------|-------------|----------|
| Orchestrator SPOF + signal loss | Orchestrator dies, signals queue up, new orchestrator replays stale signals in wrong order | Signal log timestamps prevent misordering, but the new orchestrator must process them chronologically |
| Librarian lag + context collapse | Ingestion backlog fills the librarian's context, quality drops, workers get wrong answers | The librarian should distill before the backlog causes collapse — but it may not notice in time |
| Worker scope creep + context collapse | Extra work fills the worker's context, implementation quality drops on the actual ticket | The scope creep itself causes the collapse — catching it early prevents both |
| Stale worktree + signal loss | Worker boots into dirty state, sends STARTING, but the librarian doesn't transition because the signal was lost | Worker is implementing on garbage and nobody knows the ticket is in progress |

## Automation priorities

Ranked by impact and feasibility:

1. **Signal acknowledgment protocol** — signals confirm receipt. Highest impact: prevents silent signal loss, the most insidious failure mode. Feasible: extend `project prompt` to wait for an ack signal or log entry.
2. **Worktree validation hook** — pre-boot check that the worktree is clean and branched from current main. Already partially implemented in the worker skill; formalizing as a CLI command (`project validate-worktree`) makes it reliable.
3. **Librarian backlog detection** — the librarian tracks its ingestion queue depth and signals when it's falling behind, so the orchestrator can throttle spawns. Medium complexity: requires the librarian to maintain queue state.
4. **Orchestrator heartbeat** — periodic timestamp write, watchdog checks staleness. Simple to implement but needs a watcher — the librarian or a dedicated monitor.
5. **Context quality heuristic** — token count or signal-to-noise ratio triggers automatic distill suggestions. Hard to get right without false positives, but even a crude heuristic (e.g. "agent has been running for 2 hours without a distill") would help.
