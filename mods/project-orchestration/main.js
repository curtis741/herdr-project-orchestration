// Project orchestration: a live roster of each project's agents (from the project=/role=
// labels the hc backend puts on every terminal, plus the project state file for tickets),
// a Start dialog, a Dump button, and install/upgrade of the CLI + skills (mod-setup.sh → the share clone). All actions go through the `project` CLI; nothing here
// re-implements it. One mod, two views: the panel, and (props.view === "start") the dialog.

import { View, div } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import * as fs from "fs/promises";
import { exec, home, appHome, checking, terminals, agents, run, theme, props, notify,
         readTextFile, openOverlay, closeOverlay, pickFolder, focused } from "herdr";

const MOD = "project-orchestration";
const PROJECT_BIN = () => `${home()}/.local/bin/project`;
// Every exec of the CLI below is `env PROJECT_BACKEND=hc project …`: the mod's exec has no
// HC_TERMINAL_ID, so without it the CLI would pick the classic backend.

const FIXED = ["orchestrator", "librarian", "watcher", "researcher"];
const roleRank = (r) => { const i = FIXED.indexOf(r); return i < 0 ? FIXED.length : i; };

// Install/upgrade: runs mod-setup.sh from this mod's folder. A mod can't ask for its own
// folder name (an add flow may rename it), so we look through mods/ for folders carrying
// mod-setup.sh with this mod's marker line and run each one: they're all copies of this mod,
// and the work is idempotent. mod-setup.sh skips a development copy itself (a mod folder
// inside a git work tree) and prints, as its last line, `dev` | `current <v>` |
// `installed <old> <new>`. We add `folder <path>` lines so the panel can show the command.
// PROJECT_BACKEND=hc so the upgrade note setup.sh sends goes through the hc backend.
const INSTALL_SH = `
found=0
for d in "$1"/*/; do
  s="\${d}mod-setup.sh"
  [ -f "$s" ] && head -n 2 "$s" | grep -q 'project-orchestration mod-setup' || continue
  found=1
  echo "folder \${d%/}"
  bash "$s" || { echo "failed in \${d%/}" >&2; exit 1; }
done
[ "$found" = 1 ] || echo "nofolder"
`;

const PAUSED = "\u0000paused";
const DONE = "\u0000done:"; // + project name: that project's collapsed "Done" row
// Paused = `project dump` wrote paused_at (cleared when an agent registers or spawns again), `project close`
// didn't write closed_at, and the project lives in an app space (ids "sp…"; classic workspaces are "w…"
// and aren't this panel's business). Projects with a live terminal are listed as running instead.
const isPaused = (st) => Boolean(st && st.paused_at && !st.closed_at
  && typeof st.workspace_id === "string" && st.workspace_id.startsWith("sp"));

const stateOf = (s) => (s === "error" ? "blocked" : s || "idle");

// project -> { workspace, rows: [{role, terminal, name, status, ticket}] }, from live terminals,
// topped up with state-file roles that have no live terminal (stopped, or gone). Hosted roles
// (hosted_by, or a stopped one still on its host's terminal) get no row until promoted.
function roster(files) {
  const out = new Map();
  for (const t of terminals()) {
    const L = t.labels ?? {};
    if (!L.project || !L.role || L.role === "deliver") continue; // deliver = queue deliverer, not an agent
    if (t.state && t.state !== "live") continue;
    if (!out.has(L.project)) out.set(L.project, { rows: [] });
    out.get(L.project).rows.push({ role: L.role, terminal: t.address, name: t.name, status: stateOf(t.status) });
  }
  for (const [p, entry] of out) {
    const st = files[p];
    entry.workspace = st?.workspace_id;
    const live = new Set(entry.rows.map((r) => r.role));
    for (const r of entry.rows) r.ticket = st?.agents?.[r.role]?.current_ticket;
    for (const [role, a] of Object.entries(st?.agents ?? {})) {
      if (live.has(role) || a.hosted_by) continue;
      // A stopped hosted role is un-hosted but keeps its host's pane_id: still not its own agent.
      if (a.pane_id && entry.rows.some((r) => r.terminal === a.pane_id && r.role !== role)) continue;
      entry.rows.push({ role, status: a.stopped ? "stopped" : "unreachable", ticket: a.current_ticket });
    }
    const byRole = (a, b) => roleRank(a.role) - roleRank(b.role) || a.role.localeCompare(b.role);
    // Running = has a live terminal of its own; everything else is "Done" (stopped, finished, gone).
    entry.done = entry.rows.filter((r) => !r.terminal).sort(byRole);
    entry.rows = entry.rows.filter((r) => r.terminal).sort(byRole);
  }
  return [...out.entries()].sort((a, b) => a[0].localeCompare(b[0]));
}

