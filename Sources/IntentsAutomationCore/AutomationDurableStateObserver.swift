#if os(macOS)
import Foundation
import Security

/// The schema of a reviewed, independently readable storage boundary.
/// This is data, never executable extraction code. SQLite/SwiftData and cache reads
/// are deliberately unsupported. The supported recipe pins the actual producer source.
public struct AutomationJSONStorageDeclaration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var format: String
    public var completionBoundary: String
    public var storagePath: String
    public var entityTypeID: String
    public var recordsField: String
    public var idField: String
    public var queryField: String
    public var propertyFields: [String: String]
    public var documentPropertyFields: [String: String]?
    public var properties: [String: String]
    public var evidence: String
}

/// Registered recipe data is reviewed against the pinned producer and build
/// source. Adding a supported app adds one profile, never an extraction script.
struct AutomationDurableStateProfile: Equatable, Sendable {
    let id: String, bundleID: String, storageFilename: String
    let sourceDigests: [String: String]
    let entityTypeID: String, recordsField: String, idField: String, queryField: String
    let properties: [String: String], propertyFields: [String: String], documentPropertyFields: [String: String]
    let documentKeys: Set<String>, recordKeys: Set<String>
    let evidence: String
    // Initial ownership base is specifically an unsandboxed Mac app's Documents.
    // Other bases need separate qualified resolution before they can be registered.
    static let registered: [Self] = [.init(
        id: "duplicate-tasks-json.v2", bundleID: "com.coryparry.IntentsAutomation.DuplicateTasks", storageFilename: "DuplicateTasks.json",
        sourceDigests: [
            "App/TaskIntents.swift": "b06732829b46f2bedd4730e023e74357fa4dfc22151d264d7c01d4393a430ee9",
            "App/TaskRepository.swift": "d546490206b74341b7b092e84a6bbc18e9d464af8690632dc5e76b994263d617",
            "Models/TaskDiskStore.swift": "fb2e7d711354006b9f3b62b0b244476e917d9d9e6d014557505239befac5f57a",
            "DuplicateTasks.xcodeproj/project.pbxproj": "6b499bbf6bfb4627db00356c8ac4d4674d26e529de69fe5b4412579d31074584"],
        entityTypeID: "TaskEntity", recordsField: "records", idField: "id", queryField: "title",
        properties: ["title": "text", "owner": "text", "completed": "bool", "control": "text"],
        propertyFields: ["title": "title", "owner": "owner", "completed": "completed"], documentPropertyFields: ["control": "control"],
        documentKeys: ["records", "control", "executionCount"], recordKeys: ["id", "title", "owner", "completed"],
        evidence: "Seeded control fixture: reviewed TaskDiskStore.write atomically persists before complete returns; missing-save retains the old completed field. The pinned DuplicateTasksMac target is an unsandboxed native Mac app; TaskRepository uses Documents/DuplicateTasks.json.")]
    func storageURL() -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/" + storageFilename) }
    func schema() -> AutomationJSONStorageDeclaration {
        .init(schemaVersion: 1, format: "jsonEntityDocument", completionBoundary: "durableBeforeActionReturns",
            storagePath: storageURL().path, entityTypeID: entityTypeID, recordsField: recordsField, idField: idField, queryField: queryField,
            propertyFields: propertyFields, documentPropertyFields: documentPropertyFields, properties: properties, evidence: evidence)
    }
}

/// Frozen facts identify one supported independent reader. They cannot reconstruct
/// a live lease, issue a runtime qualification, or choose the assertion result.
public struct AutomationDurableStateReader: Codable, Equatable, Sendable {
    public let profileID: String
    public let catalogDigest: String, hostProductDigest: String, hostXctestrunDigest: String
    public let app: AppIdentity
    public let target: TargetIdentity
    public let environmentID: String
    public let sourceManifestPath: String
    public let sourceFiles: [String: String]
    public let declaration: AutomationJSONStorageDeclaration

