const notify = (message) => {
  try { new Notice(message); } catch { console.warn("task-rollover:", message); }
};

const file = app.vault.getAbstractFileByPath(dv.current()?.file?.path ?? "");
const button = dv.el("button", "Move Open Tasks", { cls: "carry-todos" });

button.addEventListener("click", async () => {
  if (!file) {
    notify("Move Open Tasks: no active daily note");
    return;
  }

  button.disabled = true;
  try {
    let result = "";
    await app.vault.process(file, (content) => {
      const lines = content.split("\n");
      const callout = (re) => {
        const header = lines.findIndex((line) => re.test(line));
        if (header === -1) return null;
        let end = header + 1;
        while (end < lines.length && lines[end].startsWith(">")) end++;
        return { start: header + 1, end };
      };

      const today = callout(/^>\s*\[!todo\][+-]?\s*TODOs Today/i);
      const tomorrow = callout(/^>\s*\[!abstract\][+-]?\s*TODOs (Tomorrow|Next Day)/i);
      if (!today || !tomorrow) {
        result = "Move Open Tasks: could not find both callouts";
        return content;
      }

      const indent = (line) => line.replace(/^>\s?/, "").match(/^[ \t]*/)[0].length;
      const isTask = (line) => /^>\s*[-*]\s*\[[ xX]\]/.test(line);
      const isOpen = (line) => /^>\s*[-*]\s*\[ \]/.test(line);
      const carried = [];
      let keep = false;
      let taskIndent = 0;

      for (const line of lines.slice(today.start, today.end)) {
        if (isTask(line)) {
          keep = isOpen(line);
          taskIndent = indent(line);
          if (keep) carried.push(line);
          continue;
        }
        if (keep && indent(line) > taskIndent) carried.push(line);
        else keep = false;
      }

      if (!carried.length) {
        result = "Move Open Tasks: no open TODOs today";
        return content;
      }

      const placeholder = /Add tasks (that need to be tackled tomorrow|for the next working day) here/;
      const existing = lines.slice(tomorrow.start, tomorrow.end).filter((line) => !placeholder.test(line));
      const fresh = carried.filter((line) => !existing.includes(line));
      if (!fresh.length) {
        result = "Move Open Tasks: everything is already in Next Day";
        return content;
      }

      lines.splice(tomorrow.start, tomorrow.end - tomorrow.start, ...existing, ...fresh);
      result = `Move Open Tasks: ${fresh.length} line${fresh.length === 1 ? "" : "s"} copied to Next Day`;
      return lines.join("\n");
    });
    notify(result);
  } catch (error) {
    notify(`Move Open Tasks failed: ${error.message ?? error}`);
  } finally {
    button.disabled = false;
  }
});
