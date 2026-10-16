import test from "node:test";
import assert from "node:assert/strict";
import {
  addCase,
  duplicateCase,
  removeCase,
  caseEditingSelection,
} from "../ui/react/case-actions.js";

test("case duplication preserves setup and assertions without sharing mutable data", () => {
  const original = {
    id: "original",
    name: "JSON",
    prompt: "Only JSON",
    conversation: { setupTurns: [{ id: "turn", prompt: "Remember apple" }] },
    fieldAssertions: [
      {
        id: "check",
        pointer: "/fruit",
        operation: "equals",
        expectedValue: '"apple"',
      },
    ],
  };
  const draft = { cases: [original] };
  const copy = duplicateCase(draft, original.id);
  assert.notEqual(copy.id, original.id);
  assert.deepEqual(copy.conversation, original.conversation);
  copy.conversation.setupTurns[0].prompt = "Changed";
  copy.fieldAssertions[0].expectedValue = '"banana"';
  assert.equal(original.conversation.setupTurns[0].prompt, "Remember apple");
  assert.equal(original.fieldAssertions[0].expectedValue, '"apple"');
  assert.equal(removeCase(draft, copy.id), original.id);
  assert.throws(() => removeCase(draft, original.id), /at least one/);
});
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
