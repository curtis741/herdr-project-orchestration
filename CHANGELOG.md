# Changelog

## 0.12.1

- **The researcher asks you directly.** On an ambiguity or decision the code can't settle, it asks with AskUserQuestion in its own pane, at the moment it hits it. It no longer hands decisions to the orchestrator to relay. It tells the orchestrator only when the answer changes tickets or dependencies, or when its question goes unanswered.

## 0.12.0

- **`project recycle <role> [--timeout SECS]`** gives an agent fresh context in one command. It asks the agent to write its distill file, waits (bounded), then spawns the successor as a takeover with the original label, title and cwd. The successor reads the distill file and retires its predecessor. A blocked or stuck agent is left running and the command exits 1. It refuses hosted, unassigned and stopped roles, and the caller's own role. When approving a `DISTILL` request, the orchestrator now runs this instead of the manual ACK / READY / takeover sequence (the manual flow still works).
- **Classic Herdr no longer loses signals to a blocked agent.** A prompt to an agent showing a question or permission prompt is queued and delivered in order once it's free, as on the app. `ctrl+s` is never sent to a blocked agent. The signal log records QUEUED, DELIVERED and DROPPED on both backends.
- **Projects panel** has a Recycle button on each running agent row (inline confirm) and a Spinoff dialog per project (title, brief, repo folder).

## 0.11.0

- **Projects start small.** At startup the orchestrator hosts librarian and researcher. No support agents are spawned. It says so in one line when it confirms the plan. Exception: an epic with no tasks gets a researcher right away to fill them in.
- **Unassigned roles.** The watcher starts with no agent. `project status watcher` prints `unassigned`. `project prompt` to an unassigned role fails at once with "<role> has no agent — do it yourself", with no NEED escalation. Until the watcher has its own agent, workers watch their own PR's CI and the librarian sends no WATCH.
- **Promotion is proposed, not automatic.** The orchestrator suggests giving a role its own agent (AskUserQuestion) when its context gets heavy, 3 or more workers run at once, merged diffs pile up, CI churns, or a research question is expensive. On yes, it writes `$(project dir)/<role>.handoff.md` and runs `project promote <role>`. A promoted agent reads the handoff first.
- **When hosted.** `librarian.md` and `researcher.md` have a short section the orchestrator follows when a `[to <role>]` message arrives. Steps between roles it hosts become its own steps, never messages to itself.

## 0.10.1

- **Role hosting.** The orchestrator hosts librarian, researcher and watcher until a role gets its own agent. `project host <role>` takes a role, and `project promote <role> --task …` moves it to a dedicated agent without closing the host. `project spawn` on a hosted role promotes it. A message delivered to a host starts with `[to <role>]`, so you know which role's rules apply. Senders don't change: always signal the role.
- **Upgrade notice carries the CHANGELOG.** On upgrade the orchestrator gets the new entries. Summarize them for the user and don't message other agents; the user decides whether to recycle any.
- **Quieter CLI output.** `project prompt --wait` prints nothing on success. `project read` skips blank padding and the input box, so `--lines N` returns real content. UNBLOCKED, WATCH, PROJECT_COMPLETE and the DISTILL replies get their own types in the signal log.
- **`project open`** refuses a name whose workspace is still open.
- **Projects panel** docks on the left. Projects are collapsible with an agent count, and paused projects (after `dump`) appear in their own section.
- **Install** pins a fresh clone to the newest release tag and removes stale links left by older installs.
- **Guided tour** starts small (workers only, the orchestrator hosts the rest), then offers to scale up and promotes the librarian and researcher live.

## 0.10.0

