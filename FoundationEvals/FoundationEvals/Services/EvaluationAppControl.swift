import Foundation
import Observation

/// One set of coordinators backs both the visible workspace and the authenticated MCP API.
@MainActor @Observable final class EvaluationAppControl {
  @ObservationIgnored lazy var mcp = MCPControlService(control: self)
  let store: EvaluationStore
  let production: ProductionWorkspaceStore
  let scenarios: ScenarioCoordinator
  let runners: DeveloperRunnerStore

  init(store: EvaluationStore) {
    self.store = store
    production = ProductionWorkspaceStore(root: store.overviewStorageDirectory)
    scenarios = ScenarioCoordinator(
      supportDirectory: store.overviewStorageDirectory, evaluationStore: store)
    runners = DeveloperRunnerStore(evaluationStore: store)
    scenarios.bindRunnerStore(runners)
  }
}
