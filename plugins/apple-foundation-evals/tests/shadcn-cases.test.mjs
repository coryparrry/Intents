import test from "node:test";
import assert from "node:assert/strict";
import {
  addCase,
  duplicateCase,
  caseEditingSelection,
} from "../ui/react/case-actions.js";

test("case selection follows visible search results and empty/limit cases are safe", () => {
  const draft = {
    cases: [
      { id: "a", name: "First", prompt: "Apple" },
      { id: "b", name: "Second", prompt: "Banana" },
    ],
  };
  assert.equal(caseEditingSelection(draft, "a", "BANANA").selected.id, "b");
  assert.equal(caseEditingSelection(draft, "a", "missing").selected, undefined);
  const added = addCase(draft);
  assert.equal(added.prompt, "");
  assert.throws(() => duplicateCase(draft, "missing"), /not found/);
  const full = {
    cases: Array.from({ length: 100 }, (_, i) => ({ id: String(i) })),
  };
  assert.throws(() => addCase(full), /at most 100/);
  assert.throws(() => duplicateCase(full, "0"), /at most 100/);
});
