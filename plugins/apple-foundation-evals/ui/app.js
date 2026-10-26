import { renderCatalogRecovery, exportRecoveryRecord, forgetRemovedRecoveryRecord, setCatalogRecoveryLayout } from "./catalog-recovery.js";
import { createWorkspaceScope, resetSuiteEvidence, mutateSuiteDraft } from "./workspace-state.js";
import { mountUI, unmountUI, libraryDialog as dialog } from "./react/workspace.tsx";
import { createAppTransport } from "./vendor/transport.js";
import { applyHostContext } from "./theme.js";
import {
  tabDestination,
  comparisonSelection,
  duplicateSuiteDraft,
  workspaceMatches,
} from "./workspace-controls.js";
import {
  resultKey,
  outcome,
  caseTitle,
  resultTitle,
  comparisonMatches,
  runMetrics,
  visibleResults,
  selectedResult,
  transcriptEntries,
  traceExportPayload,
} from "./presentation.js";
import { createDraftAutosave } from "./autosave.js";
import { createStatusPoller } from "./polling.js";
import { APP_SCORING, newAppSuite } from "./native-suite.js";
import { renderNativeSetup } from "./native-setup.js";
import {
  nativeAnalyzeRun,
  nativeRewritePrompt,
  createInstructionExperiment,
  renderExperiment,
  nativeCorrectJudgment,
  nativeApproveBaseline,
  nativeReleaseReport,
} from "./workflows.js";
import {
  nativeScore,
  renderNativeHistory,
  renderNativeWorkflow,
  renderNativeReport,
} from "./native-results.js";

let resumeRecoveryAutosave;
const transport = createAppTransport(),
  /** Looks up a workspace element by its DOM ID. */
  $ = (id) => document.getElementById(id);
const state = {
  page: "overview",
  suiteTab: "cases",
  runTab: "trace",
  setupPage: "instructions",
  inspectorTab: "io",
  projects: [],
  projectId: null,
  allSuites: [],
  allRuns: [],
  suites: [],
  runs: [],
  draft: null,
  dirty: false,
  run: null,
  model: null,
  limits: null,
  connected: false,
  busy: false,
  disposed: false,
  hostCapabilities: {},
  caseId: null,
  resultId: null,
  spanId: null,
  caseSearch: "",
  resultSearch: "",
  resultFilter: "All",
  workspaceSearch: "",
  suiteSearch: "",
  comparison: null,
  compareIds: [],
  compareCount: 2,
  disclosures: {},
};
const workspaceScope = createWorkspaceScope(state);
let initialResult = false,
  fileSequence = 0,
  comparisonSequence = 0,
  fieldSequence = 0;
/** Creates an HTML element with optional text content and CSS classes. */
function node(tag, text, className) {
  const el = document.createElement(tag);
  if (text != null) el.textContent = String(text);
  if (className) el.className = className;
  return el;
}
/** Builds an aria-hidden SVG for the requested symbol, falling back to the file icon. */
function icon(name) {
  const paths = {
    sidebar: ["M3 4h18v16H3zM9 4v16M5.5 7h1M5.5 10h1"],
    more: ["M5 12h.01M12 12h.01M19 12h.01"],
    close: ["M6 6l12 12M6 18L18 6"],
    suite: ["M4 6l2 2 4-4M13 6h7M4 13l2 2 4-4M13 13h7M4 20l2 2 4-4M13 20h7"],
    cpu: [
      "M7 7h10v10H7zM9 1v3M15 1v3M9 20v3M15 20v3M1 9h3M1 15h3M20 9h3M20 15h3",
    ],
    play: ["M8 5l11 7-11 7z"],
    trace: ["M4 5h7M4 12h12M4 19h7M17 3l4 2-4 2M19 10l2 2-2 2M17 17l4 2-4 2"],
    clock: ["M12 8v5l3 2"],
    file: ["M6 3h9l4 4v14H6zM14 3v5h5M9 12h7M9 16h7"],
    chevron: ["M8 4l8 8-8 8"],
    instructions: ["M4 5h16M4 12h16M4 19h10"],
    tools: [
      "M15 3a6 6 0 0 0-7 8L3 16a3 3 0 0 0 5 5l5-5a6 6 0 0 0 8-7l-4 4-6-6z",
    ],
    schema: ["M5 3H2v18h3M19 3h3v18h-3M8 8h8M8 12h8M8 16h8"],
    profile: ["M5 21v-4a7 7 0 0 1 14 0v4M8 5a4 4 0 1 0 8 0a4 4 0 1 0-8 0"],
    reset: ["M3 10a9 9 0 1 1 2 8M3 3v7h7"],
    info: ["M12 10v7M12 6v1"],
  };
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  for (const path of paths[name] || paths.file) {
    const el = document.createElementNS(svg.namespaceURI, "path");
    el.setAttribute("d", path);
    svg.append(el);
  }
  if (name === "more") {
    for (const cx of [5, 12, 19]) {
      const dot = document.createElementNS(svg.namespaceURI, "circle");
      dot.setAttribute("cx", cx);
      dot.setAttribute("cy", "12");
      dot.setAttribute("r", "1.5");
      dot.setAttribute("fill", "currentColor");
      dot.setAttribute("stroke", "none");
      svg.append(dot);
    }
  }
  if (["clock", "info"].includes(name)) {
    const circle = document.createElementNS(svg.namespaceURI, "circle");
    circle.setAttribute("cx", "12");
    circle.setAttribute("cy", "12");
    circle.setAttribute("r", "9");
    svg.append(circle);
  }
  return svg;
}
/** Creates a button whose asynchronous action is disabled while pending and reports failures through the workspace notice. */
function button(text, action, className = "secondary", disabled = false) {
  const el = node("button", text, className);
  el.type = "button";
  el.disabled = !!disabled;
  /** Closes the surrounding action menu, awaits the action, and restores the connected button’s previous disabled state even after failure. */
  el.onclick = async () => {
    el.closest(".action-menu")?.removeAttribute("open");
    const disabled = el.disabled;
    el.disabled = true;
    try {
      await action();
    } catch (error) {
      fail(error);
    } finally {
      if (el.isConnected) el.disabled = disabled;
    }
  };
  return el;
}
/** Updates the shared notice text, visibility, and error styling. */
function notice(text, error = false) {
  $("notice").hidden = !text;
  $("notice").textContent = text;
  $("notice").classList.toggle("error", error);
}
/** Displays an exception message, or its string representation, as an error notice. */
function fail(error) {
  notice(error?.message || String(error), true);
}
/**
 * Calls a local eval tool through MCP tools/call with a 180-second timeout.
 * Tool error responses become exceptions containing their text blocks; successful responses return structuredContent or an empty object.
 */
