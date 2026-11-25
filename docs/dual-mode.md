# Dual-mode adoption: plugin (CLI) or mod (app)

Status: plan, not started. Written 2026-11-24.

## Goal

Run project orchestration from either:
- **classic Herdr**, as a plugin (`herdr-plugin.toml`, the `herdr` CLI), which is what exists today; or
- **the Herdr app**, as a mod (`~/.config/herdr-app/mods/project-orchestration/`), driving terminals through herdr-core (`hc`) and window commands (`herdr-app do`).

The skills, the signal protocol and the `project` CLI interface stay the same. Only the transport underneath changes.

## Why a mod

The Herdr app has no plugin system. A mod is the only way to package for it. Mods are trusted code: they can run any program (`exec`, `hc`), call any app command (`run`), and read and write files. So a mod can carry the whole system:
- **A panel** in place of `[[actions]]`: a live roster with agent states and click-to-focus, plus recycle, dump and spinoff buttons.
- **A start dialog** that asks for the epic key and label. Plugin actions can't take arguments, which is why "Start a project" today only prints usage.
- **Install and upgrade:** `init()` runs `setup.sh` when the mod's version changes, guarded by `checking()`, and sends the CHANGELOG entry to the running orchestrator. This replaces the build hook and the `herdr plugin update` flow.

The app's own guide, written by the app on every start, is `~/.config/herdr-app/AGENTS.md`, with the full API in `herdr.d.ts` and `gpui-kit.d.ts` beside it. `hc --skill` and `herdr-app --skill` print the agent manuals.

## Decisions

- **Mod name:** `project-orchestration`, matching the plugin id. `project` alone is too generic: a name already taken on herdr.dev gets renamed on install.
- **Never use `hc` parent/child: always `--no-parent`.** Parent and child in `hc` is a hierarchy plus lifecycle coupling: children die with their parent, and notes are typed into the parent automatically. Both conflict with this system, where agents collaborate as peers, signals are routed through roles, and the orchestrator is distilled while workers keep running. With no parent there's no auto-kill and no automatic notes.
- **Names are addresses: `<project>-<role>`,** for example `app-1234-librarian`, `app-1234-alpha`. `hc --name` is unique across all live terminals on the machine (`a-z 0-9 - _`, at most 32 characters), so the project prefix is required. Workers keep the alpha/bravo/… scheme from `next-worker`.
- **Labels:** `--label project=<key> --label role=<role>`. The roster can come from `hc ls --json` filtered by label, so the registry's pane-ID bookkeeping can mostly go away. Hosted roles ([mode.md](mode.md)) need either a label listing several roles or the registry kept for role → host.
- **Visible vs hidden:** a terminal shows in the window only with `--label herdr.space=<id>`; with no `herdr.tab` label, the app creates a new tab in that space. Agents the user should see get those labels.
- **Backend chosen from the environment:** `HC_TERMINAL_ID` means the hc backend, `HERDR_ENV` means classic Herdr. No config needed, and both apps can be installed side by side.
- **Repo supports both.** Both setups make the same symlinks into the same repo, so switching is `herdr plugin uninstall` followed by installing the mod. Leaving both installed is fine.

## Command mapping

| Classic `herdr` | Herdr app |
|---|---|
| `workspace create` | `herdr-app do space.new '{name, folder, tab, argv, task}'` |
| `tab create` + `agent start` | `herdr-app do tab.new '{space, name, folder, argv, task}'`, or `hc run --bg --no-parent --name … --label herdr.space=<id> -- claude "<task>"` |
| `agent prompt` (+ the `send-keys ctrl+s` draft stash) | `hc send`. It already holds a send while the person is typing (`draft_wait`), so the stash goes away. |
| `prompt --wait` | `hc send --wait` / `hc wait` |
| `agent read` | `hc read <t>` (`--lines N`) |
| `agent get` / `agent list` | `hc get` / `hc ls --json`, which report working, done or blocked |
| `pane close` / `tab close` / `workspace close` | `hc kill` / `herdr-app do tab.close` / `herdr-app do space.close` |
| `tab rename` | `herdr-app do tab.rename` |