    public static func supported(prepared: AutomationPreparedApplication, approval: RunApproval) throws -> Self? {
        guard approval.app == prepared.host.app, approval.target == prepared.host.target,
              approval.target.kind == .nativeMac, prepared.host.app.sourceManifestDigest == (try prepared.source.digest),
              let bundle = prepared.host.app.canonicalBundlePath else { return nil }
        let session = try AutomationPath.canonical(URL(fileURLWithPath: prepared.buildLogPath).deletingLastPathComponent())
        let frozenRoot = session.appendingPathComponent("source")
        guard prepared.generatedHost.projectPath.hasPrefix(frozenRoot.path + "/"), bundle.hasPrefix(session.path + "/") else { return nil }
        for profile in AutomationDurableStateProfile.registered where profile.bundleID == prepared.host.app.bundleID {
            var sources: [String: String] = [:]
            var matched = 0
            for (relative, digest) in profile.sourceDigests {
                guard let file = prepared.source.files.first(where: { $0.relativePath == relative }),
                      file.symbolicLink == nil, file.sha256 == digest else { continue }
                matched += 1
                // The retained project is rewritten to associate the host. Its
                // original reviewed fingerprint remains in the frozen manifest.
                if relative.hasSuffix(".swift") { sources[frozenRoot.appendingPathComponent(file.relativePath).path] = digest }
            }
            guard matched == profile.sourceDigests.count,
                  prepared.catalog.entities?.contains(where: { $0.typeID == profile.entityTypeID && $0.properties == profile.properties }) == true,
                  isUnsandboxedProduct(URL(fileURLWithPath: bundle)) else { continue }
            let recipe = Self(profileID: profile.id, catalogDigest: try AutomationRecipeContext.catalogDigest(prepared.catalog),
                              hostProductDigest: prepared.host.hostProductDigest, hostXctestrunDigest: prepared.host.xctestrunDigest, app: approval.app, target: approval.target, environmentID: approval.environmentID,
                              sourceManifestPath: session.appendingPathComponent("source-manifest.json").path,
                              sourceFiles: sources, declaration: profile.schema())
            try recipe.validateIdentity(); try recipe.verifyDeclarationAndProduct()
            return recipe
        }
        return nil
    }
    private static func isUnsandboxedProduct(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return entitlements?["com.apple.security.app-sandbox"] as? Bool != true
    }
    func validateIdentity() throws {
        // Validate lexical path shape here. Foundation standardization can turn
        // an already canonical /private/var capture path into its /var symlink
        // alias. Actual retained paths still require realpath equality and
        // descriptor-relative no-follow verification before issuing evidence.
        guard let profile = AutomationDurableStateProfile.registered.first(where: { $0.id == profileID }),
              target.kind == .nativeMac, app.platform == "macos", app.productDigest != nil,
              app.sourceManifestDigest != nil, app.canonicalBundlePath != nil, !environmentID.isEmpty,
              app.bundleID == profile.bundleID, declaration == profile.schema(),
              [catalogDigest, hostProductDigest, hostXctestrunDigest].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
              Set(sourceFiles.values) == Set(profile.sourceDigests.filter { $0.key.hasSuffix(".swift") }.values),
              sourceFiles.count == profile.sourceDigests.filter({ $0.key.hasSuffix(".swift") }).count,
              sourceManifestPath.hasSuffix("/source-manifest.json"), sourceManifestPath.hasPrefix("/"),
              sourceManifestPath.utf8.count <= 4096, !sourceManifestPath.contains("\0"),
              sourceManifestPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw AutomationContractError.invalidPlan("Storage reader requires an exact registered source-reviewed recipe")
        }
        let roots = sourceFiles.compactMap { path, digest -> String? in
            guard let relative = profile.sourceDigests.first(where: { $0.value == digest })?.key,
                  path.hasSuffix("/" + relative) else { return nil }
            return String(path.dropLast(relative.count + 1))
        }
        let expectedRoot = URL(fileURLWithPath: sourceManifestPath).deletingLastPathComponent().appendingPathComponent("source").path
        guard roots.count == sourceFiles.count, Set(roots) == [expectedRoot] else { throw AutomationContractError.invalidIdentity }
    }
    func validate(plan: AutomationCase, segment: AutomationSegment) throws {
        try validateIdentity()
        let catalog = plan.preparedMacBuildArtifacts?.catalogDigest ?? plan.provenance["catalog"]
        let host = plan.preparedMacBuildArtifacts?.hostProductDigest ?? plan.provenance["apple.macHostProductDigest"]
        let testRun = plan.preparedMacBuildArtifacts?.xctestrunDigest ?? plan.provenance["apple.macXctestrunDigest"]
        guard plan.app == app, plan.target == target, plan.environmentID == environmentID,
              catalog == catalogDigest, host == hostProductDigest, testRun == hostXctestrunDigest,
              segment.kind == .storageRead, segment.phase == .observe, segment.effects == [.observe],
              segment.lifecycle == .persistedStateAcrossSegments, segment.uiProgram == nil,
              (segment.inputBindings ?? []).allSatisfy({ $0.destination == .hostQueryIDs }), segment.attemptTextBindings?.isEmpty != false,
              let program = segment.hostProgram, (1...10).contains(program.operations.count),
              program.operations.allSatisfy({ $0.kind == .query && $0.typeID == declaration.entityTypeID && $0.properties == declaration.properties }) else {
            throw AutomationContractError.invalidPlan("Durable reader does not match this frozen independent query")
        }
        // Deferred identity selectors are validated as placeholders at preflight;
        // execution validates the exact resolved IDs before reading the file.
        var projection = program
        for binding in segment.inputBindings ?? [] {
            if let index = projection.operations.firstIndex(where: { $0.id == binding.operationID }), projection.operations[index].queryIDs == nil {
                projection.operations[index].queryIDs = ["preflight-placeholder"]
            }
        }
        try projection.validate(route: .storageRead, phase: .observe)
    }
    func digest() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AutomationArtifactRegistry.digest(try encoder.encode(self))
    }
    /// Verify source authority against the retained capture, never the editable
    /// original checkout. The host-rewritten project is qualified by its original
    /// source-manifest entry; unchanged producer Swift files are read directly.
    func verifyFrozenSources() throws {
        try validateIdentity()
        guard let profile = AutomationDurableStateProfile.registered.first(where: { $0.id == profileID }) else { throw AutomationContractError.invalidIdentity }
        let session = URL(fileURLWithPath: sourceManifestPath).deletingLastPathComponent()
        guard try AutomationPath.canonical(session).path == session.path else { throw AutomationContractError.conflictingOperation }
        let bytes = try AutomationReadOnlyFile.read(root: session, relativePath: "source-manifest.json", maximumBytes: AutomationSourceSnapshot.maximumManifestBytes)
        let manifest = try JSONDecoder().decode(AutomationSourceManifest.self, from: bytes)
        guard app.sourceManifestDigest == (try manifest.digest) else { throw AutomationContractError.conflictingOperation }
        try manifest.validateCaptureLayout()
        for (relative, digest) in profile.sourceDigests {
            guard let file = manifest.files.first(where: { $0.relativePath == relative }), file.symbolicLink == nil, file.sha256 == digest else {
                throw AutomationContractError.conflictingOperation
            }
            if relative.hasSuffix(".swift") {
                let path = session.appendingPathComponent("source/" + file.relativePath).path
                guard sourceFiles[path] == digest,
                      AutomationArtifactRegistry.digest(try AutomationReadOnlyFile.read(root: session.appendingPathComponent("source"), relativePath: file.relativePath, maximumBytes: 1_048_576)) == digest else {
                    throw AutomationContractError.conflictingOperation
                }
            }
        }
    }
    func verifyDeclarationAndProduct() throws {
        try verifyFrozenSources()
        guard let bundle = app.canonicalBundlePath,
              bundle.hasPrefix(URL(fileURLWithPath: sourceManifestPath).deletingLastPathComponent().path + "/"),
              try AutomationProductDigest.compute(bundle: URL(fileURLWithPath: bundle), version: app.productDigestVersion) == app.productDigest,
              Self.isUnsandboxedProduct(URL(fileURLWithPath: bundle)) else {
            throw AutomationContractError.conflictingOperation
        }
    }
    func read(program: AutomationHostProgram) throws -> (Data, [String: AutomationValue]) {
        try snapshot(program: program, storageURL: URL(fileURLWithPath: declaration.storagePath))
    }
    /// Internal seam exercises the storage algorithm in disposable test files. It
    /// cannot mint a supported recipe, live runtime authority or product receipt.
    func snapshot(program: AutomationHostProgram, storageURL: URL, afterFirstRead: (() throws -> Void)? = nil) throws -> (Data, [String: AutomationValue]) {
        // Traverse every component without following symlinks. A second independent
        // read fences pathname replacement as well as in-place concurrent writes.
        let path = storageURL.path
        var firstIdentity: AutomationReadOnlyFile.Identity?, secondIdentity: AutomationReadOnlyFile.Identity?
        let data = try AutomationReadOnlyFile.read(root: URL(fileURLWithPath: "/"), relativePath: String(path.dropFirst()), maximumBytes: 1_048_576, identity: { firstIdentity = $0 })
        try afterFirstRead?()
        let repeated = try AutomationReadOnlyFile.read(root: URL(fileURLWithPath: "/"), relativePath: String(path.dropFirst()), maximumBytes: 1_048_576, identity: { secondIdentity = $0 })
        guard firstIdentity != nil, firstIdentity == secondIdentity, data == repeated else { throw AutomationContractError.conflictingOperation }
        try AutomationPackageResolution.validateUniqueJSONKeys(data)
        let json = try JSONDecoder().decode(AutomationJSON.self, from: data)
        guard let profile = AutomationDurableStateProfile.registered.first(where: { $0.id == profileID }),
              let document = json.object, Set(document.keys) == profile.documentKeys,
              case .array(let rows) = document[declaration.recordsField], rows.count <= 1000 else {
            throw AutomationContractError.missingEvidence("Storage document has no bounded entity collection")
        }
        var records: [AutomationValue] = [], ids = Set<String>()
        for row in rows {
            guard let fields = row.object, Set(fields.keys) == profile.recordKeys, case .string(let id) = fields[declaration.idField], ids.insert(id).inserted else {
                throw AutomationContractError.conflictingOperation
            }
            var properties: [String: AutomationValue] = [:]
            for (property, codec) in declaration.properties {
                let raw: AutomationJSON?
                if let field = declaration.propertyFields[property] { raw = fields[field] }
                else if let field = declaration.documentPropertyFields?[property] { raw = document[field] }
                else { raw = nil }
                let value: AutomationValue
                switch (raw, codec) {
                case (.some(.string(let text)), "text"): value = .text(text)
                case (.some(.bool(let flag)), "bool"): value = .bool(flag)
                default: throw AutomationContractError.missingEvidence("Storage field has no declared scalar value")
                }
                properties[property] = value
            }
            records.append(.object(["entity": .entity(typeID: declaration.entityTypeID, value: id), "properties": .object(properties)]))
        }
        var outputs: [String: AutomationValue] = [:]
        for query in program.operations {
            guard query.attemptQueryPrefix == nil else { throw AutomationInputBindingError.inputUnavailable }
            let selected = records.filter { record in
                guard case .object(let fields) = record, case .entity(_, let id) = fields["entity"], case .object(let properties) = fields["properties"] else { return false }
                if let ids = query.queryIDs { return ids.contains(id) }
                guard let text = query.queryText, case .text(let title) = properties[declaration.queryField] else { return false }
                return title.localizedCaseInsensitiveContains(text)
            }
            guard query.queryIDs.map({ Set($0) == Set(selected.compactMap { record in
                guard case .object(let fields) = record, case .entity(_, let id) = fields["entity"] else { return nil }; return id
            }) }) ?? true else { throw AutomationContractError.missingEvidence("Storage read did not resolve every selected entity ID") }
            let value = AutomationValue.array(selected)
            try AutomationEntitySelection.validateQueryOutput(value, query: query)
            outputs[query.id] = value
        }
        return (data, outputs)
    }
    /// Only build fingerprints and owned capture locations vary across separately
    /// verified builds. Profile, producer bytes, schema, storage path and target
    /// remain part of the comparison contract.
    var comparisonProjection: Self {
        var identity = app
        identity.canonicalBundlePath = nil; identity.productDigest = nil; identity.productDigestVersion = nil
        identity.codeDirectoryIdentity = nil; identity.sourceManifestDigest = nil; identity.sourceSyntaxIndexDigest = nil
        identity.provenanceStrength = "comparisonContract"
        let base = URL(fileURLWithPath: sourceManifestPath).deletingLastPathComponent().appendingPathComponent("source").path + "/"
        let sources = Dictionary(uniqueKeysWithValues: sourceFiles.map { path, digest in
            ("/captured-source/source/" + String(path.dropFirst(base.count)), digest)
        })
        return .init(profileID: profileID, catalogDigest: String(repeating: "0", count: 64), hostProductDigest: String(repeating: "0", count: 64),
            hostXctestrunDigest: String(repeating: "0", count: 64), app: identity, target: target, environmentID: environmentID,
            sourceManifestPath: "/captured-source/source-manifest.json", sourceFiles: sources, declaration: declaration)
    }
    static func replacingReaders(in plan: AutomationCase, with candidate: Self) throws -> AutomationCase {
        try candidate.validateIdentity()
        var changed = plan
        for index in changed.observations.indices {
            guard let before = changed.observations[index].durableStateReader else { continue }
            try before.validateIdentity()
            guard before.comparisonProjection == candidate.comparisonProjection else {
                throw AutomationContractError.invalidPlan("Changed build has no identical reviewed storage-reader contract")
            }
            changed.observations[index].durableStateReader = candidate
            try candidate.validate(plan: changed, segment: changed.observations[index])
        }
        return changed
    }
    /// Upgrade only the independent observers; the subject and setup are untouched.
    public func applying(to plan: AutomationCase) throws -> AutomationCase {
        var result = plan
        guard !result.requirements.isEmpty else { throw AutomationContractError.missingEvidence("Choose an entity-state requirement before adding durable observation") }
        for index in result.observations.indices where result.requirements.contains(where: { $0.observationID == result.observations[index].id }) {
            result.observations[index].kind = .storageRead
            result.observations[index].requiredCapabilities = []
            result.observations[index].durableStateReader = self
            try validate(plan: result, segment: result.observations[index])
        }
        result.provenance["observation.storageProfile"] = profileID
        result.provenance["observation.storageQualification"] = "reviewed producer source and independent local reader; seeded controls require live demonstration"
        for index in result.requirements.indices {
            guard result.requirements[index].entityProperty != nil else { throw AutomationContractError.invalidPlan("Storage reader supports entity property predicates") }
            result.requirements[index].proof = .persistedState
        }
        result.id = "durable." + String(try AutomationFrozenCase.planDigest(result).prefix(32))
        return result
    }
}