// A terminal the app shows in a pane is focused there; a hidden one is peeked.
function focusTerminal(address) {
  if (agents().some((a) => a.address === address)) run("pane.focus", { terminal: address });
  else run("terminal.peek", { terminal: address });
}

const tail = (s, n = 400) => (s ?? "").trim().split("\n").slice(-6).join("\n").slice(-n);

export default class ProjectOrchestration extends View {
  init(_props, cx) {
    this.handle = cx.focus_handle();
    if (props()?.view === "start") return this.initStart(cx);
    this.files = {};
    this.loading = new Set();
    this.confirm = null; // project awaiting "dump?" confirmation
    this.busy = new Set(); // projects with a dump running
    this.names = []; // every project that has a state file (for the Paused section)
    this.collapsed = this.loadCollapsed(); // per viewer: localStorage, survives restarts
    this.setupErr = null; // set when the share clone is missing or setup failed: {msg, cmd}
    this.scan(cx);
    cx.timer.every(10000, (cx) => { this.scan(cx); this.reload(cx); });
    if (!checking()) this.install(cx);
  }

  // --- install / upgrade -------------------------------------------------------------
  install(cx) {
    cx.spawn(async (cx) => {
      let folder = `${appHome()}/mods/${MOD}`;
      const fail = (msg) => {
        this.setupErr = { msg, cmd: `bash ${folder}/mod-setup.sh` };
        notify({ title: "Project orchestration setup failed", body: msg, level: "error" });
        cx.notify();
      };
      try {
        const r = await exec("env", ["PROJECT_BACKEND=hc", "bash", "-c", INSTALL_SH, "_", `${appHome()}/mods`], { timeout: 180000 });
        const lines = r.stdout.trim().split("\n");
        folder = lines.filter((l) => l.startsWith("folder ")).pop()?.slice(7) ?? folder;
        if (r.code !== 0) return fail(tail(r.stderr || r.stdout));
        const last = lines.filter((l) => /^(installed|current) /.test(l)).pop() ?? lines.pop() ?? ""; // a dev copy beside a real one must not hide its result
        const clone = await exec("test", ["-f", `${home()}/.local/share/project-orchestration/scripts/setup.sh`]);
        if (last.startsWith("dev")) return; // development copy: nothing installed on purpose
        if (last === "nofolder" || clone.code !== 0) return fail("The share clone (~/.local/share/project-orchestration) is missing.");
        this.setupErr = null;
        cx.notify();
        if (last.startsWith("installed")) {
          const [, from, to] = last.split(" ");
          notify({ title: "Project orchestration", level: "success",
            body: from === "none" ? `Installed v${to}` : `Upgraded v${from} → v${to}` });
        }
      } catch (e) {
        fail(String(e.message ?? e));
      }
    });
  }

  // Collapsed state, per viewer. Running projects are open unless listed; "Paused" is closed
  // unless listed under "paused-open". Stored as { "<project>": true|false, "\u0000paused": ... }.
  loadCollapsed() {
    try { return JSON.parse(localStorage.getItem("po-collapsed") ?? "{}") ?? {}; } catch { return {}; }
  }
  // Paused and every project's Done row start collapsed.
  isCollapsed(key) { return key in this.collapsed ? this.collapsed[key] : key === PAUSED || key.startsWith(DONE); }
  toggle(key, cx) {
    this.collapsed[key] = !this.isCollapsed(key);
    try { localStorage.setItem("po-collapsed", JSON.stringify(this.collapsed)); } catch {}
    cx.notify();
  }

