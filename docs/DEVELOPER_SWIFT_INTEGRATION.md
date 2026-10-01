# Developer Swift integration and device runners

`FoundationEvalsDeveloper` lets an app expose its real feature entry points to
Foundation Evals. The model session, `@Generable` values, tools, app data, and
feature implementation remain in the developer app. The desktop sends a typed
test input and receives explicit response evidence over an encrypted, paired
connection.

The package supports iOS 26, iPadOS 26, and macOS 26 or later. Foundation Evals
itself currently targets macOS 27.

## Add the package

Add this repository as a Swift package and link the
`FoundationEvalsDeveloper` library product to the app target. The package uses
Swift 6 and its public concurrency boundaries are `Sendable`.

For an iPhone or iPad target, add these values to its Info.plist:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connect to Foundation Evals on your development Mac.</string>
<key>NSBonjourServices</key>
<array>
    <string>_fnd-evals._tcp</string>
</array>
```

The Mac and device need to be able to discover each other on the local network.
Enterprise Wi-Fi client isolation can block discovery; in that case use a local
network that allows peer-to-peer traffic.

## Register the production feature

Registration is generic over the app's input and output. The closure calls the
same production service the UI calls. A typed Foundation Models result can stay
typed for the whole model interaction and is encoded only after the feature
returns.

```swift
import FoundationEvalsDeveloper
import FoundationModels

@Generable
struct Summary: Codable, Sendable {
    var title: String
    var detail: String
}

let registry = DeveloperFeatureRegistry()
let descriptor = DeveloperFeatureDescriptor(
    id: "com.example.summary",
    displayName: "Article summary",
    version: "3",
    inputTypeName: String(reflecting: DeveloperTextFeatureInput.self),
    outputTypeName: String(reflecting: Summary.self),
    capabilityNames: ["guided-generation", "article-lookup-tool"]
)

