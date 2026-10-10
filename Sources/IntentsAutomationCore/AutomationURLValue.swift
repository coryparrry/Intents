import Foundation
import IntentsAutomationDateCodec

extension AutomationURLReference {
    var taggedValue: AutomationValue { .object(["url": .text(absoluteString)]) }
    init(taggedValue: AutomationValue) throws {
        try taggedValue.validate()
        guard case .object(let fields) = taggedValue, Set(fields.keys) == ["url"], case .text(let url) = fields["url"] else {
            throw AutomationContractError.invalidPlan("URL reference requires its explicit URL field")
        }
        try self.init(url)
    }
}
