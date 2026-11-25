# CLI Reference

The `project` CLI handles inter-agent communication and state management. All agents use it to send signals, ask questions, and look up each other's pane IDs.

## Commands

### `project init <project-name> [workspace-id]`

Create a project state file. Prints `export HERDR_PROJECT=<name>` — wrap in `eval` to set the env var.

### `project register <role>`

Register this agent and signal READY to the orchestrator. Pane ID and session ID are auto-detected. Pass explicit IDs only for crash recovery (`project register <role> <pane-id> [session-id]`).

### `project stop <role>`

Stop an agent. Marks it as stopped in the state file but preserves its session ID, pane ID, and ticket history for later resume. On a hosted role it only un-hosts the role (the host is never stopped or closed); stopping a host also stops the roles it hosts.

### `project host <role>`

The calling agent takes on a role. The registry points the role at the caller's terminal, marked `hosted by <caller>`. Messages for the role arrive prefixed `[to <role>] `. Refused if the role has its own live agent or the caller is not registered. The orchestrator does this automatically for librarian, researcher and watcher when it runs `project register orchestrator`.

### `project promote <role> [spawn options] (--task … | --task-file PATH | --resume)`

Give a hosted role its own agent: a `project spawn` seeded from the handoff the host wrote. The role's entry now points at the new agent; the host is never stopped or closed. Same options as `spawn`. `project spawn <role>` on a hosted role behaves the same.

### `project next-worker`

Print the next available worker name (NATO alphabet: alpha, bravo, charlie...).

### `project assign <role> <ticket-key>`

Track a ticket assignment to a worker. Supports multiple tickets per worker.

### `project prompt <role> <message> [--wait] [--timeout N]`

Send a message to an agent. Fire-and-forget by default. `--wait` blocks until the agent finishes processing.

### `project ask <role> <question> [--timeout N] [--lines N]`

Send a question, wait for the agent to finish, and print its response to stdout. Blocking.

### `project read <role> [--lines N]`

Read an agent's recent pane output. Non-blocking. Default: 40 lines.

### `project research <question>`

Ask a domain question routed to the researcher agent. Async — the answer comes back via prompt.

### `project roster`

Print the current role-to-pane-ID map. Hosted roles show the host's pane and `hosted by <host>`.

### `project status`

Show agent states (idle, working, blocked) for all registered roles. A hosted role shows its host's state and `hosted by <host>`.

### `project info`

Print the project name, workspace ID, and agent count as JSON.

### `project name`

Print the current project's key; exit 1 if the caller is in no project. Backend-neutral — skills use this to detect an existing project and to fill the PR footer instead of reading `$HERDR_PROJECT`.

### `project resolve <role>`

Print the pane ID for a role. For scripting.

### `project session <role>`

Print the session ID for a role. For `--resume` or `SendMessage`.

### `project file`

Print the path to the project state file.

### `project log [--tail N]`

Print the signal log. Default: last 50 entries.

### `project log-decision <decision-type> <payload>`

Log an orchestrator decision (wave transition, spawn, etc.).

### `project dump [--timeout SECS]`

Pause the project: every other live agent writes unreported state to `<role>.final.md`, then is stopped and its pane closed. Hosted roles are skipped (their host answers for them). Writes `paused_at` to the state file; any later `register` or `spawn` clears it. The mod's Paused list reads it.

### `project close`

Close the project's workspace. Writes `closed_at` first, which keeps the project out of the mod's Paused list.

### `project observe`

Read-only snapshot of the project: agents and their status, recent signals, active blockers, and worktree state. Non-blocking — useful for checking in without interrupting agents.

## Global flags

- `--project <name>` — override `$HERDR_PROJECT`
- `-h`, `--help` — show usage

## Message routing

Messages sent with `project prompt` are automatically prefixed with `FROM(<sender>):` so every agent knows who's talking. Messages without a prefix came from a human. A message for a role the receiver only *hosts* starts with `[to <role>] `, so the host knows which role's rules apply. An agent that messages a role it hosts itself is refused: it is that role.

When an agent messages a stopped agent, the CLI auto-escalates to the orchestrator with a `NEED` signal — the orchestrator decides whether to bring it back.
