# Native engine worklog

Goal: reuse the app's complete local Apple Foundation Models evaluation engine in a standalone plugin, without an app installation or Intent Lab/provider dependencies.

Completed: 45 bundled source files with original/bundled hashes; macOS 27 gates; legacy protocol compatibility; full suites, schemas, tools, conversations, traces, references; actual experiment, baseline, repeatability, release, assessment and correction workflows; real progress events and cooperative cancellation. Human corrections retain the original judgment.

Verified: current SDK compile and optimized build; 53 legacy core assertions; legacy real inference; 153 actual app protocol assertions; 64 actual workflow assertions; 16 final no-inference workflow guard assertions; 45 provenance hashes; launch syntax and scoped diff checks. Cancellation returned in 0.015 seconds and retained two actual samples.

Artifacts: final optimized executable `/tmp/apple-eval-engine-optimized`; regression logs `/tmp/apple-app-protocol.log`, `/tmp/apple-eval-workflows.log`, `/tmp/apple-eval-optimized.log`; earlier real wire request/result `/tmp/apple-eval-request.json`, `/tmp/apple-eval-result.json`.

Boundary: the backend owns persistence, leases, timeouts and bounded kill fallback; the main chat owns UI verification. The full engine requires macOS 27 and the Xcode 27 SDK. Vision and Spotlight generation were not exercised; runtime model capability gates remain authoritative. No app or simulator was opened. No commits or pushes.
