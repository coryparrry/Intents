# Website verification — 2 October 2026

## Outcome

The static site passed the scoped checks below. Native app source was unchanged.
The native build opened to collect references was closed; no simulator or Xcode
build was started for this task.

## Automated checks

- `node --check dist/app.js` — passed.
- `node --check dist/demo-data.mjs` — passed.
- `node --test tests/demo.test.mjs` — 8 tests passed, 0 failures.
- Tests cover search across name/prompt/response, intersected status filters,
  empty/no-match cases, stale selection, HTML escaping, recorded span data,
  asset references, document anchors, and icon references.

## Browser integration checks

Tested in the Codex in-app browser using CUA:

- Desktop 1280×720 and 1440×1000: inspected page hierarchy, source/download links,
  full page rhythm, native window, report, trace, Lab and footer.
- Mobile 390×844 and 320×740: headline fits, no page-level horizontal overflow,
  miniature window controls do not overlap. Tables scroll within the preview.
- Tablet 834×1112: no page-level horizontal overflow; native preview scales.
- Select “Correction replaces old value”: the response changes to the recorded
  “The meeting is scheduled for Friday.”
- Failed filter: no matching rows and no stale response. All restores cases.
- Search “vegetarian”: one result, “Retain compatible constraint”. Unmatched
  search returns zero results. Clearing the query restores all three.
- Arrow Down moves selection from the first result to the second.
- Native Report/Workflow trace buttons preserve keyboard focus. Tab then reaches
  the trace expansion control.
- Selecting Generate response shows +6.70 s start, +9.38 s end and 2.68 s duration.
- Collapse spans shows one row; expand restores all 13.
- Intent Lab selection and disclosure expansion work.
- Pause motion works and persists across reloads.
- Emulated system reduced motion disables animation, hides the playhead, and
  leaves span selection operational. Emulation was reset after testing.
- Browser console: no captured errors or warnings in the tested local session.

## Visual reference and corrections

Compared against the real current native app and its 1 October screenshots:
sidebar width, system typography, canvas and panel colours, rounded panels,
blue selection, status badge placement, report hierarchy, table labels, exact
recorded responses and the expanded workflow waterfall.

Two scoped correction rounds addressed headline spacing, badge alignment,
small-screen header fit, shared control styles, keyboard focus, and stable
click targets during entrance animation. The final checks above passed.

This is a browser recreation of the native interface. Native macOS materials
and text rasterization differ across browsers. It is not a pixel-diff-certified
native rendering. Mobile intentionally hides the sidebar and allows tables to
scroll. Native-only operations, including model execution and device connection,
are outside the website preview.

## Scoped source review

Applied the review-and-simplify-changes rubrics separately to the final authored
HTML, CSS, JavaScript and data: reuse, code quality, efficiency. No additional
material issues were found. No review-only refactors were applied (reuse 0,
quality 0, efficiency 0). Vendor code was excluded from the authored-code review.
The site has no backend, analytics, model endpoint, or secret.

## Search and AI discovery update

- `node --test tests/*.test.mjs` — 12 tests passed, 0 failures, including four
  discovery contracts for canonical URLs, structured identities, crawler rules,
  linked text resources, product limitations, and static content availability.
- `node --check scripts/check-discovery.mjs` and `git diff --check` — passed.
- Compared with approved source `43d76ed2628713485a333f712361fb1669e943d7`:
  the complete HTML body is byte-for-byte unchanged. CSS, interactive code,
  recorded data, images, and animation libraries are unchanged.
- Inspected the rendered page at 1280×720. With JavaScript disabled, product
  information, Intent Lab, MIT licence, and download links remain readable.
- Restored JavaScript and selected “Correction replaces old value”: the recorded
  Friday response appears. No browser errors or warnings were captured.
- Reviewed the stable discovery changes for factual consistency, crawl access,
  existing-UI preservation, and unnecessary dependencies. No material findings
  remained. No invented ratings or unverified version number were added.

Production verification is a separate post-publication step using
`node scripts/check-discovery.mjs`; local tests alone do not establish public
access or actual indexing. Search Console and Bing verification are not claimed.
