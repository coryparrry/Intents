import Foundation
import IntentsAutomationDateCodec

extension AutomationDurationInput {
    var taggedValue: AutomationValue { .object(["seconds": .integer(seconds), "attoseconds": .integer(attoseconds)]) }
    init(taggedValue: AutomationValue) throws {
        try taggedValue.validate()
        guard case .object(let fields) = taggedValue, Set(fields.keys) == ["seconds", "attoseconds"],
              case .integer(let seconds) = fields["seconds"], case .integer(let fraction) = fields["attoseconds"] else {
            throw AutomationContractError.invalidPlan("Duration requires exact seconds and attoseconds")
        }
        self.init(seconds: seconds, attoseconds: fraction); _ = try duration()
    }
}
