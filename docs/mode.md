# Project size and role hosting

Status: CLI built 2026-11-25 (`project host` / `promote`, hosted registry entries); skills not updated yet. Started 2026-11-24.

## The idea

Small and large projects are not two modes. They differ only in **which agent hosts each role**.

A role (orchestrator, librarian, researcher, watcher) is an **address**. An agent is a **host**. One agent can host several roles. The full split, where every role has its own agent, is one end of a range. The other end is a single orchestrator hosting every role except workers.

Senders never change. A worker always runs `project prompt librarian "COMPLETE …"` or `project research ask "…"`. The `project` CLI resolves the role to whichever agent hosts it now. A worker doesn't know or care how big the project is.

## Rule: signal once, to a role

Every event is sent **once**, to **one role**. Never the same information to several destinations. Hosting is what makes that cheap on a small project: the signal still goes to `librarian`, and it lands with the orchestrator when the orchestrator hosts that role. There's no fan-out and no "also tell the orchestrator."

## Default: the orchestrator hosts everything

*Decided 2026-11-25.* Every project starts with the orchestrator hosting librarian, researcher and watcher. A role gets its own agent only when it's promoted. So a role always resolves to someone, and senders never need a fallback. CLI (built):
- **`project host <role>`:** the calling agent takes a role. The registry points the role at the caller's terminal, marked as hosted. `project init` / `start` do this for the orchestrator automatically.
- **`project promote <role> --task …`:** the host writes a handoff for that role. Then spawn a dedicated agent seeded from it and point the role at the new agent. The host's terminal is never closed (unlike `--takeover` + `retire`).
- **A message carries its role** (`[librarian] DONE …`) so a host knows which role's rules apply.

The guided tour (`DEMO-`) shows this: it starts small with only workers, and the orchestrator hosting the rest. Then it asks whether to scale up, and promotes the librarian and researcher live.

## Choosing at the start

Staffing is decided when the project starts (`/start-project <key>`), not with a flag:

1. The orchestrator reads the epic and its tickets and works out the scope: ticket count, how wide the dependency graph gets (how many tickets can run at once), number of repos, whether CI needs watching, and whether tickets exist at all.
2. It proposes a staffing plan and asks the user to confirm. For example: "5 tickets, mostly sequential, one repo. I'd stay small: I host librarian and watcher, and workers run one at a time. Or do you want the full rollout?"
3. The user confirms or changes it. The roles get registered to their hosts.

Typical small staffing:
- The orchestrator hosts librarian and watcher. Workers watch their own CI.
- **An epic with no tasks:** spawn a dedicated researcher to fill them in, then keep it around in case it's useful later. Being small doesn't mean refusing a helper that's already earned its place.

Large staffing is today's split.

## Promotion is driven by need

A small project that's growing promotes a role to its own agent when the host is overloaded. Project size isn't the trigger. Signs:

- The orchestrator's context is getting heavy (the context guard fires, or it's near a distill).
- Several workers are running at once, so merged diffs to ingest pile up.
- CI churn is filling the orchestrator's context with polling.

Promoting a role:
1. The host writes a handoff for that role: what it knows *as librarian*, or whichever role it is, kept separate from its orchestrator state.
2. Spawn a dedicated agent for the role, seeded from that handoff.
3. Point the role's registry entry at the new agent. From now on, signals to `librarian` go there.
4. The orchestrator distills. It drops the role's context it was carrying.

The reverse could happen too: a retiring role goes back to the orchestrator.

## Routing details

Settled and built in `scripts/project.sh` (2026-11-25):

- **Registry shape. Settled.** A hosted role's entry is `{pane_id: <host's terminal>, hosted_by: <host role>, hosted_at}`. Several roles share one terminal. The entry keeps its own history keys (`session_id`, `previous_sessions`) while hosted, so a later `promote --resume` can use them. Nothing hosted ever stores the host's session.
- **Callers.** `resolve_caller` picks the entry for the caller's terminal that is *not* hosted, so the signal log's sender is always the real agent's role (`orchestrator`, never `librarian`).
- **Defaults.** `project register orchestrator` (what `start` and a hand-started orchestrator both run) makes the orchestrator host librarian, researcher and watcher, except roles with their own live agent or hosted by someone else. Stopped or missing entries become hosted. `project init` alone only creates the empty registry: it can't know which pane will be the orchestrator (`start` runs it from the user's shell).
- **Hosts follow their terminal.** When the host re-registers on a new terminal (takeover), roles it hosts move with it; the old terminal can then be retired.
- **Which role a message is for. Settled.** A message to a hosted role is prefixed `[to <role>] ` (before `FROM(<sender>):`) by `prompt`, `ask`, `research`, `punt` and spinoff-done. Roles that are the agent's own get no prefix.
- **Hosts know their roles. Settled, in the CLI.** `project host <role>` tells the host what it now holds. A host that messages a role it hosts is refused (`error: you host 'librarian' yourself …`, nothing sent), so a misrouted signal fails loudly instead of landing in its own input. The role's skill text (what to do instead of messaging) is not written yet.
- **Stopping. Settled.** `project stop <role>` on a hosted role un-hosts it: marked stopped, `hosted_by` removed, host untouched (`--close` is ignored). Stopping a host also marks every role it hosts stopped. `dump` and `reset --handoff` ignore hosted roles (the host answers for them).
- **Promotion. Settled.** `project promote <role> --task-file PATH` (or `--task`, or `--resume`) is a spawn of the hosted role. `project spawn <role>` on any hosted role does the same, so start-project's existing `project spawn librarian` keeps working. The host is never stopped, closed or made a `--takeover` predecessor.
- **Lifecycle markers.** `dump` writes `paused_at` (cleared by any register or spawn), `close` writes `closed_at`. The mod's Paused list shows state files with `paused_at`, no `closed_at`, in an app space (`sp…` ids).
- **Role instructions.** A host loads a role's definition (for example `librarian.md`) only when it takes that role on, not upfront. *Still to do in the skills.*
- **Herdr app backend. Not needed so far.** Hosting lives in the registry; labels were not touched. The mod's panel reads `project=`/`role=` labels only, so a hosted role shows no row of its own (the host's row shows). Decide later whether the roster should list hosted roles.

## Open questions

- What should the orchestrator propose by default for a given scope, and should it show its reasoning (ticket count, width) in the proposal?
- How much of the role's rules does a host need: the full role definition, or a condensed "when hosting" section?
- When a role is promoted, does the new agent also get the role's past signal log, or only the handoff?
- Does `DEMO-` need to show the small staffing, the large one, or both?
