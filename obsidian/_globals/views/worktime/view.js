// Work Time widget for the daily notes.
//   await dv.view("Work/_Global/views/worktime")
// Reads the clock_in / clock_out frontmatter properties written by the
// "Daily Clock In" / "Daily Clock Out" templates. view.css alongside styles it.
//
// Loaded ONCE into globalThis by the note's dataviewjs block and called
// synchronously on every later render. That matters: Dataview re-renders a
// block on every index change (~2.5s while you type) by emptying it and
// re-running the script, and the browser only paints that empty state if the
// script yields for real I/O. Going through dv.view() reads two files from the
// vault each time, which is exactly such a yield - hence the flicker. With the
// code cached there is no I/O, the rebuild finishes inside the same task, and
// nothing is ever painted empty.
//
// The widget also redraws itself after a clock button and once a minute while
// the day runs, so it stays correct between Dataview refreshes.

// Deducted once the day is closed off - the lunch break is not worked time.
// The running figure stays gross: while you are still here the break may not
// have happened yet, so taking it off early would understate the morning.
const BREAK_MIN = 30;
// How often the running figure re-ticks. Display granularity is one minute.
const TICK_SECONDS = 60;

const path = dv.current()?.file?.path;
const file = path ? app.vault.getAbstractFileByPath(path) : null;

// Stored as plain "HH:mm" strings, but YAML/Dataview may hand back a number or
// a date object, so go through the text in every case.
const minutes = (v) => {
  const m = String(v ?? "").match(/(\d{1,2}):(\d{2})/);
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
};
const clock = (m) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
const span = (m) => (m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")} min` : `${m} min`);
const elapsed = (from, to) => (to - from + 24 * 60) % (24 * 60);   // tolerate crossing midnight
const net = (m) => Math.max(0, m - BREAK_MIN);                     // minus the break, never negative
const frontmatter = () => (file ? app.metadataCache.getFileCache(file)?.frontmatter ?? {} : {});

// One timer per note, cleared before any redraw, so repeated draws cannot stack
// timers up and a closed-off day leaves none behind.
if (!globalThis.__worktimeTickers) globalThis.__worktimeTickers = {};
const clearTicker = () => {
  if (globalThis.__worktimeTickers[path]) {
    window.clearInterval(globalThis.__worktimeTickers[path]);
    delete globalThis.__worktimeTickers[path];
  }
};

const notify = (msg) => { try { new Notice(msg); } catch { console.warn("worktime:", msg); } };
const writeClock = async (field, offsetMinutes) => {
  if (!file) { notify("Work time: no active daily note"); return; }

  const t = new Date(Date.now() + offsetMinutes * 60000);
  const now = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
  let message = "";

  await app.fileManager.processFrontMatter(file, (fm) => {
    if (fm[field]) {
      message = `Already clocked ${field === "clock_in" ? "in" : "out"} at ${fm[field]} — edit the ${field} property to change it.`;
      return;
    }
    fm[field] = now;

    if (field === "clock_in") {
      message = offsetMinutes
        ? `Clocked in at ${now} (−${Math.abs(offsetMinutes)} min)`
        : `Clocked in at ${now}`;
      return;
    }

    const start = minutes(fm.clock_in);
    if (start == null) {
      message = `Clocked out at ${now} — no clock_in recorded for this note.`;
      return;
    }
    const gross = (minutes(now) - start + 24 * 60) % (24 * 60);
    const worked = Math.max(0, gross - BREAK_MIN);
    message = `Clocked out at ${now} — ${Math.floor(worked / 60)} h ${String(worked % 60).padStart(2, "0")} min worked`;
  });

  notify(message);
};

// A re-render can run this into the same container again and append rather than
// replace, so drop any earlier copy first.
dv.container.querySelectorAll(".worktime").forEach((e) => e.remove());
clearTicker();

// Both rows live in one container, centred by the same flex box, so they cannot
// drift onto different axes.
const box = dv.el("div", "", { cls: "worktime" });

function draw() {
  clearTicker();
  box.empty();
  const fm = frontmatter();
  const start = minutes(fm.clock_in);
  const end = minutes(fm.clock_out);

  const times = box.createEl("div", { cls: "worktime-row worktime-times" });
  const chip = (cls, text, tip) =>
    times.createEl("span", { cls: `worktime-chip ${cls}`, text, attr: tip ? { title: tip } : {} });

  // Always the same three slots - In, duration, Out - so the row keeps one shape
  // whatever is filled in, mirrored around the duration and lining the two
  // buttons up under In and Out. Empty slots show an em dash.
  chip("is-in", start == null ? "In —" : `In ${clock(start)}`, "Arrival");
  if (start != null && end != null) {
    chip("is-total", span(net(elapsed(start, end))), `Total worked, ${BREAK_MIN} min break deducted`);
  } else if (start != null) {
    const live = chip("is-running", "",
      `Elapsed so far, still running - the ${BREAK_MIN} min break comes off when you depart`);
    const tick = () => {
      const n = new Date();
      live.textContent = span(elapsed(start, n.getHours() * 60 + n.getMinutes()));
    };
    tick();
    const timer = window.setInterval(tick, TICK_SECONDS * 1000);
    globalThis.__worktimeTickers[path] = timer;
    dv.component.registerInterval(timer);   // also cleared when the note is closed
  } else {
    chip("is-empty", "—", "No time recorded yet");
  }
  chip("is-out", end == null ? "Out —" : `Out ${clock(end)}`, "Departure");

  const actions = box.createEl("div", { cls: "worktime-row worktime-actions" });
  const action = (cls, label, handler) => {
    const b = actions.createEl("button", { cls: `worktime-btn ${cls}`, text: label });
    b.addEventListener("click", async () => {
      try {
        const before = JSON.stringify(frontmatter());
        await handler();
        // Frontmatter writes asynchronously; redraw as soon as the metadata
        // cache reflects it, giving up after a couple of seconds.
        let tries = 0;
        const poll = window.setInterval(() => {
          if (JSON.stringify(frontmatter()) !== before || ++tries > 10) {
            window.clearInterval(poll);
            draw();
          }
        }, 200);
        dv.component.registerInterval(poll);
      } catch (error) {
        notify(`Work time update failed: ${error.message ?? error}`);
      }
    });
  };
  action("is-in", "Clock In", () => writeClock("clock_in", -5));
  action("is-out", "Clock out", () => writeClock("clock_out", 5));
}

draw();
