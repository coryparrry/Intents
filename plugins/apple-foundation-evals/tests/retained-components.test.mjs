import test from "node:test";
import assert from "node:assert/strict";
import { build } from "esbuild";
import { JSDOM } from "jsdom";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";

test("retained component compositions preserve keyboard, focus, and controlled state", { timeout: 20_000 }, async (t) => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "http://localhost",
    pretendToBeVisual: true,
  });
  const globals = new Map();
  for (const key of [
    "window", "document", "navigator", "HTMLElement", "Element", "Node",
    "Event", "MouseEvent", "KeyboardEvent", "MutationObserver", "CustomEvent",
    "HTMLInputElement", "SVGElement", "DocumentFragment", "NodeFilter",
  ]) {
    globals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
  }
  for (const key of ["getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"]) {
    globals.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    globalThis[key] = dom.window[key].bind(dom.window);
  }
  globals.set("IS_REACT_ACT_ENVIRONMENT", Object.getOwnPropertyDescriptor(globalThis, "IS_REACT_ACT_ENVIRONMENT"));
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const mediaListeners = new Set();
  dom.window.matchMedia = () => ({
    matches: dom.window.innerWidth < 768,
    addEventListener: (_event, listener) => mediaListeners.add(listener),
    removeEventListener: (_event, listener) => mediaListeners.delete(listener),
  });
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  globals.set("ResizeObserver", Object.getOwnPropertyDescriptor(globalThis, "ResizeObserver"));
  // JSDOM has no layout; these checks exercise interaction state, not popover geometry.
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  const output = new URL(`../.retained-components-${process.pid}.mjs`, import.meta.url);
  let cleanup;
  try {
    await build({
      stdin: {
        resolveDir: fileURLToPath(new URL("../ui/react", import.meta.url)),
        loader: "tsx",
        contents: `
          import * as React from "react";
          import { Button } from "@/components/ui/button";
          import { SidebarProvider, Sidebar, SidebarHeader, SidebarContent,
            SidebarFooter, SidebarGroup, SidebarGroupLabel, SidebarGroupContent,
            SidebarMenu, SidebarMenuItem, SidebarMenuButton, useSidebar
          } from "@/components/ui/sidebar";
          import { TooltipProvider } from "@/components/ui/tooltip";
          import { Dialog, DialogContent, DialogHeader, DialogTitle,
            DialogDescription } from "@/components/ui/dialog";

          /** Exposes provider state through the same toggle action used by its keyboard shortcut. */
          function NavigationState() {
            const state = useSidebar();
            return <>
              <Button onClick={state.toggleSidebar}>Toggle navigation</Button>
              <output aria-label="Navigation state">{state.state}:{String(state.openMobile)}</output>
            </>;
          }
          /** Composes the retained navigation slots with a slotted link and collapsed tooltip. */
          export function Navigation({ open, onOpenChange, collapsible = "offcanvas" }) {
            return <TooltipProvider><SidebarProvider open={open} onOpenChange={onOpenChange}>
              <NavigationState />
              <Sidebar collapsible={collapsible}>
                <SidebarHeader>Foundation Evals</SidebarHeader>
                <SidebarContent><SidebarGroup>
                  <SidebarGroupLabel>Workspace</SidebarGroupLabel>
                  <SidebarGroupContent><SidebarMenu><SidebarMenuItem>
                    <SidebarMenuButton asChild isActive tooltip="Open overview">
                      <a href="#overview">Overview</a>
                    </SidebarMenuButton>
                  </SidebarMenuItem></SidebarMenu></SidebarGroupContent>
                </SidebarGroup></SidebarContent>
                <SidebarFooter>Local evaluations</SidebarFooter>
              </Sidebar>
            </SidebarProvider></TooltipProvider>;
          }
          /** Mirrors programmatic workspace dialogs, including their explicit opener-focus restoration. */
          export function DialogFlow() {
            const [open, setOpen] = React.useState(false);
            const opener = React.useRef(null);
            return <>
              <Button ref={opener} onClick={() => setOpen(true)}>Model status</Button>
              <Dialog open={open} onOpenChange={setOpen}>
                <DialogContent onCloseAutoFocus={(event) => {
                  event.preventDefault();
                  opener.current?.focus();
                }}>
                  <DialogHeader><DialogTitle>Model availability</DialogTitle>
                    <DialogDescription>Ready for local evaluations.</DialogDescription>
                  </DialogHeader>
                  <Button>Check model</Button>
                </DialogContent>
              </Dialog>
            </>;
          }
        `,
      },
      tsconfig: fileURLToPath(new URL("../tsconfig.json", import.meta.url)),
      outfile: fileURLToPath(output),
      bundle: true,
      platform: "node",
      format: "esm",
      packages: "external",
      jsx: "automatic",
      logLevel: "silent",
    });
    const { Navigation, DialogFlow } = await import(output.href);
    const { createElement } = await import("react");
    const testing = await import("@testing-library/react");
    const { act, fireEvent, render, within, waitFor } = testing;
    cleanup = testing.cleanup;
    t.afterEach(() => cleanup());

    await t.test("sidebar shortcuts preserve controlled and internal desktop state, cookie writes, and link composition", async () => {
      const changes = [];
      const view = render(createElement(Navigation, { open: true, onOpenChange: (value) => changes.push(value) }));
      const state = view.getByLabelText("Navigation state");
      const link = view.getByRole("link", { name: "Overview" });
      assert.equal(link.dataset.active, "true");
      assert.equal(link.dataset.slot, "sidebar-menu-button");
      await act(async () => fireEvent.keyDown(window, { key: "b", ctrlKey: true }));
      assert.deepEqual(changes, [false]);
      assert.equal(state.textContent, "expanded:false");
      assert.match(document.cookie, /sidebar_state=false/);
      view.rerender(createElement(Navigation, { open: false, onOpenChange: (value) => changes.push(value) }));
      assert.equal(state.textContent, "collapsed:false");
      await act(async () => link.focus());
      await waitFor(() => assert.ok(view.getByRole("tooltip", { name: "Open overview" })));
      await act(async () => fireEvent.keyDown(window, { key: "b", metaKey: true }));
      assert.deepEqual(changes, [false, true]);
      assert.equal(state.textContent, "collapsed:false");
      view.unmount();
      const internal = render(createElement(Navigation, { collapsible: "none" }));
      await act(async () => fireEvent.keyDown(window, { key: "b" }));
      assert.equal(internal.getByLabelText("Navigation state").textContent, "expanded:false");
      await act(async () => fireEvent.keyDown(window, { key: "b", ctrlKey: true }));
      assert.equal(internal.getByLabelText("Navigation state").textContent, "collapsed:false");
      assert.ok(internal.getByRole("link", { name: "Overview" }));
      internal.unmount();
      assert.equal(mediaListeners.size, 0);
    });

    await t.test("mobile shortcut opens the labelled sheet and Escape closes only mobile state", async () => {
      dom.window.innerWidth = 500;
      const view = render(createElement(Navigation));
      const toggle = view.getByRole("button", { name: "Toggle navigation" });
      await act(async () => toggle.focus());
      await act(async () => fireEvent.keyDown(window, { key: "b", metaKey: true }));
      const sheet = view.getByRole("dialog", { name: "Sidebar" });
      assert.equal(sheet.getAttribute("aria-describedby")?.length > 0, true);
      assert.ok(within(sheet).getByRole("link", { name: "Overview" }));
      assert.equal(view.getByLabelText("Navigation state").textContent, "expanded:true");
      assert.equal(sheet.contains(document.activeElement), true);
      assert.equal(view.queryByRole("tooltip"), null);
      await act(async () => fireEvent.keyDown(document.activeElement, { key: "Escape" }));
      await waitFor(() => assert.equal(view.queryByRole("dialog"), null));
      assert.equal(view.getByLabelText("Navigation state").textContent, "expanded:false");
      view.unmount();
      dom.window.innerWidth = 1024;
    });

    await t.test("programmatic dialogs keep their accessible description and restore opener focus on Escape", async () => {
      const view = render(createElement(DialogFlow));
      const opener = view.getByRole("button", { name: "Model status" });
      await act(async () => opener.focus());
      await act(async () => fireEvent.click(opener));
      const dialog = view.getByRole("dialog", { name: "Model availability" });
      assert.equal(document.getElementById(dialog.getAttribute("aria-describedby")).textContent, "Ready for local evaluations.");
      assert.equal(dialog.contains(document.activeElement), true);
      await act(async () => fireEvent.keyDown(document.activeElement, { key: "Escape" }));
      await waitFor(() => assert.equal(view.queryByRole("dialog"), null));
      assert.equal(document.activeElement, opener);
      view.unmount();
    });
  } finally {
    cleanup?.();
    await rm(output, { force: true });
    dom.window.close();
    for (const [key, descriptor] of globals) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
