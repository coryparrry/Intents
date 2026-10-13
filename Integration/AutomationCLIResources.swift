import Foundation

/// Host sources are data for the owned generated project, never compiled into the CLI.
public enum AutomationCLIResources {
    public static func hostTemplates() throws -> URL {
        guard let root = Bundle.module.url(forResource: "AutomationHost", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }
}
