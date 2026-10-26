/** Filters cases by name or prompt and selects the requested visible case or the first visible fallback. */
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
/** Appends and returns a newly identified empty case, rejecting additions beyond the suite limit of 100. */
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
/** Appends a deep copy with a fresh case identifier, rejecting a missing source or the 100-case limit. */
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
/** Removes a case and its critical-case references, returning the nearest remaining selection and retaining at least one case. */
export function removeCase(draft, id) {
  if (draft.cases.length <= 1)
    throw Error("Keep at least one case in the suite.");
  const index = draft.cases.findIndex((item) => item.id === id);
  if (index < 0) throw Error("Case not found.");
  draft.cases.splice(index, 1);
  if (draft.releasePolicy?.criticalCaseIDs) {
    draft.releasePolicy.criticalCaseIDs = draft.releasePolicy.criticalCaseIDs.filter(caseId => caseId.toLowerCase() !== id.toLowerCase());
  }
  return draft.cases[Math.min(index, draft.cases.length - 1)].id;
}
