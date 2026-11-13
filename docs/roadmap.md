# Roadmap

## Next up

- **Battle-test v0.6.0** — run a real epic with the PR_OPEN/DONE split, watcher agent, and librarian relay. Validate the signal flow end-to-end before publishing.

## Short term

- **Project status mod** — a herdr TUI pane that reads the project state file and shows live epic status: active workers, ticket assignments, wave progress, CI status from the watcher. Companion to the plugin, distributed as a herdr mod (`mods/project-status/`). Read-only view — all control stays in the CLI and skills.
- **Release detection** — orchestrator or a hook detects a release containing epic work and tells the librarian to transition tickets from Acceptance Test to Done. Today this is manual.
- **Tester generalization** — extend the tester pattern beyond API parity to data migration verification, background job output checks, and other post-deploy validation.

## Medium term

- **Public plugin** — make the repo public so anyone can `herdr plugin install` it. Requires the v0.6.0 battle-test and a clean audit pass.
- **Librarian advising on splits** — orchestrator asks librarian how to decompose a large ticket based on codebase knowledge.
- **Researcher skill** — formalize the researcher as a proper skill (currently just a role definition).

## Ideas (unvalidated)

- **Worker handoff briefs** — workers emit operational knowledge at PR_OPEN that the diff doesn't capture. Librarian stores it for future worker queries. (Partially implemented in v0.6.0 via operational notes in PR_OPEN signal.)
- **Cross-repo orchestration** — map tickets to repos by Jira labels/components. Most land in the primary repo, some in frontend, pipelines, etc.
