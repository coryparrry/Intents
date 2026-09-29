import Foundation
import CryptoKit
import IntentLabContracts

struct FixtureIntentActionStart: Sendable {
    fileprivate var executionID: UUID
    fileprivate var appSessionID: UUID
    fileprivate var attemptContext: String
    fileprivate var lane: String
    fileprivate var attempt: Int
    fileprivate var operationID: String
    fileprivate var resolvedParametersJSON: Data
    fileprivate var kind: String
    fileprivate var isTopLevel: Bool
    fileprivate var sequence: Int
    fileprivate var startedAt: Date
}

struct FixtureNote: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String
}

enum FixtureNotes {
    static let all = [
        FixtureNote(id: "packing-001", title: "Packing note", body: "Passport, blue charger, and rain jacket."),
        FixtureNote(id: "packing-002", title: "Packing notes", body: "Archive: beach towel and paperback."),
        FixtureNote(id: "garden-001", title: "Garden note", body: "Water the basil on Tuesday."),
        FixtureNote(id: "trip-2027", title: "Trip plan", body: "Train 218 leaves at 08:45 on 14 June 2027. Bring the red folder. The return train leaves at 19:10."),
        FixtureNote(id: "meeting-001", title: "Planning meeting", body: "The team agreed to ship the offline guide on Friday. Maya will review the screenshots; Theo will check the installation steps. The budget remains £240. No customer data will be used in the demo. The follow-up is scheduled for 3 July 2027."),
        FixtureNote(id: "short-001", title: "One-word reminder", body: "Umbrella.")
    ]

    static func note(id: String) -> FixtureNote? { all.first { $0.id == id } }

    static func contentDigest(_ note: FixtureNote) -> String {
        let bytes = Data("\(note.id)\u{0}\(note.title)\u{0}\(note.body)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(prompt: String) throws -> FixtureNote {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func containsWhole(_ value: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: value.lowercased())
            return text.range(of: "(?<![[:alnum:]-])\(escaped)(?![[:alnum:]-])", options: .regularExpression) != nil
        }
        let matches = all.filter { note in
            containsWhole(note.id) || containsWhole(note.title)
        }
        guard matches.count == 1, let note = matches.first else {
            throw FixtureNoteResolutionError.invalidOrAmbiguous
        }
        return note
    }
}

enum FixtureNoteResolutionError: LocalizedError {
    case invalidOrAmbiguous
    var errorDescription: String? { "Name exactly one synthetic note by stable ID or full title." }
}

struct FixtureSummaryReceipt: Codable, Sendable {
    var noteID: String
    var sourceContentDigest: String
    var summary: String
    var context: String
    var completionID: String
    var route: String
    var subjectCaseID: UUID?
    var subjectAttemptID: UUID?
}

enum FixtureState {
    static let selectedNoteKey = "intent-lab.selected-note-id"
    static let mutationCountKey = "intent-lab.mutation-count"
    static let activeContextKey = "intent-lab.active-context"
    static let observedContextKey = "intent-lab.observed-context"
    static let eventKey = "intent-lab.last-event"
    static let summaryReceiptKey = "intent-lab.summary-receipt"
    static let actionReceiptsKey = "intent-lab.action-receipts"
    static let actionReceiptOverflowKey = "intent-lab.action-receipts-overflowed"
    private static let actionReceiptLimit = 16
    private static let actionReceiptByteLimit = 65_536
    private static let actionReceiptErrorCharacterLimit = 512
    private static let actionReceiptLock = NSLock()
    private static let appSessionID = UUID()
    nonisolated(unsafe) private static var actionReceiptSequence = 0

    private struct InvocationScope {
        var lane: IntentLabLane
        var attempt: Int
    }

    static func reset() {
        actionReceiptLock.lock()
        defer { actionReceiptLock.unlock() }
        UserDefaults.standard.set("none", forKey: selectedNoteKey)
        UserDefaults.standard.set(0, forKey: mutationCountKey)
        UserDefaults.standard.removeObject(forKey: observedContextKey)
        UserDefaults.standard.removeObject(forKey: eventKey)
        UserDefaults.standard.removeObject(forKey: summaryReceiptKey)
        UserDefaults.standard.set(encodeActionReceipts([]), forKey: actionReceiptsKey)
        UserDefaults.standard.set(false, forKey: actionReceiptOverflowKey)
    }