await registry.register(
    descriptor,
    input: DeveloperTextFeatureInput.self,
    output: Summary.self
) { input, context in
    try context.checkCancellation()

    // The real tool instance and @Generable output remain inside this app.
    let session = LanguageModelSession(
        tools: [ArticleLookupTool()],
        instructions: input.instructions
    )
    let response = try await session.respond(
        to: input.prompt,
        generating: Summary.self
    )
    try context.checkCancellation()
    return response.content
} response: { summary in
    "\(summary.title)\n\n\(summary.detail)"
}
```

For a feature that already returns a displayable result or needs a custom
encoding, use `registerTextFeature`. Its closure returns
`DeveloperFeatureOutput` directly. Capturing a configured service or tools in
either `@Sendable` closure is supported; Foundation Evals does not reconstruct
those values on the desktop.

Feature IDs and versions are compatibility contracts. Change the version when
the input/output interpretation changes. A version mismatch fails before the
application closure runs.

## Host the runner

Create one stable runner UUID per app installation and keep trust files in the
app's private Application Support directory:

```swift
let identity = DeveloperRunnerIdentity.current(
    id: savedRunnerID,
    displayName: "My App – Cory's iPhone"
)
let service = DeveloperRunnerService(
    identity: identity,
    registry: registry,
    trustStoreURL: applicationSupportURL.appending(path: "foundation-evals-trust.json")
)
```

Embed `DeveloperRunnerView(service: service)` anywhere in a development build.
It is a small adaptive SwiftUI companion surface for iPhone, iPad, and Mac. It
starts discovery when shown, lists registered features and connected desktops,
and presents explicit pairing controls. Production builds can provide their own
surface over the same observable `DeveloperRunnerService`.

Pairing is never automatic:

1. On the runner, choose **Start pairing**. The service displays a 128-bit,
   grouped pairing code, endpoint name, and five-minute expiry.
2. In Foundation Evals, connect to that discovered runner and enter the code
   shown on the runner.
3. The Multipeer Connectivity session requires transport encryption. The code
   itself is never sent: the desktop sends a transcript-bound HMAC proof, and
   the runner returns the new trust token inside an AES-GCM receipt derived from
   that high-entropy code. Only then is trust stored in the two apps' private
   support directories.
4. A saved receipt allows the same desktop and runner to reconnect. The runner
   sends a fresh, expiring nonce and the desktop returns an HMAC proof; the
   runner returns a role-separated proof of the same saved secret. The bearer
   token is never sent during discovery or reconnection, and a captured proof
   cannot be replayed for a later connection. All post-authentication commands,
   results, cancellation, and disconnect messages are then AES-GCM sealed with
   a per-connection key derived from that secret and nonce. The authenticated
   data binds the session, direction, and monotonic sequence number, so altered,
   replayed, cross-direction, or out-of-order messages are rejected. Five
   invalid code attempts cancel the pairing session, with a delay between
   attempts. Removing trust requires pairing again.

Call `await service.cancelPairing()` to invalidate an outstanding code and
`await service.stop()` when the host app intentionally stops its runner. A nil
`trustStoreURL` keeps receipts only for the current process.

The desktop client keeps one active runner connection at a time. Other devices
remain visible in `runners`, but connecting one requires disconnecting the
current runner first. This matches the single-suite execution lock in
`EvaluationStore` and avoids presenting a per-device disconnect control that
Multipeer Connectivity cannot honor within one shared session.

### Transport state and ownership

Discovery data is a hint, never identity. The desktop owns one candidate record
per physical Multipeer peer; that record alone owns its claimed runner UUID,
pairing and reconnect challenges, pending pairing proof, session cipher, and
authentication deadline. Durable trust remains keyed by runner UUID, while an
authenticated runner-to-peer binding is created only after proof succeeds.

The lifecycle is deliberately one-way:

`discovered → transport connected → pairing or saved-trust proof → authenticated → executing → disconnected`

- Multiple unauthenticated peers may claim the same runner UUID. Their secrets
  and challenges never share storage. A pairing code is proved independently to
  every connected candidate for that UUID, so only the peer displaying that
  code can return a decryptable receipt.
- The first peer to prove the saved or newly issued trust secret owns the
  authenticated binding. Competing candidates are evicted. If no peer proves
  trust before the deadline, the unauthenticated shared session is reset to
  release its transport slots.
- A saved-trust rejection is accepted only when it matches that peer's current
  reconnect challenge. It permits replacement pairing without deleting the
  durable receipt; an unauthenticated peer therefore cannot erase saved trust.
- Only the authenticated peer may execute, cancel, return results, or request a
  disconnect. Closing its connection cancels the request IDs owned by that
  connection and clears its ephemeral cipher.
- The runner buffers sealed outbound envelopes by sequence before writing them
  to Multipeer Connectivity. Concurrent feature completions can therefore run
  in parallel without putting sequence `N+1` on the wire before sequence `N`.

Do not publish pairing codes, runner trust files, or test inputs in logs.
Multipeer display names are discovery labels, not identities; the trust receipt
is the authentication material. Discovery candidates remain unauthenticated
until they prove that receipt. A candidate cannot reserve a runner UUID: each
peer has isolated challenge and cipher state, unauthenticated candidates expire,
and only the first peer that proves saved trust becomes the connected runner.

The current encrypted LAN transport is isolated behind the protocol and host
engine types, but it uses Multipeer Connectivity, which Xcode 27 deprecates on
macOS 27 in favor of Network.framework. It remains available on the package's
macOS 26 and iOS 26 deployment targets and supplies required session encryption.
A future Network.framework transport must provision authenticated TLS identities
before replacing it; an unencrypted Bonjour socket is not an acceptable
migration.

## Desktop lifecycle and persisted evidence

The desktop contract is `DeveloperRunnerStore`:

```swift
let runners = DeveloperRunnerStore(evaluationStore: evaluationStore)
runners.start()

try runners.beginPairing(with: discoveredRunnerID)
try runners.trustRunner(discoveredRunnerID, pairingCode: codeFromDevice)

