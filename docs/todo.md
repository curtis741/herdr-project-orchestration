# Todo

Small items noticed along the way and parked for later. Bigger ideas go in [roadmap.md](roadmap.md).

## Other

- **Mod panel buttons for recycle and spinoff.** There's no `project recycle` (a DISTILL takeover is agent-driven today). Spinoff needs a dialog for title, brief and repo, and a defined requester when it's called from outside an agent.
- **Could the watcher be pure shell?** CI polling is mechanical: `gh` checks per PR, then `project prompt <worker>` on failure. A shell loop would cost no tokens while idle. Open question: what judgment does the watcher apply today that a script can't?
