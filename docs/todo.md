# Todo

Small items noticed along the way and parked for later. Bigger ideas go in [roadmap.md](roadmap.md).

## From the dual-mode step 1 dry run (2026-11-25)

- **The watcher sends its WATCH ack back to the librarian:** one extra signal per WATCH, against signal economy. It didn't happen on the step 2 run, so it's model variance. Still worth one line in the watcher's role definition: acknowledge only in your own output.
- **The librarian named pane IDs in its output** despite being told not to look them up. It didn't happen on the step 2 run either. If it comes back, check whether `project prompt` echoes the pane ID.


## Other

- **Mod panel buttons for recycle and spinoff.** There's no `project recycle` (a DISTILL takeover is agent-driven today). Spinoff needs a dialog for title, brief and repo, and a defined requester when it's called from outside an agent.
- **Could the watcher be pure shell?** CI polling is mechanical: `gh` checks per PR, then `project prompt <worker>` on failure. A shell loop would cost no tokens while idle. Open question: what judgment does the watcher apply today that a script can't?
