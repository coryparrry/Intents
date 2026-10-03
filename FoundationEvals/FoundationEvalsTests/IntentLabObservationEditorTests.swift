import Testing
@testable import FoundationEvals

struct IntentLabObservationEditorTests {
    @Test func newUIObservationHasNoCompiledOperation() {
        let observation = ScenarioReusableChecksView.newObservation(index: 2)

        #expect(observation.id == "observation-2")
        #expect(observation.source == .uiElement)
        #expect(observation.operationID == nil)
        #expect(observation.selector == nil)
    }
}
