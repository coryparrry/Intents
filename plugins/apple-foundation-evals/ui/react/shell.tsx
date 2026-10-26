import {
  ListChecks,
  LayoutDashboard,
  Search,
  Plus,
  Play,
  Cpu,
  MoreHorizontal,
  Copy,
  Trash2,
  FileDown,
  FileUp,
  History,
  ChevronRight,
  RefreshCw,
  Settings2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";

import {
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectGroup,
  SelectItem,
} from "@/components/ui/select";

import {
  SidebarProvider,
  Sidebar,
  SidebarHeader,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarGroupContent,
  SidebarMenu,
  SidebarMenuItem,
  SidebarMenuButton,
} from "@/components/ui/sidebar";

import { workspaceMatches } from "../workspace-controls.js";

import { cn } from "@/lib/utils";

type Context = any;
import { Action, invoke } from "./shared";
/** Renders project selection and the new-project sentinel through the shared workspace action handler. */
function ProjectSelect({ ctx }: { ctx: Context }) {
  const { state, actions } = ctx;
  return (
    <Select
      value={state.projectId || undefined}
      onValueChange={(value) => invoke(ctx, () => actions.changeProject(value))}
    >
      <SelectTrigger aria-label="Project" className="w-full">
        <SelectValue placeholder="Choose project" />
      </SelectTrigger>
      <SelectContent>
        <SelectGroup>
          {state.projects.map((project: any) => (
            <SelectItem key={project.id} value={project.id}>
              {project.name}
            </SelectItem>
          ))}
          <SelectItem value="__new">New Project…</SelectItem>
        </SelectGroup>
      </SelectContent>
    </Select>
  );
}
/** Renders project navigation with searchable suites and runs scoped to the displayed suite when applicable. */
export function WorkspaceSidebar({ ctx }: { ctx: Context }) {
  const { state, actions } = ctx;
  const suiteId =
    state.page === "suites"
      ? state.draft?.id
      : state.page === "traces"
        ? state.run?.suiteId
        : null;
  const suites = state.suites.filter((suite: any) =>
    workspaceMatches(suite, state.workspaceSearch),
  );
  const runs = state.runs.filter(
    (run: any) =>
      (!suiteId || run.suiteId === suiteId) &&
      `${run.suiteName} ${ctx.date(run.startedAt)}`
        .toLowerCase()
        .includes(state.workspaceSearch.trim().toLowerCase()),
  );
  return (
    <SidebarProvider className="min-h-0 h-full w-full">
      <Sidebar collapsible="none" className="h-full w-full">
        <SidebarHeader className="gap-4 p-4">
          <div className="flex items-center gap-2">
            <ListChecks className="size-5" />
            <span className="font-semibold tracking-tight">
              Foundation Evals
            </span>
          </div>
          <ProjectSelect ctx={ctx} />
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-2.5 size-4 text-muted-foreground" />
            <Input
              id="workspace-search"
              aria-label="Search workspace"
              placeholder="Search workspace"
              className="pl-9"
              value={state.workspaceSearch}
              onChange={(event) => {
                state.workspaceSearch = event.target.value;
                ctx.renderSidebar();
              }}
            />
          </div>
        </SidebarHeader>
        <SidebarContent>
          <SidebarGroup>
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton
                  isActive={state.page === "overview"}
                  onClick={() => invoke(ctx, () => actions.overview())}
                >
                  <LayoutDashboard />
                  <span>Overview</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarGroup>
          <SidebarGroup>
            <SidebarGroupLabel>Suites</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {suites.map((suite: any) => (
                  <SidebarMenuItem key={suite.id}>
                    <SidebarMenuButton
                      aria-label={suite.name}
                      isActive={
                        state.page === "suites" && suite.id === state.draft?.id
                      }
                      onClick={() => invoke(ctx, () => ctx.selectSuite(suite))}
                    >
                      <ListChecks />
                      <span>
                        {suite.id === state.draft?.id
                          ? state.draft.name
                          : suite.name}
                      </span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
          <SidebarGroup>
            <SidebarGroupLabel>Saved runs</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {runs.map((run: any) => (
                  <SidebarMenuItem key={run.id}>
                    <SidebarMenuButton
                      className="h-auto py-2"
                      isActive={
                        state.page === "traces" && run.id === state.run?.id
                      }
                      onClick={() => invoke(ctx, () => ctx.selectRun(run.id))}
                    >
                      <History />
                      <div className="flex min-w-0 flex-col gap-0.5">
                        <span className="truncate">
                          {ctx.date(run.startedAt)}
                        </span>
                        <span className="text-xs text-muted-foreground">
                          {run.status} · {run.passed} passed
                        </span>
                      </div>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
              {!runs.length && (
                <p className="px-2 text-xs text-muted-foreground">
                  No saved runs
                </p>
              )}
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
        <SidebarFooter className="gap-2 p-4">
          <Action ctx={ctx} action={ctx.createSuite} variant="outline">
            <Plus data-icon="inline-start" />
            New Suite
          </Action>
          <Action
            ctx={ctx}
            action={() => actions.projectDetails()}
            variant="ghost"
            size="sm"
          >
            <Settings2 data-icon="inline-start" />
            Project settings
          </Action>
        </SidebarFooter>
      </Sidebar>
    </SidebarProvider>
  );
}
/** Renders the current project and optional suite or run title with responsive breadcrumb truncation. */
export function Breadcrumb({ ctx }: { ctx: Context }) {
  const { state } = ctx;
  const project =
    state.projects.find((item: any) => item.id === state.projectId)?.name ||
    "Workspace";
  const current =
    state.page === "suites"
      ? state.draft?.name
      : state.page === "traces"
        ? state.run?.suite?.name || state.run?.suiteName
        : null;
  return (
    <div className="flex min-w-0 items-center gap-2 text-sm">
      <span
        className={cn(
          "truncate",
          current && "hidden text-muted-foreground md:inline",
        )}
      >
        {project}
      </span>
      {current && (
        <>
          <ChevronRight className="hidden size-4 text-muted-foreground md:block" />
          <span className="truncate font-medium">{current}</span>
        </>
      )}
    </div>
  );
}
/** Renders page-specific workspace actions, respecting busy state, active runs and host download capability. */
export function ToolbarActions({ ctx }: { ctx: Context }) {
  const { state, actions } = ctx;
  if (state.page === "suites" && state.draft)
    return (
      <div className="flex items-center gap-2">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon-sm" aria-label="Suite actions">
              <MoreHorizontal />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuGroup>
              <DropdownMenuItem onSelect={() => actions.suiteDetails()}>
                Suite details
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={!state.hostCapabilities.downloadFile}
                onSelect={() => invoke(ctx, actions.exportSuite)}
              >
                <FileDown />
                Export suite
              </DropdownMenuItem>
              <DropdownMenuItem
                onSelect={() => invoke(ctx, actions.importSuite)}
              >
                <FileUp />
                Import suite
              </DropdownMenuItem>
              <DropdownMenuItem
                disabled={state.busy}
                onSelect={() => invoke(ctx, actions.duplicateSuite)}
              >
                <Copy />
                Duplicate suite
              </DropdownMenuItem>
              <DropdownMenuItem
                onSelect={() => invoke(ctx, actions.showBaseline)}
              >
                Approved baseline
              </DropdownMenuItem>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuGroup>
              <DropdownMenuItem
                variant="destructive"
                disabled={state.busy || ctx.active()}
                onSelect={() => invoke(ctx, actions.deleteSuite)}
              >
                <Trash2 />
                Delete suite…
              </DropdownMenuItem>
            </DropdownMenuGroup>
          </DropdownMenuContent>
        </DropdownMenu>
        <Action
          ctx={ctx}
          action={actions.modelDetails}
          variant="outline"
          size="icon-sm"
          aria-label="This Mac"
        >
          <Cpu />
        </Action>
        <Action
          ctx={ctx}
          action={actions.startRun}
          size="sm"
          disabled={state.busy || ctx.active()}
        >
          <Play data-icon="inline-start" />
          Run
        </Action>
      </div>
    );
  if (state.page === "traces" && state.run)
    return (
      <div className="flex items-center gap-2">
        <Action
          ctx={ctx}
          action={actions.exportRun}
          variant="outline"
          size="sm"
          disabled={!state.hostCapabilities.downloadFile}
        >
          <FileDown data-icon="inline-start" />
          Export
        </Action>
        {!state.imported && (
          <Action
            ctx={ctx}
            action={actions.deleteRun}
            variant="ghost"
            size="icon-sm"
            aria-label="Delete run"
            disabled={state.run.status === "running" || state.busy}
          >
            <Trash2 />
          </Action>
        )}
        {state.run.status === "running" && !state.imported && (
          <Action
            ctx={ctx}
            action={actions.cancelRun}
            variant="destructive"
            size="sm"
          >
            Cancel
          </Action>
        )}
      </div>
    );
  return (
    <div className="flex items-center gap-2">
      <Action
        ctx={ctx}
        action={actions.projectReport}
        variant="outline"
        size="sm"
      >
        Project report
      </Action>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon-sm" aria-label="Workspace actions">
            <MoreHorizontal />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuGroup>
            <DropdownMenuItem onSelect={() => invoke(ctx, actions.importSuite)}>
              <FileUp />
              Import suite
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => invoke(ctx, ctx.refresh)}>
              <RefreshCw />
              Refresh workspace
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => invoke(ctx, actions.modelDetails)}
            >
              <Cpu />
              This Mac
            </DropdownMenuItem>
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}
/** Renders suite or run document tabs and routes changes through the workspace action handler. */
export function DocumentTabs({ ctx }: { ctx: Context }) {
  const { state, actions } = ctx;
  const suite = state.page === "suites" && state.draft;
  const run = state.page === "traces" && state.run;
  if (!suite && !run) return null;
  const items = suite
    ? [
        ["cases", "Cases"],
        ["results", "Results"],
        ["compare", "Compare"],
        ["setup", "Setup"],
      ]
    : [
        ["trace", "Workflow trace"],
        ["report", "Report"],
      ];
  return (
    <Tabs
      value={suite ? state.suiteTab : state.runTab}
      onValueChange={(value) => invoke(ctx, () => actions.changeTab(value))}
    >
      <TabsList
        aria-label={suite ? "Evaluation pages" : "Run view"}
        variant="line"
      >
        {items.map(([value, title]) => (
          <TabsTrigger key={value} value={value} disabled={state.busy}>
            {title}
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  );
}
