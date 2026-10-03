# Lean checks: evidence admission and recovery journals

`LeanEvidenceAdmission.lean` models the admission boundary in
`XCTestEvidenceImporter.importEvidence`. It proves that rejected evidence leaves
the import ledger unchanged, replayed invocation IDs and nonces cannot be
accepted, and successful admission records the invocation ID. Concrete checks
also reject a replayed artifact ID and invalid identity or test count.

The model treats schema, journal phase, identity, lane-result, and artifact
validation as Boolean inputs. It does not prove JSON parsing, product hashes,
file paths, SHA-256, or those validation functions. Swift contract tests now
check that a rejected import leaves the ledger empty and a corrected payload
using the same invocation can still be imported.

`LeanRecoveryJournal.lean` models one device and one journal through initial
persistence, launch, evidence validation, interruption, reconciliation, and
manual quarantine clearing. It proves that a failed initial save releases its
reservation, rejected evidence and interrupted runs quarantine the device,
and neither absent readiness attestation nor an active or merely reserved run
can be cleared. A second state model tracks invocation ownership and a clear
claim: a failed save cannot release another invocation's reservation, a second
clear cannot claim the same device, and clearing blocks a new preflight. The
`readinessProven` input represents the operator's attestation; the model does
not prove actual device termination or fixture state.

The journal check exposed two Swift issues: a failed initial journal save
could leave an in-memory device reservation, and `clearQuarantine` could clear
a preparing run's reservation. Review found that two overlapping clears could
also erase a newer reservation. `XcodeTestExecutor` now releases only the
failed invocation's reservation and claims quarantine clearing per device
until journal updates finish. Regression tests failed on the first two old
behaviors; a contract test checks that a second clear claim is rejected.
Existing tests also cover relaunch reconciliation, cancellation, and accepted
or rejected evidence.

Run from this directory with the pinned `lean-toolchain`:

```sh
lean LeanEvidenceAdmission.lean
lean LeanRecoveryJournal.lean
```

These are hand-written models of selected decisions. The Swift tests connect
their edge cases to production code; no formal equivalence proof is claimed.

## Worklog (2026-09-24)

1. Traced importer admission, ledger mutation, executor reservations, journal
   persistence, and quarantine clearing.
2. Added two Lean models and checked their safety properties.
3. Added Swift regression checks for rejected imports, journal-save failure,
   false readiness, active execution, and reserved execution.
4. Fixed reservation cleanup after initial journal-save failure and restricted
   manual clearing to quarantined reservations.
5. Independent review found the overlapping-clear race. Added a per-device
   clearing claim, an owner-aware Lean model, and a duplicate-claim test.
6. Both new Lean files and all 31 scenario contract tests passed.
