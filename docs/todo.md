# Todo

Small items noticed along the way and parked for later. Bigger ideas go in [roadmap.md](roadmap.md).

## From the dual-mode step 1 dry run (2026-11-25)

- **`project read <role> --lines 40` shows only blank lines right after a spawn.** Claude Code pads the screen, so the last 40 lines are empty. 80 lines worked. Either trim trailing blank lines in `read` or raise the harness's line count.
- **`project prompt … --wait` prints herdr's raw JSON result** to stdout. That's noise in an agent's context. Print nothing, or one line.
- **UNBLOCKED is logged as type `PROMPT`** in the signal log, while READY, STARTING and COMPLETE get their own types. Add it to the type detection.
- **The watcher sends its WATCH ack back to the librarian:** one extra signal per WATCH, against signal economy. It didn't happen on the step 2 run, so it's model variance. Still worth one line in the watcher's role definition: acknowledge only in your own output.
- **The librarian named pane IDs in its output** despite being told not to look them up. It didn't happen on the step 2 run either. If it comes back, check whether `project prompt` echoes the pane ID.
- **The dry run doesn't start clean.** `project open DRY-RUN` overwrites the leftover state file but keeps the old signal log, so `project log` mixes in earlier runs. The harness should remove `DRY-RUN.json` and its log before `open`, or `open` should rotate the log.

- **The dry run's DAG-complete check depends on the librarian volunteering it.** On the hc run (step 3) the librarian only ACKed the final merge. The librarian's boot prompt in the harness should ask for an explicit `DAG COMPLETE` line.
- **`project open` with a name that already exists** overwrites the state file and loses the earlier workspace id, which orphans that workspace. It should refuse, or reuse the workspace.

- **The dry-run harness says "steps 3-7"** in the Step 4 assignment, but the worker boot prompt has 6 steps. fake-001 noticed and stopped at 6. Also, Step 5's "librarian → you: ACK" overstates it: the librarian ACKs in its own pane.

## Other

- **The upgrade notice in `setup.sh` tells the orchestrator to have agents reload their skills.** That's a fan-out, which DESIGN.md § "Plugin updates are orchestrator-only" rules out. Reword it to: tell the user what changed and let them decide which agents to recycle.
- **Could the watcher be pure shell?** CI polling is mechanical: `gh` checks per PR, then `project prompt <worker>` on failure. A shell loop would cost no tokens while idle. Open question: what judgment does the watcher apply today that a script can't?
