# Owned physical installation source

The installer copies manifest-bound iPhoneOS payload bytes into private state, then uses the selected Xcode directory and exact physical device ID for an owned `devicectl device install app` command. The caller supplies its current system lease, matching approval, preparation scope and durable journal. Dispatch intent is recorded before installation; an unresolved or completed operation cannot automatically install again.

A successful return requires command exit zero without truncated logs, a fresh complete app inventory before and after installation on the same actual device UUID, exactly one matching bundle ID, unchanged staged bytes and drained local commands. Raw command logs and inventories remain in the private installation directory. Failure retains logs and leaves lease release to the caller. An unproved drain prevents reuse.

The versioned receipt explicitly encodes `evidenceScope=ownedInstallCommandAndBundlePresence` and `installedBytesVerified=false`. It retains the selected local payload digest and requested full target separately from the actual device UUID and installed bundle URL. It does not prove that the phone's installed bytes equal that digest, signing eligibility, launch success or application correctness.

The UI sidecar now receives the selected `DEVELOPER_DIR`. Physical construction requires the pinned SDK expected runner IDs, distinct from the app under test. These IDs are source/build expectations; executable identity still requires artifact/device observation. The same configured scope reaches release preparation and verification. Invalid developer selections are rejected before state creation.

Verification: Swift187 21 tests passed; Swift188 64 tests passed, including injected owned-install command composition, receipt encoding, cancellation, runner registration and actual owned Node environment transport. Swift189 rechecked the affected selection/RPC/preflight boundary:14 passed. Fresh installer and sidecar reviews found issues that were fixed; subsequent fresh rechecks were clear. Native50 compiled successfully and its raw app was preserved without launching it.

Physical product execution remains fenced while its installed-subject route and qualification are completed. No physical commands, UI controller, app launch, new runtime packaging or publication ran for this checkpoint. The existing signed package15 still contains earlier native44. Full M0–M6 remains incomplete.

[Immutable hashes and check evidence](physical-install-source-1.json)