  // Names of all project state files, so projects without a live terminal can be listed as paused.
  scan(cx) {
    cx.spawn(async (cx) => {
      try {
        const names = (await fs.readdir(`${home()}/.herdr/projects`))
          .filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5));
        if (names.join() !== this.names.join()) { this.names = names; cx.notify(); }
      } catch { /* no projects folder yet */ }
    });
  }

  // --- panel data --------------------------------------------------------------------
  load(project, cx) {
    if (this.loading.has(project)) return;
    this.loading.add(project);
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(`${home()}/.herdr/projects/${project}.json`);
        this.files[project] = text ? JSON.parse(text) : null;
      } catch { this.files[project] = null; }
      this.loading.delete(project);
      cx.notify();
    });
  }
  reload(cx) {
    for (const p of Object.keys(this.files)) { this.loading.delete(p); this.load(p, cx); }
  }

  dump(project, cx) {
    this.confirm = null;
    this.busy.add(project);
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("env", ["PROJECT_BACKEND=hc", PROJECT_BIN(), "--project", project, "dump"], { timeout: 600000 });
        notify({ title: `${project}: dump ${r.code === 0 ? "done" : "incomplete"}`,
          body: tail(r.code === 0 ? r.stdout : r.stderr || r.stdout), level: r.code === 0 ? "success" : "warning" });
      } catch (e) {
        notify({ title: `${project}: dump failed`, body: String(e.message ?? e), level: "error" });
      }
      this.busy.delete(project);
      cx.notify();
    });
  }

  // --- start dialog ------------------------------------------------------------------
  initStart(cx) {
    this.key = ""; this.label = ""; this.folder = focused()?.cwd ?? home();
    this.err = ""; this.starting = false; this.focusIn = "key";
    this.keyIn = InputState.new({ placeholder: "epic key, e.g. APP-1234" });
    this.labelIn = InputState.new({ placeholder: "label (default: the key)" });
    this.keyIn.on("change", (_e, cx) => { this.key = this.keyIn.value(); cx.notify(); });
    this.labelIn.on("change", (_e, cx) => { this.label = this.labelIn.value(); cx.notify(); });
    this.keyIn.on("submit", (_e, cx) => this.submit(cx));
    this.labelIn.on("submit", (_e, cx) => this.submit(cx));
    this.keyIn.on("focus", (_e, cx) => { this.focusIn = "key"; cx.notify(); });
    this.labelIn.on("focus", (_e, cx) => { this.focusIn = "label"; cx.notify(); });
    this.keyIn.focus();
    cx.timer.after(600, () => this.keyIn.focus());
  }

  submit(cx) {
    const key = this.key.trim();
    if (this.starting) return;
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(key)) { this.err = "Epic key: letters, digits, - _ . only"; cx.notify(); return; }
    this.starting = true; this.err = ""; cx.notify();
    const label = this.label.trim() || key;
    cx.spawn(async (cx) => {
      try {
        const r = await exec("env", ["PROJECT_BACKEND=hc", PROJECT_BIN(), "start", key, label],
          { cwd: this.folder, timeout: 180000 });
        if (r.code !== 0) throw new Error(tail(r.stderr || r.stdout));
        const ws = /workspace (\S+?)[,)]/.exec(r.stderr + r.stdout)?.[1];
        closeOverlay(props().overlay);
        notify({ title: `Started ${key}`, body: `Orchestrator running in "${label}"`, level: "success" });
        if (ws) run("space.select", { id: ws });
      } catch (e) {
        this.err = String(e.message ?? e);
        this.starting = false;
        cx.notify();
      }
    });
  }

  renderStart() {
    const t = theme();
    const p = props();
    const label = (s) => div().pt(14).pb(6).text_size(11.5).text_color(t.dim).child(s);
    const field = (state, name) => Input.new(state).h(36).px(10).rounded(9).border_1()
      .border_color(this.focusIn === name ? t.accent : t.input).bg(t.background).text_size(12.8).text_color(t.foreground);
    const button = (id, text, primary, action) => h_flex().id(id).h(32).px(14).items_center().rounded(8)
      .border_1().border_color(primary ? t.solid : t.input).bg(primary ? t.solid : t.raised)
      .text_color(primary ? t.solid_foreground : t.foreground).text_size(12.5).font_medium().cursor_pointer()
      .hover((s) => s.opacity(0.88)).on_click(action).child(text);
    return v_flex().id("po-start").track_focus(this.handle)
      .on_key_down((e, cx) => { if (e.key === "escape") { closeOverlay(p.overlay); cx.stop_propagation(); } })
      .w_full().min_h(0).p(18).bg(t.popover).text_color(t.foreground)
      .child(h_flex().items_center()
        .child(div().flex_1().text_size(15).font_semibold().child("Start a project"))
        .child(div().text_size(11).text_color(t.dim).child("Esc")))
      .child(label("Epic key"))
      .child(field(this.keyIn, "key"))
      .child(label("Label (space name)"))
      .child(field(this.labelIn, "label"))
      .child(label("Folder (where the orchestrator runs)"))
      .child(h_flex().gap(8).items_center()
        .child(div().flex_1().truncate().text_size(12).text_color(t.muted).child(this.folder))
        .child(button("po-pick", "Choose…", false, (_e, cx) => {
          cx.spawn(async (cx) => { const f = await pickFolder({ prompt: "Use" }); if (f) this.folder = f; cx.notify(); });
        })))
      .when(Boolean(this.err), (el) => el.child(div().pt(10).text_size(11.5).text_color(t.blocked).child(this.err)))
      .child(h_flex().pt(20).gap(8).justify_end()
        .child(button("po-cancel", "Cancel", false, () => closeOverlay(p.overlay)))
        .child(button("po-go", this.starting ? "Starting…" : "Start", true, (_e, cx) => this.submit(cx))));
  }

  // --- panel -------------------------------------------------------------------------
  render(cx) {
    if (props()?.view === "start") return this.renderStart();
    const t = theme();
    const list = roster(this.files);
    for (const [p] of list) if (!(p in this.files)) { this.files[p] = null; this.load(p, cx); }
    const live = new Set(list.map(([p]) => p));
    const paused = this.names.filter((n) => !live.has(n));
    for (const n of paused) if (!(n in this.files)) { this.files[n] = null; this.load(n, cx); }
    const pausedList = paused.filter((n) => isPaused(this.files[n]));
    const color = { working: t.working, blocked: t.blocked, done: t.done, idle: t.idle };
    const mini = (id, text, fg, action) => div().id(id).px(6).py(2).rounded(5).text_size(11).text_color(fg)
      .cursor_pointer().hover((s) => s.bg(t.hover)).on_click(action).child(text);

    const row = (p, r) => {
      const dot = div().w(8).h(8).rounded(4).flex_none().bg(color[r.status] ?? t.dim);
      const el = h_flex().id(`po-${p}-${r.role}-${r.terminal ?? "x"}`).gap(8).items_center().px(12).py(4)
        .when(Boolean(r.terminal), (e) => e.cursor_pointer().hover((s) => s.bg(t.hover)).on_click(() => focusTerminal(r.terminal)))
        .child(r.status === "working" ? dot.loop("opacity", { from: 0.35, to: 1, period: 1200 }) : dot)
        .child(div().flex_1().truncate().text_size(12.5).text_color(r.terminal ? t.foreground : t.muted).child(r.role))
        .when(Boolean(r.ticket), (e) => e.child(div().text_size(11).text_color(t.dim).child(r.ticket)))
        .child(div().w(62).text_size(11).text_color(color[r.status] ?? t.dim).child(r.status));
      return el;
    };

    const section = ([p, entry]) => {
      const confirming = this.confirm === p;
      const open = !this.isCollapsed(p);
      return v_flex().id(`po-proj-${p}`).pb(8)
        .child(h_flex().items_center().px(12).py(6).gap(4)
          .child(div().id(`po-tog-${p}`).w(14).text_size(11).text_color(t.dim).cursor_pointer()
            .on_click((_e, cx) => this.toggle(p, cx)).child(open ? "▾" : "▸"))
          .child(div().id(`po-name-${p}`).flex_1().truncate().text_size(12).font_semibold().text_color(t.foreground)
            .when(Boolean(entry.workspace), (e) => e.cursor_pointer().on_click(() => run("space.select", { id: entry.workspace })))
            .child(`${p} (${entry.rows.length})`))
          .when(this.busy.has(p), (e) => e.child(div().text_size(11).text_color(t.dim).child("dumping…")))
          .when(!this.busy.has(p) && !confirming, (e) =>
            e.child(mini(`po-dump-${p}`, "Dump", t.muted, () => { this.confirm = p; cx.notify(); })))
          .when(confirming, (e) => e
            .child(div().text_size(11).text_color(t.blocked).child("stop all agents?"))
            .child(mini(`po-dump-yes-${p}`, "Yes", t.blocked, (_e, cx) => this.dump(p, cx)))
            .child(mini(`po-dump-no-${p}`, "No", t.muted, () => { this.confirm = null; cx.notify(); }))))
        .when(open, (e) => e.children(entry.rows.map((r) => row(p, r))))
        .when(open && entry.done.length > 0, (e) => {
          const dk = DONE + p;
          const dopen = !this.isCollapsed(dk);
          return e.child(v_flex().id(`po-done-${p}`)
            .child(h_flex().id(`po-done-head-${p}`).items_center().px(12).py(4).gap(4).cursor_pointer()
              .on_click((_e, cx) => this.toggle(dk, cx))
              .child(div().w(14).text_size(11).text_color(t.dim).child(dopen ? "▾" : "▸"))
              .child(div().flex_1().text_size(11.5).text_color(t.dim).child(`Done (${entry.done.length})`)))
            .when(dopen, (x) => x.children(entry.done.map((r) =>
              h_flex().id(`po-done-${p}-${r.role}`).gap(8).items_center().px(12).py(3).pl(26)
                .child(div().flex_1().truncate().text_size(12).text_color(t.dim).child(r.role))
                .child(div().w(62).text_size(11).text_color(t.dim).child(r.status))))));
        });
    };

    const pausedSection = () => {
      const open = !this.isCollapsed(PAUSED);
      return v_flex().id("po-paused").pb(8)
        .child(h_flex().id("po-paused-head").items_center().px(12).py(6).gap(4).cursor_pointer()
          .on_click((_e, cx) => this.toggle(PAUSED, cx))
          .child(div().w(14).text_size(11).text_color(t.dim).child(open ? "▾" : "▸"))
          .child(div().flex_1().text_size(12).font_semibold().text_color(t.dim).child(`Paused (${pausedList.length})`)))
        .when(open, (e) => e.children(pausedList.map((n) => {
          const ws = this.files[n]?.workspace_id;
          return div().id(`po-paused-${n}`).px(12).py(4).pl(26).truncate().text_size(12).text_color(t.dim)
            .when(Boolean(ws), (x) => x.cursor_pointer().hover((s) => s.bg(t.hover)).on_click(() => run("space.select", { id: ws })))
            .child(`${n} (${Object.values(this.files[n].agents ?? {}).filter((a) => !a.hosted_by).length})`);
        })));
    };

    return v_flex().id("po-root").size_full().bg(t.surface).text_color(t.foreground)
      .child(h_flex().items_center().px(12).py(8).gap(8)
        .child(div().flex_1().text_size(13).font_semibold().child("Projects"))
        .child(mini("po-start-btn", "+ Start", t.accent, () =>
          openOverlay({ mod: MOD, props: { view: "start" }, kind: "dialog", width: 420, height: 330 }))))
      .when(Boolean(this.setupErr), (e) => e.child(v_flex().px(12).py(6).gap(4)
        .child(div().text_size(12).text_color(t.blocked).child(`Setup problem: ${this.setupErr.msg}`))
        .child(div().text_size(11).text_color(t.dim).child("Run in a terminal, then restart the app:"))
        .child(div().id("po-setup-cmd").text_size(11).text_color(t.muted).child(this.setupErr.cmd))))
      .child(v_flex().flex_1().overflow_y_scrollbar()
        .when(list.length === 0, (e) => e.child(div().px(12).py(6).text_size(12).text_color(t.dim)
          .child("No running projects. + Start, or: project start <epic-key> \"<label>\"")))
        .children(list.map(section))
        .when(pausedList.length > 0, (e) => e.child(pausedSection())));
  }
}
