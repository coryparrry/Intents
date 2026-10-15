import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { JSDOM } from "jsdom";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

test("library editor persists edits through selection and dialogs release their DOM ownership", async () => {
  const dom = new JSDOM(
    '<!doctype html><html><body><main id="main"></main></body></html>',
    { url: "http://localhost", pretendToBeVisual: true },
  );
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "Event",
    "MouseEvent",
    "KeyboardEvent",
    "MutationObserver",
    "CustomEvent",
    "HTMLInputElement",
    "SVGElement",
    "DocumentFragment",
    "NodeFilter",
  ])
    Object.defineProperty(globalThis, key, {
      configurable: true,
      value: dom.window[key],
    });
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(
    dom.window,
  );
  globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(
    dom.window,
  );
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const output = new URL(`../.ui-test-${process.pid}.mjs`, import.meta.url);
  try {
    await build({
      entryPoints: [
        fileURLToPath(new URL("../ui/react/workspace.tsx", import.meta.url)),
      ],
      outfile: fileURLToPath(output),
      bundle: true,
      platform: "node",
      format: "esm",
      packages: "external",
      jsx: "automatic",
      logLevel: "silent",
    });
    const { mountUI, unmountUI, libraryDialog } = await import(output.href);
    const { act, fireEvent, within } = await import("@testing-library/react");
    const main = document.getElementById("main");
    let saves = 0;
    const state = {
      caseSearch: "",
      caseId: "first",
      dirty: false,
      draft: {
        id: "suite",
        name: "Suite",
        scoringMode: "exactMatch",
        cases: [
          { id: "first", name: "First", prompt: "Apple", expected: "apple" },
          {
            id: "second",
            name: "Second",
            prompt: "Banana",
            expected: "banana",
          },
        ],
      },
    };
    const ctx = {
      state,
      actions: { suiteDetails: () => {} },
      changed: () => saves++,
      active: () => false,
      caseTitle: (item) => item.name,
      scoringLabel: () => "Exact text",
      importCases: () => {},
      fail: (error) => {
        throw error;
      },
      renderToolbar: () => {},
      renderMain: () => mountUI("cases", main, ctx),
    };
    await act(async () => ctx.renderMain());
    assert.ok(main.querySelector('[data-slot="textarea"]'));
    await act(async () =>
      fireEvent.change(within(main).getByLabelText("Prompt"), {
        target: { value: "Edited apple" },
      }),
    );
    assert.equal(state.draft.cases[0].prompt, "Edited apple");
    assert.equal(saves, 1);
    await act(async () =>
      fireEvent.click(within(main).getByRole("button", { name: /Second/ })),
    );
    assert.equal(within(main).getByLabelText("Prompt").value, "Banana");
    await act(async () =>
      fireEvent.click(within(main).getByRole("button", { name: /First/ })),
    );
    assert.equal(within(main).getByLabelText("Prompt").value, "Edited apple");
    await act(async () =>
      fireEvent.change(within(main).getByLabelText("Find a case"), {
        target: { value: "missing" },
      }),
    );
    assert.ok(within(main).getByText("No matching cases"));
    await act(async () => unmountUI(main));
    const legacy = document.createElement("p");
    legacy.textContent = "Legacy results";
    main.append(legacy);
    assert.equal(main.textContent, "Legacy results");
    const opener = document.createElement("button");
    opener.textContent = "Open model";
    document.body.append(opener);
    opener.focus();
    let body,
      closed = 0;
    await act(async () => {
      body = libraryDialog("Model status", (el) => {
        el.append(document.createElement("button"));
      });
      body.addEventListener("close", () => closed++);
    });
    assert.ok(
      within(document.body).getByRole("dialog", { name: "Model status" }),
    );
    await act(async () => {
      body.close();
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    assert.equal(document.activeElement, opener);
    assert.equal(closed, 1);
    assert.equal(document.querySelector('[role="dialog"]'), null);
    body.close();
    assert.equal(closed, 1);
  } finally {
    await rm(output, { force: true });
    dom.window.close();
  }
});
