import CoreAILanguageModels
import Darwin
import Foundation
import FoundationModels

enum CoreAIModelLoadingError: LocalizedError, Equatable, Sendable {
    case resourcesPathRequired
    case resourcesFolderUnavailable(String)
    case resourcesPathIsNotFolder(String)
    case staleResourcesBookmark(String)
    case modelLoadFailed(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .resourcesPathRequired:
            "Choose a Core AI model resource folder before running the evaluation."
        case .resourcesFolderUnavailable(let path):
            "The Core AI model resource folder is unavailable at \(path). Choose it again."
        case .resourcesPathIsNotFolder(let path):
            "The selected Core AI model resource path is not a folder: \(path)."
        case .staleResourcesBookmark(let path):
            "Access to the Core AI model resource folder at \(path) has expired. Choose it again."
        case .modelLoadFailed(let path, let message):
            "Could not load the Core AI model resources at \(path): \(message)"
        }
    }
}

struct CoreAIModelLoadResult: Sendable {
    let model: CoreAILanguageModel
    let modelName: String
    let contextSize: Int
    let capabilities: LanguageModelCapabilities
    let estimatedSizeOnDiskBytes: Int?
    let resourceIdentity: CoreAIModelLoader.ResourceIdentity

    fileprivate let securityScopedAccess: CoreAISecurityScopedAccess
}

struct CoreAIModelDescriptor: Equatable, Sendable {
    let modelName: String
    let contextSize: Int
    let estimatedSizeOnDiskBytes: Int?
    let supportsVision: Bool
    let supportsGuidedGeneration: Bool
    let supportsReasoning: Bool
    let supportsToolCalling: Bool

    /// Copies the loaded model metadata into the value used by model controls.
    init(result: CoreAIModelLoadResult) {
        modelName = result.modelName
        contextSize = result.contextSize
        estimatedSizeOnDiskBytes = result.estimatedSizeOnDiskBytes
        supportsVision = result.capabilities.contains(.vision)
        supportsGuidedGeneration = result.capabilities.contains(.guidedGeneration)
        supportsReasoning = result.capabilities.contains(.reasoning)
        supportsToolCalling = result.capabilities.contains(.toolCalling)
    }
}

enum CoreAIModelControlStatus: Equatable, Sendable {
    case unconfigured
    case readyToLoad
    case loading
    case loaded(CoreAIModelDescriptor)
    case failed(String)
}

