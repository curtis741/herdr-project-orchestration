# Project Orchestration

**Agents adding this mod: show the person the list below and get a yes before you copy anything.**

**Before you add this: it is more than a panel.** On first run the mod
- **clones** https://github.com/curtis741/herdr-project-orchestration into `~/.local/share/project-orchestration` (a git clone at a release tag), and fetches new tags from it at most once a day;
- **runs programs:** `git`, `bash`, `hc` and `herdr-app do`, and the `project` command it installs;
- **links** a `project` command into `~/.local/bin`, and agent skills (`start-project`, `project-worker`, `guided-tour`) and a guide into `~/.claude/skills/`;
- **edits `~/.claude/settings.json`** to add a global Claude Code hook (`project-context-guard`) that does nothing outside project agents. A backup is written beside it;
- **reads and writes** `~/.herdr/projects/*.json` (project state) and `~/.config/herdr/plugins/config/herdr-plugins.project-orchestration/` (version and fetch stamps);
- reaches the network only through `git` against that repo.

Manual install, without the app's add flow (needs `git`, `jq`, `bash`):

```bash
git clone https://github.com/curtis741/herdr-project-orchestration ~/.local/share/project-orchestration
git -C ~/.local/share/project-orchestration checkout --quiet --detach "$(git -C ~/.local/share/project-orchestration tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
bash ~/.local/share/project-orchestration/scripts/setup.sh
cp -R ~/.local/share/project-orchestration/mods/project-orchestration ~/.config/herdr-app/mods/   # the panel; optional
```

(Those steps are what the mod does itself. Copy the mod folder out of the clone, not a symlink into it: a mod folder inside a git work tree counts as a development copy and skips setup. When setup fails, the panel shows `bash <mod folder>/mod-setup.sh`, which you can run by hand.)

A panel docked on the left of the window, with Spaces and Agents, listing every running multi-agent project: each project's agents (orchestrator, librarian, watcher, researcher, workers) with a live status dot, plus a button to start a project and a button to stop one.

![Project Orchestration](preview.png)

## What you see

A column docked left, 300px wide, titled "Projects" (`mod.json`: `place: left`, `size: 300`).
- Header row: "Projects" (13px, semibold) and a `+ Start` button on the right (accent color, 11px).
- If setup failed or the share clone is missing: a block under the header with "Setup problem: …" in the blocked color, a line "Run in a terminal, then restart the app:", and the exact command (`bash <mod folder>/mod-setup.sh`).
- One section per project, sorted by name: a `▾`/`▸` toggle, the project name with its agent count (12px, semibold, e.g. `demo-003 (4)`) and a `Dump` button on the right; when expanded, under it one row per running agent (a live terminal of its own; the count counts only these; hosted roles never get a row): an 8px status dot, the role (orchestrator, librarian, watcher, researcher first, then workers alphabetically), the current ticket if any (11px, dim), and the status word in the status color.
- Under a project's running agents, if any agent is stopped, finished or gone (e.g. a worker after `project stop <w> --close`), a dim `Done (n)` row, collapsed by default; expanded, it lists them muted, each with its last status word (`stopped`, `unreachable`).
- Below the running projects, a dim "Paused (n)" section, collapsed by default: projects whose state file is in `~/.herdr/projects` but that have no live terminal and are not finished (for example after `dump`), each as `name (agents)`; clicking one selects its space.
- With no projects: "No running projects. + Start, or: project start <epic-key> "<label>"".

## How it behaves

