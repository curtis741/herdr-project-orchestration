# CLI Reference

The `project` CLI handles inter-agent communication and state management. All agents use it to send signals, ask questions, and look up each other's pane IDs.

## Commands

### `project init <project-name> [workspace-id]`

Create a project state file. Prints `export HERDR_PROJECT=<name>` — wrap in `eval` to set the env var.

### `project register <role>`

Register this agent and signal READY to the orchestrator. Pane ID and session ID are auto-detected. Pass explicit IDs only for crash recovery (`project register <role> <pane-id> [session-id]`).

### `project stop <role>`

Stop an agent. Marks it as stopped in the state file but preserves its session ID, pane ID, and ticket history for later resume.

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

Print the current role-to-pane-ID map.

### `project status`

Show agent states (idle, working, blocked) for all registered roles.

### `project info`

Print the project name, workspace ID, and agent count as JSON.

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

## Global flags

- `--project <name>` — override `$HERDR_PROJECT`
- `-h`, `--help` — show usage

## Message routing

Messages sent with `project prompt` are automatically prefixed with `FROM(<sender>):` so every agent knows who's talking. Messages without a prefix came from a human.

When an agent messages a stopped agent, the CLI auto-escalates to the orchestrator with a `NEED` signal — the orchestrator decides whether to bring it back.
