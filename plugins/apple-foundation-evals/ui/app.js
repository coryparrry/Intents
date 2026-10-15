import { mountUI, unmountUI, libraryDialog } from "./react/workspace.tsx";
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
import { APP_SCORING, newAppSuite, renderNativeCases } from "./native-suite.js";
import { renderNativeSetup } from "./native-setup.js";
import { renderNativeOverview } from "./native-overview.js";
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

const transport = createAppTransport(),
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
let polling,
  initialResult = false,
  fileSequence = 0,
  comparisonSequence = 0,
  fieldSequence = 0;
function node(tag, text, className) {
  const el = document.createElement(tag);
  if (text != null) el.textContent = String(text);
  if (className) el.className = className;
  return el;
}
function icon(name) {
  const paths = {
    sidebar: ["M3 4h18v16H3zM9 4v16M5.5 7h1M5.5 10h1"],
    plus: ["M12 5v14M5 12h14"],
    more: ["M5 12h.01M12 12h.01M19 12h.01"],
    close: ["M6 6l12 12M6 18L18 6"],
    down: ["M7 10l5 5 5-5"],
    suite: ["M4 6l2 2 4-4M13 6h7M4 13l2 2 4-4M13 13h7M4 20l2 2 4-4M13 20h7"],
    search: ["M21 21l-5-5"],
    cpu: [
      "M7 7h10v10H7zM9 1v3M15 1v3M9 20v3M15 20v3M1 9h3M1 15h3M20 9h3M20 15h3",
    ],
    play: ["M8 5l11 7-11 7z"],
    trace: ["M4 5h7M4 12h12M4 19h7M17 3l4 2-4 2M19 10l2 2-2 2M17 17l4 2-4 2"],
    clock: ["M12 8v5l3 2"],
    file: ["M6 3h9l4 4v14H6zM14 3v5h5M9 12h7M9 16h7"],
    project: ["M3 7l9-5 9 5-9 5zM3 12l9 5 9-5M3 17l9 5 9-5"],
    chevron: ["M8 4l8 8-8 8"],
    instructions: ["M4 5h16M4 12h16M4 19h10"],
    tools: [
      "M15 3a6 6 0 0 0-7 8L3 16a3 3 0 0 0 5 5l5-5a6 6 0 0 0 8-7l-4 4-6-6z",
    ],
    schema: ["M5 3H2v18h3M19 3h3v18h-3M8 8h8M8 12h8M8 16h8"],
    profile: ["M5 21v-4a7 7 0 0 1 14 0v4M8 5a4 4 0 1 0 8 0a4 4 0 1 0-8 0"],
    reset: ["M3 10a9 9 0 1 1 2 8M3 3v7h7"],
    info: ["M12 10v7M12 6v1"],
    overview: ["M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z"],
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
  if (["search", "clock", "info"].includes(name)) {
    const circle = document.createElementNS(svg.namespaceURI, "circle");
    circle.setAttribute("cx", name === "search" ? "10" : "12");
    circle.setAttribute("cy", name === "search" ? "10" : "12");
    circle.setAttribute("r", name === "search" ? "6.5" : "9");
    svg.append(circle);
  }
  return svg;
}
function button(text, action, className = "secondary", disabled = false) {
  const el = node("button", text, className);
  el.type = "button";
  el.disabled = !!disabled;
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
function notice(text, error = false) {
  $("notice").hidden = !text;
  $("notice").textContent = text;
  $("notice").classList.toggle("error", error);
}
function fail(error) {
  notice(error?.message || String(error), true);
}
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
const clone = (value) => structuredClone(value),
  active = () =>
    state.allRuns.some((run) => run.status === "running") ||
    state.experiment?.status === "running",
  date = (value) =>
    value
      ? new Date(value).toLocaleString(undefined, {
          month: "short",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "—",
  duration = (value) =>
    Number.isFinite(value)
      ? value < 1000
        ? `${Math.round(value)} ms`
        : `${(value / 1000).toFixed(2)} s`
      : "—",
  rate = (value) => (value == null ? "—" : `${Math.round(value * 100)}%`);
function pill(value) {
  return node(
    "span",
    value,
    `pill ${String(value).toLowerCase().replaceAll(" ", "-")}`,
  );
}
function metric(label, value) {
  const cell = node("div", null, "metric");
  cell.append(node("span", label), node("strong", value));
  return cell;
}
function segmented(items, selected, action, label) {
  const group = node("div", null, "segmented");
  group.setAttribute("role", "tablist");
  group.setAttribute("aria-label", label);
  for (const [index, [value, title]] of items.entries()) {
    const el = button(title, () => action(value), "segment");
    el.setAttribute("role", "tab");
    el.setAttribute("aria-selected", String(value === selected));
    el.tabIndex = value === selected ? 0 : -1;
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
function field(label, value, onInput, multiline = false, className = "") {
  const wrap = node("div", null, `field ${className}`),
    caption = node("label", label),
    control = node(multiline ? "textarea" : "input");
  control.value = value ?? "";
  control.id = `field-${++fieldSequence}`;
  control.setAttribute("aria-label", label);
  caption.htmlFor = control.id;
  control.oninput = () => {
    onInput(control.value);
    markDirty();
  };
  wrap.append(caption, control);
  return wrap;
}
function panelHeader(title, count, actions = []) {
  const header = node("div", null, "panel-header"),
    text = node("h2", title);
  if (count != null) text.append(node("span", count, "count"));
  const controls = node("div", null, "actions");
  controls.append(...actions);
  header.append(text, controls);
  return header;
}
function empty(title, detail, action) {
  const view = node("div", null, "empty-state");
  view.append(icon("suite"), node("h2", title), node("p", detail));
  if (action) view.append(action);
  return view;
}
function context() {
  return {
    state,
    node,
    icon,
    button,
    field,
    fail,
    renderSidebar,
    renderToolbar,
    actions: {
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
      changeProject: async (id) => {
        await flush();
        if (id === "__new") {
          await projectDetails(true);
          return;
        }
        state.projectId = id;
        state.draft = null;
        state.page = "overview";
        filterProject();
        render();
      },
      changeTab: (value) => {
        if (state.page === "suites") {
          state.suiteTab = value;
          if (value === "compare") loadExperiments().catch(fail);
        } else state.runTab = value;
        renderMain();
        renderToolbar();
        $("main").scrollTop = 0;
      },
      cancelRun: async () => {
        state.run = (
          await call("eval_cancel_run", { runId: state.run.id })
        ).run;
        await refresh();
        render();
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
    jsonEditor,
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
    scoringLabel: (mode) => APP_SCORING[mode] || "Case scoring",
    newSuite: newAppSuite,
    createExperiment: () => createInstructionExperiment(context()),
    correctJudgment: (run, result) =>
      nativeCorrectJudgment(context(), run, result),
    approveBaseline: (run) => nativeApproveBaseline(context(), run),
    releaseReport: (run) => nativeReleaseReport(context(), run),
  };
}
function filterProject() {
  state.suites = state.allSuites.filter(
    (item) => item.projectId === state.projectId,
  );
  state.runs = state.allRuns.filter(
    (item) => item.projectId === state.projectId,
  );
}
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
  read: () => state.draft,
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
function markDirty() {
  state.dirty = true;
  autosave.changed();
}
async function flush() {
  await autosave.flush();
}
async function setPage(page) {
  await flush();
  state.page = page;
  state.imported = false;
  render();
  $("main").scrollTop = 0;
}
async function selectSuite(suite) {
  await flush();
  state.draft = clone(
    state.allSuites.find((item) => item.id === suite.id) || suite,
  );
  state.dirty = false;
  state.page = "suites";
  state.caseId = state.draft.cases[0]?.id;
  state.caseSearch = "";
  state.imported = false;
  state.experiments = null;
  state.experiment = null;
  state.experimentSummary = null;
  render();
  $("main").scrollTop = 0;
}
async function createSuite() {
  await flush();
  state.draft = newAppSuite(state.projectId);
  state.caseId = state.draft.cases[0].id;
  state.page = "suites";
  state.suiteTab = "cases";
  state.caseSearch = "";
  markDirty();
  render();
}
async function selectRun(id, tab = "trace") {
  await flush();
  const run = (await call("eval_get_run", { runId: id })).run;
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
async function runSuite(suite) {
  await selectSuite(suite);
  await startRun();
}
async function startRun() {
  await flush();
  state.busy = true;
  renderToolbar();
  try {
    state.run = (
      await call("eval_start_run", {
        suiteId: state.draft.id,
        expectedRevision: state.draft.revision,
      })
    ).run;
    state.page = "traces";
    state.runTab = "trace";
    state.resultId = null;
    state.imported = false;
    await refresh();
    notice("Evaluation running on this Mac.");
    render();
  } finally {
    state.busy = false;
    renderToolbar();
  }
}
function renderSidebar() {
  mountUI("sidebar", $("workspace-sidebar"), context());
  $("workspace-status").textContent =
    `${state.suites.length} suites · ${state.runs.length} runs`;
}
function renderToolbar() {
  const ctx = context();
  mountUI("actions", $("toolbar-actions"), ctx);
  mountUI("breadcrumb", $("toolbar-context"), ctx);
  mountUI("tabs", $("view-tabs"), ctx);
  $("view-tabs").hidden = state.page === "overview";
}
function suiteHeading() {
  const draft = state.draft,
    header = node("div", null, "page-heading"),
    mark = node("div", null, "page-symbol");
  mark.append(icon("suite"));
  const copy = node("div", null, "heading-copy"),
    input = node("input", null, "title-input");
  input.value = draft.name;
  input.setAttribute("aria-label", "Suite name");
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
function renderLegacyMain() {
  const main = $("main"),
    scroll = main.scrollTop;
  main.replaceChildren();
  main.classList.toggle(
    "trace-main",
    state.page === "traces" && state.runTab === "trace",
  );
  main.classList.toggle(
    "cases-main",
    state.page === "suites" && state.suiteTab === "cases",
  );
  main.classList.toggle(
    "setup-main",
    state.page === "suites" && state.suiteTab === "setup",
  );
  if (state.page === "overview") main.append(renderNativeOverview(context()));
  else if (state.page === "suites") {
    const page = node(
      "div",
      null,
      `page suite-page ${state.suiteTab === "cases" ? "cases-page" : state.suiteTab === "setup" ? "setup-page" : ""}`,
    );
    page.append(suiteHeading());
    if (state.suiteTab === "cases") page.append(renderNativeCases(context()));
    else if (state.suiteTab === "setup")
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
function render() {
  renderSidebar();
  renderToolbar();
  renderMain();
}
async function refresh() {
  const [projects, suites, runs] = await Promise.all([
    call("eval_list_projects"),
    call("eval_list_suites"),
    call("eval_list_runs"),
  ]);
  if (state.disposed) return;
  state.projects = projects.projects;
  state.allSuites = suites.suites;
  state.allRuns = runs.runs;
  state.projectId ||= state.projects[0]?.id;
  filterProject();
  if (state.run && !state.imported) {
    const id = state.run.id,
      result = await call("eval_get_run", { runId: id });
    if (id === state.run?.id) {
      const wasRunning = state.run.status === "running";
      state.run = result.run;
      if (wasRunning && result.run.status !== "running")
        notice(`Evaluation ${result.run.status}.`);
    }
  }
  if (state.experiment?.status === "running") {
    const data = await call("eval_get_experiment", {
      experimentId: state.experiment.id,
    });
    state.experiment = data.experiment;
    state.experimentSummary = data.summary;
  }
  renderSidebar();
  renderToolbar();
  if (
    state.page !== "suites" ||
    ["results", "compare"].includes(state.suiteTab)
  )
    renderMain();
  schedulePoll();
}
function schedulePoll() {
  clearTimeout(polling);
  if (active() && !state.disposed)
    polling = setTimeout(() => refresh().catch(fail), 1800);
}
function dialog(title, renderBody) {
  return libraryDialog(title, renderBody);
}
function jsonEditor(title, object, applied) {
  dialog(title, (el) => {
    const input = node(
        "textarea",
        JSON.stringify(object, null, 2),
        "json-editor",
      ),
      message = node("p", null, "hint");
    input.setAttribute("aria-label", title);
    el.append(
      input,
      message,
      button(
        "Apply",
        () => {
          try {
            const value = JSON.parse(input.value);
            applied(value);
            markDirty();
            renderMain();
            el.close();
          } catch (error) {
            message.textContent = error.message;
          }
        },
        "primary",
      ),
    );
  });
}
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
          await flush();
          const result = await call(
            isNew ? "eval_create_project" : "eval_update_project",
            {
              ...(isNew ? {} : { projectId: project.id }),
              name: name.value,
              description: description.value,
            },
          );
          state.projectId = result.project.id;
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
async function duplicateSuite() {
  await flush();
  const suite = duplicateSuiteDraft(state.draft);
  const response = await call("eval_save_suite", {
    projectId: state.projectId,
    suite,
  });
  await refresh();
  await selectSuite(response.suite);
  notice("Suite duplicated with its cases and settings.");
}
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
function deleteSuite() {
  const suite = state.draft;
  if (!suite || state.busy || active()) return;
  confirmRemoval(
    "Delete suite?",
    `Delete “${suite.name}”? Saved runs retain their suite definitions. This cannot be undone.`,
    async () => {
      await flush();
      await call("eval_delete_suite", { suiteId: suite.id });
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
function deleteRun() {
  const run = state.run;
  if (!run || state.imported || run.status === "running" || state.busy) return;
  confirmRemoval(
    "Delete run?",
    `Delete this saved run for “${run.suite?.name || run.suiteName}”? Its recorded evidence will be removed. This cannot be undone.`,
    async () => {
      await call("eval_delete_run", { runId: run.id });
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
async function showBaseline() {
  await flush();
  const response = await call("eval_get_baseline", { suiteId: state.draft.id });
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
async function projectReport() {
  await flush();
  const result = await call("eval_project_release_report", {
    projectId: state.projectId,
  });
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
async function modelDetails() {
  dialog("This Mac", (el) => {
    const content = node("div");
    el.append(content);
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
function rewritePrompt(test, action) {
  return nativeRewritePrompt(context(), test, action);
}
function chooseFiles(accept, multiple, onFiles) {
  const input = node("input");
  input.type = "file";
  input.accept = accept;
  input.multiple = multiple;
  input.hidden = true;
  input.onchange = () =>
    Promise.resolve(onFiles([...input.files]))
      .catch(fail)
      .finally(() => input.remove());
  input.oncancel = () => input.remove();
  document.body.append(input);
  input.click();
}
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
async function exportSuite() {
  await flush();
  const result = await call("eval_export_suite", { suiteId: state.draft.id });
  await download(result.filename, result.json);
}
async function exportRun() {
  const result = state.imported
    ? {
        filename: `${state.run.id}.afevaltrace`,
        json: JSON.stringify(traceExportPayload(state.run), null, 2),
      }
    : await call("eval_export_run", { runId: state.run.id });
  await download(result.filename, result.json);
}
function importSuite() {
  chooseFiles(".json,.afevalsuite,.afevaltrace", false, async (files) => {
    if (!files[0]) return;
    await flush();
    const text = await files[0].text(),
      payload = JSON.parse(text);
    if (payload.format === "apple-foundation-evals-trace" || payload.results) {
      const { run } = await call("eval_import_run", {
        json: text,
        projectId: state.projectId,
      });
      await refresh();
      await selectRun(run.id);
    } else {
      const { suite } = await call("eval_import_suite", {
        json: text,
        projectId: state.projectId,
      });
      await refresh();
      await selectSuite(suite);
    }
    notice("Imported with its saved settings and evidence.");
  });
}
function importCases() {
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
          await flush();
          const result = await call("eval_import_cases", {
            suiteId: state.draft.id,
            expectedRevision: state.draft.revision,
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
          });
          state.draft = clone(result.suite);
          state.dirty = false;
          state.caseId = state.draft.cases.at(-1)?.id;
          el.close();
          await refresh();
          render();
          notice(`${result.importedCount} cases imported.`);
        },
        "primary",
      ),
    );
  });
}
function fileBase64(bytes) {
  let string = "";
  for (let index = 0; index < bytes.length; index += 8192)
    string += String.fromCharCode(...bytes.subarray(index, index + 8192));
  return btoa(string);
}
function addReferences() {
  chooseFiles(
    ".txt,.md,.csv,.json,.pdf,.png,.jpg,.jpeg,.heic,.heif,.tiff,.gif,.webp",
    true,
    async (files) => {
      await flush();
      const suiteId = state.draft.id;
      for (const file of files) {
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
        const result = await call("eval_add_reference_file", {
          suiteId,
          name: file.name,
          mimeType: mime,
          base64: fileBase64(new Uint8Array(await file.arrayBuffer())),
          expectedRevision: state.draft.revision,
        });
        if (state.draft.id !== suiteId)
          throw Error("The selected suite changed during import.");
        state.draft = clone(result.suite);
        if (result.truncated)
          notice(
            `${file.name}: extracted text was truncated to the app context limit.`,
          );
      }
      await refresh();
      renderMain();
    },
  );
}
async function analyzeRun() {
  return nativeAnalyzeRun(context(), state.run);
}
async function loadExperiments() {
  const suiteId = state.draft.id,
    data = await call("eval_list_experiments", { suiteId });
  if (state.draft?.id === suiteId) {
    state.experiments = data.experiments;
    renderMain();
  }
}
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
    picker.onchange = async () => {
      try {
        const result = await call("eval_get_experiment", {
          experimentId: picker.value,
        });
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
          comparisonMatches(request, {
            sequence: comparisonSequence,
            suiteId: state.draft.id,
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
async function openFile(file) {
  await flush();
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
  if (sequence !== fileSequence || state.disposed) return;
  state.run = run;
  state.page = "traces";
  state.runTab = "trace";
  state.resultId = null;
  state.imported = true;
  render();
  refresh().catch(fail);
}
async function acceptResult(payload) {
  const data = payload?.structuredContent ?? payload?.result?.structuredContent;
  if (!data) return;
  initialResult = true;
  if (data.page === "workspace") {
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
$("overview-tab").onclick = () => setPage("overview").catch(fail);
$("new-suite").onclick = () => createSuite().catch(fail);
$("workspace-symbol").append(icon("suite"));
$("overview-symbol").append(icon("overview"));
$("add-symbol").append(icon("plus"));
$("project-details").append(icon("down"));
$("sidebar-toggle").append(icon("sidebar"));
$("search-symbol").append(icon("search"));
$("workspace-search").placeholder = "Search workspace";
$("workspace-search").setAttribute("aria-label", "Search workspace");
$("project-symbol").append(icon("project"));
$("workspace-search").oninput = (event) => {
  state.workspaceSearch = event.target.value;
  renderSidebar();
};
$("project-select").onchange = async (event) => {
  const id = event.target.value;
  try {
    await flush();
    if (id === "__new") {
      renderSidebar();
      await projectDetails(true);
      return;
    }
    state.projectId = id;
    state.draft = null;
    state.page = "overview";
    filterProject();
    render();
  } catch (error) {
    fail(error);
    renderSidebar();
  }
};
$("project-details").onclick = () => projectDetails().catch(fail);
function updateSidebar() {
  const narrow = matchMedia("(max-width:600px)").matches,
    open = narrow
      ? document.body.classList.contains("sidebar-open")
      : !document.body.classList.contains("sidebar-hidden");
  $("sidebar-toggle").setAttribute("aria-expanded", String(open));
  $("workspace-sidebar").inert = !open;
}
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
    $("workspace-search").focus();
  }
});
transport.on("ui/notifications/tool-result", (payload) =>
  acceptResult(payload).catch(fail),
);
transport.on("ui/notifications/tool-input", (payload) => {
  if (payload.arguments?.file) openFile(payload.arguments.file).catch(fail);
});
transport.handle("ui/resource-teardown", async () => {
  await flush();
  state.disposed = true;
  clearTimeout(polling);
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
      if (response.protocolVersion !== "2026-01-26")
        throw Error("Unsupported MCP app UI protocol.");
      applyHostContext(response.hostContext, document);
      state.connected = true;
      state.hostCapabilities = response.hostCapabilities || {};
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
