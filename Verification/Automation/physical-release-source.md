# Physical release source boundary

Physical product preparation and execution remain unavailable. A new `AutomationPhysicalDeviceReleaseVerifier` implements the shared release protocol using read-only, complete device inventories. It does not start or terminate device applications.

The caller supplies every controller's bundle ID, actual executable name and owned PID when known. Preparation requires their absence before control begins and captures the actual device UUID. Release requires the same full target, controller scope and actual UUID, complete fresh absence, and successful local inspection-command drain. Missing, foreign, malformed or ambiguous evidence returns failure. An unproved local drain remains latched; concurrent batches cannot interleave.

The inspector now checks all controllers against one apps/processes pair, rather than running two commands per controller. Its production command remains owned `/usr/bin/xcrun devicectl device info`, with explicit selected `DEVELOPER_DIR`. Both parsed payloads must declare the exact requested fresh output path. Controller and absence validation share one grammar. Offline parser compatibility without an expected output URL validates the declared payload only; it does not establish a current invocation.

Twenty focused Swift tests passed: release protocol9, inventory6, actual inspector composition5. The latter inject command results and exercise the real argument/environment construction, output parsing, serialization and drain latch. They do not invoke a device. Native46 `xcodebuild ... -jobs 2 ... build` passed; no app launch or UI test ran. Private signed package15 remains the earlier native44 artifact. Fresh Sol reviews found output-path correlation and inconsistent bundle-ID validation; both were fixed and independently rechecked.

Failure traces remain: Swift179's test workspace used Foundation normalization instead of the repository's `realpath` contract; Swift180 exposed the same difference in a parser guard. The fixture now uses `AutomationPath.canonical`, and the parser compares the exact requested path without rewriting `/private/var`. Swift181 passed. Native45 failed on sandboxed build-cache access; the authorized native46 compile with normal caches passed.

[Immutable checkpoint](physical-release-source-1.json) records 15 source/test/log/binary hashes. It is source and local compilation evidence only. Physical signing/preparation/install identity, execution-route wiring, controller lifecycle, actual device release and Siri ABI qualification remain open.
