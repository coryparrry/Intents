import CoreSpotlight
import Foundation
import Testing
@testable import FoundationEvals

struct SpotlightSearchToolTests {
    @Test func defaultsAreOffBoundedAndRoundTrip() throws {
        let configuration = EvaluationSpotlightSearchConfiguration()

        #expect(!configuration.enabled)
        #expect(configuration.fileSource.enabled)
        #expect(!configuration.coreSpotlightSource.enabled)
        #expect(!configuration.contactIdentity.enabled)
        #expect(!configuration.pipeline.deduplicateItems)
        #expect(configuration.fileSource.maximumResults == 8)
        #expect(configuration.maximumResponseSize == 1_024)
        #expect(configuration.conservativeContextTokenReserve(maximumCalls: 4) == 0)
        #expect(configuration.enabledToolNames.isEmpty)

        let decoded = try JSONDecoder().decode(
            EvaluationSpotlightSearchConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
    }

    @Test func legacySpotlightObjectDefaultsNewCustomizationsToOff() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(EvaluationSpotlightSearchConfiguration())
            ) as? [String: Any]
        )
        object.removeValue(forKey: "contactIdentity")
        object.removeValue(forKey: "pipeline")

        let decoded = try JSONDecoder().decode(
            EvaluationSpotlightSearchConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.contactIdentity.enabled)
        #expect(!decoded.pipeline.deduplicateItems)
    }

    @Test func legacyFeatureObjectDefaultsSpotlightToOff() throws {
        let features = EvaluationFeatureConfiguration()
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(features)) as? [String: Any]
        )
        object.removeValue(forKey: "spotlightSearch")

        let decoded = try JSONDecoder().decode(
            EvaluationFeatureConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.spotlightSearch == EvaluationSpotlightSearchConfiguration())
        #expect(!decoded.spotlightSearch.enabled)
    }

    @Test func allPublicGuideModesAndSourceOptionsPersist() throws {
        let dynamic = EvaluationSpotlightSearchConfiguration(
            enabled: true,
            fileSource: .init(
                enabled: true,
                folderPath: "/tmp/foundation-evals-spotlight-fixture",
                maximumResults: 7,
                fetchedAttributes: .init(
                    presets: [.title, .textContent],
                    customAttributeNames: ["com.example.fixture.rank"]
                )
            ),
            coreSpotlightSource: .init(
                enabled: true,
                maximumResults: 5,
                fetchedAttributes: .init(presets: [.subject, .authorNames]),
                allowMail: true
            ),
            guidance: .init(
                mode: .dynamic,
                focusedDomain: .communications,
                dynamicProfile: .init(
                    textMatch: .allowed,
                    similarityMatch: .disallowed,
                    numericMatch: .unused,
                    dates: .allowed,
                    people: .disallowed,
                    contentType: .allowed,
                    attributes: .init(presets: [.title, .contentCreationDate])
                ),
                outputFormat: .structured
            ),
            contactIdentity: .init(
                enabled: true,
                displayName: "Fixture Person",
                alternateNames: ["The Tester"],
                emailAddresses: ["fixture@example.invalid"],
                phoneNumbers: ["+44 0000 000000"]
            ),
            pipeline: .init(deduplicateItems: true),
            maximumResponseSize: 2_048
        )

        let decoded = try JSONDecoder().decode(
            EvaluationSpotlightSearchConfiguration.self,
            from: JSONEncoder().encode(dynamic)
        )
        #expect(decoded == dynamic)
        #expect(decoded.validationIssue == nil)

        var complete = dynamic
        complete.guidance.mode = .complete
        complete.guidance.outputFormat = .compact
        #expect(complete.validationIssue == nil)

        var focused = dynamic
        focused.guidance.mode = .focused
        for domain in EvaluationSpotlightContentDomain.allCases {
            focused.guidance.focusedDomain = domain
            #expect(focused.validationIssue == nil)
        }
    }

    @Test func validationRejectsUnboundedOrUnusableConfigurations() {
        var configuration = EvaluationSpotlightSearchConfiguration(enabled: true)
        #expect(configuration.validationIssue?.contains("Choose one local folder") == true)

        configuration.fileSource.folderPath = "/"
        #expect(configuration.validationIssue?.contains("narrower folder") == true)

        configuration.fileSource.enabled = false
        #expect(configuration.validationIssue?.contains("at least one source") == true)

        configuration.coreSpotlightSource.enabled = true
        configuration.coreSpotlightSource.maximumResults = 0
        #expect(configuration.validationIssue?.contains("between 1") == true)

        configuration.coreSpotlightSource.maximumResults = 8
        configuration.maximumResponseSize = 128
        #expect(configuration.validationIssue?.contains("maximum response size") == true)

        configuration.maximumResponseSize = 1_024
        configuration.guidance.mode = .dynamic
        configuration.guidance.dynamicProfile = .init(
            textMatch: .disallowed,
            similarityMatch: .unused,
            numericMatch: .disallowed,
            dates: .unused,
            people: .disallowed,
            contentType: .unused
        )
        #expect(configuration.validationIssue == nil)

        configuration.contactIdentity.enabled = true
        #expect(configuration.validationIssue?.contains("display name") == true)

        configuration.contactIdentity.displayName = "Fixture Person"
        #expect(configuration.validationIssue == nil)
    }

    @Test func runtimeBuildsWithoutSearchingAndTraceContainsOnlyMetadata() async throws {
        let fixtureFolder = FileManager.default.temporaryDirectory
            .appending(path: "foundation-evals-spotlight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureFolder) }

        let configuration = EvaluationSpotlightSearchConfiguration(
            enabled: true,
            fileSource: .init(
                folderPath: fixtureFolder.path,
                maximumResults: 3,
                fetchedAttributes: .init(presets: [.title, .textContent])
            ),
            guidance: .init(
                mode: .focused,
                focusedDomain: .documents,
                outputFormat: .compact
            ),
            contactIdentity: .init(enabled: true, displayName: "Fixture Person"),
            pipeline: .init(deduplicateItems: true),
            maximumResponseSize: 512
        )
        let runtime = try #require(
            try EvaluationSpotlightSearchRuntime.make(
                from: configuration,
                limiter: EvaluationToolCallLimiter(maximumCalls: 2)
            )
        )
        let trace = await runtime.snapshot()

        #expect(runtime.tool.name == configuration.enabledToolNames.first)
        #expect(trace.searchedFiles)
        #expect(!trace.searchedCoreSpotlight)
        #expect(trace.maximumPossibleResults == 3)
        #expect(trace.maximumResponseSize == 512)
        #expect(trace.guidanceMode == .focused)
        #expect(trace.focusedDomain == .documents)
        #expect(trace.outputFormat == .compact)
        #expect(trace.contactResolverEnabled)
        #expect(trace.customPipelineStages == [EvaluationSpotlightDeduplicateItemsStage.name])
        #expect(trace.replyCount == 0)

        let encodedTrace = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        #expect(!encodedTrace.contains(fixtureFolder.path))
        #expect(!encodedTrace.contains("folderPath"))
        #expect(!encodedTrace.contains("argumentsJSON"))
        #expect(!encodedTrace.contains("\"output\":"))
        #expect(!encodedTrace.contains("Fixture Person"))
    }

    @Test func runtimeMapsEveryGuideModeWithoutSearching() async throws {
        var configuration = EvaluationSpotlightSearchConfiguration(
            enabled: true,
            fileSource: .init(enabled: false),
            coreSpotlightSource: .init(enabled: true),
            guidance: .init(mode: .complete, outputFormat: .structured)
        )

        for mode in EvaluationSpotlightGuidanceMode.allCases {
            configuration.guidance.mode = mode
            let runtime = try #require(
                try EvaluationSpotlightSearchRuntime.make(
                    from: configuration,
                    limiter: EvaluationToolCallLimiter(maximumCalls: 1)
                )
            )
            let trace = await runtime.snapshot()
            #expect(trace.guidanceMode == mode)
            #expect(trace.searchedCoreSpotlight)
            #expect(!trace.allowedMail)
            #expect(trace.replyCount == 0)
        }
    }

    @Test func runtimeRejectsHomeScopeAndDuplicateNativeAttributes() throws {
        var configuration = EvaluationSpotlightSearchConfiguration(
            enabled: true,
            fileSource: .init(folderPath: FileManager.default.homeDirectoryForCurrentUser.path)
        )
        #expect(throws: EvaluationSpotlightSearchRuntimeError.self) {
            _ = try EvaluationSpotlightSearchRuntime.make(
                from: configuration,
                limiter: EvaluationToolCallLimiter(maximumCalls: 1)
            )
        }

        let fixtureFolder = FileManager.default.temporaryDirectory
            .appending(path: "foundation-evals-spotlight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureFolder) }
        configuration.fileSource.folderPath = fixtureFolder.path
        configuration.fileSource.fetchedAttributes = .init(
            presets: [.title],
            customAttributeNames: [SearchableItemAttribute.title.rawValue]
        )
        #expect(throws: EvaluationSpotlightSearchRuntimeError.self) {
            _ = try EvaluationSpotlightSearchRuntime.make(
                from: configuration,
                limiter: EvaluationToolCallLimiter(maximumCalls: 1)
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func recordingDrainWaitsForDelayedCompletionAndJoinsConsumer() async {
        let probe = SpotlightRecordingDrainProbe()
        let initialRevisionRead = AsyncStream<Void>.makeStream()
        let incompleteStageRead = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var initialRevisionIterator = initialRevisionRead.stream.makeAsyncIterator()
            _ = await initialRevisionIterator.next()
            await probe.recordPartial()
            var incompleteStageIterator = incompleteStageRead.stream.makeAsyncIterator()
            _ = await incompleteStageIterator.next()
            await probe.recordComplete()
            while !Task.isCancelled {
                await Task.yield()
            }
            await probe.markTerminated()
        }

        let drainResult = await EvaluationSpotlightRecordingDrain.waitUntilQuiescent(
            expectingReplies: true,
            quietPeriod: .milliseconds(5),
            // This checks ordering, not scheduler speed during the full parallel suite.
            maximumWait: .seconds(30),
            pollInterval: .milliseconds(1),
            revision: {
                let revision = await probe.revision
                if revision == 0 {
                    initialRevisionRead.continuation.yield(())
                }
                return revision
            },
            hasIncompleteStages: {
                let hasIncompleteStages = await probe.hasIncompleteStages
                if hasIncompleteStages {
                    incompleteStageRead.continuation.yield(())
                }
                return hasIncompleteStages
            }
        )

        let revision = await probe.revision
        let hasIncompleteStages = await probe.hasIncompleteStages
        #expect(drainResult == .complete)
        #expect(revision == 2)
        #expect(!hasIncompleteStages)

        await EvaluationSpotlightRecordingDrain.cancelAndWait(consumer)
        let terminated = await probe.terminated
        #expect(terminated)
    }

    @Test func recordingDrainReportsMissingExpectedReply() async {
        let result = await EvaluationSpotlightRecordingDrain.waitUntilQuiescent(
            expectingReplies: true,
            quietPeriod: .milliseconds(1),
            maximumWait: .milliseconds(5),
            pollInterval: .milliseconds(1),
            revision: { 0 },
            hasIncompleteStages: { false }
        )

        #expect(result == .timedOutWaitingForReply)
        #expect(!result.collectionComplete)
        #expect(result.issue != nil)
    }
}

private actor SpotlightRecordingDrainProbe {
    private(set) var revision = 0
    private(set) var hasIncompleteStages = false
    private(set) var terminated = false

    func recordPartial() {
        revision += 1
        hasIncompleteStages = true
    }

    func recordComplete() {
        revision += 1
        hasIncompleteStages = false
    }

    func markTerminated() {
        terminated = true
    }
}
