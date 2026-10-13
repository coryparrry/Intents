#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationCore

final class AutomationPreparationDiagnosticTests: XCTestCase {
    func testPrivateLocalSnapshotPreservesScopedFailureAndDrainEvidence() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "prepare.install", leaseGeneration: 2)
        let identity = try AutomationProcessIdentity.current()
        var paths: [URL] = []
        for completed in [false, true] {
            let result = AutomationOwnedCommand.Result(exitStatus: completed ? 0 : -1,
                stdout: Data("install context".utf8), stderr: Data("install diagnostic".utf8),
                logsTruncated: false, ownedIdentity: identity, directChildReaped: completed,
                pipesDrained: completed, callbacksDrained: completed)
            let path = try AutomationPreparationCommandDiagnostic.save(result: result, scope: scope,
                operation: "install", error: AutomationRPCError.timedOut, root: root)
            paths.append(path)
            let data = try AutomationReadOnlyFile.read(path, maximumBytes: 4_194_304)
            let diagnostic = try JSONDecoder().decode(AutomationPreparationCommandDiagnostic.self, from: data)
            XCTAssertEqual(diagnostic.schemaVersion, 1)
            XCTAssertEqual(diagnostic.scope, scope)
            XCTAssertEqual(diagnostic.operation, "install")
            XCTAssertEqual(diagnostic.errorDescription, "timedOut")
            XCTAssertEqual(diagnostic.exitStatus, result.exitStatus)
            XCTAssertEqual(diagnostic.ownedIdentity, identity)
            XCTAssertEqual(diagnostic.stdout, result.stdout)
            XCTAssertEqual(diagnostic.stderr, result.stderr)
            XCTAssertEqual(diagnostic.directChildReaped, completed)
            XCTAssertEqual(diagnostic.pipesDrained, completed)
            XCTAssertEqual(diagnostic.callbacksDrained, completed)
            XCTAssertFalse(diagnostic.logsTruncated)
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o600)
        }
        XCTAssertNotEqual(paths[0], paths[1], "Cleanup diagnostics must preserve the earlier failure snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[0].path))
    }

    func testEarlyRejectedOrCancelledInvocationCannotPublishEarlierRetainedLogs() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let command = AutomationOwnedCommand()
        let first = AutomationPreparationCommandInvocation()
        let firstScope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "prepare.first", leaseGeneration: 1)
        var firstPath: URL?
        do {
            _ = try await command.run(executable: AutomationPath.canonical(URL(fileURLWithPath: "/bin/sh")),
                arguments: ["-c", "printf 'earlier-private-output'; printf 'earlier-private-diagnostic' >&2; exec /bin/sleep 30"],
                directory: root, environment: [:], timeout: .seconds(1),
                willStart: { await first.enter() })
            XCTFail("Expected the initial command to time out")
        } catch {
            XCTAssertEqual(error as? AutomationRPCError, .timedOut)
            firstPath = try await first.saveFailure(command: command, scope: firstScope,
                operation: "first", error: error, root: root)
        }
        let retained = await command.retainedLogs()
        XCTAssertEqual(String(decoding: retained.stdout, as: UTF8.self), "earlier-private-output")
        XCTAssertEqual(String(decoding: retained.stderr, as: UTF8.self), "earlier-private-diagnostic")
        XCTAssertNotNil(retained.ownedIdentity)
        XCTAssertNotNil(firstPath)
        for preCancelled in [false, true] {
            let invocation = AutomationPreparationCommandInvocation()
            let nextScope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "prepare.second", leaseGeneration: 2)
            let second = Task<URL?, any Error> {
                if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    _ = try await command.run(executable: AutomationPath.canonical(URL(fileURLWithPath: "/usr/bin/true")),
                        arguments: preCancelled ? [] : ["\0"], directory: root, environment: [:], timeout: .seconds(1),
                        willStart: { await invocation.enter() })
                    XCTFail("Expected early invocation rejection")
                    return nil
                } catch {
                    if preCancelled { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? AutomationContractError, .invalidIdentity) }
                    return try await invocation.saveFailure(command: command, scope: nextScope,
                        operation: "second", error: error, root: root)
                }
            }
            let path = try await second.value
            XCTAssertNil(path, "Earlier raw output must not be tagged with a rejected invocation's scope")
            let after = await command.retainedLogs()
            XCTAssertEqual(after.stdout, retained.stdout)
            XCTAssertEqual(after.stderr, retained.stderr)
            XCTAssertEqual(after.ownedIdentity, retained.ownedIdentity)
        }
        let paths = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("preparation-command-failures"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(paths.count, 1)
        let diagnostic = try JSONDecoder().decode(AutomationPreparationCommandDiagnostic.self,
            from: AutomationReadOnlyFile.read(try XCTUnwrap(paths.first), maximumBytes: 4_194_304))
        XCTAssertEqual(diagnostic.scope, firstScope)
    }

    func testLocalSnapshotBoundsBothLogsAndMarksDiagnosticTruncation() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AutomationScope(runID: "run", attemptID: "attempt", segmentID: "prepare.install", leaseGeneration: 2)
        let result = AutomationOwnedCommand.Result(exitStatus: -1, stdout: Data(repeating: 65, count: 1_048_577),
            stderr: Data(repeating: 66, count: 1_048_578), logsTruncated: false)
        let path = try AutomationPreparationCommandDiagnostic.save(result: result, scope: scope,
            operation: "install", error: AutomationRPCError.timedOut, root: root)
        let bytes = try AutomationReadOnlyFile.read(path, maximumBytes: 4_194_304)
        let diagnostic = try JSONDecoder().decode(AutomationPreparationCommandDiagnostic.self, from: bytes)
        XCTAssertEqual(diagnostic.stdout, Data(result.stdout.prefix(1_048_576)))
        XCTAssertEqual(diagnostic.stderr, Data(result.stderr.prefix(1_048_576)))
        XCTAssertTrue(diagnostic.logsTruncated)
        XCTAssertFalse(diagnostic.directChildReaped)
        XCTAssertFalse(diagnostic.pipesDrained)
        XCTAssertFalse(diagnostic.callbacksDrained)
        XCTAssertNil(diagnostic.ownedIdentity)
    }
}
#endif
