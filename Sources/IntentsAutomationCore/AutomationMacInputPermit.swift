#if os(macOS)
import Foundation

/// One native command admission from an already allowed policy action. The
/// bridge separately validates scope, selected instance, coordinates and ABI.
enum AutomationMacInputPermit: Sendable {
    case tap
    case ordinaryFill(String)
    case scroll(String)

    init?(approvedAction: AutomationJSON) {
        guard let action = approvedAction.object else { return nil }
        switch action["kind"] {
        case .string("tap"):
            guard Set(action.keys) == ["kind"] else { return nil }
            self = .tap
        case .string("fill"):
            guard Set(action.keys) == ["kind", "value", "sensitive"], action["sensitive"] == .bool(false),
                  let value = action["value"]?.string, (try? AutomationMacOrdinaryFillInput.validate(value)) != nil else { return nil }
            self = .ordinaryFill(value)
        case .string("swipe"):
            guard Set(action.keys) == ["kind", "direction"], let direction = action["direction"]?.string,
                  ["up", "down", "left", "right"].contains(direction) else { return nil }
            self = .scroll(direction)
        default: return nil
        }
    }
    func matches(nativeAction: AutomationJSON) -> Bool {
        guard let action = nativeAction.object else { return false }
        switch self {
        case .tap: return action["kind"] == .string("press")
        case .ordinaryFill(let approved):
            guard action["kind"] == .string("ordinaryFill"), let actual = action["value"]?.string else { return false }
            return approved.utf16.elementsEqual(actual.utf16)
        case .scroll(let direction): return action["kind"] == .string("scroll") && action["direction"] == .string(direction)
        }
    }
}
#endif