async function call(name, args = {}) {
  const response = await transport.request(
    "tools/call",
    { name, arguments: args },
    180000,
  );
  if (response.isError)
    throw Error(
      response.content
        ?.filter((item) => item.type === "text")
        .map((item) => item.text)
        .join("\n") || "The operation failed.",
    );
  return response.structuredContent || {};
}
/** Reports whether the selected run, any saved run, or a tracked instruction experiment is running. */
const active = () =>
    state.run?.status === "running" ||
    state.allRuns.some((run) => run.status === "running") ||
    state.experiment?.status === "running" ||
    state.activeExperiment?.status === "running",
  /** Formats a present timestamp with the local month, day, and time, or an em dash when absent. */
  date = (value) =>
    value
      ? new Date(value).toLocaleString(undefined, {
          month: "short",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "—",
  /** Formats finite millisecond durations in milliseconds or seconds, using an em dash for unavailable values. */
  duration = (value) =>
    Number.isFinite(value)
      ? value < 1000
        ? `${Math.round(value)} ms`
        : `${(value / 1000).toFixed(2)} s`
      : "—",
  /** Formats a fractional rate as a rounded percentage, preserving unavailable values as an em dash. */
  rate = (value) => (value == null ? "—" : `${Math.round(value * 100)}%`);
/** Creates a status badge with CSS classes derived from its displayed value. */
function pill(value) {
  return node(
    "span",
    value,
    `pill ${String(value).toLowerCase().replaceAll(" ", "-")}`,
  );
}
/** Creates a metric cell containing a label and its emphasized value. */
function metric(label, value) {
  const cell = node("div", null, "metric");
  cell.append(node("span", label), node("strong", value));
  return cell;
}
/** Builds an accessible tab group with selected-tab focus and keyboard navigation delegated to the supplied action. */
function segmented(items, selected, action, label) {
  const group = node("div", null, "segmented");
  group.setAttribute("role", "tablist");
  group.setAttribute("aria-label", label);
  for (const [index, [value, title]] of items.entries()) {
    const el = button(title, () => action(value), "segment");
    el.setAttribute("role", "tab");
    el.setAttribute("aria-selected", String(value === selected));
    el.tabIndex = value === selected ? 0 : -1;
    /** Handles supported tab-navigation keys, awaits the new selection, and focuses the selected tab after rerendering. */
    el.onkeydown = (event) => {
      const next = tabDestination(event.key, index, items.length);
      if (next == null) return;
      event.preventDefault();
      Promise.resolve(action(items[next][0]))
        .then(() => {
          const current = [
            ...document.querySelectorAll('[role="tablist"]'),
          ].find((item) => item.getAttribute("aria-label") === label);
          current?.querySelector('[aria-selected="true"]')?.focus();
        })
        .catch(fail);
    };
    group.append(el);
  }
  return group;
}
/** Creates a labeled input or textarea that applies each edit and schedules the draft for autosave. */
function field(label, value, onInput, multiline = false, className = "") {
  const wrap = node("div", null, `field ${className}`),
    caption = node("label", label),
    control = node(multiline ? "textarea" : "input");
  control.value = value ?? "";
  control.id = `field-${++fieldSequence}`;
  control.setAttribute("aria-label", label);
  caption.htmlFor = control.id;
  /** Passes the current field value to its editor callback and marks the draft dirty. */
  control.oninput = () => {
    onInput(control.value);
    markDirty();
  };
  wrap.append(caption, control);
  return wrap;
}
/** Creates a panel title with an optional count and trailing action controls. */
function panelHeader(title, count, actions = []) {
  const header = node("div", null, "panel-header"),
    text = node("h2", title);
  if (count != null) text.append(node("span", count, "count"));
  const controls = node("div", null, "actions");
  controls.append(...actions);
  header.append(text, controls);
  return header;
}
/** Creates an empty-state explanation with an optional action control. */
function empty(title, detail, action) {
  const view = node("div", null, "empty-state");
  view.append(icon("suite"), node("h2", title), node("p", detail));
  if (action) view.append(action);
  return view;
}
/**
 * Exposes the shared state, navigation scope, rendering helpers, and workspace actions to React and native views.
 * Callbacks operate on current state; asynchronous actions capture ownership where a response could otherwise update a different selection.
 */
function context() {
  return {
    state,
    scope: workspaceScope,
    mutateSuite: mutateDraft,
    trackExperiment,
    node,
    icon,
    button,
    field,
    fail,
    renderSidebar,
    renderToolbar,
    actions: {
      /** Navigates to the overview after flushing pending draft edits. */
      overview: () => setPage("overview"),
      projectDetails,
      suiteDetails,
      exportSuite,
      importSuite,
      duplicateSuite,
      showBaseline,
      deleteSuite,
      modelDetails,
      startRun,
      exportRun,
      deleteRun,
      projectReport,
      /**
       * Flushes pending edits before opening project creation or selecting another project.
       * A superseding navigation cancels the state update; selection clears suite evidence and the current run and draft before rendering the overview.
       */
      changeProject: async (id) => {
        const request = workspaceScope.navigate();
        await flush();
        if (!workspaceScope.current(request)) return;
        if (id === "__new") {
          await projectDetails(true);
          return;
        }
        state.projectId = id;
        resetSuiteEvidence(state);
        state.run = null;
        state.draft = null;
        state.page = "overview";
        filterProject();
        render();
      },
      /** Changes the active suite or run tab, loads experiments for comparison, and rerenders the main view and toolbar from the top. */
      changeTab: (value) => {
        if (state.page === "suites") {
          state.suiteTab = value;
          if (value === "compare") loadExperiments().catch(fail);
        } else state.runTab = value;
        renderMain();
        renderToolbar();
        $("main").scrollTop = 0;
      },
      /** Requests cancellation of the captured run, applies the response only to its current selection, and refreshes the catalog afterward. */
      cancelRun: async () => {
        const request = workspaceScope.capture(), runId = state.run.id;
        const result = await call("eval_cancel_run", { runId });
        if (workspaceScope.current(request) && state.run?.id === runId) state.run = result.run;
        await refresh();
      },
    },
    changed: markDirty,
    renderMain,
    panelHeader,
    caseTitle,
    resultTitle,
    empty,
    importCases,
    addReferences,
    rewritePrompt,
    date,
    duration,
    rate,
    createSuite,
    selectSuite,
    selectRun,
    runSuite,
    active,
    pill,
    metric,
    segmented,
    runHeading,
    analyzeRun,
    call,
    flush,
    dialog,
    refresh,
    render,
    notice,
    /** Resolves a scoring mode to its app label with a generic case-scoring fallback. */
    scoringLabel: (mode) => APP_SCORING[mode] || "Case scoring",
    newSuite: newAppSuite,
    /** Starts the instruction-comparison workflow with the current workspace context. */
    createExperiment: () => createInstructionExperiment(context()),
    /** Opens the judgment-correction workflow for the supplied run result in the current workspace. */
    correctJudgment: (run, result) =>
      nativeCorrectJudgment(context(), run, result),
    /** Opens the baseline-approval workflow for the supplied run in the current workspace. */
    approveBaseline: (run) => nativeApproveBaseline(context(), run),
    /** Opens the release-report workflow for the supplied run in the current workspace. */
    releaseReport: (run) => nativeReleaseReport(context(), run),
  };
}
/** Derives the visible suite and run lists from the selected project ID. */
function filterProject() {
  state.suites = state.allSuites.filter(
    (item) => item.projectId === state.projectId,
  );
  state.runs = state.allRuns.filter(
    (item) => item.projectId === state.projectId,
  );
}
/** Updates the mounted save indicator for saved, pending, or failed autosave status. */
function updateSavedLabel(status) {
  const label = $("save-state");
  if (label) {
    label.textContent =
      status === "saved"
        ? "Saved"
        : status === "error"
          ? "Could not save"
          : "Saving…";
    label.classList.toggle("unsaved", status === "error");
  }
}
const autosave = createDraftAutosave({
  /** Supplies the currently selected draft to the autosave queue. */
  read: () => state.draft,
  /**
   * Saves an autosave snapshot without server-managed revision or timestamp fields in the suite payload.
   * The project is passed separately and an existing revision becomes expectedRevision so conflicting saves are rejected by the tool.
   */
  save: async (snapshot) => {
    const { projectId, revision, updatedAt, createdAt, ...suite } = snapshot;
    return (
      await call("eval_save_suite", {
        suite,
        projectId: projectId || state.projectId,
        ...(revision ? { expectedRevision: revision } : {}),
      })
    ).suite;
  },
  /** Copies saved metadata into the current draft, replaces its catalog entry, and retains dirty status when newer edits remain pending. */
  applied: (draft, saved, current) => {
    draft.revision = saved.revision;
    draft.updatedAt = saved.updatedAt;
    draft.projectId = saved.projectId;
    const index = state.allSuites.findIndex((item) => item.id === saved.id);
    if (index < 0) state.allSuites.unshift(saved);
    else state.allSuites[index] = saved;
    filterProject();
    state.dirty = !current;
    renderSidebar();
    renderToolbar();
  },
  status: updateSavedLabel,
  error: fail,
});
/** Tracks a running experiment independently of suite selection, clears a matching completed experiment, and updates polling unless disposed. */
function trackExperiment(experiment) {
  if (state.disposed) return;
  if (experiment?.status === "running") state.activeExperiment = experiment;
  else if (state.activeExperiment?.id === experiment?.id) state.activeExperiment = null;
  renderToolbar();
  schedulePoll();
}
/**
 * Queues a server mutation only while the supplied owner remains the selected draft.
 * The mutation helper flushes autosave and merges concurrent edits; this wrapper updates the catalog while rerendering only when its captured navigation remains current.
 */
async function mutateDraft(mutate, owner = state.draft) {
  if (!owner || state.draft !== owner) return null;
  const request = workspaceScope.capture();
  return mutateSuiteDraft({
    autosave,
    /** Keeps a queued mutation attached to its original draft, returning null after a different draft is selected. */
    read: () => state.draft === owner ? owner : null,
    mutate,
    /** Replaces the saved suite’s catalog entry, retains merged-edit dirty status, and rerenders only within the original navigation scope. */
    applied: (saved, edited) => {
      const index = state.allSuites.findIndex(item => item.id === saved.id);
      if (index < 0) state.allSuites.unshift(saved); else state.allSuites[index] = saved;
      state.dirty = edited;
      filterProject();
      if (workspaceScope.current(request)) render();
    },
    changed: markDirty,
  });
}
/** Marks the draft dirty and schedules its next autosave snapshot. */
function markDirty() {
  state.dirty = true;
  autosave.changed();
}
/** Waits for pending autosaves and preserves the promise continuation boundary before navigation or teardown proceeds. */
async function flush() {
  await autosave.flush();
}
/** Flushes draft edits before changing pages, discarding a superseded navigation and resetting imported-view state and scroll. */
async function setPage(page) {
  const request = workspaceScope.navigate();
  await flush();
  if (!workspaceScope.current(request)) return;
  state.page = page;
  state.imported = false;
  render();
  $("main").scrollTop = 0;
}
/**
 * Flushes edits and clones the latest catalog version of the requested suite into the editor.
 * Only the current navigation may select it; selection resets case search and suite evidence and returns true when completed.
 */
async function selectSuite(suite) {
  const request = workspaceScope.navigate();
  await flush();
  if (!workspaceScope.current(request)) return;
  state.draft = structuredClone(
    state.allSuites.find((item) => item.id === suite.id) || suite,
  );
  state.dirty = false;
  state.page = "suites";
  state.caseId = state.draft.cases[0]?.id;
  state.caseSearch = "";
  state.imported = false;
  resetSuiteEvidence(state);
  render();
  $("main").scrollTop = 0;
  return true;
}
/** Flushes edits before selecting a new app suite, resets suite evidence and case navigation, and schedules its initial autosave. */
async function createSuite() {
  const request = workspaceScope.navigate();
  await flush();
  if (!workspaceScope.current(request)) return;
  resetSuiteEvidence(state);
  state.draft = newAppSuite(state.projectId);
  state.caseId = state.draft.cases[0].id;
  state.page = "suites";
  state.suiteTab = "cases";
  state.caseSearch = "";
  markDirty();
  render();
}
/**
 * Flushes edits and fetches a saved run before opening its requested trace or report tab.
 * Navigation checks before and after the RPC prevent a stale run response from replacing a newer selection; result filters and imported state are reset.
 */
async function selectRun(id, tab = "trace") {
  const request = workspaceScope.navigate();
  await flush();
  if (!workspaceScope.current(request)) return;
  const run = (await call("eval_get_run", { runId: id })).run;
  if (!workspaceScope.current(request)) return;
  state.run = run;
  state.page = "traces";
  state.runTab = tab;
  state.resultId = null;
  state.spanId = null;
  state.imported = false;
  state.resultSearch = "";
  state.resultFilter = "All";
  render();
  $("main").scrollTop = 0;
}
/** Starts a run only if selecting and flushing the requested suite completes in the current navigation. */
async function runSuite(suite) {
  if (await selectSuite(suite)) await startRun();
}
/**
 * Flushes the captured draft and starts a run using its saved ID and expected revision.
 * A current response opens the trace and enables polling; a stale response only refreshes the catalog, and the busy toolbar state is cleared in finally.
 */
async function startRun() {
  const request = workspaceScope.navigate(), draft = state.draft;
  await flush();
  if (!workspaceScope.current(request) || state.draft !== draft) return;
  state.busy = true;
  renderToolbar();
  try {
    const result = await call("eval_start_run", { suiteId: draft.id, expectedRevision: draft.revision });
    if (!workspaceScope.current(request)) { await refresh(); return; }
    state.run = result.run;
    state.page = "traces";
    state.runTab = "trace";
    state.resultId = null;
    state.imported = false;
    schedulePoll();
    await refresh();
    if (!workspaceScope.current(request)) return;
    notice("Evaluation running on this Mac.");
    render();
  } finally {
    state.busy = false;
    renderToolbar();
  }
}
/** Mounts the React sidebar and updates the selected project’s suite and run counts. */
function renderSidebar() {
  mountUI("sidebar", $("workspace-sidebar"), context());
  $("workspace-status").textContent =
    `${state.suites.length} suites · ${state.runs.length} runs`;
}
/** Mounts the action, breadcrumb, and tab controls, hiding view tabs on the overview. */
function renderToolbar() {
  const ctx = context();
  mountUI("actions", $("toolbar-actions"), ctx);
  mountUI("breadcrumb", $("toolbar-context"), ctx);
  mountUI("tabs", $("view-tabs"), ctx);
  $("view-tabs").hidden = state.page === "overview";
}
/** Builds the editable suite heading with scoring metadata, save status, and a details action. */
function suiteHeading() {
  const draft = state.draft,
    header = node("div", null, "page-heading"),
    mark = node("div", null, "page-symbol");
  mark.append(icon("suite"));
  const copy = node("div", null, "heading-copy"),
    input = node("input", null, "title-input");
  input.value = draft.name;
  input.setAttribute("aria-label", "Suite name");
  /** Copies the edited title into the captured suite draft and schedules autosave. */
  input.oninput = () => {
    draft.name = input.value;
    markDirty();
  };
  const meta = node("div", null, "metadata");
  meta.append(
    node("span", `${draft.cases.length} cases`),
    node("span", APP_SCORING[draft.scoringMode] || "Case scoring"),
    node("span", "On device"),
  );
  copy.append(input, meta);
  const saved = node("span", state.dirty ? "Saving…" : "Saved", "save-state");
  saved.id = "save-state";
  meta.append(saved);
  const detail = button("", suiteDetails, "icon-button");
  detail.setAttribute("aria-label", "Suite details");
  detail.append(icon("info"));
  header.append(mark, copy, detail);
  return header;
}
/** Builds a run heading with its suite title, start time, scoring mode, sample count, and evidence origin. */
function runHeading(run) {
  const header = node("div", null, "page-heading"),
    mark = node("div", null, "page-symbol");
  mark.append(icon("trace"));
  const copy = node("div", null, "heading-copy"),
    meta = node("div", null, "metadata");
  meta.append(
    node("span", date(run.startedAt)),
    node("span", APP_SCORING[run.suite?.scoringMode] || "Case scoring"),
    node("span", `${run.results?.length || 0} samples`),
    node("span", state.imported ? "Imported" : "On device"),
  );
  copy.append(
    node("h1", run.suite?.name || run.suiteName || "Evaluation"),
    meta,
  );
  header.append(mark, copy);
  return header;
}
/** Uses React for overview and case editing, unmounting it before rendering the remaining legacy views. */
function renderMain() {
  const main = $("main");
  if (
    state.page === "overview" ||
    (state.page === "suites" && state.suiteTab === "cases")
  ) {
    main.className = "";
    mountUI(state.page === "overview" ? "overview" : "cases", main, context());
  } else {
    unmountUI(main);
    main.className = "legacy-view";
    renderLegacyMain();
  }
}
/** Rebuilds the selected native suite or run view with its layout classes while preserving the main scroll position. */
function renderLegacyMain() {
  const main = $("main"),
    scroll = main.scrollTop;
  main.replaceChildren();
  main.classList.toggle(
    "trace-main",
    state.page === "traces" && state.runTab === "trace",
  );
  main.classList.toggle(
    "setup-main",
    state.page === "suites" && state.suiteTab === "setup",
  );
  if (state.page === "suites") {
    const page = node(
      "div",
      null,
      `page suite-page ${state.suiteTab === "setup" ? "setup-page" : ""}`,
    );
    page.append(suiteHeading());
    if (state.suiteTab === "setup")
      page.append(renderNativeSetup(context()));
    else if (state.suiteTab === "results")
      renderNativeHistory(
        context(),
        page,
        state.runs.filter((run) => run.suiteId === state.draft.id),
      );
    else renderCompare(page);
    main.append(page);
  } else if (state.run) {
    if (state.runTab === "trace")
      renderNativeWorkflow(context(), main, state.run);
    else renderNativeReport(context(), main, state.run);
  }
  main.scrollTop = scroll;
}
/**
 * Renders either catalog recovery or the normal sidebar, toolbar, and main workspace.
 * Recovery hides normal navigation, unmounts the React main view, and wires paging, retry, export, and confirmed removal actions.
 */
function render() {
  const recovering = !!state.catalogRecovery;
  setCatalogRecoveryLayout(document, recovering);
  for (const id of ['workspace-sidebar', 'toolbar-actions', 'toolbar-context']) $(id).hidden = recovering;
  if (recovering) {
    $('view-tabs').hidden = true;
    $('workspace-status').textContent = 'Catalog recovery';
    const main = $('main'); unmountUI(main); main.className = 'legacy-view';
    /** Loads a recovery cursor for the requested record kind, applies the returned page, and displays failures in the workspace notice. */
    const onPage = async (kind, cursor) => {
      try { await acceptResult({ structuredContent: await call('eval_catalog_recovery', { kind, cursor }) }); }
      catch (error) { fail(error); }
    };
    main.replaceChildren(renderCatalogRecovery({ node, button, data: state.catalogRecovery, canDownload: !!state.hostCapabilities.downloadFile, onPage,
      /** Retries opening the workspace and applies either its recovered catalog or the next recovery response. */
      onRetry: async () => acceptResult({ structuredContent: await call('eval_open_workspace') }),
      /** Exports the selected recovery record and passes its filename and text to the host download flow. */
      onExport: async (kind, record) => { const exported = await exportRecoveryRecord(call, kind, record); await download(exported.filename, exported.text); },
      /** Removes the exact recovery record revision with confirmation, clears affected evidence, and reloads the first recovery page. */
      onRemove: async (kind, record) => {
        await call('eval_catalog_remove', { kind, recordId: record.id, recordRevision: record.recordRevision, confirm: true });
        if (forgetRemovedRecoveryRecord(state, kind, record.id)) resetSuiteEvidence(state);
        await onPage(kind, '0');
      }
    }));
    return;
  }
  renderSidebar();
  renderToolbar();
  renderMain();
}
/**
 * Fetches project, suite, and run catalogs concurrently, handing any catalog-recovery response to the recovery view.
 * A captured refresh scope prevents stale catalog and selected-run updates; running evidence is refreshed, active editing views are preserved, and polling is rescheduled.
 */
async function refresh() {
  const request = workspaceScope.capture("refresh");
  const [projects, suites, runs] = await Promise.all([
    call("eval_list_projects"),
    call("eval_list_suites"),
    call("eval_list_runs"),
  ]);
  if (!workspaceScope.current(request)) { schedulePoll(); return; }
  const recovery = [projects, suites, runs].find((result) => result.page === 'catalogRecovery');
  if (recovery) { await acceptResult({ structuredContent: recovery }); return; }
  state.catalogRecovery = null;
  state.projects = projects.projects;
  state.allSuites = suites.suites;
  state.allRuns = runs.runs;
  state.projectId ||= state.projects[0]?.id;
  filterProject();
  if (state.run && !state.imported) {
    const id = state.run.id,
      result = await call("eval_get_run", { runId: id });
    if (workspaceScope.current(request) && id === state.run?.id) {
      const wasRunning = state.run.status === "running";
      state.run = result.run;
      if (wasRunning && result.run.status !== "running")
        notice(`Evaluation ${result.run.status}.`);
    }
  }
  const experiment = state.activeExperiment?.status === "running" ? state.activeExperiment : state.experiment;
  if (experiment?.status === "running") {
    const data = await call("eval_get_experiment", { experimentId: experiment.id });
    trackExperiment(data.experiment);
    if (workspaceScope.current(request) && state.experiment?.id === experiment.id) {
      state.experiment = data.experiment;
      state.experimentSummary = data.summary;
    }
  }
  if (!workspaceScope.current(request)) { schedulePoll(); return; }
  renderSidebar();
  renderToolbar();
  if (
    state.page !== "suites" ||
    ["results", "compare"].includes(state.suiteTab)
  )
    renderMain();
  schedulePoll();
}
const statusPoller = createStatusPoller({
  /** Allows status polling only while runnable work exists outside catalog recovery. */
  active: () => !state.catalogRecovery && active(), refresh, error: fail,
  /** Stops the status poller after the workspace has been torn down. */
  disposed: () => state.disposed,
});
const schedulePoll = statusPoller.schedule;
/**
 * Opens a project creation or editing dialog whose save action flushes pending draft edits before the project RPC.
 * The action checks navigation ownership around asynchronous work, selects the saved project, clears prior evidence, and refreshes the overview.
 */
async function projectDetails(isNew = false) {
  const project = state.projects.find((item) => item.id === state.projectId);
  dialog(isNew ? "New project" : "Project details", (el) => {
    const name = node("input"),
      description = node("textarea");
    name.value = isNew ? "" : project?.name || "";
    description.value = isNew ? "" : project?.description || "";
    name.setAttribute("aria-label", "Project name");
    description.setAttribute("aria-label", "Project description");
    el.append(
      node("label", "Name"),
      name,
      node("label", "Description"),
      description,
      button(
        isNew ? "Create project" : "Save",
        async () => {
          const request = workspaceScope.capture();
          await flush();
          if (!workspaceScope.current(request)) return;
          const result = await call(
            isNew ? "eval_create_project" : "eval_update_project",
            {
              ...(isNew ? {} : { projectId: project.id }),
              name: name.value,
              description: description.value,
            },
          );
          if (!workspaceScope.current(request)) return;
          await flush();
          if (!workspaceScope.current(request)) return;
          workspaceScope.navigate();
          resetSuiteEvidence(state);
          state.projectId = result.project.id;
          state.run = null;
          state.draft = null;
          state.page = "overview";
          el.close();
          await refresh();
          render();
        },
        "primary",
      ),
    );
  });
}
/** Flushes and saves a duplicated suite, refreshes the catalog, and selects the copy only if the original navigation is still current. */
async function duplicateSuite() {
  const request = workspaceScope.capture();
  await flush();
  if (!workspaceScope.current(request)) return;
  const suite = duplicateSuiteDraft(state.draft);
  const response = await call("eval_save_suite", {
    projectId: state.projectId,
    suite,
  });
  await refresh();
  if (!workspaceScope.current(request)) return;
  await selectSuite(response.suite);
  notice("Suite duplicated with its cases and settings.");
}
/** Opens a cancel-or-delete dialog that closes after the asynchronous removal action succeeds. */
function confirmRemoval(title, detail, action) {
  dialog(title, (el) => {
    const controls = node("div", null, "dialog-actions");
    controls.append(
      button("Cancel", () => el.close(), "secondary"),
      button(
        "Delete",
        async () => {
          await action();
          el.close();
        },
        "danger",
      ),
    );
    el.append(node("p", detail, "hint"), controls);
  });
}
/**
 * Offers deletion only for a selected suite while no run, experiment, or busy action is active.
 * The confirmed action flushes edits, deletes the suite, and clears its selection only if still owned; saved runs remain in the refreshed catalog.
 */
function deleteSuite() {
  const suite = state.draft;
  if (!suite || state.busy || active()) return;
  confirmRemoval(
    "Delete suite?",
    `Delete “${suite.name}”? Saved runs retain their suite definitions. This cannot be undone.`,
    async () => {
      const request = workspaceScope.capture();
      await flush();
      if (!workspaceScope.current(request)) return;
      await call("eval_delete_suite", { suiteId: suite.id });
      if (!workspaceScope.current(request) || state.draft !== suite) { await refresh(); return; }
      workspaceScope.navigate();
      resetSuiteEvidence(state);
      state.draft = null;
      state.dirty = false;
      state.comparison = null;
      state.page = "overview";
      await refresh();
      render();
      notice("Suite deleted. Its saved runs remain available.");
    },
  );
}
/**
 * Offers deletion for a saved, nonrunning run while no busy action is active.
 * The confirmed action deletes the captured run and clears its result and comparison state only if that selection remains current, then refreshes the catalog.
 */
function deleteRun() {
  const run = state.run;
  if (!run || state.imported || run.status === "running" || state.busy) return;
  confirmRemoval(
    "Delete run?",
    `Delete this saved run for “${run.suite?.name || run.suiteName}”? Its recorded evidence will be removed. This cannot be undone.`,
    async () => {
      const request = workspaceScope.capture();
      await call("eval_delete_run", { runId: run.id });
      if (!workspaceScope.current(request) || state.run?.id !== run.id) { await refresh(); return; }
      workspaceScope.navigate();
      state.run = null;
      state.resultId = null;
      state.spanId = null;
      state.comparison = null;
      state.compareIds = [];
      state.page = "overview";
      await refresh();
      render();
      notice("Run deleted.");
    },
  );
}
/** Flushes the suite and fetches its approved baseline, opening the evidence dialog only while the captured navigation remains current. */
async function showBaseline() {
  const request = workspaceScope.capture();
  await flush();
  if (!workspaceScope.current(request)) return;
  const response = await call("eval_get_baseline", { suiteId: state.draft.id });
  if (!workspaceScope.current(request)) return;
  dialog("Approved baseline", (el) =>
    el.append(
      node(
        "pre",
        response.baseline
          ? JSON.stringify(response, null, 2)
          : "No baseline has been approved. Open a completed run’s Report to approve it.",
        "content-well",
      ),
    ),
  );
}
/** Flushes edits and retrieves the selected project’s release report, displaying Markdown or structured data only for the current navigation. */
async function projectReport() {
  const request = workspaceScope.capture();
  await flush();
  if (!workspaceScope.current(request)) return;
  const result = await call("eval_project_release_report", {
    projectId: state.projectId,
  });
  if (!workspaceScope.current(request)) return;
  dialog("Project release report", (el) =>
    el.append(
      node(
        "pre",
        result.markdown || JSON.stringify(result.report || result, null, 2),
        "content-well",
      ),
    ),
  );
}
/** Opens editable name and version fields for the current draft or run suite and displays its saved identity and revision. */
function suiteDetails() {
  dialog("Suite details", (el) => {
    const draft = state.draft || state.run?.suite;
    el.append(
      field("Suite name", draft.name, (value) => (draft.name = value)),
      field(
        "Version",
        draft.version || "v1",
        (value) => (draft.version = value),
      ),
      node("p", `Suite ID: ${draft.id}`, "hint"),
      node(
        "p",
        `Saved revision: ${draft.revision || state.run?.suiteRevision || "not yet saved"}`,
        "hint",
      ),
      button(
        "Done",
        () => {
          render();
          el.close();
        },
        "primary",
      ),
    );
  });
}
/** Opens the local model-status dialog with an action that refreshes eval_model_status and redraws its availability details. */
async function modelDetails() {
  dialog("This Mac", (el) => {
    const content = node("div");
    el.append(content);
    /** Replaces the model-status content with current availability, reason or model name, and local engine requirements. */
    const show = () => {
      content.replaceChildren(
        node(
          "h3",
          state.model?.available
            ? "Apple Foundation Models is ready"
            : "Apple Foundation Models",
        ),
        node(
          "p",
          state.model?.reason ||
            state.model?.model ||
            "Runs locally on this Mac.",
          "hint",
        ),
        node(
          "p",
          "The complete eval engine requires macOS 27 and Xcode 27. Apple Intelligence must be enabled and its model downloaded.",
          "hint",
        ),
      );
    };
    show();
    el.append(
      button(
        "Check model",
        async () => {
          state.model = await call("eval_model_status");
          show();
        },
        "secondary",
      ),
    );
  });
}
/** Delegates prompt rewriting to the native workflow with the current workspace context and supplied test action. */
function rewritePrompt(test, action) {
  return nativeRewritePrompt(context(), test, action);
}
/** Opens a hidden file picker with the requested extensions and multiplicity, reporting callback failures and removing the input after selection or cancellation. */
function chooseFiles(accept, multiple, onFiles) {
  const input = node("input");
  input.type = "file";
  input.accept = accept;
  input.multiple = multiple;
  input.hidden = true;
  /** Passes the selected files to the asynchronous import callback, reports failures, and removes the temporary input afterward. */
  input.onchange = () =>
    Promise.resolve(onFiles([...input.files]))
      .catch(fail)
      .finally(() => input.remove());
  /** Removes the temporary file input when the picker is cancelled. */
  input.oncancel = () => input.remove();
  document.body.append(input);
  input.click();
}
/**
 * Requires host download support and requests a JSON resource download with a five-minute timeout.
 * The filename is URI-encoded in the resource URI; host error responses produce a cancellation notice instead of an export-success notice.
 */
async function download(filename, text) {
  if (!state.hostCapabilities.downloadFile)
    throw Error(
      "This Codex host does not support downloads. Use the export tool to read the saved JSON.",
    );
  const response = await transport.request(
    "ui/download-file",
    {
      contents: [
        {
          type: "resource",
          resource: {
            uri: `file:///${encodeURIComponent(filename)}`,
            mimeType: "application/json",
            text,
          },
        },
      ],
    },
    300000,
  );
  notice(response.isError ? "Export cancelled." : "Exported.");
}
/** Flushes pending edits before exporting the selected saved suite and downloading the tool-provided JSON. */
async function exportSuite() {
  await flush();
  const result = await call("eval_export_suite", { suiteId: state.draft.id });
  await download(result.filename, result.json);
}
/** Downloads tool-exported saved-run JSON or a locally serialized trace payload for an imported run. */
async function exportRun() {
  const result = state.imported
    ? {
        filename: `${state.run.id}.afevaltrace`,
        json: JSON.stringify(traceExportPayload(state.run), null, 2),
      }
    : await call("eval_export_run", { runId: state.run.id });
  await download(result.filename, result.json);
}
/**
 * Chooses a suite or trace file, flushes edits, and imports its JSON into the selected project using the matching tool.
 * The captured navigation guards import selection after file reads and catalog refresh; trace-format markers or a results field select run import.
 */
function importSuite() {
  const request = workspaceScope.capture();
  chooseFiles(".json,.afevalsuite,.afevaltrace", false, async (files) => {
    if (!files[0]) return;
    await flush();
    const text = await files[0].text(),
      payload = JSON.parse(text);
    if (!workspaceScope.current(request)) return;
    if (payload.format === "apple-foundation-evals-trace" || payload.results) {
      const { run } = await call("eval_import_run", {
        json: text,
        projectId: state.projectId,
      });
      await refresh();
      if (!workspaceScope.current(request)) return;
      await selectRun(run.id);
    } else {
      const { suite } = await call("eval_import_suite", {
        json: text,
        projectId: state.projectId,
      });
      await refresh();
      if (!workspaceScope.current(request)) return;
      await selectSuite(suite);
    }
    if (!state.disposed) notice("Imported with its saved settings and evidence.");
  });
}
/**
 * Opens JSON, JSONL, or CSV case import with optional CSV column mapping and file loading.
 * Submission mutates the captured draft at its expected revision, preserves concurrent edits, and selects the last case only while the original workspace scope remains current.
 */
function importCases() {
  const owner = state.draft, request = workspaceScope.capture();
  dialog("Import cases", (el) => {
    const format = node("select");
    format.setAttribute("aria-label", "Case file format");
    for (const value of ["json", "jsonl", "csv"])
      format.append(new Option(value.toUpperCase(), value));
    const text = node("textarea", null, "json-editor");
    text.setAttribute("aria-label", "Cases to import");
    text.placeholder = "Paste cases, or choose a file.";
    const prompt = node("input"),
      name = node("input"),
      expected = node("input");
    prompt.value = "prompt";
    name.value = "name";
    expected.value = "expected";
    for (const [input, label] of [
      [prompt, "Prompt column"],
      [name, "Name column"],
      [expected, "Expected column"],
    ])
      input.setAttribute("aria-label", label);
    const columns = node("div", null, "form-grid");
    columns.append(prompt, name, expected);
    columns.hidden = true;
    /** Shows column-mapping inputs only when CSV is selected as the case import format. */
    format.onchange = () => (columns.hidden = format.value !== "csv");
    el.append(
      format,
      button(
        "Choose file",
        () =>
          chooseFiles(".json,.jsonl,.csv", false, async (files) => {
            if (!files[0]) return;
            const extension = files[0].name.split(".").pop();
            if (["json", "jsonl", "csv"].includes(extension))
              format.value = extension;
            text.value = await files[0].text();
            columns.hidden = format.value !== "csv";
          }),
        "secondary",
      ),
      text,
      columns,
      button(
        "Import cases",
        async () => {
          if (!workspaceScope.current(request)) return;
          const result = await mutateDraft(base => call("eval_import_cases", {
            suiteId: base.id,
            expectedRevision: base.revision,
            format: format.value,
            text: text.value,
            ...(format.value === "csv"
              ? {
                  mapping: {
                    promptColumn: prompt.value,
                    nameColumn: name.value || undefined,
                    expectedColumn: expected.value || undefined,
                  },
                }
              : {}),
          }), owner);
          if (!result || !workspaceScope.current(request)) return;
          state.caseId = state.draft.cases.at(-1)?.id;
          el.close();
          await refresh();
          if (!workspaceScope.current(request)) return;
          render();
          notice(`${result.importedCount} cases imported.`);
        },
        "primary",
      ),
    );
  });
}
/** Encodes file bytes as base64 in bounded chunks to avoid oversized String.fromCharCode argument lists. */
function fileBase64(bytes) {
  let string = "";
  for (let index = 0; index < bytes.length; index += 8192)
    string += String.fromCharCode(...bytes.subarray(index, index + 8192));
  return btoa(string);
}
/**
 * Reads selected reference files sequentially, enforcing image or text byte limits and inferring missing MIME types before base64 encoding.
 * Each tool mutation uses the captured draft’s saved revision and stops after navigation changes; extraction truncation is surfaced before the catalog refresh.
 */
function addReferences() {
  const owner = state.draft, request = workspaceScope.capture();
  chooseFiles(
    ".txt,.md,.csv,.json,.pdf,.png,.jpg,.jpeg,.heic,.heif,.tiff,.gif,.webp",
    true,
    async (files) => {
      if (!workspaceScope.current(request)) return;
      for (const file of files) {
        if (!workspaceScope.current(request)) return;
        const image = /\.(png|jpe?g|heic|heif|tiff?|gif|webp)$/i.test(
            file.name,
          ),
          max = image
            ? state.limits?.maxImageBytes || 10000000
            : state.limits?.maxTextFileBytes || 5000000;
        if (file.size > max)
          throw Error(`${file.name} exceeds the ${max / 1000000} MB limit.`);
        const extension = file.name.split(".").pop().toLowerCase(),
          mime =
            file.type ||
            {
              md: "text/markdown",
              txt: "text/plain",
              csv: "text/csv",
              json: "application/json",
              pdf: "application/pdf",
              heic: "image/heic",
              heif: "image/heif",
              tiff: "image/tiff",
            }[extension] ||
            (image ? "image/" + extension : "text/plain");
        const bytes = fileBase64(new Uint8Array(await file.arrayBuffer()));
        if (!workspaceScope.current(request)) return;
        const result = await mutateDraft(base => call("eval_add_reference_file", {
          suiteId: base.id,
          name: file.name,
          mimeType: mime,
          base64: bytes,
          expectedRevision: base.revision,
        }), owner);
        if (!result || !workspaceScope.current(request)) return;
        if (result.truncated)
          notice(
            `${file.name}: extracted text was truncated to the app context limit.`,
          );
      }
      await refresh();
      if (workspaceScope.current(request)) renderMain();
    },
  );
}
/** Runs the native analysis workflow for the currently selected run. */
async function analyzeRun() {
  return nativeAnalyzeRun(context(), state.run);
}
/** Loads experiments for the captured suite and rerenders only if both the request channel and suite selection remain current. */
async function loadExperiments() {
  const suiteId = state.draft.id,
    request = workspaceScope.capture("experiment-list"),
    data = await call("eval_list_experiments", { suiteId });
  if (workspaceScope.current(request) && state.draft?.id === suiteId) {
    state.experiments = data.experiments;
    renderMain();
  }
}
/**
 * Builds saved-experiment selection and a two-to-four-run comparison interface for the selected suite.
 * Comparison requests include pairwise analysis when applicable and apply only while navigation, request sequence, suite, and selected run IDs still match; aligned outcomes and responses are rendered below.
 */
function renderCompare(page) {
  if (state.experiments?.length) {
    const picker = node("select");
    picker.setAttribute("aria-label", "Saved experiment");
    picker.append(new Option("Choose an experiment", ""));
    for (const experiment of state.experiments)
      picker.append(
        new Option(
          experiment.name || experiment.experiment?.name || experiment.id,
          experiment.id,
        ),
      );
    picker.value = state.experiment?.id || "";
    /** Loads and tracks the chosen experiment, applying its details only if the experiment-selection request and suite remain current. */
    picker.onchange = async () => {
      try {
        const request = workspaceScope.capture("experiment-selection"), suiteId = state.draft.id;
        const result = await call("eval_get_experiment", { experimentId: picker.value });
        trackExperiment(result.experiment);
        if (!workspaceScope.current(request) || state.draft?.id !== suiteId) return;
        state.experiment = result.experiment;
        state.experimentSummary = result.summary;
        renderMain();
      } catch (error) {
        fail(error);
      }
    };
    page.append(picker);
  }
  renderExperiment(context(), page);
  page.append(
    button(
      "Compare instructions",
      () => createInstructionExperiment(context()),
      "secondary",
    ),
  );
  const runs = state.runs.filter(
      (run) => run.suiteId === state.draft.id && run.status !== "running",
    ),
    panel = node("section", null, "surface");
  panel.append(panelHeader("Compare runs"));
  if (runs.length < 2) {
    panel.append(
      empty(
        "Compare saved runs",
        "Run the suite at least twice to compare responses, scores, and latency.",
      ),
    );
    page.append(panel);
    return;
  }
  state.compareCount = Math.min(state.compareCount, runs.length, 4);
  state.compareIds = comparisonSelection(
    runs,
    state.compareIds,
    state.compareCount,
  );
  const controls = node("div", null, "compare-controls"),
    countLabel = node("label", "Runs to compare"),
    count = node("select");
  count.setAttribute("aria-label", "Runs to compare");
  for (let n = 2; n <= Math.min(4, runs.length); n++)
    count.append(new Option(String(n), String(n)));
  count.value = String(state.compareCount);
  /** Changes the number of compared runs, clears previous comparison evidence, and rebuilds the controls. */
  count.onchange = () => {
    state.compareCount = Number(count.value);
    state.comparison = null;
    renderMain();
  };
  countLabel.append(count);
  controls.append(countLabel);
  for (let index = 0; index < state.compareCount; index++) {
    const title =
        index === 0
          ? "Reference"
          : state.compareCount === 2
            ? "Candidate"
            : `Run ${index + 1}`,
      label = node("label", title),
      select = node("select");
    select.setAttribute(
      "aria-label",
      index < 2 && state.compareCount === 2
        ? `${title} run`
        : index === 0
          ? "Reference run"
          : `Comparison run ${index + 1}`,
    );
    for (const run of runs)
      select.append(
        new Option(
          `${date(run.startedAt)} · ${rate(run.passed + run.failed ? run.passed / (run.passed + run.failed) : null)}`,
          run.id,
        ),
      );
    select.value = state.compareIds[index];
    /** Updates one comparison run selection, clears its previous evidence, and rerenders the comparison view. */
    select.onchange = () => {
      state.compareIds[index] = select.value;
      state.comparison = null;
      renderMain();
    };
    label.append(select);
    controls.append(label);
  }
  controls.append(
    button(
      "Compare",
      async () => {
        if (new Set(state.compareIds).size !== state.compareCount)
          throw Error("Choose different runs for each comparison.");
        const ownership = workspaceScope.capture("comparison");
        const request = {
          sequence: ++comparisonSequence,
          suiteId: state.draft.id,
          runIds: [...state.compareIds],
        };
        const [comparison, analysis] = await Promise.all([
          call("eval_compare_runs", { runIds: request.runIds }),
          request.runIds.length === 2
            ? call("eval_analyze_run", {
                runId: request.runIds[1],
                baselineRunId: request.runIds[0],
              })
            : Promise.resolve({}),
        ]);
        comparison.evidence = analysis.comparison;
        if (
          workspaceScope.current(ownership) && comparisonMatches(request, {
            sequence: comparisonSequence,
            suiteId: state.draft?.id,
            runIds: state.compareIds,
          })
        ) {
          state.comparison = comparison;
          renderMain();
        }
      },
      "primary",
    ),
  );
  panel.append(controls);
  if (state.comparison) {
    const evidence = state.comparison.evidence;
    if (evidence) {
      panel.append(
        node(
          "p",
          `Compatibility: ${evidence.compatibility} · ${evidence.improvedCaseCount} improved · ${evidence.regressedCaseCount} regressed · ${evidence.unchangedCaseCount} unchanged`,
          "hint padded",
        ),
      );
      for (const reason of [
        ...(evidence.incompatibilityReasons || []),
        ...(evidence.warnings || []).map((warning) =>
          typeof warning === "string"
            ? warning
                .replace(/([a-z])([A-Z])/g, "$1 $2")
                .replace(/^./, (letter) => letter.toUpperCase())
            : warning.message || JSON.stringify(warning),
        ),
      ])
        panel.append(node("p", reason, "evidence-warning"));
    }
    const results =
      state.comparison.alignedResults || state.comparison.cases || [];
    if (results.length) {
      const table = node("table", null, "data-table comparison-table"),
        head = node("tr");
      head.append(node("th", "Case"));
      for (const [index, run] of state.comparison.runs.entries())
        head.append(
          node(
            "th",
            `${index === 0 ? "Reference" : `Run ${index + 1}`} · ${date(run.startedAt)}`,
          ),
        );
      const thead = node("thead");
      thead.append(head);
      table.append(thead);
      const tbody = node("tbody");
      for (const item of results) {
        const row = node("tr");
        row.append(
          node(
            "td",
            item.caseId ? resultTitle({ suite: state.draft }, item) : item.key,
          ),
        );
        for (const comparedRun of state.comparison.runs) {
          const result = item.results.find(
            (sample) => sample.runId === comparedRun.id,
          );
          const cell = node("td");
          cell.append(
            node("strong", result ? outcome(result) : "No result"),
            node("pre", result?.response || "", "comparison-response"),
          );
          row.append(cell);
        }
        tbody.append(row);
      }
      table.append(tbody);
      const scroll = node("div", null, "data-table-scroll");
      scroll.append(table);
      panel.append(scroll);
    } else
      panel.append(
        node("pre", JSON.stringify(state.comparison, null, 2), "content-well"),
      );
  }
  page.append(panel);
}
/**
 * Flushes edits and reads a host-provided .afevaltrace resource as text or decoded base64, rejecting content larger than 32 MiB before parsing.
 * The eval_parse_trace result opens as imported evidence only if both the file sequence and navigation scope remain current; catalog refresh follows asynchronously.
 */
async function openFile(file) {
  const request = workspaceScope.navigate();
  await flush();
  if (!workspaceScope.current(request)) return;
  if (
    !file?.name?.endsWith(".afevaltrace") ||
    typeof file.resourceUri !== "string"
  )
    throw Error("Open a .afevaltrace file to inspect its saved evidence.");
  const sequence = ++fileSequence,
    response = await transport.request("resources/read", {
      uri: file.resourceUri,
      _meta: { "openai/resource": { representation: "text" } },
    });
  const content = response.contents?.[0],
    text =
      content?.text ??
      (content?.blob
        ? new TextDecoder().decode(
            Uint8Array.from(atob(content.blob), (c) => c.charCodeAt(0)),
          )
        : "");
  if (new TextEncoder().encode(text).length > 32 * 1024 * 1024)
    throw Error("Trace file exceeds32 MiB.");
  const { run } = await call("eval_parse_trace", { json: text });
  if (sequence !== fileSequence || !workspaceScope.current(request)) return;
  state.run = run;
  state.page = "traces";
  state.runTab = "trace";
  state.resultId = null;
  state.imported = true;
  render();
  refresh().catch(fail);
}
/**
 * Accepts structured tool results from either notification shape and ignores missing data or disposed workspaces.
 * Catalog recovery pauses autosave until a workspace result resumes it and replaces the catalog, model status, and limits; trace results delegate to the guarded resource-opening flow.
 */
async function acceptResult(payload) {
  const data = payload?.structuredContent ?? payload?.result?.structuredContent;
  if (!data || state.disposed) return;
  initialResult = true;
  if (data.page === 'catalogRecovery') {
    if (!state.catalogRecovery) resumeRecoveryAutosave = autosave.pause();
    state.catalogRecovery = data;
    render();
    return;
  }
  if (data.page === "workspace") {
    state.catalogRecovery = null;
    resumeRecoveryAutosave?.(); resumeRecoveryAutosave = null;
    state.projects = data.projects || [];
    state.projectId ||= data.defaultProjectId || state.projects[0]?.id;
    state.allSuites = data.suites || [];
    state.allRuns = data.runs || [];
    state.model = data.model;
    state.limits = data.limits;
    filterProject();
    render();
    schedulePoll();
  } else if (data.page === "trace" && data.file) await openFile(data.file);
}
$("sidebar-toggle").append(icon("sidebar"));
/** Synchronizes sidebar expansion accessibility and inertness with narrow-screen open or wide-screen hidden state. */
function updateSidebar() {
  const narrow = matchMedia("(max-width:600px)").matches,
    open = narrow
      ? document.body.classList.contains("sidebar-open")
      : !document.body.classList.contains("sidebar-hidden");
  $("sidebar-toggle").setAttribute("aria-expanded", String(open));
  $("workspace-sidebar").inert = !open;
}
/** Toggles the responsive sidebar visibility class and synchronizes its accessibility state. */
$("sidebar-toggle").onclick = () => {
  document.body.classList.toggle(
    matchMedia("(max-width:600px)").matches ? "sidebar-open" : "sidebar-hidden",
  );
  updateSidebar();
};
matchMedia("(max-width:600px)").addEventListener("change", updateSidebar);
updateSidebar();
document.querySelector("aside").addEventListener("click", (event) => {
  if (event.target.closest("button")) {
    document.body.classList.remove("sidebar-open");
    updateSidebar();
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    for (const menu of document.querySelectorAll(".action-menu[open]"))
      menu.removeAttribute("open");
    document.body.classList.remove("sidebar-open");
    updateSidebar();
  }
  if ((event.metaKey || event.ctrlKey) && event.key === "f") {
    event.preventDefault();
    document.body.classList.remove("sidebar-hidden");
    if (matchMedia("(max-width:600px)").matches)
      document.body.classList.add("sidebar-open");
    updateSidebar();
    $("workspace-search")?.focus();
  }
});
transport.on("ui/notifications/tool-result", (payload) =>
  acceptResult(payload).catch(fail),
);
transport.on("ui/notifications/tool-input", (payload) => {
  if (payload.arguments?.file) openFile(payload.arguments.file).catch(fail);
});
/**
 * Invalidates earlier navigation and awaits autosave before disposing workspace services.
 * A flush failure rejects teardown before disposal; transport disposal is deferred until after the response.
 */
transport.handle("ui/resource-teardown", async () => {
  workspaceScope.navigate();
  await flush();
  state.disposed = true;
  statusPoller.dispose();
  autosave.dispose();
  setTimeout(() => transport.dispose(), 0);
  return {};
});
transport.on("ui/notifications/host-context-changed", (payload) =>
  applyHostContext(payload.hostContext || payload, document),
);
render();
if (parent !== window) {
  transport
    .request("ui/initialize", {
      protocolVersion: "2026-01-26",
      appInfo: { name: "apple-foundation-evals", version: "0.5.0" },
      appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
    })
    .then((response) => {
      if (state.disposed) return;
      if (response.protocolVersion !== "2026-01-26")
        throw Error("Unsupported MCP app UI protocol.");
      applyHostContext(response.hostContext, document);
      state.connected = true;
      state.hostCapabilities = response.hostCapabilities || {};
      if (state.catalogRecovery) render();
      transport.notify("ui/notifications/initialized");
      setTimeout(() => {
        if (!initialResult && !state.disposed)
          call("eval_open_workspace")
            .then((data) => acceptResult({ structuredContent: data }))
            .catch(fail);
      }, 500);
    })
    .catch(fail);
} else
  notice(
    "Open Foundation Evals in Codex to connect this workspace to its local model runner.",
  );