    static func select(noteID: String) {
        UserDefaults.standard.set(noteID, forKey: selectedNoteKey)
    }

    static func beginSummaryAttempt(noteID: String) {
        let defaults = UserDefaults.standard
        defaults.set(noteID, forKey: selectedNoteKey)
        defaults.removeObject(forKey: summaryReceiptKey)
        defaults.removeObject(forKey: eventKey)
        defaults.removeObject(forKey: observedContextKey)
    }

    static func begin(context: String) {
        actionReceiptLock.lock()
        defer { actionReceiptLock.unlock() }
        UserDefaults.standard.set(context, forKey: activeContextKey)
    }

    static func beginProductionIntent(operationID: String, noteID: String) -> FixtureIntentActionStart? {
        beginAction(
            operationID: operationID,
            resolvedParameters: [
                "note": .entity(.init(typeIdentifier: "NoteEntity", identifier: noteID))
            ],
            kind: .productionIntent,
            isTopLevel: true
        )
    }

    static func beginProductionService(
        operationID: String,
        noteID: String,
        resolvedParameters: [String: IntentLabValue]
    ) -> FixtureIntentActionStart? {
        beginAction(
            operationID: operationID,
            resolvedParameters: resolvedParameters.isEmpty
                ? ["note": .entity(.init(typeIdentifier: "NoteEntity", identifier: noteID))]
                : resolvedParameters,
            kind: .productionService,
            isTopLevel: FixtureActionContext.parentKind != IntentLabActionKind.productionIntent.rawValue
        )
    }

    static func beginTestSupport(
        operationID: String,
        resolvedParameters: [String: IntentLabValue]
    ) -> FixtureIntentActionStart? {
        beginAction(
            operationID: operationID,
            resolvedParameters: resolvedParameters,
            kind: .testSupport,
            isTopLevel: false
        )
    }

    private static func beginAction(
        operationID: String,
        resolvedParameters: [String: IntentLabValue],
        kind: IntentLabActionKind,
        isTopLevel: Bool
    ) -> FixtureIntentActionStart? {
        actionReceiptLock.lock()
        defer { actionReceiptLock.unlock() }
        let defaults = UserDefaults.standard
        guard let context = defaults.string(forKey: activeContextKey),
              let scope = invocationScope(for: context) else { return nil }
        actionReceiptSequence += 1
        let parametersData = (try? JSONEncoder.intentLab.encode(resolvedParameters)) ?? Data("{}".utf8)
        return FixtureIntentActionStart(
            executionID: UUID(),
            appSessionID: appSessionID,
            attemptContext: context,
            lane: scope.lane.rawValue,
            attempt: scope.attempt,
            operationID: operationID,
            resolvedParametersJSON: parametersData,
            kind: kind.rawValue,
            isTopLevel: isTopLevel,
            sequence: actionReceiptSequence,
            startedAt: Date()
        )
    }

