# Mac workflows

Use [Mac App Intent tests](Mac-App-Intent-tests.md) to select a built Mac app,
inspect its compiled action metadata, and author explicit JSON inputs and expected
results. Execution requires Apple's AppIntentsTesting framework, Xcode 27+,
macOS 27+, and matching development-team signatures.

Seven local generated-runner cases passed on a native Mac sample. This is limited
to the tested sample and environment. Source checks, catalog inspection, and unit
tests remain separate evidence, and the workflow does not verify Siri.
