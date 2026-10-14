<%*
/* Copy every unticked task (and its indented sub-lines) from the "TODOs Today"
   callout into the "TODOs Next Day" callout of the current note. Ticked tasks
   are skipped, lines already present in Next Day are not duplicated, and the
   Next Day placeholder text is replaced. Works on the open editor, inserts nothing. */
const editor = app.workspace.activeEditor?.editor;
if (!editor) { new Notice("Move Open Tasks: no active editor"); return; }
const lines = editor.getValue().split("\n");

// [start, endExclusive) of a callout's body: the `>` lines after its header
const callout = (re) => {
  const h = lines.findIndex(l => re.test(l));
  if (h === -1) return null;
  let e = h + 1;
  while (e < lines.length && lines[e].startsWith(">")) e++;
  return { header: h, start: h + 1, end: e };
};
const today = callout(/^>\s*\[!todo\][+-]?\s*TODOs Today/i);
const tomorrow = callout(/^>\s*\[!abstract\][+-]?\s*TODOs (Tomorrow|Next Day)/i);
if (!today || !tomorrow) { new Notice("Move Open Tasks: could not find both callouts"); return; }

// indentation of a `> ` line's content, for grouping sub-lines under their task
const indent = (l) => l.replace(/^>\s?/, "").match(/^[ \t]*/)[0].length;
const isTask = (l) => /^>\s*[-*]\s*\[[ xX]\]/.test(l);
const isOpen = (l) => /^>\s*[-*]\s*\[ \]/.test(l);

const carried = [];
let keep = false, taskIndent = 0;
for (const l of lines.slice(today.start, today.end)) {
  if (isTask(l)) { keep = isOpen(l); taskIndent = indent(l); if (keep) carried.push(l); continue; }
  if (keep && indent(l) > taskIndent) carried.push(l);   // sub-line of an open task
  else keep = false;
}
if (!carried.length) { new Notice("Move Open Tasks: no open TODOs today"); return; }

const placeholder = /Add tasks (that need to be tackled tomorrow|for the next working day) here/;
const existing = lines.slice(tomorrow.start, tomorrow.end).filter(l => !placeholder.test(l));
const fresh = carried.filter(l => !existing.includes(l));
if (!fresh.length) { new Notice("Move Open Tasks: everything is already in Next Day"); return; }

const cursor = editor.getCursor();
lines.splice(tomorrow.start, tomorrow.end - tomorrow.start, ...existing, ...fresh);
editor.setValue(lines.join("\n"));
editor.setCursor(cursor);
new Notice(`Move Open Tasks: ${fresh.length} line${fresh.length === 1 ? "" : "s"} copied to Next Day`);
-%>
