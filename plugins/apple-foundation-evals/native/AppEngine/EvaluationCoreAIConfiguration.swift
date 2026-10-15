import Foundation

@available(macOS 27.0, *)
struct EvaluationCoreAIConfiguration: Codable, Equatable, Sendable {
    var resourcesPath = "" {
        didSet {
            if resourcesPath != oldValue {
                resourcesBookmark = nil
            }
        }
    }
    var resourcesBookmark: Data?

    var hasResources: Bool {
        !resourcesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func selectResources(at url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        resourcesPath = url.path(percentEncoded: false)
        resourcesBookmark = bookmark
    }

    mutating func clearResources() {
        resourcesPath = ""
        resourcesBookmark = nil
    }
}
