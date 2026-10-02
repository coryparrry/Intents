import {cases, spans, filterCases, resolveSelection, escapeHTML as esc} from './demo-data.mjs';

const screen = document.querySelector('#native-screen');
const app = document.querySelector('#native-app');
const viewport = document.querySelector('#app-viewport');
const announcement = document.querySelector('#demo-announcement');
const media = matchMedia('(prefers-reduced-motion: reduce)');
let view = 'report';
let filter = 'all';
let query = '';
let selectedCase = cases[0].id;
let selectedSpan = 0;
let collapsed = false;
let motionContext;
let userPaused = false;
try { userPaused = localStorage.getItem('intents-motion-paused') === 'true'; } catch { /* Preferences are optional. */ }

const icon = (name, className = 'icon') => `<svg class="${className}" aria-hidden="true"><use href="/assets/icons.svg#${name}"/></svg>`;
const passed = '<span class="check-circle" aria-hidden="true">✓</span>';

const mobilePreview = window.matchMedia('(max-width: 760px)');
new ResizeObserver(([entry]) => {
  app.style.transform = !mobilePreview.matches ? `scale(${Math.round(entry.contentRect.width) / 1400})` : '';
}).observe(viewport);

function reportMarkup() {
  return `<div class="report-screen">
    <div class="native-title-row"><div><p class="native-date">Thursday 17 September at 5:34 pm</p><h2 class="native-title">Conversation behaviour</h2></div><span class="native-complete">${passed} Completed</span></div>
    <p class="native-model">On-device · AFM 3 Core Advanced · Judged by Custom judge · deepseek-flash</p>
    <details class="native-disclosure"><summary>Run information</summary><p>Version v1 · 3 cases · 1 repetition each · AI rubric scoring<br>Recorded on 17 September 2026. This website replays the saved evidence; it does not run a model.</p></details>
    <div class="native-panel result-summary"><h3>All responses passed their checks</h3><div><span>${icon('circle-check')}3 passed</span><span>${icon('circle-x')}0 failed</span><span>3 of 3 responses collected</span></div><p>Select a response below to read it and see why it passed.</p></div>
    <div class="native-panel results-panel"><div class="results-heading"><h3>Results</h3><span class="result-count" id="result-count">3</span><div class="result-filters" role="group" aria-label="Result filter">${['all','passed','failed','issues'].map(key => `<button data-filter="${key}" class="${filter === key ? 'active' : ''}" aria-pressed="${filter === key}">${key[0].toUpperCase()+key.slice(1)}</button>`).join('')}</div><label class="result-search">${icon('search')}<span class="sr-only">Search case, prompt, or response</span><input type="search" id="result-search" placeholder="Search results" value="${esc(query)}" autocomplete="off"></label></div>
      <div class="native-table-wrap"><table class="native-table" aria-label="Recorded evaluation results"><thead><tr><th>Case</th><th>Outcome</th><th>Score</th><th>Response time</th><th>Repetition</th></tr></thead><tbody id="result-rows"></tbody></table></div>
      <div id="response-detail"></div>
    </div>
    <details class="native-disclosure"><summary>Performance and comparison</summary><p>The selected run contains three recorded responses: 9 secs, 382 ms; 993 ms; and 4 secs, 757 ms. Open the Workflow trace above to inspect the first case’s measured stages.</p></details>
    <details class="native-disclosure"><summary>Run configuration</summary><p>On-device · AFM 3 Core Advanced<br>AI rubric · Custom judge · deepseek-flash<br>1 repetition for each of 3 cases</p></details>
  </div>`;
}

