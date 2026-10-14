<%*
/* Copy every unticked task/note (and its indented sub-lines) from each source
   callout into its matching Next Day callout. Ticked items are skipped, lines
   already present are not duplicated, and placeholders are replaced. */
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
const pairs = [
  {
    source: callout(/^>\s*\[!todo\][+-]?\s*TODOs Today/i),
    destination: callout(/^>\s*\[!abstract\][+-]?\s*TODOs (Tomorrow|Next Day)/i),
    placeholder: /Add tasks (that need to be tackled tomorrow|for the next working day) here/,
  },
  {
    source: callout(/^>\s*\[!note\][+-]?\s*General Notes/i),
    destination: callout(/^>\s*\[!abstract\][+-]?\s*General Notes Next Day/i),
    placeholder: /Add general notes for the next working day here/,
  },
];
if (pairs.some(pair => !pair.source || !pair.destination)) {
  new Notice("Move Open Tasks: could not find all callouts");
  return;
}

// indentation of a `> ` line's content, for grouping sub-lines under their task
const indent = (l) => l.replace(/^>\s?/, "").match(/^[ \t]*/)[0].length;
const isTask = (l) => /^>\s*[-*]\s*\[[ xX]\]/.test(l);
const isOpen = (l) => /^>\s*[-*]\s*\[ \]/.test(l);

let copied = 0;
const cursor = editor.getCursor();
for (const pair of pairs.sort((a, b) => b.destination.start - a.destination.start)) {
  const carried = [];
  let keep = false, taskIndent = 0;
  for (const l of lines.slice(pair.source.start, pair.source.end)) {
    if (isTask(l)) { keep = isOpen(l); taskIndent = indent(l); if (keep) carried.push(l); continue; }
    if (keep && indent(l) > taskIndent) carried.push(l);
    else keep = false;
  }
  const existing = lines.slice(pair.destination.start, pair.destination.end)
    .filter(l => !pair.placeholder.test(l));
  const fresh = carried.filter(l => !existing.includes(l));
  if (fresh.length) {
    lines.splice(pair.destination.start, pair.destination.end - pair.destination.start, ...existing, ...fresh);
    copied += fresh.length;
  }
}
if (!copied) { new Notice("Move Open Tasks: no new open items to copy"); return; }
editor.setValue(lines.join("\n"));
editor.setCursor(cursor);
new Notice(`Move Open Tasks: ${copied} line${copied === 1 ? "" : "s"} copied to Next Day`);
-%>
