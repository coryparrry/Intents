#if os(macOS)
import Foundation

/// Internal input capabilities derived from an exact whole-runtime receipt.
/// The normal product route has no qualification dependency for these units.
enum AutomationMacInputCapabilities: Sendable, Equatable {
    case tapOnly, ordinaryFillAndScroll
    var sourceVariant: AutomationMacNativeHelperBridge.SourceVariant {
        self == .tapOnly ? .tapOnly : .boundedFillExperiment
    }
    var helperSHA256: String {
        self == .tapOnly ? AutomationMacNativeHelperBridge.privateHelperSHA256 : AutomationMacNativeHelperBridge.privateFillHelperSHA256
    }
    func validate(_ program: AutomationUIProgram) throws {
        for operation in program.operations {
            if self == .tapOnly && (operation.kind == .fillBinding || operation.kind == .scroll ||
                operation.goal?.allowedFillBindings?.isEmpty == false || operation.goal?.minimumBindingUses?.values.contains(where: { $0 > 0 }) == true) {
                throw AutomationContractError.missingEvidence("Private Mac input supports tap only")
            }
        }
        if self == .ordinaryFillAndScroll {
            for value in program.bindings.values { try AutomationMacOrdinaryFillInput.validate(value) }
        }
    }
}
#endif