function renderResults() {
  const shown = filterCases(cases, filter, query);
  const current = resolveSelection(shown, selectedCase);
  if (current) selectedCase = current.id;
  document.querySelector('#result-count').textContent = shown.length;
  document.querySelector('#result-rows').innerHTML = shown.length ? shown.map(item => `<tr data-case="${item.id}" class="${current?.id === item.id ? 'selected' : ''}"><td><button data-case="${item.id}" aria-pressed="${current?.id === item.id}">${esc(item.name)}</button></td><td><span class="table-passed">${passed} Passed</span></td><td>${item.score}</td><td>${item.time}</td><td>1 / 1</td></tr>`).join('') : '<tr><td colspan="5" class="table-empty">No matching responses in this recorded run.</td></tr>';
  document.querySelector('#response-detail').innerHTML = current ? `<article class="response-detail" aria-label="Selected response">
    <div class="response-heading">${passed}<div><h4>${esc(current.name)}</h4><p>Judged by Custom judge · deepseek-flash</p></div><span class="green-pill">Passed</span><span>${current.score}</span></div>
    <p class="response-field"><small>Prompt</small>${esc(current.prompt)}</p><p class="response-field"><small>Expected or reference answer</small>${esc(current.expected)}</p>
    <div class="response-field-head"><span>Response</span><button class="copy-button" id="copy-response">${icon('copy')}<span>Copy Response</span></button></div><pre class="response-text">${esc(current.response)}</pre><div class="response-why"><h5>Why it passed</h5><p>${esc(current.reason)}</p></div>
    <details class="native-disclosure"><summary>Response details</summary><p>Score: ${current.score} · Response time: ${current.time} · Repetition: 1 / 1<br>Scoring evidence is the recorded judge’s assessment of this example.</p></details>
  </article>` : '<p class="no-results-detail">Choose All or change your search to explore the recorded responses.</p>';
  document.querySelectorAll('[data-filter]').forEach(button => {
    button.classList.toggle('active', button.dataset.filter === filter);
    button.setAttribute('aria-pressed', button.dataset.filter === filter);
  });
}

function traceMarkup() {
  const metrics = [['Outcome','Passed'],['Workflow','18.39 s'],['Subject request','9.38 s'],['Subject tokens','1,138'],['First content','442 ms']];
  return `<div class="trace-screen"><div class="trace-native-header"><p class="native-date">Workflow trace</p><h2 class="native-title">Conversation behaviour</h2><p class="native-model">On-device · AFM 3 Core Advanced　 ◇ AI rubric　 · 17 Sep at 5:34 pm　 · 3 / 3 samples</p><div class="trace-metrics">${metrics.map(([label,value]) => `<div class="trace-metric">${label}<b>${value}</b></div>`).join('')}</div></div>
    <div class="trace-span-toolbar"><div>13 spans <span>· App-observed timing</span></div><button id="collapse-spans" aria-expanded="${!collapsed}">${collapsed ? 'Expand all spans' : 'Collapse all spans'}</button></div>
    <div class="trace-native-body"><div class="trace-waterfall"><p class="trace-scale-note">Expanded time scale · Short steps spaced apart · Exact durations shown</p><div class="trace-columns"><span>Span</span><span>Start</span><span class="trace-ruler"><span>0.0 ms</span><span>6.52 s</span><span>18.39 s</span></span><span style="text-align:right">Duration</span></div><div id="trace-rows"></div></div><aside class="trace-inspector" id="trace-inspector" aria-label="Span details"></aside></div></div>`;
}

