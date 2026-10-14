// Dataview view behind "Work Dashboard.md" (view.css alongside styles its tables).
//   await dv.view("Work/_Global/views/work-dashboard", { section: "<name>" })
// Sections: hours | week | dropped | carried | done | history
// Reads the "TODOs Today" callout of every daily note (archived month folders
// included). Parsed once per change; the five sections share the result.

const DAILIES = "00_Dailies";
const DROPPED_MAX_AGE = 30;   // days; older forgotten tasks stop nagging

async function load() {
  const pages = dv.pages(`"${DAILIES}"`)
    .where(p => /^\d{4}-\d{2}-\d{2}$/.test(p.file.name))
    .sort(p => p.file.name).array();
  // Cache keyed on the notes' mtimes: the five sections share one parse, but any
  // edit (e.g. ticking a checkbox in this dashboard) invalidates it immediately.
  // A time-based cache made ticks look like they bounced back.
  const stamp = pages.map(p => `${p.file.path}:${p.file.mtime?.ts ?? 0}`).join("|");
  const cache = globalThis.__tasksDashboard;
  if (cache && cache.stamp === stamp) return cache.data;
  const ranges = new Map();   // note -> [start, end) lines of its TODOs Today callout
  const seen = new Map();     // task text -> { text, first, last, streak, openAtLast, doneOn }
  //   streak: consecutive open occurrences up to the last one
  //   doneOn: most recent note in which it was ticked (a task can be
  //           ticked and later re-added, so this is not "done for good")
  const perDay = [];          // { name, open, done }
  for (const p of pages) {
    const lines = (await dv.io.load(p.file.path)).split("\n");
    const h = lines.findIndex(l => /^>\s*\[!todo\][+-]?\s*TODOs Today/i.test(l));
    if (h === -1) continue;
    let e = h + 1; while (e < lines.length && lines[e].startsWith(">")) e++;
    ranges.set(p.file.name, [h + 1, e]);
    let open = 0, done = 0;
    for (const l of lines.slice(h + 1, e)) {
      const m = l.match(/^>\s*- \[( |x|X)\]\s*(.+?)\s*$/);   // top-level tasks only
      if (!m) continue;
      const isDone = m[1] !== " "; isDone ? done++ : open++;
      const t = seen.get(m[2]) ?? { text: m[2], first: p.file.name, last: p.file.name, streak: 0, openAtLast: false, doneOn: null };
      t.last = p.file.name; t.openAtLast = !isDone;
      if (isDone) { t.doneOn = p.file.name; t.streak = 0; }
      else if (++t.streak === 1) t.since = p.file.name;   // start of the current open run
      seen.set(m[2], t);
    }
    perDay.push({ name: p.file.name, open, done });
  }
  const data = { pages, ranges, seen, perDay, latest: pages.at(-1) };
  globalThis.__tasksDashboard = { stamp, data };
  return data;
}

