# Roadmap

## Next up

- **Battle-test v0.6.0** — run a real epic with the COMPLETE/DONE split, watcher agent, and librarian relay. Validate the signal flow end-to-end before publishing.

## Short term

- **Project status view** — live TUI pane showing epic status: active workers, ticket assignments, wave progress, CI status from the watcher. Evaluate [herdr-dagr](https://github.com/topics/herdr-plugin) (153 stars, live DAG visualization) before building our own — it may already do what we need if it can read our state file format.
- **Release detection** — orchestrator or a hook detects a release containing epic work and tells the librarian to transition tickets from Acceptance Test to Done. Today this is manual.
- **Tester generalization** — extend the tester pattern beyond API parity to data migration verification, background job output checks, and other post-deploy validation.

- **Tune the context guard threshold** — 60% of window is a starting guess (the first absolute 150k threshold caused a distill ping-pong). Also: setup could offer to install the statusline window tap instead of documenting it. Watch real runs: do agents distill at the right time, too early (1M-context agents), or still get compacted? Consider per-role thresholds (the librarian's accumulated summaries are signal, not noise).
- **Upstream: herdr re-injects tab env on resume** — sessions resumed after a reboot lose `--env HERDR_PROJECT`. The CLI now recovers the project from the state file via `HERDR_PANE_ID`/`HERDR_WORKSPACE_ID`, but herdr persisting per-tab env would fix it for any plugin.

## Spike: could the watcher be plain shell? (DOG-504)

**Finding: mostly yes.** Polling, status classification and routing are mechanical. The one real judgment call is small enough to push to the worker.

What the agent watcher does today, and whether a script can:

| Job | Script? |
|-----|---------|
| Poll `gh pr checks` per PR, every 120s | Yes. An agent burns a turn per wakeup (idle heartbeat included); a loop costs nothing. |
| Classify pass / fail / pending-over-10-min | Yes. Exit codes and `--json` fields. |
| Dedupe (don't re-report the same failure) | Yes, and better than an agent. Key on PR + head SHA + check name in a state file; a new push is a new key. |
| Route: PR → worker role | Yes. Take the PR→worker mapping from the state file the librarian already writes at COMPLETE, instead of a `WATCH` signal. |
| Excerpt the failing log | Mostly. `gh run view --log-failed`, strip ANSI, keep the last ~60 lines of each failed job. Not a summary, but the worker is an LLM and reads an excerpt fine. |
| Flaky vs real failure | No, not reliably. Cheap proxy: on the first failure of a check, `gh run rerun --failed` once and report only if it fails again. Costs one CI run, no tokens. |

What is lost: the one-line "punch list" summary an agent writes. The worker gets check names plus a log tail and does that reading itself, in a context that already holds the code. Net token change: the watcher's cost drops to zero, each failure costs the worker a little more.

**Recommendation.** Replace the agent watcher with a shell loop in an hc terminal, like the queue delivery loop:

1. Loop every ~120s over open PRs from the state file; skip PRs with no change.
2. On fail (after the one rerun): `project prompt <worker> "CI FAILED — PR #N: <checks>\n<log tail>"`.
3. On green: `project prompt librarian "CI GREEN — PR #N for <ticket>"`. On merge: `MERGED …`. Same signals, so nothing downstream changes.
4. No agent to promote: the "CI churn → propose promoting the watcher" rule goes away and the watcher is just on once any PR is open. The unassigned-watcher fallback (workers watch their own CI) stays for projects without `gh`.
5. Keep the agent role only as an opt-in for trackers/CI without a usable CLI, where judgment is the whole job.

Not done here: this is not a small change. It needs the PR→worker mapping exposed by the CLI, a state file for dedupe, loop lifecycle (start on first COMPLETE, stop at project end), and a rule for non-GitHub CI. Worth its own ticket. Open question: should the failing log go to the worker directly, or to a wake-an-agent step first? Recommend direct, since an intermediate agent re-adds the cost we are removing.

## Medium term

- **Publish to plugin gallery** — make the repo public, add the `herdr-plugin` GitHub topic. The herdr plugin index picks it up automatically (no sign-up, no review). Requires the v0.6.0 battle-test and a clean audit pass.
- **Librarian advising on splits** — orchestrator asks librarian how to decompose a large ticket based on codebase knowledge.
- **Researcher skill** — formalize the researcher as a proper skill (currently just a role definition).

## Ideas (unvalidated)

- **Worker handoff briefs** — workers emit operational knowledge at COMPLETE that the diff doesn't capture. Librarian stores it for future worker queries. (Partially implemented in v0.6.0 via operational notes in COMPLETE signal.)
- **Cross-repo orchestration** — map tickets to repos by labels/components. Most land in the primary repo, some in frontend, pipelines, etc.
- **herdr-jira integration** — herdr-jira plugin (15 stars) provides a Jira TUI pane. Could complement our orchestrator for browsing/delegation.

## Ecosystem context (2026-11-13)

Surveyed 92 herdr plugins in the orchestration/multi-agent space. Nothing replicates our pipeline (project tickets → dependency DAG → wave scheduling → librarian knowledge accumulation → semantic signals → watcher CI monitoring). Closest:

| Plugin | What it does | Relationship |
|--------|-------------|-------------|
| herdr-dagr | Live DAG visualization of agent swarms | Could visualize our DAG — evaluate before building status view |
| odysseus | Governed multi-agent workflows with review gates | Generic task→agent, no Jira/knowledge pattern |
| bermuda | Flow-based orchestration with scheduler | Workflow engine, different approach |
| herdr-jira | Jira TUI pane | Complementary for browsing |
| herdr-radar | Agent activity dashboard | Observability, not orchestration |