function renderSpans() {
  document.querySelector('#trace-rows').innerHTML = spans.map((span,index) => collapsed && index > 0 ? '' : `<button class="trace-row ${selectedSpan === index ? 'selected' : ''}" data-span="${index}" aria-pressed="${selectedSpan === index}" style="--depth:${span.depth};--span-color:${span.color};--start:${span.x}%;--length:${span.width}%"><span class="trace-name">${icon(span.icon)}${esc(span.name)}</span><span class="trace-start">+${span.start}</span><span class="trace-track"><i></i></span><span class="trace-duration">${span.duration}</span></button>`).join('');
  const selected = spans[selectedSpan];
  const timing = [['Start',`+${selected.start}`],['End',`+${selected.end}`],['Duration',selected.duration]];
  document.querySelector('#trace-inspector').innerHTML = `<h4>${icon(selected.icon)}${esc(selected.name)}</h4><div class="inspector-status"><span>Succeeded</span><b>${selected.duration}</b></div><div class="inspector-tabs"><span class="active">Details</span><span>Input / Output</span><span>Transcript</span></div><h5>TIMING</h5><dl>${timing.map(([label,value]) => `<div><dt>${label}</dt><dd>${value}</dd></div>`).join('')}</dl><p>Elapsed time measured by the app on a monotonic clock. Nested durations overlap and must not be added together.</p><h5>SUBJECT SESSION USAGE</h5><dl><div><dt>Input</dt><dd>729</dd></div><div><dt>Cached input</dt><dd>0</dd></div><div><dt>Output</dt><dd>409</dd></div><div><dt>Reasoning</dt><dd>0</dd></div></dl><p>Framework-reported usage. Includes recorded setup turns in the subject session. AI judge usage is separate.</p><dl><div><dt>AI judge tokens</dt><dd>2,514</dd></div></dl><h5>METADATA</h5><dl><div><dt>Model</dt><dd>On-device · AFM 3 Core Advanced</dd></div><div><dt>Case</dt><dd>Latest preference wins</dd></div></dl>`;
}

function labMarkup() {
  return `<div class="native-lab-header"><span class="native-icon-box">${icon('workflow')}</span><div><h3>Intent Lab</h3><p>Describe an action and the result you expect.</p></div></div><div class="lab-native-content"><div class="lab-create-heading"><div><h4>Create a test</h4><p>Describe the request and the result you expect.</p></div><span>Saved tests</span></div><section class="native-panel lab-native-card"><h4>${icon('list-checks')}What should happen?</h4><p>Describe success, then add result checks to verify it.</p><dl class="lab-native-form"><div><dt>Test name</dt><dd>PR54 physical read-only check</dd></div><div><dt>Request</dt><dd>Open the packing note in Intent Lab Fixture</dd></div><div><dt>Expected result</dt><dd>Open packing-001 without changing the note store.</dd></div><div><dt>App action</dt><dd>OpenNoteIntent</dd></div></dl><details class="native-disclosure"><summary>App and language details</summary><p>Intent Lab Fixture · OpenNoteIntent<br>This preview shows a saved test definition from the native app.</p></details></section><section class="native-panel lab-native-card"><h4>${icon('list-checks')}What should this test check?</h4><p>Choose the parts to include. Required parts decide whether this test passes.</p>${[['App action','Run the action directly, without Siri.','Required'],['Siri','Send the request text to Siri on your iPhone.','Not included'],['App evaluation','Reuse a saved evaluation linked in advanced settings.','Not included']].map(([label,detail,choice]) => `<div class="lab-check-row"><div><strong>${label}</strong><span>${detail}</span></div><span class="native-select">${choice}${icon('chevrons-up-down')}</span></div>`).join('')}<p class="lab-footnote">Checks that the action runs and its returned value matches. Changes inside the app are not verified.</p><details class="native-disclosure"><summary>Verification options</summary><p>Choose additional checks inside Intents when the test needs to verify changes in the app. Optional parts are recorded separately.</p></details></section><p class="native-lab-quiet-note">Saved test preview. Download Intents to connect an app and run your own checks.</p></div>`;
}

