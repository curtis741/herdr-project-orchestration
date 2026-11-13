# Roadmap

## Next up

- **Battle-test v0.6.0** — run a real epic with the PR_OPEN/DONE split, watcher agent, and librarian relay. Validate the signal flow end-to-end before publishing.

## Short term

- **Project status view** — live TUI pane showing epic status: active workers, ticket assignments, wave progress, CI status from the watcher. Evaluate [herdr-dagr](https://github.com/topics/herdr-plugin) (153 stars, live DAG visualization) before building our own — it may already do what we need if it can read our state file format.
- **Release detection** — orchestrator or a hook detects a release containing epic work and tells the librarian to transition tickets from Acceptance Test to Done. Today this is manual.
- **Tester generalization** — extend the tester pattern beyond API parity to data migration verification, background job output checks, and other post-deploy validation.

## Medium term

- **Publish to plugin gallery** — make the repo public, add the `herdr-plugin` GitHub topic. The herdr plugin index picks it up automatically (no sign-up, no review). Requires the v0.6.0 battle-test and a clean audit pass.
- **Librarian advising on splits** — orchestrator asks librarian how to decompose a large ticket based on codebase knowledge.
- **Researcher skill** — formalize the researcher as a proper skill (currently just a role definition).

## Ideas (unvalidated)

- **Worker handoff briefs** — workers emit operational knowledge at PR_OPEN that the diff doesn't capture. Librarian stores it for future worker queries. (Partially implemented in v0.6.0 via operational notes in PR_OPEN signal.)
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
