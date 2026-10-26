import * as React from "react";
import { createRoot, type Root } from "react-dom/client";

import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";

import { TooltipProvider } from "@/components/ui/tooltip";

type Context = any;
import {
  WorkspaceSidebar,
  ToolbarActions,
  Breadcrumb,
  DocumentTabs,
} from "./shell";
import { Overview } from "./overview";
import { Cases } from "./cases";
const roots = new Map<Element, Root>();
/** Unmounts and removes the tracked React root for a target element when one exists. */
export function unmountUI(target: Element) {
  const root = roots.get(target);
  if (root) {
    root.unmount();
    roots.delete(target);
  }
}
/**
 * Mounts or updates the requested workspace component in a root owned by the target element.
 * Case and overview keys follow draft or project identity so their local React state resets on navigation.
 * @param kind One of sidebar, actions, tabs, breadcrumb, overview or cases.
 */
export function mountUI(kind: string, target: Element, ctx: Context) {
  let root = roots.get(target);
  if (!root) {
    target.replaceChildren();
    root = createRoot(target);
    roots.set(target, root);
  }
  const components: Record<string, React.ElementType> = {
    sidebar: WorkspaceSidebar,
    actions: ToolbarActions,
    tabs: DocumentTabs,
    breadcrumb: Breadcrumb,
    overview: Overview,
    cases: Cases,
  };
  const Component = components[kind];
  root.render(
    <TooltipProvider>
      <Component
        key={
          kind === "cases"
            ? ctx.state.draft?.id
            : kind === "overview"
              ? ctx.state.projectId
              : kind
        }
        ctx={ctx}
      />
    </TooltipProvider>,
  );
}
/**
 * Hosts a legacy DOM-rendered dialog body inside the React dialog shell and returns it with a close method.
 * Closing dispatches the legacy close event, removes the root and host, and lets the shell restore opener focus.
 */
export function libraryDialog(title: string, renderBody: (body: any) => void) {
  const opener = document.activeElement as HTMLElement | null;
  const openerLabel = opener?.getAttribute("aria-label");
  const openerText = opener?.textContent?.trim();
  const host = document.createElement("div");
  const body: any = document.createElement("div");
  body.className = "legacy-view dialog-body";
  let closed = false;
  /** Closes the dialog once, dispatching the legacy close event before unmounting its React root and removing the host. */
  body.close = () => {
    if (closed) return;
    closed = true;
    body.dispatchEvent(new Event("close"));
    root.unmount();
    host.remove();
  };
  renderBody(body);
  document.body.append(host);
  const root = createRoot(host);
  root.render(
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) body.close();
      }}
    >
      <DialogContent
        className="max-h-[85vh] overflow-y-auto sm:max-w-2xl"
        onCloseAutoFocus={(event) => {
          event.preventDefault();
          const fallback = openerLabel
            ? [...document.querySelectorAll<HTMLElement>("[aria-label]")].find(
                (element) => element.getAttribute("aria-label") === openerLabel,
              )
            : [...document.querySelectorAll<HTMLElement>("button")].find(
                (button) => button.textContent?.trim() === openerText,
              );
          const target =
            opener?.isConnected && !opener.matches(":disabled")
              ? opener
              : fallback || document.getElementById("sidebar-toggle");
          target?.focus();
        }}
      >
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription className="sr-only">
            {title} controls and details.
          </DialogDescription>
        </DialogHeader>
        <div
          ref={(el) => {
            if (el && body.parentElement !== el) el.append(body);
          }}
        />
      </DialogContent>
    </Dialog>,
  );
  return body;
}
