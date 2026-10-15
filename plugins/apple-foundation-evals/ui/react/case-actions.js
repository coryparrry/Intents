export function caseEditingSelection(draft, id, query = "") {
  const visible = draft.cases.filter((item) =>
    `${item.name || ""} ${item.prompt}`
      .toLowerCase()
      .includes(query.toLowerCase()),
  );
  return {
    visible,
    selected: visible.find((item) => item.id === id) || visible[0],
  };
}
export function addCase(draft) {
  if (draft.cases.length >= 100)
    throw Error("A suite can contain at most 100 cases.");
  const item = {
    id: crypto.randomUUID(),
    name: "New case",
    prompt: "",
    expected: "",
    scoring: "none",
  };
  draft.cases.push(item);
  return item;
}
export function duplicateCase(draft, id) {
  if (draft.cases.length >= 100)
    throw Error("A suite can contain at most 100 cases.");
  const source = draft.cases.find((item) => item.id === id);
  if (!source) throw Error("Case not found.");
  const item = structuredClone(source);
  item.id = crypto.randomUUID();
  item.name = `${source.name || "Case"} copy`;
  draft.cases.push(item);
  return item;
}
export function removeCase(draft, id) {
  if (draft.cases.length <= 1)
    throw Error("Keep at least one case in the suite.");
  const index = draft.cases.findIndex((item) => item.id === id);
  if (index < 0) throw Error("Case not found.");
  draft.cases.splice(index, 1);
  return draft.cases[Math.min(index, draft.cases.length - 1)].id;
}
