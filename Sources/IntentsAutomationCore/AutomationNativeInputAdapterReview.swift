import Foundation

/// Review describes a conversion-only XCTest. No selected action is performed.
public struct AutomationNativeInputAdapterReview: Codable, Equatable, Sendable {
    public let probeDigest: String
    public let app: AppIdentity
    public let target: TargetIdentity
    public let actionID: String
    public let parameterNames: [String]
    public let purpose: String
    public let fixedSamples: [String: [AutomationValue]]
    static func validate(_ reviews: [Self]?, plan: AutomationCase) throws {
        guard let reviews else { return }
        guard plan.target.kind == .nativeMac, (1...10).contains(reviews.count),
              Set(reviews.map(\.actionID)).count == reviews.count else { throw AutomationContractError.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(reviews).count <= 327_680 else { throw AutomationContractError.invalidIdentity }
        for review in reviews {
            guard review.app == plan.app, review.target == plan.target,
                  AutomationHostProgram.identifier(review.actionID), review.probeDigest.count == 64,
                  review.probeDigest.allSatisfy({ $0.isASCII && "0123456789abcdef".contains($0) }),
                  (1...10).contains(review.parameterNames.count), review.parameterNames == review.parameterNames.sorted(),
                  Set(review.parameterNames).count == review.parameterNames.count,
                  Set(review.fixedSamples.keys) == Set(review.parameterNames),
                  review.parameterNames.allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil }),
                  review.purpose == "Construct, assign and read intent parameters; never perform the action" else {
                throw AutomationContractError.invalidIdentity
            }
            for samples in review.fixedSamples.values {
                guard (1...2).contains(samples.count) else { throw AutomationContractError.invalidIdentity }
                for sample in samples { try sample.validate() }
            }
        }
    }
}
