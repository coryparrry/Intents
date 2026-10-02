# Intents website worklog

Goal: create and host an animated open-source showcase using faithful code-rendered examples of the current native app.

- Scope: new isolated `website/` project; preserve existing app source and unrelated changes.
- Reference: current source in Developer/Projects/Intents; native screenshots from the 1 October Lab UX verification. The current worktree predates that redesign.
- Direction: native white/neutral surfaces, macOS blue controls, real app icon, careful editorial spacing, restrained staged motion. Use official, pinned GSAP and native Lucide assets locally.
- Planned sections: introduction and interactive app; evaluations/report/trace examples; Intent Lab; local-first models and MCP; open-source/download.
- Must verify: desktop/mobile, keyboard controls, reduced motion, actual demo states, links, source provenance, deployment.

- Implemented: full static showcase, real report data, selectable trace spans, Lab fixture, responsive layout and motion controls.
- Verification round 1: inspected desktop, tested filtering/search/selection/keyboard/trace/Lab/pause; 8 Node tests passed. Corrected headline spacing and the report badge alignment.
- Verification round 2 fixes: constrain mobile headline; align the shared mini-window styles in the CSS cascade; preserve native tab keyboard focus; use opacity-only entrance for the interactive window so it never moves away from a click.
- Final browser checks passed at 320, 390, 834, 1280 and 1440 pixels. No browser errors captured. Eight scoped tests passed. See QA.md.
- Current app reference process is closed. No simulator was started.
- Sites project registered. Recovering an intermittently unavailable plugin helper from an unchanged temporary copy; credentials remain in session memory.

## Search and AI discovery update

- Goal: make the approved showcase publicly discoverable and readable by search engines and AI services. Preserve the page body, CSS, interactions and animation.
- Opened the existing Sites source at `43d76ed2628713485a333f712361fb1669e943d7`; checkout was clean. Current owner-only access prevents public discovery.
- Plan: descriptive metadata and social previews, truthful JSON-LD, permissive robots.txt, sitemap, and linked Markdown product information. No additional runtime dependencies.
- Verify: structured data and discovery-file contracts, unchanged visual source, no-JavaScript reading, browser presentation, and anonymous production requests after publication.
- Implemented: head-only metadata/JSON-LD changes; robots.txt, sitemap.xml, llms.txt, Markdown overview, and text/alternate-link headers. No visual assets or runtime dependencies changed.
- Local verification: 12 tests pass; approved body is byte-for-byte unchanged; inspected the browser, disabled JavaScript to verify product readability, restored it, and checked report selection. No console errors or warnings.
- Review complete. Publishing the verified source, then enabling public discovery and testing anonymous delivery. Actual indexing remains controlled by search providers.
- First publication succeeded and access is public. All nine anonymous product/discovery checks passed. A separate missing-route check exposed a homepage fallback with HTTP 200; Sites also ignored `_headers` (native text MIME types are already correct).
- Correction: use the supported static `not_found_handling: none` setting and remove the ineffective `_headers` file. Added local and production regression checks for missing routes. Homepage content and visuals remain unchanged.
