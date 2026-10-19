---
week: KW-<% tp.date.now('ww',0, tp.file.title, 'YYYY-MM-DD') %>
date: <% tp.date.now("YYYY-MM-DD") %>
clock_in:
clock_out:
tags:
  - daily
  - log
cssclasses:
  - daily-note
---
<%*
/* Carry over open TODOs and General TODOs from the most recent earlier daily
   note (not necessarily yesterday - skips weekends/holidays). */
const dailies = tp.file.folder(true);
const prev = app.vault.getMarkdownFiles()
  .filter(f => f.path.startsWith(dailies + "/") && /^\d{4}-\d{2}-\d{2}$/.test(f.basename) && f.basename < tp.file.title)
  .sort((a, b) => a.basename.localeCompare(b.basename))
  .pop();
let todosToday = "> - [ ] Add task you are tackling today.";
let generalNotesToday = "> - [ ] Add a general task.";
// "Yesterday" link: the previous existing note, falling back to the calendar day
const yesterday = prev ? prev.basename : tp.date.now("YYYY-MM-DD", -1, tp.file.title, "YYYY-MM-DD");
if (prev) {
  const lines = (await app.vault.read(prev)).split("\n");
  const start = lines.findIndex(l => /^>\s*\[!abstract\][+-]?\s*TODOs (Tomorrow|Next Day)/i.test(l));
  if (start !== -1) {
    const body = [];
    for (let i = start + 1; i < lines.length && lines[i].startsWith(">"); i++) body.push(lines[i]);
    const real = body.filter(l => !/Add tasks (that need to be tackled tomorrow|for the next working day) here/.test(l) && l.replace(/^>\s*/, "").trim() !== "");
    if (real.length) todosToday = real.join("\n");
  }
  const notesStart = lines.findIndex(l => /^>\s*\[!abstract\][+-]?\s*General TODOs Next Day$/i.test(l));
  if (notesStart !== -1) {
    const body = [];
    for (let i = notesStart + 1; i < lines.length && lines[i].startsWith(">"); i++) body.push(lines[i]);
    const real = body.filter(l => !/Add general tasks for the next working day here/.test(l) && l.replace(/^>\s*/, "").trim() !== "");
    if (real.length) generalNotesToday = real.join("\n");
  }
}
-%>

<% tp.web.daily_quote() %>

# <% tp.date.now("dddd, Do MMMM YYYY", 0, tp.file.title, "YYYY-MM-DD") %>

[[00_Dailies/<% yesterday %>|⬅️ Yesterday]] | [[00_Dailies/<% tp.date.now("YYYY-MM-DD", 1, tp.file.title, "YYYY-MM-DD") %>|➡️ Tomorrow]]

> [!clock] Work Time
> ```dataviewjs
> await dv.view("_globals/views/worktime");
> ```

## [[Work Dashboard|Daily Tasks Log]]
---

> [!todo]+ TODOs Today
<% todosToday %>

> [!success]+ Done Today
> Add task successfully finished today.

> [!abstract]+ TODOs Next Day
> Add tasks for the next working day here.

> [!note]+ General TODOs
<% generalNotesToday %>

> [!abstract]+ General TODOs Next Day
> Add general tasks for the next working day here.

```dataviewjs
await dv.view("_globals/views/task-rollover");
```

## Daily Notes
---

**TODO**

## Today's Created Notes
---

> [!example]- Created Today
> ```dataview
> table without id
> file.link as Note,
> file.folder as Folder,
> file.ctime as "Created"
> FROM ""
> where file.ctime >= date(<%tp.file.title%>) AND file.ctime <= date(<%moment(tp.file.title,'YYYY-MM-DD').add(1, 'd').format("YYYY-MM-DD")%>) AND file.path != this.file.path
> sort file.ctime desc
> ```

> [!example]- Modified Today
> ```dataview
> table without id
> file.link as Note,
> file.folder as Folder,
> file.mtime as "Last Modified"
> FROM ""
> where file.mtime >= date(<%tp.file.title%>) AND file.mtime <= date(<%moment(tp.file.title,'YYYY-MM-DD').add(1, 'd').format("YYYY-MM-DD")%>) AND file.path != this.file.path
> sort file.mtime desc
> ```
