import XCTest
import IntentLabContracts
@testable import IntentLabTesting

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabReadinessTestIntentTransportTests: XCTestCase {
    func testTransportInvokesOnlyTheDeclaredReadinessIntentAndReturnsTypedObservation() async throws {
        let declaration = try readinessDeclaration()
        var received: (String, String, [IntentLabParameter], [IntentLabIntegrationDeclaration.Projection])?

        let result = try await IntentLabReadinessTestIntentTransport.invoke(
            bundleIdentifier: "com.example.App",
            declaration: declaration,
            context: "readiness-run-123",
            intentInvoker: { bundleIdentifier, intentIdentifier, parameters, projections in
                received = (bundleIdentifier, intentIdentifier, parameters, projections)
                return [
                    "readiness.ready": .boolean(true),
                    "readiness.context": .string("readiness-run-123"),
                ]
            }
        )

        XCTAssertEqual(received?.0, "com.example.App")
        XCTAssertEqual(received?.1, "IntentLabReadinessIntent")
        XCTAssertEqual(received?.2.count, 1)
        XCTAssertEqual(received?.2.first?.name, "context")
        if let presence = received?.2.first?.presence {
            guard case .value(.string("readiness-run-123")) = presence else {
                return XCTFail("The readiness intent must receive the current context only")
            }
        } else {
            XCTFail("The readiness context parameter was not sent")
        }
        XCTAssertEqual(received?.3.map(\.id), ["readiness.ready", "readiness.context"])
        XCTAssertEqual(result.observations, ["readiness.ready": .boolean(true)])
        XCTAssertEqual(result.source, "testOnlyIntentTransport")
    }

    func testMissingReadinessControlDoesNotInvokeAnyIntent() async throws {
        let declaration = try readinessDeclaration(includingControl: false)
        var invoked = false

        do {
            _ = try await IntentLabReadinessTestIntentTransport.invoke(
                bundleIdentifier: "com.example.App",
                declaration: declaration,
                context: "readiness-run-456",
                intentInvoker: { _, _, _, _ in
                    invoked = true
                    return [:]
                }
            )
            XCTFail("Expected setup-required declaration to reject readiness invocation")
        } catch let error as IntentLabDeclarationError {
            guard case .readinessControlNotDeclared = error else {
                return XCTFail("Expected missing readiness control, got \(error)")
            }
        }

        XCTAssertFalse(invoked)
    }

    func testMismatchedContextAndUntypedResponseAreRejected() async throws {
        let declaration = try readinessDeclaration()

        do {
            _ = try await IntentLabReadinessTestIntentTransport.invoke(
                bundleIdentifier: "com.example.App",
                declaration: declaration,
                context: "expected-context",
                intentInvoker: { _, _, _, _ in
                    [
                        "readiness.ready": .boolean(true),
                        "readiness.context": .string("different-context"),
                    ]
                }
            )
            XCTFail("Expected context mismatch to be rejected")
        } catch is IntentLabReadinessTestIntentTransportError {
            // The wrapper result is not bound to the current readiness request.
        }

        do {
            _ = try await IntentLabReadinessTestIntentTransport.invoke(
                bundleIdentifier: "com.example.App",
                declaration: declaration,
                context: "expected-context",
                intentInvoker: { _, _, _, _ in
                    [
                        "readiness.ready": .string("true"),
                        "readiness.context": .string("expected-context"),
                    ]
                }
            )
            XCTFail("Expected non-boolean readiness result to be rejected")
        } catch is IntentLabReadinessTestIntentTransportError {
            // The result must satisfy the declaration's Boolean projection.
        }
    }

    func testFalseReadinessIsReturnedAsTypedFalseForHostStatusPolicy() async throws {
        let declaration = try readinessDeclaration()
        let result = try await IntentLabReadinessTestIntentTransport.invoke(
            bundleIdentifier: "com.example.App",
            declaration: declaration,
            context: "readiness-run-false",
            intentInvoker: { _, _, _, _ in
                [
                    "readiness.ready": .boolean(false),
                    "readiness.context": .string("readiness-run-false"),
                ]
            }
        )

        XCTAssertEqual(result.observations["readiness.ready"], .boolean(false))
    }

    private func readinessDeclaration(
        includingControl: Bool = true
    ) throws -> IntentLabIntegrationDeclaration {
        var json: [String: Any] = [
            "schemaVersion": 1,
            "id": "readiness-integration",
            "version": "1",
            "targetBundleIdentifier": "com.example.App",
            "projectIdentity": "App.xcodeproj",
            "targetIdentity": "AppUITests",
            "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [],
            "resultProjections": [],
            "preparationOperations": [],
            "observers": [],
            "isolation": ["kind": "readOnly"],
            "capabilities": includingControl ? ["test-only-intent"] : ["direct-intent-execution"],
        ]
        if includingControl {
            let control = IntentLabIntegrationDeclaration.ReadinessControl(
                operationID: "intentLabReadiness",
                testIntentIdentifier: "IntentLabReadinessIntent",
                response: .init(
                    id: "readiness.ready",
                    type: .primitive(.boolean),
                    path: [
                        .init(kind: .property, name: "value"),
                        .init(kind: .property, name: "ready"),
                    ]
                )
            )
            json["readinessControl"] = try JSONSerialization.jsonObject(
                with: JSONEncoder.intentLab.encode(control)
            )
        }
        return try JSONDecoder.intentLab.decode(
            IntentLabIntegrationDeclaration.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }
}
