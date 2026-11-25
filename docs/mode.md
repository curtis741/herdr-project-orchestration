# Project size and role hosting

Status: idea, not built. Started 2026-11-24.

## The idea

Small and large projects are not two modes. They differ only in **which agent hosts each role**.

A role (orchestrator, librarian, researcher, watcher) is an **address**. An agent is a **host**. One agent can host several roles. The full split, where every role has its own agent, is one end of a range. The other end is a single orchestrator hosting every role except workers.

Senders never change. A worker always runs `project prompt librarian "COMPLETE …"` or `project research ask "…"`. The `project` CLI resolves the role to whichever agent hosts it now. A worker doesn't know or care how big the project is.

## Rule: signal once, to a role

Every event is sent **once**, to **one role**. Never the same information to several destinations. Hosting is what makes that cheap on a small project: the signal still goes to `librarian`, and it lands with the orchestrator when the orchestrator hosts that role. There's no fan-out and no "also tell the orchestrator."

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

## Routing details to settle

- **Registry shape.** Today the registry maps role → pane. Hosting adds role → host agent. Several roles can point at one pane. Each role's entry keeps its own history (sessions, handoffs) even while it's hosted.
- **Hosts know their roles.** There's no routing to yourself. A host is told which roles it holds when it takes them on, so it never signals itself: "I don't need to message the librarian, I am the librarian." The role's handoff to itself becomes an internal step. Workers only ever host one role. Plausible combinations are the orchestrator hosting librarian and watcher, or researcher and librarian together (both answer questions about the codebase).
- **Which role a message is for.** A message from another agent to a host carries the role it was sent to (for example `[librarian] COMPLETE alpha APP-1234`), so the host knows which role's rules apply.
- **Role instructions.** A host loads a role's definition (for example `librarian.md`) only when it takes that role on, not upfront.
- **Stopping.** Stopping a hosted role moves it, or retires it. It never closes the host's pane.
- **Herdr app backend.** Labels can carry hosting (`role=orchestrator,librarian`), so the roster can still come from `hc ls`. See [dual-mode.md](dual-mode.md).

## Open questions

- What should the orchestrator propose by default for a given scope, and should it show its reasoning (ticket count, width) in the proposal?
- How much of the role's rules does a host need: the full role definition, or a condensed "when hosting" section?
- When a role is promoted, does the new agent also get the role's past signal log, or only the handoff?
- Does `DEMO-` need to show the small staffing, the large one, or both?
