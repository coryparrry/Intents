import CoreSpotlight
import Foundation
import FoundationModels

enum EvaluationSpotlightSearchRuntimeError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case unavailableFolder(String)
    case scopeIsTooBroad(String)
    case duplicateAttribute(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let issue):
            issue
        case .unavailableFolder(let path):
            "The Spotlight file-search folder is unavailable or is not a directory: \(path)"
        case .scopeIsTooBroad(let path):
            "The Spotlight file-search scope is too broad: \(path). Choose a dedicated folder."
        case .duplicateAttribute(let name):
            "The Spotlight configuration resolves more than one fetched attribute to \(name)."
        }
    }
}

struct EvaluationSpotlightSearchTrace: Codable, Equatable, Sendable {
    var searchedFiles: Bool
    var searchedCoreSpotlight: Bool
    var allowedMail: Bool
    var guidanceMode: EvaluationSpotlightGuidanceMode
    var focusedDomain: EvaluationSpotlightContentDomain?
    var outputFormat: EvaluationSpotlightOutputFormat
    var maximumResponseSize: Int
    var maximumPossibleResults: Int
    var contactResolverEnabled: Bool
    var customPipelineStages: [String]
    var collectionComplete: Bool = true
    var collectionIssue: String?
    var replyCount: Int = 0
    var queryCount: Int = 0
    var stageCount: Int = 0
    var partialReplyCount: Int = 0
    var completeReplyCount: Int = 0
    var itemResultCount: Int = 0
    var scoredItemResultCount: Int = 0
    var groupedItemResultCount: Int = 0
    var countReplyCount: Int = 0
    var countResultTotal: Int = 0
    var tableReplyCount: Int = 0
    var tableRowCount: Int = 0
    var statisticReplyCount: Int = 0
    var textReplyCount: Int = 0
    var unknownReplyCount: Int = 0
    var recordingMilliseconds: Double = 0
}

struct EvaluationSpotlightSearchRuntime: Sendable {
    let tool: EvaluationBoundedTool<SpotlightSearchTool>
    private let nativeTool: SpotlightSearchTool
    private let recorder: EvaluationSpotlightSearchRecorder

    static func make(
        from configuration: EvaluationSpotlightSearchConfiguration,
        limiter: EvaluationToolCallLimiter
    ) throws -> Self? {
        guard configuration.enabled else { return nil }
        if let issue = configuration.validationIssue {
            throw EvaluationSpotlightSearchRuntimeError.invalidConfiguration(issue)
        }
        if configuration.guidance.mode == .dynamic {
            _ = try nativeAttributes(configuration.guidance.dynamicProfile.attributes)
        }

        var sources: [SearchSource] = []
        if configuration.fileSource.enabled {
            let folderURL = try resolvedFolderURL(path: configuration.fileSource.folderPath)
            let attributes = try nativeAttributes(configuration.fileSource.fetchedAttributes)
            var fileSource = FileSource(fetchAttributes: attributes)
            fileSource.scopes = [folderURL]
            fileSource.maximumResultCount = configuration.fileSource.maximumResults
            sources.append(.files(fileSource))
        }

        if configuration.coreSpotlightSource.enabled {
            let attributes = try nativeAttributes(configuration.coreSpotlightSource.fetchedAttributes)
            var coreSpotlightSource = CoreSpotlightSource(fetchAttributes: attributes)
            coreSpotlightSource.maximumResultCount = configuration.coreSpotlightSource.maximumResults
            if configuration.coreSpotlightSource.allowMail {
                coreSpotlightSource.sourceOptions = [.allowMail]
            }
            sources.append(.coreSpotlight(coreSpotlightSource))
        }

        let contactResolver: (any ContactResolver)? = configuration.contactIdentity.enabled
            ? EvaluationSpotlightConfiguredContactResolver(
                configuration: configuration.contactIdentity
            )
            : nil
        var customStages: [any CustomStage] = []
        if configuration.pipeline.deduplicateItems {
            customStages.append(EvaluationSpotlightDeduplicateItemsStage())
        }

        let nativeConfiguration = SpotlightSearchTool.Configuration(
            sources: sources,
            guide: configuration.guidance.nativeGuide,
            contactResolver: contactResolver,
            customStages: customStages,
            maximumResponseSize: configuration.maximumResponseSize
        )
        let nativeTool = SpotlightSearchTool(configuration: nativeConfiguration)
        let tool = EvaluationBoundedTool(
            tool: nativeTool,
            limiter: limiter,
            tokenCounter: EvaluationSystemPromptTokenCounter()
        )
        let recorder = EvaluationSpotlightSearchRecorder(
            initialTrace: EvaluationSpotlightSearchTrace(configuration: configuration)
        )
        return Self(tool: tool, nativeTool: nativeTool, recorder: recorder)
    }

