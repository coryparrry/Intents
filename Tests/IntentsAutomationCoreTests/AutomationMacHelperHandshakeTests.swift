import XCTest
@testable import IntentsAutomationCore

final class AutomationMacHelperHandshakeTests: XCTestCase {
    private let nonce = "12345678-1234-1234-1234-123456789abc"
    private let identity = AutomationProcessIdentity(pid: 42, startIdentity: "100:0")
    func testCanonicalReadyAndAckBindIndependentChildIdentity() throws {
        let ready = try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity)
        let ack = try AutomationMacHelperHandshake.acknowledgement(ready: ready, nonce: nonce, ownedChild: identity)
        try AutomationMacHelperHandshake.validateAcknowledgement(ack, nonce: nonce, identity: identity)
    }
    func testForeignNoncePIDAndStartCannotAuthorizeInput() throws {
        let ready = try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity)
        for wrong in [AutomationProcessIdentity(pid: 43, startIdentity: "100:0"), .init(pid: 42, startIdentity: "101:0")] {
            XCTAssertThrowsError(try AutomationMacHelperHandshake.acknowledgement(ready: ready, nonce: nonce, ownedChild: wrong))
        }
        XCTAssertThrowsError(try AutomationMacHelperHandshake.acknowledgement(ready: ready, nonce: "aaaaaaaa-1234-1234-1234-123456789abc", ownedChild: identity))
    }
    func testNoncanonicalDuplicateAndExtraFramesCannotAuthorizeInput() throws {
        let ready = try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity)
        for bad in [ready + ready, Data(ready.dropLast()), Data(" ".utf8) + ready,
                    Data(String(decoding: ready, as: UTF8.self).replacingOccurrences(of: "\"kind\":\"ready\"", with: "\"kind\":\"ready\",\"kind\":\"ready\"").utf8)] {
            XCTAssertThrowsError(try AutomationMacHelperHandshake.acknowledgement(ready: bad, nonce: nonce, ownedChild: identity))
        }
    }
    func testInvalidKernelIdentityAndNonceAreRejected() {
        for bad in [AutomationProcessIdentity(pid: 0, startIdentity: "100:0"), .init(pid: 1, startIdentity: "100:00"),
                    .init(pid: 1, startIdentity: "100:1000000"), .init(pid: 1, startIdentity: "0:0")] {
            XCTAssertThrowsError(try AutomationMacHelperHandshake.ready(nonce: nonce, identity: bad))
        }
        XCTAssertThrowsError(try AutomationMacHelperHandshake.ready(nonce: nonce.uppercased(), identity: identity))
    }
    func testOversizedVersionAndMalformedAcknowledgementsAreRejected() throws {
        let ready = try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity)
        let version = Data(String(decoding: ready, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
        XCTAssertThrowsError(try AutomationMacHelperHandshake.acknowledgement(ready: version, nonce: nonce, ownedChild: identity))
        XCTAssertThrowsError(try AutomationMacHelperHandshake.acknowledgement(ready: Data(repeating: 10, count: 4097), nonce: nonce, ownedChild: identity))
        XCTAssertThrowsError(try AutomationMacHelperHandshake.validateAcknowledgement(ready, nonce: nonce, identity: identity))
    }
    #if os(macOS) || os(Linux)
    func testClosedPeerRejectsAcknowledgementWithoutSIGPIPE() async throws {
        let input = try AutomationCommandGateInput()
        input.childStarted()
        do { try await input.acknowledge(Data("ack\n".utf8), deadline: .now.advanced(by: .seconds(1)), beforeWrite: {}); XCTFail("Closed peer admitted") } catch {}
    }
    func testStdinGateDeliversOneBoundedAcknowledgementAndEOF() async throws {
        let input = try AutomationCommandGateInput(), reader = input.childHandle
        let bytes = Data("ack\n".utf8)
        try await input.acknowledge(bytes, deadline: .now.advanced(by: .seconds(1)), beforeWrite: {})
        XCTAssertEqual(try reader.readToEnd(), bytes)
        do { try await input.acknowledge(bytes, deadline: .now.advanced(by: .seconds(1)), beforeWrite: {}); XCTFail("Second acknowledgement admitted") } catch {}
        input.childStarted()
    }
    #endif
}
