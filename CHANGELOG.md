# Changelog

## 0.5.0

- **Librarian and researcher are role definitions, not skills** — moved from standalone skills to `start-project/librarian.md` and `start-project/researcher.md`. Agents read their own role file during boot instead of loading a skill. Keeps the orchestrator's context window clean.
- **GUIDE.md** — new user guide explaining the system, roles, and communication protocol. Symlinked to `~/.claude/skills/PROJECT_GUIDE.md` on install. Includes a walkthrough prompt for new users and a path to the dry-run.
- **Worker: merge main before opening PRs** — prevents stale worktrees from polluting PR diffs.
- **Worker: reuse worktrees for follow-up work** — new branch in existing worktree, don't remove and recreate.
- **Scrubbed all org-specific references** — skills use generic placeholders only.

## 0.4.0

- **`FROM(role):` prefix on all cross-agent messages** — `project prompt` and `project ask` auto-detect the caller and prefix messages with `FROM(<role>):`. No prefix means the message came from a human. Agents can now distinguish peer messages from direct instructions.
- **`project stop` replaces `project unregister`** — stopping an agent marks it `stopped: true` but preserves session ID, pane ID, and ticket history. No data is deleted from the state file. Stopped worker names are available for reuse via `project next-worker`.
- **Agents self-register** — agents run `project register <role>` during boot (pane ID and session ID auto-detected). Register also signals `READY` to the orchestrator. The orchestrator no longer calls `project register` for spawned agents.
- **`NEED` escalation** — messaging a stopped agent auto-escalates to the orchestrator with `NEED — <caller> needs <role> (stopped)` and the original message. The orchestrator decides whether to restart the agent.
- **Researcher and librarian are both long-lived** — idle shutdown applies only to workers and testers. Both knowledge agents stay up for the life of the epic.
- **`project roster` shows session IDs and tickets** — supports reboot recovery without `herdr agent list`.

## 0.3.0

- **Removed `HERDR_ENV=1` from skill descriptions** — agents were misreading it as a runtime gate and refusing to use `project prompt`. All skills now say "Requires Herdr" instead.
- **Librarian fetches origin/main on every merge signal** — prevents stale local checkout from giving workers wrong information about merged code.
- **Agents route questions outside their scope** — librarian forwards domain questions to researcher instead of researching itself; orchestrator forwards to librarian or researcher instead of grepping the codebase.
- **Workers retarget PRs when merging another worker's branch** — PR base changes to the upstream branch so the diff only shows incremental work.
- **Orchestrator shuts down idle workers** — finished workers with no next ticket get `/exit`. Resume later via session ID if needed.
- **Default to fresh workers** — reuse only when the context window carries implementation details the librarian can't summarize.

## 0.2.0

- **`project research "<question>"`** — async research command. Routes to researcher if registered, falls back to orchestrator. Checks if the target is busy before sending. Answer comes back via `project prompt <caller>`.
- **Two-phase boot for all agents** — librarian and researcher now follow the same boot pattern as workers: short identity prompt → READY → full assignment payload.
- **Workers message researchers directly** — workers use `project research` instead of routing through the orchestrator.
- **Upgrade notifications** — `herdr plugin update` notifies running orchestrators of skill/CLI changes so they can cascade to agents.

## 0.1.0

- Initial release: orchestrator, worker, librarian, researcher roles
- `project` CLI: init, register, prompt, ask, read, roster, status
- Worktree-per-ticket workflow
- Dependency DAG with wave-based scheduling
- Librarian tracks merged diffs, manages Jira transitions, advises on worker reuse
