# Todo

Small items noticed along the way and parked for later. Bigger ideas go in [roadmap.md](roadmap.md).

## From the dual-mode step 1 dry run (2026-11-25)

- **`project read <role> --lines 40` shows only blank lines right after a spawn.** Claude Code pads the screen, so the last 40 lines are empty. 80 lines worked. Either trim trailing blank lines in `read` or raise the harness's line count.
- **`project prompt … --wait` prints herdr's raw JSON result** to stdout. That's noise in an agent's context. Print nothing, or one line.
- **UNBLOCKED is logged as type `PROMPT`** in the signal log, while READY, STARTING and COMPLETE get their own types. Add it to the type detection.
- **The watcher sends its WATCH ack back to the librarian:** one extra signal per WATCH, against signal economy. Its role definition should say to acknowledge only in its own output.
- **The librarian named pane IDs in its output** despite being told not to look them up. Most likely `project prompt` echoes the pane ID. Drop pane IDs from user-facing CLI output.

## Other

- **The upgrade notice in `setup.sh` tells the orchestrator to have agents reload their skills.** That's a fan-out, which DESIGN.md § "Plugin updates are orchestrator-only" rules out. Reword it to: tell the user what changed and let them decide which agents to recycle.
- **Could the watcher be pure shell?** CI polling is mechanical: `gh` checks per PR, then `project prompt <worker>` on failure. A shell loop would cost no tokens while idle. Open question: what judgment does the watcher apply today that a script can't?