function setView(next, moveFocus = false) {
  if (!['report','trace','lab'].includes(next)) return;
  const isInitialRender = !screen.hasChildNodes();
  view = next;
  screen.innerHTML = view === 'report' ? reportMarkup() : view === 'trace' ? traceMarkup() : labMarkup();
  if (view === 'report') renderResults();
  if (view === 'trace') renderSpans();
  document.querySelector('#native-view-tabs').innerHTML = view === 'lab'
    ? '<span>Connect app</span><span class="active">Create test</span><span>Results</span>'
    : `<button data-view="report" class="${view === 'report' ? 'active' : ''}" aria-pressed="${view === 'report'}">Report</button><button data-view="trace" class="${view === 'trace' ? 'active' : ''}" aria-pressed="${view === 'trace'}">Workflow trace</button>`;
  document.querySelectorAll('.demo-switcher [data-view]').forEach(button => {
    button.classList.toggle('selected', button.dataset.view === view);
    button.setAttribute('aria-pressed', button.dataset.view === view);
  });
  document.querySelector('.native-nav button').classList.toggle('active',view === 'lab');
  document.querySelector('.sidebar-run[data-view]').classList.toggle('active',view !== 'lab');
  const caption = view === 'report' ? 'Explore a real run. Select a result or switch to its trace.' : view === 'trace' ? 'Select a span to inspect its recorded timing.' : 'A saved Intent Lab test. Expand the details to explore.';
  document.querySelector('.demo-caption span').textContent = caption;
  announcement.textContent = `${view === 'report' ? 'Evaluation report' : view === 'trace' ? 'Workflow trace' : 'Intent Lab'} example selected.`;
  if (!isInitialRender) screen.scrollTop = 0;
  if (moveFocus) document.querySelector(`.demo-switcher [data-view="${view}"]`).focus({preventScroll:true});
  if (!motionDisabled() && window.gsap) {
    gsap.fromTo(screen,{opacity:.2},{opacity:1,duration:.32,clearProps:'opacity',overwrite:true});
    if (view === 'trace') gsap.from('.trace-track i',{scaleX:0,stagger:.025,duration:.65,ease:'power2.out',clearProps:'transform'});
  }
}

document.addEventListener('click', async event => {
  const viewButton = event.target.closest('button[data-view]');
  if (viewButton) {
    const restoreNativeFocus = Boolean(viewButton.closest('#native-view-tabs'));
    setView(viewButton.dataset.view);
    if (restoreNativeFocus) document.querySelector(`#native-view-tabs [data-view="${view}"]`)?.focus({preventScroll:true});
    return;
  }
  const filterButton = event.target.closest('[data-filter]');
  if (filterButton) {
    filter = filterButton.dataset.filter;
    renderResults();
    announcement.textContent = `${filterCases(cases,filter,query).length} matching responses.`;
    return;
  }
  const caseButton = event.target.closest('[data-case]');
  if (caseButton) {
    selectedCase = caseButton.dataset.case;
    renderResults();
    document.querySelector(`button[data-case="${selectedCase}"]`).focus({preventScroll:true});
    announcement.textContent = `${cases.find(item => item.id === selectedCase).name} selected.`;
    return;
  }
  const spanButton = event.target.closest('[data-span]');
  if (spanButton) {
    selectedSpan = Number(spanButton.dataset.span);
    renderSpans();
    document.querySelector(`[data-span="${selectedSpan}"]`).focus({preventScroll:true});
    announcement.textContent = `${spans[selectedSpan].name}: ${spans[selectedSpan].duration}.`;
    return;
  }
  if (event.target.closest('#collapse-spans')) {
    collapsed = !collapsed;
    if (collapsed) selectedSpan = 0;
    renderSpans();
    const button = document.querySelector('#collapse-spans');
    button.textContent = collapsed ? 'Expand all spans' : 'Collapse all spans';
    button.setAttribute('aria-expanded',!collapsed);
  }
  const copyButton = event.target.closest('#copy-response');
  if (copyButton) {
    try {
      await navigator.clipboard.writeText(cases.find(item => item.id === selectedCase).response);
      copyButton.querySelector('span').textContent = 'Copied';
      announcement.textContent = 'Response copied.';
    } catch {
      copyButton.querySelector('span').textContent = 'Select text to copy';
      announcement.textContent = 'Clipboard unavailable. Select the response text to copy it.';
    }
  }
});