    func startRecording() -> Task<Void, Never> {
        let nativeTool = nativeTool
        let recorder = recorder
        return Task {
            for await reply in nativeTool.searchResults {
                guard !Task.isCancelled else { break }
                await recorder.record(reply)
            }
        }
    }

    func stopRecording(
        _ recording: Task<Void, Never>?,
        expectingReplies: Bool
    ) async -> EvaluationSpotlightSearchTrace {
        let drainResult = await EvaluationSpotlightRecordingDrain.waitUntilQuiescent(
            expectingReplies: expectingReplies,
            revision: { await recorder.recordedReplyCount },
            hasIncompleteStages: { await recorder.hasIncompleteStages }
        )
        await EvaluationSpotlightRecordingDrain.cancelAndWait(recording)
        return await recorder.stop(drainResult: drainResult)
    }

    func snapshot() async -> EvaluationSpotlightSearchTrace {
        await recorder.snapshot()
    }

    private static func resolvedFolderURL(path: String) throws -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !EvaluationSpotlightSearchConfiguration.isDisallowedFileScope(folderURL) else {
            throw EvaluationSpotlightSearchRuntimeError.scopeIsTooBroad(folderURL.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EvaluationSpotlightSearchRuntimeError.unavailableFolder(folderURL.path)
        }
        return folderURL
    }

