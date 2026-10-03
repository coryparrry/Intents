import XCTest
import Vision
import IntentLabContracts
import IntentLabSiriBridge

/// Do not install a new attempt context while an earlier action may still finish.
struct SiriAttemptSequence {
    private var unresolvedError: Error?

    mutating func run<Value>(_ attempt: () throws -> Value) throws -> Value {
        if let unresolvedError {
            throw SiriProbeError.priorAttemptUnresolved(unresolvedError.localizedDescription)
        }
        do { return try attempt() }
        catch {
            unresolvedError = error
            throw error
        }
    }
}

@available(macOS 27.0, iOS 27.0, *)
@MainActor
enum SiriProbe {
    static func run(
        request: String,
        application: XCUIApplication,
        expectedContext: String,
        safety: IntentLabSafety,
        testCase: XCTestCase,
        integration: any IntentLabSiriIntegration,
        declaration: IntentLabIntegrationDeclaration?
    ) throws -> [String: IntentLabValue] {
        #if os(macOS)
        throw SiriProbeError.unsupportedPlatform
        #endif
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SiriProbeError.missingRequest
        }
        // Clear a chooser left behind by an interrupted previous attempt.
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        #endif
        application.activate()
        let selection = SiriChoiceHandler(request: request, application: application, expectedContext: expectedContext, integration: integration, declaration: declaration)
        // activate() pumps the run loop while waiting for Siri. Handle its chooser
        // during that wait, rather than after the activation call has timed out.
        let choiceTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { selection.selectIfNeeded() }
        }
        selection.timer = choiceTimer
        RunLoop.main.add(choiceTimer, forMode: .common)
        // XCTest can abort activation through an Objective-C failure, skipping Swift defer.
        testCase.addTeardownBlock { await selection.stop() }
        defer { selection.stop() }
        let completion = SiriProbeCompletion()
        testCase.addTeardownBlock { await completion.verify() }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            MainActor.assumeIsolated {
                guard recoverableActivationTimeout(
                    description: issue.compactDescription,
                    osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    observations: selection.completionObservations,
                    expectedContext: expectedContext,
                    integration: integration
                ) else { return false }
                selection.activationTimeoutMatched = true
                selection.stop()
                return true
            }
        }
        var recoveredInterruption: String?
        XCTExpectFailure("XCTest Siri activation timed out after verified intent execution", options: options) {
            recoveredInterruption = IntentLabActivateSiri(request) {
                selection.activationTimeoutMatched
            }
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var promptWasSeen = false
        var promptIsVisible = false
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // Query directly: interruption monitors are not invoked by observation-only waits.
            // Leave consent to the operator; never tap an arbitrary Allow/Continue button.
            promptIsVisible = application.alerts.firstMatch.exists || springboard.alerts.firstMatch.exists
            promptWasSeen = promptWasSeen || promptIsVisible
            guard !promptIsVisible, let observations = try? integration.observe(
                application: application, declaration: declaration, deadlineSeconds: min(2, safety.deadlineSeconds)
            ) else { return false }
            return correlatedCompletion(observations: observations, expectedContext: expectedContext, integration: integration) != nil
        }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: waitTimeout(for: safety)) == .completed else {
            if promptWasSeen { throw SiriProbeError.permissionRequired }
            throw SiriProbeError.outcomeNotObserved
        }
        guard var observations = correlatedCompletion(
            observations: try integration.observe(
                application: application, declaration: declaration, deadlineSeconds: safety.deadlineSeconds
            ),
            expectedContext: expectedContext,
            integration: integration
        ) else {
            throw SiriProbeError.invocationNotCorrelated
        }
        observations["recognizedRequest"] = .string(request)
        if let selectedLabel = selection.selectedLabel {
            observations["siriDisambiguationSelection"] = .string(selectedLabel)
        }
        if let recoveredInterruption {
            observations["siriActivationDiagnostic"] = .string(recoveredInterruption)
        }
        completion.returned = true
        return observations
    }

    static func recoverableActivationTimeout(
        description: String,
        osMajor: Int,
        observations: [String: IntentLabValue]?,
        expectedContext: String,
        integration: any IntentLabSiriIntegration
    ) -> Bool {
        guard osMajor == 27, description == "Timed out waiting for Siri to activate",
              !expectedContext.isEmpty,
              let observations,
              observations["invocationContext"] == .string(expectedContext) else { return false }
        return integration.completed(observations: observations, context: expectedContext)
    }

    static func matchingChoice(request: String, choices: [String]) -> String? {
        let words = { (text: String) in
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let requestWords = " " + words(request) + " "
        let matches = Set(choices.filter {
            let choice = words($0)
            return !choice.isEmpty && requestWords.contains(" " + choice + " ")
        })
        return matches.count == 1 ? matches.first : nil
    }

    static func chooserRow(
        request: String,
        applicationName: String,
        text: [(label: String, bounds: CGRect)]
    ) -> (label: String, bounds: CGRect)? {
        guard let heading = text.first(where: { $0.label == "Which one?" }) else { return nil }
        // Keep matching inside the Siri card. The app beneath it can expose
        // matching words such as its Fixture tab or duplicate note titles.
        let attributionTrim = CharacterSet.whitespacesAndNewlines.union(.symbols).union(.punctuationCharacters)
        guard let attribution = text.filter({
            $0.label.trimmingCharacters(in: attributionTrim) == applicationName
                && $0.bounds.maxY < heading.bounds.minY
        }).max(by: { $0.bounds.midY < $1.bounds.midY }) else { return nil }
        let choices = text.filter {
            $0.bounds.midY < heading.bounds.minY && $0.bounds.midY > attribution.bounds.maxY
        }
        guard let label = matchingChoice(request: request, choices: choices.map(\.label)),
              let choice = choices.filter({ $0.label == label }).max(by: { $0.bounds.midY < $1.bounds.midY }) else { return nil }
        return choice
    }

    static func completionReady(promptIsVisible: Bool, observedContext: String?, expectedContext: String) -> Bool {
        !promptIsVisible && observedContext == expectedContext
    }

    static func waitTimeout(for safety: IntentLabSafety) -> TimeInterval {
        safety.deadlineSeconds
    }

    static func correlatedCompletion(
        observations: [String: IntentLabValue],
        expectedContext: String,
        integration: any IntentLabSiriIntegration
    ) -> [String: IntentLabValue]? {
        observations["invocationContext"] == .string(expectedContext)
            && integration.completed(observations: observations, context: expectedContext) ? observations : nil
    }
}

