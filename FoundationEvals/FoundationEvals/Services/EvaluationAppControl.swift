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

  /// Bind before exposing either the native UI or MCP commands. The stable
  /// store owner makes repeated window binding idempotent.
  func bindAutomationExecution(_ automation: AppAutomationStore,
                               admission: ScenarioExecutionAdmission = .shared) {
    let ownerID = automation.executionAdmissionOwnerID
    let canStart: @MainActor () -> Bool = { [weak store = self.store, weak runners = self.runners] in
      guard let store, let runners else { return false }
      return admission.allowsAutomation(ownerID) && runners.executingRunID == nil
        && !store.hasActiveExecution && !runners.automationExecutionBlocked
    }
    automation.executionCanStart = canStart
    automation.executionOwnershipChanged = { blocked in
      admission.setAutomationBlocked(blocked, ownerID: ownerID)
    }
    automation.pairedClient = runners.client
    automation.pairedCanStart = canStart
  }
}
