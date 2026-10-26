import Foundation
import Observation

/// Shared controls for evaluation workspaces and the authenticated MCP API.
@MainActor @Observable final class EvaluationAppControl {
    @ObservationIgnored lazy var mcp = MCPControlService(control: self)
    let store: EvaluationStore
    let production: ProductionWorkspaceStore
    let runners: DeveloperRunnerStore
    let appIntentTesting = MacIntentTestingStore()

    /// Creates production and runner controls rooted in the evaluation store's workspace storage,
    /// sharing that store with authenticated app control.
    init(store: EvaluationStore) {
        self.store = store
        production = ProductionWorkspaceStore(root: store.overviewStorageDirectory)
        runners = DeveloperRunnerStore(evaluationStore: store)
    }
}