@MainActor
private final class SiriProbeCompletion {
    var returned = false
    func verify() {
        XCTAssertTrue(returned, "Siri probe aborted before returning validated observations")
    }
}

@available(macOS 27.0, iOS 27.0, *)
@MainActor
private final class SiriChoiceHandler {
    let request: String
    private(set) var selectedLabel: String?
    private(set) var completionObservations: [String: IntentLabValue]?
    var activationTimeoutMatched = false
    private let expectedContext: String
    private var isSelecting = false
    private var lastDiagnostic = ""
    private let application: XCUIApplication
    private let applicationName: String
    private let integration: any IntentLabSiriIntegration
    private let declaration: IntentLabIntegrationDeclaration?
    var timer: Timer?

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    init(request: String, application: XCUIApplication, expectedContext: String, integration: any IntentLabSiriIntegration, declaration: IntentLabIntegrationDeclaration?) {
        self.expectedContext = expectedContext
        self.request = request
        self.application = application
        self.integration = integration
        self.declaration = declaration
        applicationName = application.label
    }

    private func diagnose(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        print("Siri chooser: \(message)")
    }

    private func observeCompletion() {
        guard let observations = try? integration.observe(
            application: application, declaration: declaration, deadlineSeconds: 2
        ) else { return }
        if SiriProbe.recoverableActivationTimeout(
            description: "Timed out waiting for Siri to activate", osMajor: 27,
            observations: observations, expectedContext: expectedContext, integration: integration
        ) {
            completionObservations = observations
        }
    }

    func selectIfNeeded() {
        #if os(iOS)
        guard completionObservations == nil, !isSelecting else { return }
        isSelecting = true
        defer { isSelecting = false }
        if selectedLabel != nil {
            observeCompletion()
            return
        }
        // The iOS 27 automation sheet is visible in screen captures, but requesting
        // its accessibility snapshot blocks until Siri activation times out.
        guard let image = XCUIScreen.main.screenshot().image.cgImage else {
            diagnose("Screen capture has no CGImage")
            return
        }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image).perform([recognition]) }
        catch { diagnose("Text recognition failed: \(error)"); return }
        let text = (recognition.results ?? []).compactMap { observation -> (label: String, bounds: CGRect)? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.6 else { return nil }
            return (candidate.string, observation.boundingBox)
        }
        guard let choice = SiriProbe.chooserRow(
            request: request, applicationName: applicationName, text: text
        ) else {
            observeCompletion()
            return
        }
        selectedLabel = choice.label
        application.coordinate(withNormalizedOffset: CGVector(
            dx: choice.bounds.midX,
            dy: 1 - choice.bounds.midY
        )).tap()
        #else
        observeCompletion()
        #endif
    }
}

enum SiriProbeError: LocalizedError {
    case priorAttemptUnresolved(String)
    case unsupportedPlatform
    case permissionRequired
    case missingRequest
    case fixtureUnavailable
    case outcomeNotObserved
    case invocationNotCorrelated
    var errorDescription: String? {
        switch self {
        case .priorAttemptUnresolved(let reason): "This Siri attempt was not started because an earlier attempt did not finish: \(reason)"
        case .unsupportedPlatform: "Siri UI automation requires an iOS destination."
        case .permissionRequired: "Siri permission or confirmation blocked this attempt. Approve the prompt on the device, then rerun. Remaining attempts were not started."
        case .missingRequest: "The approved Siri request is empty."
        case .fixtureUnavailable: "The synthetic fixture did not expose its baseline observation."
        case .outcomeNotObserved: "Siri did not establish the declared visible outcome before the deadline."
        case .invocationNotCorrelated: "The application outcome was not correlated to this scenario attempt."
        }
    }
}
