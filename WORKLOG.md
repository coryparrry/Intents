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