    private static func nativeAttributes(
        _ selection: EvaluationSpotlightAttributeSelection
    ) throws -> [SearchableItemAttribute] {
        let attributes = selection.presets.map(\.nativeAttribute) + selection.customAttributeNames.map {
            SearchableItemAttribute(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var seen = Set<SearchableItemAttribute>()
        for attribute in attributes where !seen.insert(attribute).inserted {
            throw EvaluationSpotlightSearchRuntimeError.duplicateAttribute(attribute.rawValue)
        }
        return attributes
    }
}

extension EvaluationSpotlightSearchConfiguration {
    var enabledToolNames: [String] {
        enabled ? [SpotlightSearchTool().name] : []
    }

    static var knownToolNames: Set<String> {
        [SpotlightSearchTool().name]
    }
}

private actor EvaluationSpotlightSearchRecorder {
    private let started = ContinuousClock.now
    private var trace: EvaluationSpotlightSearchTrace
    private var queryTokens = Set<SpotlightSearchTool.SearchReply.QueryToken>()
    private var stageTokens = Set<SpotlightSearchTool.SearchReply.StageToken>()
    private var incompleteStageTokens = Set<SpotlightSearchTool.SearchReply.StageToken>()
    private var isStopped = false

    init(initialTrace: EvaluationSpotlightSearchTrace) {
        trace = initialTrace
    }

    func record(_ reply: SpotlightSearchTool.SearchReply) {
        guard !isStopped else { return }
        trace.replyCount += 1
        queryTokens.insert(reply.queryToken)
        stageTokens.insert(reply.stageToken)

        switch reply.status {
        case .partial:
            trace.partialReplyCount += 1
            incompleteStageTokens.insert(reply.stageToken)
        case .complete:
            trace.completeReplyCount += 1
            incompleteStageTokens.remove(reply.stageToken)
        @unknown default:
            trace.unknownReplyCount += 1
        }

        switch reply.content {
        case .items(let items):
            trace.itemResultCount += items.count
        case .scoredItems(let items):
            trace.scoredItemResultCount += items.count
        case .groupedItems(let groups):
            trace.groupedItemResultCount += groups.values.reduce(0) { $0 + $1.count }
        case .count(let count):
            trace.countReplyCount += 1
            trace.countResultTotal = Self.saturatingAdd(trace.countResultTotal, count.value)
        case .table(let table):
            trace.tableReplyCount += 1
            trace.tableRowCount += table.rows.count
        case .statistic:
            trace.statisticReplyCount += 1
        case .text:
            trace.textReplyCount += 1
        @unknown default:
            trace.unknownReplyCount += 1
        }
    }

    func snapshot() -> EvaluationSpotlightSearchTrace {
        var snapshot = trace
        snapshot.queryCount = queryTokens.count
        snapshot.stageCount = stageTokens.count
        let duration = started.duration(to: .now).components
        snapshot.recordingMilliseconds = Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1e15
        return snapshot
    }

    var recordedReplyCount: Int { trace.replyCount }
    var hasIncompleteStages: Bool { !incompleteStageTokens.isEmpty }

    func stop(
        drainResult: EvaluationSpotlightRecordingDrain.Result
    ) -> EvaluationSpotlightSearchTrace {
        isStopped = true
        trace.collectionComplete = drainResult.collectionComplete
        trace.collectionIssue = drainResult.issue
        return snapshot()
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        if !overflow { return sum }
        return rhs >= 0 ? .max : .min
    }
}

enum EvaluationSpotlightRecordingDrain {
    enum Result: Equatable, Sendable {
        case noRepliesExpected
        case complete
        case timedOutWaitingForReply
        case timedOutWithIncompleteStages
        case timedOutBeforeQuiescence

        var collectionComplete: Bool {
            switch self {
            case .noRepliesExpected, .complete: true
            case .timedOutWaitingForReply,
                 .timedOutWithIncompleteStages,
                 .timedOutBeforeQuiescence: false
            }
        }

        var issue: String? {
            switch self {
            case .noRepliesExpected, .complete:
                nil
            case .timedOutWaitingForReply:
                "Timed out before the expected Spotlight trace produced a reply."
            case .timedOutWithIncompleteStages:
                "Timed out while at least one Spotlight query stage was still partial."
            case .timedOutBeforeQuiescence:
                "Timed out before the Spotlight trace became quiescent."
            }
        }
    }

    static func waitUntilQuiescent(
        expectingReplies: Bool,
        quietPeriod: Duration = .milliseconds(20),
        maximumWait: Duration = .milliseconds(250),
        pollInterval: Duration = .milliseconds(5),
        revision: @escaping @Sendable () async -> Int,
        hasIncompleteStages: @escaping @Sendable () async -> Bool
    ) async -> Result {
        guard expectingReplies else { return .noRepliesExpected }

        let clock = ContinuousClock()
        let started = clock.now
        var lastChange = started
        var observedRevision = await revision()

        while !Task.isCancelled {
            let now = clock.now
            let currentRevision = await revision()
            if currentRevision != observedRevision {
                observedRevision = currentRevision
                lastChange = now
            }

            let containsIncompleteStages = await hasIncompleteStages()
            if observedRevision > 0,
               !containsIncompleteStages,
               lastChange.duration(to: now) >= quietPeriod {
                return .complete
            }
            if started.duration(to: now) >= maximumWait {
                if observedRevision == 0 {
                    return .timedOutWaitingForReply
                }
                return containsIncompleteStages
                    ? .timedOutWithIncompleteStages
                    : .timedOutBeforeQuiescence
            }
            try? await clock.sleep(for: pollInterval)
        }
        return .timedOutBeforeQuiescence
    }

    static func cancelAndWait(_ recording: Task<Void, Never>?) async {
        guard let recording else { return }
        recording.cancel()
        await recording.value
    }
}

private extension EvaluationSpotlightSearchTrace {
    init(configuration: EvaluationSpotlightSearchConfiguration) {
        searchedFiles = configuration.fileSource.enabled
        searchedCoreSpotlight = configuration.coreSpotlightSource.enabled
        allowedMail = configuration.coreSpotlightSource.enabled
            && configuration.coreSpotlightSource.allowMail
        guidanceMode = configuration.guidance.mode
        focusedDomain = configuration.guidance.mode == .focused
            ? configuration.guidance.focusedDomain : nil
        outputFormat = configuration.guidance.outputFormat
        maximumResponseSize = configuration.maximumResponseSize
        maximumPossibleResults = (configuration.fileSource.enabled
            ? configuration.fileSource.maximumResults : 0)
            + (configuration.coreSpotlightSource.enabled
                ? configuration.coreSpotlightSource.maximumResults : 0)
        contactResolverEnabled = configuration.contactIdentity.enabled
        customPipelineStages = configuration.pipeline.deduplicateItems
            ? [EvaluationSpotlightDeduplicateItemsStage.name]
            : []
    }
}

private struct EvaluationSpotlightConfiguredContactResolver: ContactResolver {
    let configuration: EvaluationSpotlightContactIdentityConfiguration

    func userIdentity() -> ResolvedContact {
        var contact = ResolvedContact(displayName: configuration.normalizedDisplayName)
        contact.names = configuration.normalized(configuration.alternateNames)
        contact.emailAddresses = configuration.normalized(configuration.emailAddresses)
        contact.phoneNumbers = configuration.normalized(configuration.phoneNumbers)
        return contact
    }
}

@Generable
struct EvaluationSpotlightDeduplicateItemsStage: CustomStage {
    static var name: String { "deduplicate_spotlight_items" }
    static var description: String {
        "Removes duplicate Spotlight items with the same unique identifier."
    }
    static var inputTypes: [SearchPipelineDataType] { [.items] }
    static var outputType: SearchPipelineDataType { .items }

    @Guide(description: "Keep the first duplicate when true, or the last duplicate when false.")
    var keepFirst = true

    func execute(items: [SearchableItem]) async throws -> SearchPipelineData {
        var identifiers = Set<String>()
        if keepFirst {
            return .items(items.filter {
                identifiers.insert($0.item.uniqueIdentifier).inserted
            })
        }

        var retained: [SearchableItem] = []
        for item in items.reversed()
        where identifiers.insert(item.item.uniqueIdentifier).inserted {
            retained.append(item)
        }
        return .items(Array(retained.reversed()))
    }
}

private extension EvaluationSpotlightGuidanceConfiguration {
    var nativeGuide: SpotlightSearchTool.Guide {
        let level: SpotlightSearchTool.GuidanceLevel = switch mode {
        case .complete:
            .complete
        case .focused:
            .focused(focusedDomain.nativeDomain)
        case .dynamic:
            .dynamic(dynamicProfile.nativeProfile)
        }
        let format: SpotlightSearchTool.FormatLevel = switch outputFormat {
        case .structured: .structured
        case .compact: .compact
        }
        return SpotlightSearchTool.Guide(level: level, format: format)
    }
}

private extension EvaluationSpotlightContentDomain {
    var nativeDomain: SpotlightSearchTool.ContentDomain {
        switch self {
        case .items: .items
        case .documents: .documents
        case .communications: .communications
        case .calendar: .calendar
        case .audio: .audio
        case .visualMedia: .visualMedia
        }
    }
}

private extension EvaluationSpotlightDynamicGuidanceProfile {
    var nativeProfile: SpotlightSearchTool.GuidanceProfile {
        let nativeAttributes = attributes.presets.map(\.nativeAttribute)
            + attributes.customAttributeNames.map {
                SearchableItemAttribute(
                    rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        return SpotlightSearchTool.GuidanceProfile(
            textMatch: textMatch.value,
            similarityMatch: similarityMatch.value,
            numericMatch: numericMatch.value,
            dates: dates.value,
            people: people.value,
            contentType: contentType.value,
            attributes: nativeAttributes.isEmpty ? nil : nativeAttributes
        )
    }
}

private extension EvaluationSpotlightAttributePreset {
    var nativeAttribute: SearchableItemAttribute {
        switch self {
        case .identifier: .identifier
        case .displayName: .displayName
        case .title: .title
        case .subject: .subject
        case .contentDescription: .contentDescription
        case .textContent: .textContent
        case .keywords: .keywords
        case .contentType: .contentType
        case .path: .path
        case .contentURL: .contentURL
        case .authorNames: .authorNames
        case .recipientNames: .recipientNames
        case .creator: .creator
        case .contentCreationDate: .contentCreationDate
        case .contentModificationDate: .contentModificationDate
        case .addedDate: .addedDate
        case .lastUsedDate: .lastUsedDate
        case .fileSize: .fileSize
        case .pageCount: .pageCount
        case .duration: .duration
        }
    }
}