struct AutomationDurableStateReadReceipt: Codable, Equatable, Sendable {
    let scope: AutomationScope
    let planDigest: String
    let recipeDigest: String
    let documentDigest: String
    let outputsDigest: String
    static func outputsDigest(_ outputs: [String: AutomationValue]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AutomationArtifactRegistry.digest(try encoder.encode(outputs))
    }
    func validates(receipt: AutomationSegmentReceipt, segment: AutomationSegment, plan: AutomationCase, runID: String, attemptID: String) -> Bool {
        guard let reader = segment.durableStateReader, let outputs = receipt.verifiedOutputs,
              let program = segment.hostProgram, receipt.observations.count == 1,
              Set(outputs.keys) == Set(program.operations.map(\.id)),
              receipt.artifact?.isEmpty == false,
              scope.protocolVersion == 1,
              documentDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return false }
        let projection: AutomationValue
        if program.operations.count == 1 {
            guard let value = outputs[program.operations[0].id] else { return false }; projection = value
        } else { projection = .object(outputs) }
        guard receipt.observations[0].value == projection else { return false }
        return scope == receipt.scope && scope.runId == runID && scope.attemptId == attemptID && scope.segmentId == segment.id
            && scope.leaseGeneration > 0 && receipt.completed && receipt.dispatched && receipt.environmentID == plan.environmentID
            && receipt.app == plan.app && receipt.target == plan.target && receipt.route == segment.kind && receipt.segmentID == segment.id
            && planDigest == (try? AutomationFrozenCase.planDigest(plan)) && recipeDigest == (try? reader.digest())
            && documentDigest.count == 64 && outputsDigest == (try? Self.outputsDigest(outputs))
    }
}