Put the first task in the launch (`task` / `hc run … "<task>"`), not a later send: a send to a booting agent can be dropped. Check `first_message.sent` in the launch result.

## Target layout

```
scripts/
  project.sh            # same CLI, same subcommands
  backend/herdr.sh      # spawn, send, read, status, close, list → herdr
  backend/hc.sh         # same functions → hc / herdr-app do
  setup.sh              # shared: symlink CLI + skills, install context guard
herdr-plugin.toml       # plugin manifest → build hook runs setup.sh
mods/project-orchestration/
  mod.json, main.js     # panel; init() runs setup.sh
skills/                 # unchanged, shared
```

While developing, `~/.config/herdr-app/mods/project-orchestration` is a symlink to `mods/project-orchestration/` in this repo.

**Nothing here publishes.** The app picks up a mod by its folder being under `~/.config/herdr-app/mods/`. There's no manifest to register, and `mod.json` only says where the panel docks. Listing on herdr.dev happens only when a public repo gets the `herdr-mod` topic (plus `RECIPE.md` and `preview.png`). Until step 6, don't add that topic.

## Steps

1. **Route every direct `herdr` call in the skills through a `project` subcommand,** still on the classic backend. There are 68 today: start-project/SKILL.md 27, dry-run-project 21, guided-tour 11, DESIGN.md 9, plus 3 in setup.sh. Afterwards the skills only see `project <cmd> <role>`, never a pane ID or terminal name. Split this step by file. The test harnesses have to be ported here too, or they keep testing the old path.
   *Check:* `dry-run-project` passes on classic Herdr.
2. **Split `project.sh` into the CLI plus `backend/herdr.sh`,** with no behaviour change.
   *Check:* `dry-run-project` again.
3. **Add `backend/hc.sh`:** `--no-parent`, `<project>-<role>` names, `project`/`role` labels, roster from `hc ls`.
4. **Add the mod:** panel, start dialog, setup and changelog in `init()`. Run `herdr-app check` after every change.
   *Check for 3 and 4:* `DEMO-` on the app. It covers spawn, send, read, roster and close.
5. **Targeted checks on the app by hand,** for what the demo doesn't cover: more than one worker at a time (naming), spinoff, `dump` / `reset --handoff`, `recover`, and distilling the orchestrator while workers keep running. Or run the first real project on the new backend and watch those paths.
6. **Later, only if wanted: list on herdr.dev.** A herdr.dev install copies only `mods/<name>/`, not the repo root, so the mod's `init()` would clone the repo at a pinned tag and run `setup.sh`. A listing also needs `RECIPE.md`, `preview.png` and the `herdr-mod` repo topic.

`DOG-` isn't used for this work. The steps are sequential, so there's no parallel work for the orchestration to manage, and a dog-food run tests coordination, not the transport layer.

## How to run it

One orchestrating session, starting fresh from this file, plus one fresh worker per step (step 1 split by file). Each worker reports with `hc send` when done or stuck. The orchestrator reviews `git diff` and runs the step's check, rather than reading the worker's screen. The user approves commits and pushes. This is the small staffing from [mode.md](mode.md) in practice.

## Open

- Does the classic `herdr` CLI keep working alongside the app long term, or is it on its way out? That decides how long the classic backend is worth keeping.
- Hosted roles on the hc backend: is a label enough, or is the registry still needed for role → host?
- What should the CHANGELOG-on-upgrade trigger be when the mod is a dev symlink and its version doesn't change on `git pull`?
- After step 5: walk through install and upgrade end to end with the user, and how `setup.sh` runs under the plugin (build hook) versus the mod (`init()`).

## Progress

- Branch `dual-mode`. Step 1 is split as follows: `dual-1-cli` (project.sh + setup.sh, which defines the subcommand interface) runs first, then four parallel workers, one per skill file: start-project/SKILL.md, DESIGN.md, dry-run-project, guided-tour. A strict per-file split would have had every worker editing project.sh.
- Checks for steps 1–2: the orchestrator runs in the Herdr app, so `dry-run-project` runs in a new classic workspace (`herdr workspace create`) and its result is read with `herdr agent read`.
