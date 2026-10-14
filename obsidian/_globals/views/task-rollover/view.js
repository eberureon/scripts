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
      if (pairs.some((pair) => !pair.source || !pair.destination)) {
        result = "Move Open Tasks: could not find all callouts";
        return content;
      }

      const indent = (line) => line.replace(/^>\s?/, "").match(/^[ \t]*/)[0].length;
      const isTask = (line) => /^>\s*[-*]\s*\[[ xX]\]/.test(line);
      const isOpen = (line) => /^>\s*[-*]\s*\[ \]/.test(line);
      let copied = 0;
      for (const pair of pairs.sort((a, b) => b.destination.start - a.destination.start)) {
        const carried = [];
        let keep = false;
        let taskIndent = 0;
        for (const line of lines.slice(pair.source.start, pair.source.end)) {
          if (isTask(line)) {
            keep = isOpen(line);
            taskIndent = indent(line);
            if (keep) carried.push(line);
            continue;
          }
          if (keep && indent(line) > taskIndent) carried.push(line);
          else keep = false;
        }
        const existing = lines.slice(pair.destination.start, pair.destination.end)
          .filter((line) => !pair.placeholder.test(line));
        const fresh = carried.filter((line) => !existing.includes(line));
        if (fresh.length) {
          lines.splice(pair.destination.start, pair.destination.end - pair.destination.start, ...existing, ...fresh);
          copied += fresh.length;
        }
      }
      if (!copied) {
        result = "Move Open Tasks: no new open items to copy";
        return content;
      }
      result = `Move Open Tasks: ${copied} line${copied === 1 ? "" : "s"} copied to Next Day`;
      return lines.join("\n");
    });
    notify(result);
  } catch (error) {
    notify(`Move Open Tasks failed: ${error.message ?? error}`);
  } finally {
    button.disabled = false;
  }
});