- **Runs on the Herdr app as well as classic Herdr.** The `project` CLI chooses its transport from the environment: `hc` in a Herdr app terminal, classic `herdr` otherwise (`PROJECT_BACKEND=hc|herdr` overrides). Skills and signals are the same on both.
- **Skills never handle pane, tab or workspace IDs.** New role-addressed subcommands: `project spawn <role> --task …` (the first task goes in the launch, along with `--resume` and `--takeover`), `project open`/`close` (a project's workspace), `project rename <role>`, `project stop <role> --close`, `project status <role>` (one word), `project retire <role>`, and `<role>@prev` to reach a predecessor after a takeover. `project name` prints the current project's key. Use it instead of `$HERDR_PROJECT`, which isn't set on the app.
- **Signals to a busy agent wait instead of being lost (app).** If the target is showing a question or a permission prompt, the message is queued and delivered in order once it's free. The signal log records QUEUED, DELIVERED and DROPPED.
- **Herdr app mod.** A Projects panel lists live agents with their status and click-to-focus, and has Start and Dump. It installs and upgrades itself from release tags.
- **One install location.** The plugin and the mod both use a single clone, `~/.local/share/project-orchestration`, and every link points into it. Whichever is newer wins, and links that pointed at an older checkout are repointed.
- **Guided tour reworked.** Whoever needs you asks, in its own tab, with AskUserQuestion. The orchestrator asks only orchestration questions.

## 0.9.0

- **`project dump` / `project reset`** — new: wind a project down in one command. `dump` pauses: every other live agent is prompted in parallel (`DUMP — ...`) to write unreported state to `$(project dir)/<role>.final.md` or nothing, then is stopped (session preserved) and its pane closed. `reset` (orchestrator) does the same dump, writes a master-distill template to `orchestrator.reset.md`, and `reset --handoff` spawns a fresh orchestrator that boots from it. Run from outside, `reset` asks the orchestrator to do it. If you receive `DUMP —`, follow it and don't signal anyone.
- **`project spinoff "<title>" [--notify]`** — new: put a throwaway worker on a scoped one-off fix. Any agent (or the user) can run it with a brief on stdin (Problem / Why it matters / Evidence / Fix / Don't touch / Done when). The CLI spawns the worker directly. No orchestrator approval, outside the wave cap, max 2 at once. The PR references the epic, with no ticket. It's fire-and-forget unless `--notify` is passed. Use it when you've scoped a fix; keep using `punt` when you only suspect a problem.
- **Spinoff lifecycle** — the spinoff worker sends `COMPLETE — PR #N for spinoff-<name>` to the librarian as usual. The librarian skips transitions and DAG checks, tells the watcher, and relays to the orchestrator so the user can review. On merge, the librarian ingests and sends `MERGED` to the worker, which runs `project spinoff-done "<outcome>"` to stop and close its tab. The orchestrator gets a `SPINOFF` FYI and doesn't act on it.
- **PR attribution footer** — workers end every PR description with `<project-name> - <role>` (e.g. `app-1234 - bravo`) so you can tell which worker opened which PR.
- **Signals no longer merge into a half-typed message** — every prompt the CLI delivers first stashes any draft in the target pane's input box (Claude Code's Ctrl+S). Claude Code restores the draft after the signal is submitted.

## 0.8.0

- **Project working dir** — `project dir` prints `~/.herdr/projects/<project>/`, now the shared, uncommitted working area for all agents: test plans, context files, cross-agent learnings, test scripts, distill files. Prefix files with your role. Prefer writing a file there and passing the path over pasting large content into prompts.
- **DISTILL handoff reworked** — agents write state to `$(project dir)/<role>.distill.md` (not the worktree). On `DISTILL_READY`, the orchestrator spawns a successor in a **new tab** and passes the file path without reading it. The successor registers, reads the file, can question the old agent by pane ID, then runs `project retire <old-pane>` to close the old tab. Prior session IDs are kept in `previous_sessions`.
- **Prefer distill over compaction** — all roles: request DISTILL before auto-compaction hits. If you were compacted, run `project roster` to confirm you're in a project and re-read your skill.
- **Agent session names** — every `herdr agent start` passes `-- -n <role>`, so terminal titles show the role instead of a boot-prompt summary.
- **`project punt "<problem>"`** — new: hand a suspected problem to the researcher to own. The researcher investigates and acts (ticket, orchestrator, user) instead of sending findings back. `project research` stays for "I need to know this" questions where you want the answer.
- **`project research` no longer rejects a finished researcher** — `done` status was treated as busy; only `working` is now.
- **Reboot env recovery** — if `HERDR_PROJECT` is missing (e.g. a session resumed after a reboot), the `project` CLI resolves the project from the state file that claims the current pane or workspace.

## 0.7.0

- **Signal log and decision audit trail** — every `project prompt` and `project ask` appends to `~/.herdr/projects/<name>.signals.log` with timestamp, sender, receiver, and signal type. `project log` shows the trail; `project log-decision` records orchestrator decisions (wave transitions, spawn choices, reuse). Foundation for debugging stalled waves and post-run analysis.
- **Researcher two-phase model** — researcher now operates in Discovery (front-loaded, maps the system end-to-end) and Ongoing (queryable from existing findings). All findings go to `~/.herdr/projects/<name>/research.md`, which survives restarts. The orchestrator can restart the researcher cleanly — the new instance loads research.md and picks up where it left off.
- **DISTILL protocol** — any agent can send `DISTILL — <reason>` to the orchestrator when context quality degrades. Orchestrator approves (agent writes DISTILL.md, gets restarted fresh with that state) or defers (agent is close to finishing). All role definitions now include distill guidance.
- **Fast-path completion** — orchestrator can mark trivial tasks as fast-path. Workers skip PR and test brief, signal `DONE` directly to the librarian. The librarian handles `DONE` without a preceding `COMPLETE`.
- **`project feedback`** — any agent can log qualitative observations (`project feedback "<note>"`) to a timestamped, role-attributed file. Feeds skill refinement in later sessions without bloating context.
- **Worktree lifecycle rules** — documented creation, cleanup, and orphan detection. `project cleanup` cross-references worktrees with the state file and removes orphans. Orchestrator runs it at project start and end.
- **Recovery after restart** — `project recover` diagnoses the project state after a crash: which agents are reachable, which have resumable session IDs, worktree status, and recent signals. Orchestrator skill includes a full reboot-recovery procedure (resume librarian first, then workers).
- **Merged shutdown/reuse checkpoint** — worker completion is now a single decision point (Step 6): evaluate reuse → assign next ticket or full shutdown (`project stop` + `herdr pane close`). No more separate steps that the orchestrator can skip.
- **Orchestrator communication patterns** — explicit guidance on `project prompt` (fire-and-forget for assignments), `project prompt --wait` (boot prompts only), and `project ask` (blocking questions). Anti-pattern: never `--wait` on worker execution.
- **`project observe`** — read-only snapshot of agents, recent signals, active blockers, and worktree state. Non-blocking status check for humans.
- **Guided tour** — new `/guided-tour` skill. Spawns a librarian and one worker on a fake ticket, pauses at each signal to explain what's happening, and prompts the developer to try messaging agents. Designed for first-time users.
- **Daily auto-check for plugin updates** — the `project` CLI checks once per day (background, non-blocking) and prints a one-liner if the plugin has updates available.
- **Failure modes catalog** — `docs/failure-modes.md` documents known failure modes (librarian lag, signal loss, scope creep, stale worktrees, context collapse, orchestrator SPOF) with symptoms, detection, and recovery.

## 0.6.0

- **`COMPLETE` / `DONE` signal split** — `DONE` is replaced by `COMPLETE` for the common case (PR opened, implementation complete). `DONE` is now optional, only for post-merge verification (data migrations, production checks). Most tickets only send `COMPLETE`.
- **Signals flow through the librarian** — workers send `COMPLETE` and `DONE` to the librarian only. The librarian transitions tickets, stores operational notes, routes to the watcher and orchestrator. Workers no longer signal the orchestrator directly for completion. Reduces duplicate token burn.
- **Watcher agent** — new long-lived CI monitor role (`start-project/watcher.md`). Spawned alongside the librarian at epic start. Receives `WATCH` assignments from the librarian, polls CI status, reports failures directly to workers, reports green to the librarian. Doesn't fix code, doesn't talk to the orchestrator.
- **Signal economy principle** — new guidance in CLAUDE.md and DESIGN.md: minimize inter-agent chatter, one routing point per lifecycle event. Design signals so each event has a single routing agent rather than fanning out to multiple recipients.
- **Workers include operational notes in `COMPLETE`** — deploy timing, environment quirks, fragile steps. The librarian stores these alongside diff summaries for future worker queries.

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
- **Upgrade notifications** — `herdr plugin update` notifies the running orchestrator of skill/CLI changes.

## 0.1.0

- Initial release: orchestrator, worker, librarian, researcher roles
- `project` CLI: init, register, prompt, ask, read, roster, status
- Worktree-per-ticket workflow
- Dependency DAG with wave-based scheduling
- Librarian tracks merged diffs, manages ticket transitions, advises on worker reuse