const { pages, ranges, seen, perDay, latest } = await load();
const today = dv.date("today").toFormat("yyyy-LL-dd");
const dateDiff = (a, b) => Math.round((new Date(b) - new Date(a)) / 864e5);
const span = (m) => (m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")} min` : `${m} min`);
const note = n => dv.fileLink(pages.find(p => p.file.name === n).file.path, false, n);
const tasksIn = (p, done) => {
  const [a, b] = ranges.get(p.file.name) ?? [0, 0];
  return p.file.tasks.where(t => t.line >= a && t.line < b && (t.parent == null || t.parent < a) && (t.status !== " ") === done);
};

switch (input?.section) {
  case "hours": {
    // Worked time of the current ISO week, from the clock_in / clock_out
    // properties the daily notes record. Must match the worktime view: a closed
    // day has the lunch break deducted, a day still running does not.
    const BREAK_MIN = 30;
    const mins = (v) => {
      const m = String(v ?? "").match(/(\d{1,2}):(\d{2})/);
      return m ? Number(m[1]) * 60 + Number(m[2]) : null;
    };
    const monday = dv.date("today").startOf("week");
    const weekDays = pages
      .filter((p) => p.file.name >= monday.toFormat("yyyy-LL-dd"))
      .map((p) => {
        const fm = app.metadataCache.getFileCache(app.vault.getAbstractFileByPath(p.file.path))?.frontmatter ?? {};
        const a = mins(fm.clock_in), b = mins(fm.clock_out);
        if (a == null) return { page: p, worked: 0, running: false };
        const gross = ((b ?? (new Date().getHours() * 60 + new Date().getMinutes())) - a + 1440) % 1440;
        return { page: p, worked: b == null ? gross : Math.max(0, gross - BREAK_MIN), running: b == null };
      })
      .filter((d) => d.worked > 0 || d.running);

    dv.container.querySelectorAll(".wkhours").forEach((e) => e.remove());
    const box = dv.el("div", "", { cls: "wkhours" });
    if (!weekDays.length) {
      box.createEl("div", { cls: "wkhours-empty", text: "No hours recorded this week yet." });
      break;
    }
    const total = weekDays.reduce((s, d) => s + d.worked, 0);
    const peak = Math.max(...weekDays.map((d) => d.worked), 1);
    for (const d of weekDays) {
      const row = box.createEl("div", { cls: `wkhours-row${d.running ? " is-running" : ""}` });
      row.createEl("span", { cls: "wkhours-day", text: dv.date(d.page.file.name).toFormat("ccc") });
      row.createEl("div", { cls: "wkhours-bar" })
        .createEl("div", { cls: "wkhours-fill", attr: { style: `width:${Math.round((d.worked / peak) * 100)}%` } });
      row.createEl("span", { cls: "wkhours-val", text: span(d.worked) + (d.running ? " ·" : "") });
    }
    const foot = box.createEl("div", { cls: "wkhours-foot" });
    foot.createEl("span", { cls: "wkhours-total", text: span(total) });
    foot.createEl("span", {
      cls: "wkhours-meta",
      text: `${weekDays.length} day${weekDays.length === 1 ? "" : "s"} · Ø ${span(Math.round(total / weekDays.length))}` +
        (weekDays.some((d) => d.running) ? " · today still running" : "")
    });
    break;
  }
  case "week": {
    // Unticked tasks from every note of the current ISO week (Mon-Sun), each task
    // once - in its most recent note - and skipped if it was ticked later on.
    const start = dv.date("today").startOf("week"), end = start.plus({ days: 6 });
    const week = pages.filter(p => p.file.name >= start.toFormat("yyyy-LL-dd") && ranges.has(p.file.name)).reverse();
    const shown = new Set(), open = [];
    for (const p of week)
      for (const t of tasksIn(p, false)) {
        const text = t.text.trim();
        const doneOn = seen.get(text)?.doneOn;
        if (shown.has(text) || (doneOn && doneOn > p.file.name)) continue;   // ticked later on
        shown.add(text); open.push(t);
      }
    dv.paragraph(`KW ${start.toFormat("WW")} · ${start.toFormat("ccc d")} – ${end.toFormat("ccc d LLL")} · ${week.length} note${week.length === 1 ? "" : "s"}`);
    open.length ? dv.taskList(dv.array(open), true) : dv.paragraph("Nothing open this week. 🎉");
    break;
  }
  case "dropped": {
    const rows = [...seen.values()]
      .filter(t => latest && t.openAtLast && t.last !== latest.file.name && dateDiff(t.last, latest.file.name) <= DROPPED_MAX_AGE)
      .sort((a, b) => b.last.localeCompare(a.last));
    rows.length
      ? dv.table(["Task", "Last seen", "Days ago", "Carried"],
        rows.map(t => [t.text, note(t.last), dateDiff(t.last, today), t.streak > 1 ? `${t.streak}×` : ""]))
      : dv.paragraph("Nothing dropped. 👌");
    break;
  }
  case "carried": {
    const rows = [...seen.values()]
      .filter(t => latest && t.openAtLast && t.last === latest.file.name && t.streak > 1)
      .sort((a, b) => b.streak - a.streak);
    rows.length
      ? dv.table(["Task", "Since", "Notes", "Days"], rows.map(t => [t.text, note(t.since), `${t.streak}×`, dateDiff(t.since, today)]))
      : dv.paragraph("Nothing carried over. 👌");
    break;
  }
  case "done": {
    const recent = pages.filter(p => dateDiff(p.file.name, today) <= 7 && ranges.has(p.file.name)).reverse();
    const done = dv.array(recent.flatMap(p => tasksIn(p, true).array()));
    done.length ? dv.taskList(done, true) : dv.paragraph("Nothing ticked in the last week.");
    break;
  }
  case "history":
    dv.table(["Note", "Done", "Open", ""], perDay.slice(-10).reverse().map(d =>
      [note(d.name), d.done, d.open, "🟩".repeat(d.done) + "⬜".repeat(d.open)]));
    break;
  default:
    dv.paragraph(`work-dashboard: unknown section "${input?.section}"`);
}