screen.addEventListener('input', event => {
  if (event.target.id !== 'result-search') return;
  query = event.target.value;
  renderResults();
  announcement.textContent = `${filterCases(cases,filter,query).length} matching responses.`;
});

screen.addEventListener('keydown', event => {
  if (!['ArrowDown','ArrowUp'].includes(event.key)) return;
  const button = event.target.closest('button[data-case],button[data-span]');
  if (!button) return;
  const attr = button.hasAttribute('data-case') ? 'data-case' : 'data-span';
  const buttons = [...screen.querySelectorAll(`button[${attr}]`)];
  const next = buttons[buttons.indexOf(button) + (event.key === 'ArrowDown' ? 1 : -1)];
  if (next) { event.preventDefault(); next.click(); }
});

for (const [id,next] of [['explore-trace','trace'],['explore-lab','lab']]) {
  document.querySelector(`#${id}`).addEventListener('click',() => {
    setView(next,true);
    document.querySelector('#workbench').scrollIntoView({behavior:motionDisabled() ? 'instant' : 'smooth',block:'start'});
  });
}

function motionDisabled() { return media.matches || userPaused; }

function configureMotion() {
  motionContext?.revert();
  motionContext = undefined;
  const disabled = motionDisabled();
  document.documentElement.classList.toggle('motion-paused',disabled);
  const toggle = document.querySelector('#motion-toggle');
  toggle.textContent = media.matches ? 'Reduced motion enabled' : userPaused ? 'Enable motion' : 'Pause motion';
  toggle.setAttribute('aria-pressed',disabled);
  toggle.disabled = media.matches;
  if (disabled || !window.gsap || !window.ScrollTrigger) return;
  gsap.registerPlugin(ScrollTrigger);
  motionContext = gsap.context(() => {
    gsap.from('.hero-copy > *',{y:22,opacity:0,stagger:.09,duration:.85,ease:'power3.out',clearProps:'transform,opacity'});
    gsap.from('.demo-switcher',{y:16,opacity:0,duration:.8,delay:.3,clearProps:'transform,opacity'});
    gsap.from('.reveal-window',{opacity:0,duration:1.1,delay:.2,ease:'power3.out',clearProps:'opacity'});
    gsap.utils.toArray('.reveal').forEach(element => gsap.from(element,{y:24,opacity:0,duration:.85,ease:'power2.out',scrollTrigger:{trigger:element,start:'top 94%',once:true},clearProps:'transform,opacity'}));
    gsap.from('.mini-span i',{scaleX:0,duration:1.15,stagger:.16,ease:'power3.inOut',scrollTrigger:{trigger:'.trace-card',start:'top 82%',once:true},clearProps:'transform'});
    const playhead = gsap.fromTo('.timeline-playhead',{x:0,opacity:0},{x:160,opacity:.65,duration:3.6,repeat:-1,repeatDelay:1.7,ease:'none',paused:true});
    ScrollTrigger.create({trigger:'.trace-card',start:'top bottom',end:'bottom top',onToggle:self => self.isActive ? playhead.play() : playhead.pause()});
    gsap.fromTo('.source-mark',{y:8},{y:-8,duration:3,repeat:-1,yoyo:true,ease:'sine.inOut',scrollTrigger:{trigger:'.source-mark',start:'top bottom',end:'bottom top',toggleActions:'play pause play pause'}});
  });
}

document.querySelector('#motion-toggle').addEventListener('click',() => {
  userPaused = !userPaused;
  try { localStorage.setItem('intents-motion-paused',String(userPaused)); } catch { /* Optional preference. */ }
  configureMotion();
});
media.addEventListener('change',configureMotion);
setView('report');
if (document.readyState === 'complete') configureMotion();
else window.addEventListener('load',configureMotion,{once:true});