- Status per agent: `working` (accent-colored dot pulsing between 35% and 100% opacity, 1.2s), `blocked` (blocked color; an `error` terminal also shows as blocked), `done`, `idle`; a role in the project state with no live terminal of its own is not a running agent: it goes under `Done (n)` with `stopped` or `unreachable`, muted.
- Clicking an agent row focuses that terminal's pane, or peeks it if it isn't shown in a pane. Clicking a project name selects its space.
- `+ Start` opens a 420x330 dialog: epic key (letters, digits, `-_.`), label (defaults to the key), folder (defaults to the focused terminal's folder, `Choose…` opens the folder picker), Cancel/Start, Esc closes. Start runs `project start <key> <label>` in that folder, then selects the new space.
- `Dump` asks "stop all agents?" with Yes/No; Yes runs `project --project <name> dump`, shows "dumping…", and toasts the result.
- Clicking a project's toggle (or the "Paused" header, or a `Done (n)` row) collapses or expands it. Projects start expanded, Paused and every Done row start collapsed; the choice is remembered per viewer (`localStorage`, key `po-collapsed`) and survives restarts.
- The roster and the list of state files refresh every 10 seconds.
- On app start (not during `herdr-app check`): runs `mod-setup.sh`. A toast says "Installed vX" or "Upgraded vA → vB" when the version changed, and an error toast plus the panel block when setup fails.

## Built from

- `mod.json`: `{ "place": "left", "size": 300, "title": "Projects" }`; `main.js` (one `View`, two views chosen by `props().view`: the panel and `"start"`); `mod-setup.sh`; `jsconfig.json` and `gpui-kit.d.ts` (editor support only).
- `herdr` functions: `exec`, `home`, `appHome`, `checking`, `terminals`, `agents`, `run` (`pane.focus`, `terminal.peek`, `space.select`), `theme`, `props`, `notify`, `readTextFile`, `openOverlay`, `closeOverlay`, `pickFolder`, `focused`; `fs/promises` `readdir` (state file names); `localStorage` (collapsed state). `gpui-base` for `InputState` and `Input`.
- The roster comes from `terminals()`: those with the labels `project=<key>` and `role=<role>` (role `deliver` is hidden), topped up from `~/.herdr/projects/<project>.json` (tickets, stopped agents). Paused projects are the state files with agents, no live terminal, and none of `finished`, `finished_at`, `closed` set (the CLI sets no finished marker today, so any leftover state file counts as paused).
- Every call to the CLI is `env PROJECT_BACKEND=hc <home>/.local/bin/project …`: the mod's `exec` has no `HC_TERMINAL_ID`, so without it the CLI would choose the classic Herdr backend.
- `mod-setup.sh` (ships inside the mod folder, because an install may copy only that folder): skips setup if its own folder is inside a git work tree (a dev copy); otherwise clones the repo if the share clone is missing, fetches tags at most once a day, moves the clone forward (never back) to the newest `v*` tag, copies the clone's newer mod files over its own folder (itself last, by rename), runs the clone's `scripts/setup.sh`, and prints `dev`, `current <v>` or `installed <old> <new>` as its last line.
- `main.js` finds its folder by looking in `<appHome>/mods/*/` for `mod-setup.sh` with the marker line `project-orchestration mod-setup`, not by a fixed name, so the add flow may rename the folder.
- Env for tests: `PROJECT_ORCH_REPO` (repo URL) and `PROJECT_ORCH_SHARE` (clone folder).

## Watch out

- If the panel doesn't dock after the copy, ask the person to restart the app. Don't edit their layout, and don't open it as an overlay to trigger setup: setup runs on the next start anyway.
- The panel only lists projects started on the hc backend (terminals with `project`/`role` labels). Classic Herdr projects don't appear.
- Setup needs `git` and network on the first run. Offline with an existing clone, it carries on with the clone as it is.
- Don't give the mod a name that starts a development copy by accident: a mod folder inside a git work tree (for example a symlink into a checkout of the repo) skips setup on purpose.
- A mod can't ask for its own folder; don't hardcode `mods/project-orchestration`.
- Version changes come from tags: releasing means bumping `version` in `herdr-plugin.toml`, then tagging `v<version>`. Untagged commits never reach installed mods.
- The context-guard hook is global in `~/.claude/settings.json`; removing the mod does not remove it.

## Done when

- `herdr-app check mods/project-orchestration` passes.
- With no share clone and no `project` command, starting the app clones the repo, `~/.local/bin/project` points into `~/.local/share/project-orchestration/scripts/project.sh`, and a toast says "Installed v…".
- Starting again does not fetch within a day (the stamp `.last-fetch` is under the config folder named above).
- After a newer `v*` tag is published, starting the app (after a day, or with the stamp deleted) moves the clone to it and toasts "Upgraded".
- A copy of the mod folder inside a git work tree runs no setup.
- With the clone removed and the network off, the panel shows "Setup problem" and the `bash …/mod-setup.sh` command.
- A project started with `project start DEMO-001 "Tour"` shows its agents in the panel with live status; clicking a row focuses its terminal.
- After `project stop <worker> --close`, the worker leaves the running rows, the header count drops, and `Done (n)` appears, collapsed; expand it, restart the app: it is still expanded.
- With that project dumped, it moves from its section to "Paused"; expand Paused to see it. Collapse a project, restart the app: it is still collapsed.