let runID = try runners.runSelectedSuite(
    on: discoveredRunnerID,
    featureID: "com.example.summary"
)

runners.cancelRun(runID)
runners.disconnect(discoveredRunnerID)
runners.stop()
```

The observable surface contains:

- `runners`: identity, platform, OS, hardware, app version, registered features,
  trust/connection state, last-seen time, and availability detail.
- `pairingChallenges`: runner identity, pairing session ID, and expiry. The code
  is intentionally entered by the user and is never sent in discovery data.
- `runTargets`: `.local` plus each connected runner, so local evaluation remains
  available when no device is present.
- `activeRuns`: preparing, dispatching, running, completed, cancelled, failed,
  timed-out, or disconnected, with completed and total sample counts.

Remote output flows through the existing feature-adapter runner and normal
`EvaluationStore` persistence. Saved runs include immutable suite/case evidence,
normal deterministic scoring, repository metadata, and
`EvaluationDeveloperExecution` (runner, device/OS, app, feature, and protocol
versions). AI-rubric suites require an approved independent judge connection;
the desktop judges the returned feature responses before saving the run and
records that initial assessment separately from subject execution. A missing or
failed judge never becomes a pass. The run can be compared, reassessed, or
approved as a baseline in the same way as a local run.

Cancellation propagates from the desktop task to the in-flight device request.
Feature closures still need to cooperate by calling `Task.checkCancellation()`
or `context.checkCancellation()` at useful boundaries. Desktop timeout sends a
remote cancellation request and records a timed-out status. A disconnect fails
pending requests and cancels device tasks owned by that connection rather than
fabricating results; reconnecting does not replay an ambiguous in-flight
request. Cancelled, timed-out, and disconnected runs retain an explicit
termination reason and are never promoted to completed merely because their
partial evidence was persisted.

## Apple Evaluations interoperability

Xcode 27 ships `Evaluations.framework` under each platform's
`Developer/Library/Frameworks`, not in the deployable platform SDK. Its public
Swift interface imports `Testing`, `TabularData`, and `FoundationModels`, and
Apple's documented execution path is a Swift Testing test using
`.evaluates(_:info:recordTranscripts:)`. It must therefore stay in a development
test target and must not be linked into the iPhone/iPad/Mac runner product.

The supported interoperability boundary is the production feature closure:
call the same app service from an Apple `Evaluation.subject(from:)` method and
from the Foundation Evals registry closure. This preserves the real
`@Generable` type and tools in both paths without translating or inventing
Evaluations APIs.

This shape matches the Xcode 27 public interface:

```swift
import Evaluations
import Testing

struct SummaryEvaluation: Evaluation {
    let match = Metric("Exact match")
    let dataset = ArrayLoader(samples: [
        ModelSample<String>(prompt: "Summarize this fixture", expected: "Expected summary")
    ])

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        let value = try await productionSummaryFeature(sample.promptDescription)
        return ModelSubject(value: value)
    }

    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let expected = sample.expected else { return match.ignore() }
            return subject.value == expected ? match.passing() : match.failing()
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: match)
    }
}

@Test(.evaluates(SummaryEvaluation()))
func summaryQuality() {}
```

Foundation Evals does not currently import Apple's `EvaluationResult` files.
Both systems can run the same subject code, while each retains its own scoring
and report schema. If a later Apple SDK adds a stable interchange API, add it as
a separate development-only adapter instead of making the device runtime depend
on `Evaluations.framework`.

## Verification boundary

The repository tests cover protocol encoding, typed feature registration,
version mismatch, deadline and cancellation behavior, pairing, saved trust
reconnection, untrusted execution rejection, and desktop run persistence.
Package builds cover macOS and the generic iOS Simulator SDK. These checks prove
the SDK and fixture transport logic; they do not prove a physical-device
connection. Select and run a signed sample app on a specific device before
claiming physical iPhone or iPad execution.
