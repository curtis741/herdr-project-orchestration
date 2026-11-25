# Dual-mode adoption: plugin (CLI) or mod (app)

Status: steps 1–5 done (5 by real use), 6 not wanted yet. Written 2026-11-24.

## Goal

Run project orchestration from either:
- **classic Herdr**, as a plugin (`herdr-plugin.toml`, the `herdr` CLI), which is what exists today; or
- **the Herdr app**, as a mod (`~/.config/herdr-app/mods/project-orchestration/`), driving terminals through herdr-core (`hc`) and window commands (`herdr-app do`).

The skills, the signal protocol and the `project` CLI interface stay the same. Only the transport underneath changes.

## Why a mod

The Herdr app has no plugin system. A mod is the only way to package for it. Mods are trusted code: they can run any program (`exec`, `hc`), call any app command (`run`), and read and write files. So a mod can carry the whole system:
- **A panel** in place of `[[actions]]`: a live roster with agent states and click-to-focus, plus recycle, dump and spinoff buttons.
- **A start dialog** that asks for the epic key and label. Plugin actions can't take arguments, which is why "Start a project" today only prints usage.
- **Install and upgrade:** `init()` runs `setup.sh` when the mod's version changes, guarded by `checking()`. `setup.sh` then tells the running orchestrator about the upgrade. Today it sends a fixed "upgraded vA → vB" note, not the CHANGELOG entry (see todo.md). This replaces the build hook and the `herdr plugin update` flow.

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
5. **Checked by real use, not by hand (decided 2026-11-25).** The first real projects on the app exercise these paths: more than one worker at a time (naming), spinoff, `dump` / `reset --handoff`, `recover`, `--resume` keeping its session id, and distilling an agent while workers keep running. Worst case, one of them breaks and an agent does that step by hand with `hc`/`herdr-app do`. No work is lost: the predecessor stays alive in a takeover, and dump leaves stuck agents running. Fix bugs as they show up.
6. **Install from one place (in progress, 2026-11-25).** Design below, under *Install and upgrade*. Listing on herdr.dev (the `herdr-mod` topic and `preview.png`) stays out until it's wanted.

`DOG-` isn't used for this work. The steps are sequential, so there's no parallel work for the orchestration to manage, and a dog-food run tests coordination, not the transport layer.

## How to run it

One orchestrating session, starting fresh from this file, plus one fresh worker per step (step 1 split by file). Each worker reports with `hc send` when done or stuck. The orchestrator reviews `git diff` and runs the step's check, rather than reading the worker's screen. The user approves commits and pushes. This is the small staffing from [mode.md](mode.md) in practice.

## Install and upgrade

One home for the code: **`~/.local/share/project-orchestration`, a git clone at a release tag.** Every installed link points into it, whether the plugin, the mod or both are installed. The dev repo is a working copy that nothing links to, so running projects change only when a release is tagged.

| Script | Run by | Does |
|---|---|---|
| `scripts/plugin-setup.sh` | the plugin's build hook | Brings the share clone forward to at least the plugin checkout's version (clone if missing; fetch and check out that tag or commit; never backwards), then runs the clone's `scripts/setup.sh`. |
| `mods/project-orchestration/mod-setup.sh` | the mod's `init()` | Brings the share clone forward to the newest release tag (clone if missing; fetch at most once a day; never backwards). If the clone's mod files are newer, copies them over its own folder. Then runs the clone's `scripts/setup.sh`. It ships inside the mod folder, because a herdr.dev install copies only that folder. |
| `scripts/setup.sh` | only the two above, only from inside the share clone | Normalizes: refuses to run from anywhere else. Links the CLI, skills, guide and context-guard hook from the clone, and reports any link that pointed elsewhere (an old plugin checkout, a dev repo) before repointing it. On a version change, sends the upgrade notice to running orchestrators. |

- **Releasing** is: bump `version` in `herdr-plugin.toml`, then tag `v<version>` and push. Mod users pick it up on the next app start. Plugin users pick it up with `herdr plugin update`. Both end at the same clone, so an older install never rolls back a newer one.
- **Developing:** call `scripts/project.sh` by its full path, the way the dry runs did. To work on the panel, symlink the repo's mod folder as `project-orchestration-dev`. Its `init()` sees that it sits in a git work tree and skips setup.
- **`RECIPE.md`** (repo root) is the brief the app's add flow reads. Up front it says that the mod clones this repo into `~/.local/share`, runs `git`, `hc` and `herdr-app do`, links a `project` command and skills, and installs a global Claude Code hook. It gives the setup command for a manual install.
- If the panel can't find the share clone, it says so and shows the setup command, instead of failing silently.

## Open

- Does the classic `herdr` CLI keep working alongside the app long term, or is it on its way out? That decides how long the classic backend is worth keeping.
- Hosted roles on the hc backend: is a label enough, or is the registry still needed for role → host?
- What should the CHANGELOG-on-upgrade trigger be when the mod is a dev symlink and its version doesn't change on `git pull`?
- After step 5: walk through install and upgrade end to end with the user, and how `setup.sh` runs under the plugin (build hook) versus the mod (`init()`).

