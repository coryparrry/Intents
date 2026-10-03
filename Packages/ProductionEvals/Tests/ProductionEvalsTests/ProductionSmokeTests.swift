import Foundation
import Testing
@testable import ProductionEvals

@Test func productionStableRequestIdentity() {
    #expect(ProductionCodec.stableID("job/1") == ProductionCodec.stableID("job/1"))
    #expect(ProductionCodec.stableID("job/1") != ProductionCodec.stableID("job/2"))
}