actor CoreAIModelLoader {
    static let shared = CoreAIModelLoader()

    struct ResourceStamp: Hashable, Sendable {
        let relativePath: String
        let modificationDate: Date?
        let fileSize: Int?
        let fileIdentifier: String?
        let statusChangeTime: FileStatusChangeTime
    }

    struct FileStatusChangeTime: Hashable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64
    }

    struct ResourceIdentity: Hashable, Sendable {
        let resourceURL: URL
        let resourceFingerprint: [ResourceStamp]
    }

    private struct CachedModel: Sendable {
        let key: ResourceIdentity
        let result: CoreAIModelLoadResult
    }

    private var cachedModel: CachedModel?
    private var latestRequestedKey: ResourceIdentity?

    /// Loads validated resources eagerly, reusing a model only while its resource fingerprint matches.
    ///
    /// Cancellation cancels this caller's load. Concurrent requests load independently, and only
    /// results matching the latest requested resource identity replace the cache. The returned
    /// value retains security-scoped folder access.
    /// - Throws: Resource-access or model-loading errors, or `CancellationError`.
    func load(configuration: EvaluationCoreAIConfiguration) async throws -> CoreAIModelLoadResult {
        try Task.checkCancellation()
        let resolved = try Self.resolveResources(configuration)
        let key: ResourceIdentity
        do {
            key = try Self.resourceIdentity(for: resolved.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoreAIModelLoadingError.modelLoadFailed(
                path: resolved.url.path(percentEncoded: false),
                message: "Could not inspect the model resource files: \(error.localizedDescription)"
            )
        }

        latestRequestedKey = key
        if let cachedModel, cachedModel.key == key {
            return cachedModel.result
        }

        // ponytail: keep loads caller-owned so cancelling one request cannot cancel another;
        // add ref-counted coalescing only if concurrent model loads become measurable.
        let task = Task(priority: .userInitiated) {
            do {
                let bundle = try LanguageBundle(at: resolved.url)
                let model = try await CoreAILanguageModel(
                    resourcesAt: resolved.url,
                    mode: .eager
                )
                return CoreAIModelLoadResult(
                    model: model,
                    modelName: bundle.name,
                    contextSize: bundle.maxContextLength,
                    capabilities: model.capabilities,
                    estimatedSizeOnDiskBytes: model.estimatedSizeOnDiskBytes,
                    resourceIdentity: key,
                    securityScopedAccess: resolved.securityScopedAccess
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                throw CoreAIModelLoadingError.modelLoadFailed(
                    path: resolved.url.path(percentEncoded: false),
                    message: error.localizedDescription
                )
            }
        }

        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        if latestRequestedKey == key {
            cachedModel = CachedModel(key: key, result: result)
        }
        return result
    }

    /// Resolves a bookmark or expanded path, starts scoped access, and validates the canonical folder.
    /// - Throws: A configuration error when the path is empty, missing, not a folder, or its bookmark is stale.
    private static func resolveResources(
        _ configuration: EvaluationCoreAIConfiguration
    ) throws -> (url: URL, securityScopedAccess: CoreAISecurityScopedAccess) {
        let trimmedPath = configuration.resourcesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw CoreAIModelLoadingError.resourcesPathRequired
        }

        let url: URL
        if let bookmark = configuration.resourcesBookmark {
            var isStale = false
            do {
                url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                throw CoreAIModelLoadingError.staleResourcesBookmark(trimmedPath)
            }
            guard !isStale else {
                throw CoreAIModelLoadingError.staleResourcesBookmark(trimmedPath)
            }
        } else {
            let expandedPath = (trimmedPath as NSString).expandingTildeInPath
            url = URL(filePath: expandedPath, directoryHint: .isDirectory)
        }

        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let access = CoreAISecurityScopedAccess(url: canonicalURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory) else {
            throw CoreAIModelLoadingError.resourcesFolderUnavailable(trimmedPath)
        }
        guard isDirectory.boolValue else {
            throw CoreAIModelLoadingError.resourcesPathIsNotFolder(trimmedPath)
        }
        return (canonicalURL, access)
    }

    /// Resolves the configured folder and fingerprints its files while security-scoped access is retained.
    nonisolated static func resourceIdentity(
        for configuration: EvaluationCoreAIConfiguration
    ) throws -> ResourceIdentity {
        let resolved = try resolveResources(configuration)
        return try withExtendedLifetime(resolved.securityScopedAccess) {
            try resourceIdentity(for: resolved.url)
        }
    }

    /// Combines the canonical resource URL with a fingerprint of its regular files for cache identity.
    private nonisolated static func resourceIdentity(for url: URL) throws -> ResourceIdentity {
        ResourceIdentity(
            resourceURL: url,
            resourceFingerprint: try resourceFingerprint(for: url)
        )
    }

    /// Returns sorted metadata stamps for every regular file below the resource folder.
    ///
    /// Includes file identity and status-change time so replacements can invalidate the cache
    /// without relying solely on modification dates. Propagates inspection errors and cancellation.
    nonisolated static func resourceFingerprint(for url: URL) throws -> [ResourceStamp] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey,
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        let rootComponents = url.standardizedFileURL.pathComponents
        var fingerprint: [ResourceStamp] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let relativePath = fileURL.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            fingerprint.append(ResourceStamp(
                relativePath: relativePath,
                modificationDate: values.contentModificationDate,
                fileSize: values.fileSize,
                fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
                statusChangeTime: try statusChangeTime(for: fileURL)
            ))
        }
        if let enumerationError { throw enumerationError }
        return fingerprint.sorted { $0.relativePath < $1.relativePath }
    }

    /// Reads nanosecond file status-change time, throwing a POSIX error if `stat` fails.
    private nonisolated static func statusChangeTime(for url: URL) throws -> FileStatusChangeTime {
        var metadata = stat()
        let (result, errorCode) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let result = stat(path, &metadata)
            return (result, result == 0 ? 0 : errno)
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        return FileStatusChangeTime(
            seconds: Int64(metadata.st_ctimespec.tv_sec),
            nanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }
}

fileprivate final class CoreAISecurityScopedAccess: @unchecked Sendable {
    private let url: URL
    private let isAccessing: Bool

    /// Starts security-scoped access and remembers whether a matching stop is required.
    init(url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }

    /// Ends security-scoped access only when this instance successfully started it.
    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