## Progress

- Branch `dual-mode`. Step 1 is split as follows: `dual-1-cli` (project.sh + setup.sh, which defines the subcommand interface) runs first, then four parallel workers, one per skill file: start-project/SKILL.md, DESIGN.md, dry-run-project, guided-tour. A strict per-file split would have had every worker editing project.sh.
- Checks for steps 1–2: the orchestrator runs in the Herdr app, so `dry-run-project` runs in a new classic workspace (`herdr workspace create`) and its result is read with `herdr agent read`.
- Steps 1–2 done (`eb08eec`, `925ddaf`). Step 3 passed `dry-run-project` on both the app (hc) and classic.
- **Installed symlinks point at this repo** (since step 3): `~/.local/bin/project`, `~/.local/bin/project-context-guard`, and `~/.claude/skills/{start-project,project-worker,dry-run-project,guided-tour,PROJECT_GUIDE.md}`. `hc run` can't pass env, so agents spawned on hc run whichever `project` is on PATH, and the hc backend can only be tested this way. Undo with `herdr plugin update`, or by re-running the plugin's setup.

- Step 3 is committed (`007ddd2`). Step 4 passed `DEMO-` on the app, started from the mod's Start dialog. Everything stayed in one space, and the full signal chain ran, including the automatic TASK_READY → worker spawn.

### Step 4 decisions (mod)

- The mod is at `mods/project-orchestration/` and runs as a dev symlink from `~/.config/herdr-app/mods/`. The panel builds its roster from the `project=`/`role=` labels on terminals, plus the state files. It has a Dump button and a Start dialog (key, label, folder). `init()` runs `setup.sh` when the version in `herdr-plugin.toml` differs from the installed one.
- When the mod runs `project`, there is no `HC_TERMINAL_ID` in its environment, so the mod calls it as `env PROJECT_BACKEND=hc project …`.
- Skills get the project key from `project name`, never from `$HERDR_PROJECT`. On hc, that variable is filled from the terminal label.
- The guided tour follows one rule: whoever needs the user asks, with AskUserQuestion, in their own pane. The orchestrator asks only orchestration questions.

### Step 3 decisions (hc backend)

- **Backend choice:** `HC_TERMINAL_ID` set and `HERDR_ENV` unset → hc; otherwise classic. `PROJECT_BACKEND=hc|herdr` overrides.
- **Contract additions:** `be_spawn` creates the terminal, starts the agent and delivers the first task in a single call. Its `--pre-task` hook registers the role before the agent can run anything (classic: between agent start and the prompt, as before; hc: before `hc run`, because names are deterministic). Also `be_self`, `be_self_workspace` and `be_self_project`.
- **Project identity on hc:** hc can't inject `HERDR_PROJECT`, so the CLI reads the calling terminal's `project` label.
- **Session id on hc:** hc has no session API. `be_spawn` passes `--session-id <uuid>` and stores it as a `session=` label. Not verified: whether `--resume` keeps that id.
- **Names:** `<project>-<role>`. Names longer than 32 characters become the first 21 plus a hash. A name that's taken gets `-2`, `-3`, and so on (a takeover successor becomes `…-2`).
- **Waits:** on hc, a `--wait` (prompt and spawn) keeps waiting while `hc wait` returns `reason: message`, until the target's turn ends or the deadline set at the start passes.

### Open after step 3 (for steps 4–5)

- `project init` without a workspace id leaves `workspace_id` empty on hc: a hand-started orchestrator in the app can't spawn. It should probably default to `be_self_workspace`.
- ~~`hc send` to a `blocked` agent refuses without `--force`, so signals were lost silently.~~ Fixed in step 4: a prompt to a blocked agent goes into a queue for that agent. A `dlv-<target>` hc terminal delivers it once the agent unblocks, in order. The signal log records QUEUED, DELIVERED and DROPPED.
- ~~**Classic has the same problem:** `herdr agent prompt` rejects a blocked agent, and `be_prompt` sent `ctrl+s` first regardless.~~ Fixed: classic `be_prompt` queues for a blocked agent and delivers in order through the same queue as hc (`scripts/backend/queue.sh`; the deliverer is a `herdr.sh --deliver` process in its own session, so it outlives the sender). Same contract: never forced, never dropped silently, QUEUED/DELIVERED/DROPPED in the signal log. `ctrl+s` is now only sent to an agent that is not blocked. Verified on a real classic agent: `ctrl+s` is a visible no-op on an open AskUserQuestion (menu stays open, agent stays blocked); its effect on a permission prompt is still unverified, which is why it is never sent to a blocked agent.
- `project close` leaves the space's finished root shell in `hc ls --all`.
- Not exercised on hc yet: spinoff, `dump`, `reset --handoff`, `recover`, takeover. These are step 5.