    static func finishProductionIntent(
        _ action: FixtureIntentActionStart?,
        error: Error? = nil
    ) {
        guard let action,
              let lane = IntentLabLane(rawValue: action.lane),
              let kind = IntentLabActionKind(rawValue: action.kind) else { return }
        actionReceiptLock.lock()
        defer { actionReceiptLock.unlock() }

        let message: String?
        if let error {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedDescription = description.isEmpty ? "The intent operation failed." : description
            message = String(boundedDescription.prefix(actionReceiptErrorCharacterLimit))
        } else {
            message = nil
        }
        let receipt = IntentLabActionReceipt(
            executionID: action.executionID,
            appSessionID: action.appSessionID,
            attemptContext: action.attemptContext,
            lane: lane,
            attempt: action.attempt,
            kind: kind,
            operationID: action.operationID,
            resolvedParameters: (try? JSONDecoder.intentLab.decode(
                [String: IntentLabValue].self, from: action.resolvedParametersJSON
            )) ?? [:],
            terminalStatus: error == nil ? .succeeded : .failed,
            operationError: message,
            sequence: action.sequence,
            startedAt: action.startedAt,
            completedAt: Date(),
            observationTransport: "accessibleUI",
            isTopLevel: action.isTopLevel
        )

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: actionReceiptOverflowKey),
              var receipts = decodeActionReceipts(defaults.data(forKey: actionReceiptsKey)) else {
            defaults.set(true, forKey: actionReceiptOverflowKey)
            return
        }
        receipts.append(receipt)
        // Nested actions finish before their parent. Keep the persisted array
        // in start order so sequence numbers preserve the actual call tree.
        receipts.sort { $0.sequence < $1.sequence }
        if receipts.count > actionReceiptLimit {
            defaults.set(true, forKey: actionReceiptOverflowKey)
            return
        }
        let data = encodeActionReceipts(receipts)
        guard data.count <= actionReceiptByteLimit else {
            defaults.set(true, forKey: actionReceiptOverflowKey)
            return
        }
        defaults.set(data, forKey: actionReceiptsKey)
    }

    static func actionReceiptsJSON(from data: Data) -> String {
        guard !UserDefaults.standard.bool(forKey: actionReceiptOverflowKey),
              let receipts = decodeActionReceipts(data),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        guard receipts.count <= actionReceiptLimit else { return "[]" }
        return json
    }

    static func validatedActionReceipts(from data: Data?) -> [IntentLabActionReceipt] {
        guard !UserDefaults.standard.bool(forKey: actionReceiptOverflowKey) else { return [] }
        return decodeActionReceipts(data) ?? []
    }

    static func record(event: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.string(forKey: activeContextKey) ?? "unknown", forKey: observedContextKey)
        defaults.set(event, forKey: eventKey)
    }

    @discardableResult
    static func publishSummary(
        _ summary: String,
        for note: FixtureNote,
        route: String,
        subjectCaseID: UUID? = nil,
        subjectAttemptID: UUID? = nil
    ) throws -> FixtureSummaryReceipt {
        let defaults = UserDefaults.standard
        let receipt = FixtureSummaryReceipt(
            noteID: note.id,
            sourceContentDigest: FixtureNotes.contentDigest(note),
            summary: summary,
            context: defaults.string(forKey: activeContextKey) ?? "app-\(UUID().uuidString)",
            completionID: UUID().uuidString,
            route: route,
            subjectCaseID: subjectCaseID,
            subjectAttemptID: subjectAttemptID
        )
        let encoded = try JSONEncoder().encode(receipt)
        defaults.set(note.id, forKey: selectedNoteKey)
        defaults.set(encoded, forKey: summaryReceiptKey)
        record(event: "\(route):\(note.id)")
        return receipt
    }

    private static func invocationScope(for context: String) -> InvocationScope? {
        if context.hasPrefix("intent-") {
            let identifier = String(context.dropFirst("intent-".count))
            guard UUID(uuidString: identifier) != nil else { return nil }
            return InvocationScope(lane: .intentIntegration, attempt: 1)
        }
        guard context.hasPrefix("siri-") else { return nil }
        let value = String(context.dropFirst("siri-".count))
        guard let separator = value.lastIndex(of: "-"),
              UUID(uuidString: String(value[..<separator])) != nil,
              let attempt = Int(value[value.index(after: separator)...]),
              (1...3).contains(attempt) else { return nil }
        return InvocationScope(lane: .siri, attempt: attempt)
    }

    private static func decodeActionReceipts(_ data: Data?) -> [IntentLabActionReceipt]? {
        guard let data else { return [] }
        guard data.count <= actionReceiptByteLimit,
              let receipts = try? JSONDecoder.intentLab.decode([IntentLabActionReceipt].self, from: data),
              receipts.count <= actionReceiptLimit else { return nil }
        return receipts
    }

    private static func encodeActionReceipts(_ receipts: [IntentLabActionReceipt]) -> Data {
        (try? JSONEncoder.intentLab.encode(receipts)) ?? Data("[]".utf8)
    }
}
