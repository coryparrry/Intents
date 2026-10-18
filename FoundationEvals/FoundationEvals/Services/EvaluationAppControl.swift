import Foundation
import Observation

/// One set of coordinators backs both the visible workspace and the authenticated MCP API.
@MainActor @Observable final class EvaluationAppControl {
  @ObservationIgnored lazy var mcp = MCPControlService(control: self)
  let store: EvaluationStore
  let production: ProductionWorkspaceStore
  let scenarios: ScenarioCoordinator
  let runners: DeveloperRunnerStore
  @ObservationIgnored private weak var boundAutomationStore: AppAutomationStore?
  @ObservationIgnored private weak var boundAutomationAdmission: ScenarioExecutionAdmission?

  init(store: EvaluationStore) {
    self.store = store
    production = ProductionWorkspaceStore(root: store.overviewStorageDirectory)
    scenarios = ScenarioCoordinator(
      supportDirectory: store.overviewStorageDirectory, evaluationStore: store)
    runners = DeveloperRunnerStore(evaluationStore: store)
    scenarios.bindRunnerStore(runners)
  }

  /// Bind before exposing either the native UI or MCP commands. Repeating
  /// composition with the same store and admission must not mutate observed state.
  func bindAutomationExecution(_ automation: AppAutomationStore,
                               admission: ScenarioExecutionAdmission = .shared) {
    guard boundAutomationStore !== automation || boundAutomationAdmission !== admission else { return }
    boundAutomationStore = automation
    boundAutomationAdmission = admission
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
