# Manual qualification

Ordinary CI runs surviving portable tests, native unit tests, and authored app UI
checks selected by `script/ci_routes.py`. The optional stability worker repeats the
settings accessibility check ten times. It does not qualify App Intent invocation.

`FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()`
requires locally configured Core AI resources and is excluded from ordinary CI.
Run it explicitly when qualifying that configuration.

[Mac App Intent execution](wiki/Mac-App-Intent-tests.md) requires an interactive Mac,
Xcode 27+, macOS 27+, a normally installed and registered subject `.app`, and a UI-test runner signed by the
same Apple development team. Run against explicit JSON inputs and expected
results, retain the runner diagnostics, and confirm the observed returned values.
Seven local generated-runner cases passed on the native sample. This qualifies
that sample/environment, while unit tests and generated project inspection remain
separate evidence. Siri is outside this workflow.