/// Executes the supported observer locally without activating, messaging, saving,
/// repairing or retrying the subject. All ordinary routes retain their owner.
actor AutomationDurableStateRouteDriver: AutomationResolvedRouteDriver {
    private let underlying: any AutomationRouteDriver
    private let approval: RunApproval
    private let leases: AutomationDeviceLeaseManager
    private let artifacts: AutomationArtifactRegistry
    private var active: (AutomationCase, AutomationSegment, AutomationScope, AutomationDeviceLeaseManager.Lease)?
    private var acquired = false
    private var acquiring = false
    private var issued = false
    private var executing = false
    private var revoked = false
    init(underlying: any AutomationRouteDriver, approval: RunApproval, leases: AutomationDeviceLeaseManager, artifacts: AutomationArtifactRegistry) {
        self.underlying = underlying; self.approval = approval; self.leases = leases; self.artifacts = artifacts
    }
    func acquire(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: nil)
    }
    func acquireResolved(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                         authority: AutomationSegmentResolutionAuthority) async throws {
        try await acquireAuthorized(plan: plan, segment: segment, scope: scope, lease: lease, authority: authority)
    }
    private func acquireAuthorized(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease,
                                   authority: AutomationSegmentResolutionAuthority?) async throws {
        guard let reader = segment.durableStateReader else {
            guard active == nil else { throw AutomationContractError.targetBusy }
            if let authority, let driver = underlying as? any AutomationResolvedRouteDriver {
                try await driver.acquireResolved(plan: plan, segment: segment, scope: scope, lease: lease, authority: authority)
            } else { try await underlying.acquire(plan: plan, segment: segment, scope: scope, lease: lease) }
            return
        }
        if let authority {
            guard try authority.matches(plan: plan, segment: segment, scope: scope) else { throw AutomationContractError.conflictingOperation }
        } else {
            guard plan.observations.contains(segment), segment.inputBindings?.isEmpty != false else { throw AutomationContractError.conflictingOperation }
        }
        try reader.validate(plan: plan, segment: segment); try scope.validate()
        guard active == nil, approval.app == plan.app, approval.target == plan.target, approval.environmentID == plan.environmentID,
              approval.approvedCaseDigest == (try AutomationFrozenCase.planDigest(plan)), scope.runId == approval.runID,
              scope.segmentId == segment.id, scope.leaseGeneration == lease.generation, lease.control == .system,
              lease.target == plan.target, lease.runID == approval.runID else { throw AutomationContractError.unknownLease }
        // Reserve before the suspension so a racing release revokes this admission.
        active = (plan, segment, scope, lease); acquired = false; acquiring = true; issued = false; revoked = false
        defer { acquiring = false }
        guard await leases.isCurrent(lease), active?.2 == scope, !revoked else { throw AutomationContractError.unknownLease }
        acquired = true
    }
    func execute(plan: AutomationCase, segment: AutomationSegment, scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async throws -> AutomationSegmentReceipt {
        guard let reader = segment.durableStateReader else { return try await underlying.execute(plan: plan, segment: segment, scope: scope, lease: lease) }
        guard let current = active, current.0 == plan, current.1 == segment, current.2 == scope, current.3 == lease,
              acquired, !acquiring, !issued, !executing, !revoked else { throw AutomationContractError.unknownLease }
        issued = true; executing = true; defer { executing = false }
        guard await leases.isCurrent(lease), !revoked else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation(); try reader.verifyDeclarationAndProduct()
        guard let program = segment.hostProgram else { throw AutomationContractError.invalidIdentity }
        let (data, outputs) = try reader.read(program: program)
        try reader.verifyDeclarationAndProduct()
        let proof = AutomationDurableStateReadReceipt(scope: scope, planDigest: try AutomationFrozenCase.planDigest(plan),
            recipeDigest: try reader.digest(), documentDigest: AutomationArtifactRegistry.digest(data), outputsDigest: try AutomationDurableStateReadReceipt.outputsDigest(outputs))
        let artifact = try await artifacts.store(data: JSONEncoder().encode(proof), name: "durable-read-\(lease.generation).json", scope: scope)
        guard await leases.isCurrent(lease), !revoked else { throw AutomationContractError.unknownLease }
        try Task.checkCancellation()
        let value = program.operations.count == 1 ? outputs[program.operations[0].id]! : .object(outputs)
        var observation = AutomationObservation(id: segment.id, app: plan.app, target: plan.target, environmentID: plan.environmentID,
            attemptID: scope.attemptId, stepID: segment.id, route: segment.kind, proof: .persistedState, value: value)
        observation.artifact = artifact.handle
        var receipt = AutomationSegmentReceipt(scope: scope, app: plan.app, target: plan.target, segmentID: segment.id, route: segment.kind,
            dispatched: true, completed: true, observations: [observation], artifact: artifact.handle, verifiedOutputs: outputs, environmentID: plan.environmentID)
        receipt.durableStateRead = proof
        return receipt
    }
    func release(scope: AutomationScope, lease: AutomationDeviceLeaseManager.Lease) async -> AutomationReleaseProof {
        guard let current = active else { return await underlying.release(scope: scope, lease: lease) }
        guard current.2 == scope, current.3 == lease else { return .init(commandsDrained: false, runnerTerminated: false) }
        revoked = true
        guard !acquiring, !executing else { return .init(commandsDrained: false, runnerTerminated: true) }
        active = nil
        return .init(commandsDrained: true, runnerTerminated: true)
    }
}
#endif
