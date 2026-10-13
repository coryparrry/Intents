#if os(macOS)
import XCTest
@testable import IntentsAutomationCore

@MainActor
final class AutomationMacGatedCommandTests: XCTestCase {
    private func fixture(_ mode: String) throws -> (URL, URL, URL, URL) {
        let requested = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let root = try AutomationPath.canonical(requested)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let python = try AutomationSyntheticPython.executable()
        let script = root.appendingPathComponent("synthetic-helper.py"), ready = root.appendingPathComponent("ready.json")
        let source = #"""
        import json, os, sys, time
        from pathlib import Path
        mode, ready_path, marker = sys.argv[1:]
        nonce = os.environ['INTENTS_MAC_HELPER_OWNERSHIP_NONCE']
        if mode == 'missing':
            time.sleep(60)
            sys.exit(1)
        while not Path(ready_path).exists():
            time.sleep(0.005)
        ready = Path(ready_path).read_text(encoding='utf-8')
        if json.loads(ready)['identity']['pid'] != os.getpid():
            sys.exit(2)
        if mode == 'foreign':
            ready = ready.replace(nonce, 'aaaaaaaa-1234-1234-1234-123456789abc')
        sys.stdout.write(ready)
        sys.stdout.flush()
        if mode == 'block-private':
            # Read exactly the ACK, leaving the following private frame backpressured.
            line = bytearray()
            while not line.endswith(b'\n'):
                byte = os.read(0, 1)
                if not byte:
                    sys.exit(6)
                line.extend(byte)
            if json.loads(line)['nonce'] != nonce:
                sys.exit(7)
            Path(marker).write_text('ack-read', encoding='utf-8')
            time.sleep(60)
            sys.exit(1)
        lines = sys.stdin.buffer.read().decode('utf-8').rstrip('\n').split('\n')
        ack = json.loads(lines[0])
        if mode == 'private-frame':
            if len(lines) != 2 or json.loads(lines[1])['value'] != 'private-sentinel-' + 'x' * 100000:
                sys.exit(4)
            if any('private-sentinel' in value for value in sys.argv) or any('private-sentinel' in value for value in os.environ.values()):
                sys.exit(5)
        if ack['kind'] != 'ack' or ack['nonce'] != nonce or ack['identity']['pid'] != os.getpid():
            sys.exit(3)
        Path(marker).write_text('mutation-after-ack', encoding='utf-8')
        if mode == 'hang-after-ack':
            time.sleep(60)
        sys.stdout.write('synthetic-success\n')
        sys.stdout.flush()
        """#
        try Data(source.utf8).write(to: script)
        return (root, python, script, ready)
    }
    func testActualSyntheticChildWaitsForOwnedIdentityAcknowledgementAndIsReaped() async throws {
        let (root, python, script, ready) = try fixture("valid"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let result = try await command.run(executable: python, arguments: [script.path, "valid", ready.path, marker.path], directory: root,
            environment: [:], timeout: .seconds(5), ownershipGateNonce: nonce, didStart: { identity in
                guard !FileManager.default.fileExists(atPath: marker.path) else { throw AutomationContractError.invalidIdentity }
                try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
            })
        XCTAssertEqual(result.exitStatus, 0); XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "synthetic-success\n")
        XCTAssertNotNil(result.ownedIdentity); XCTAssertTrue(result.startupAcknowledged)
        XCTAssertTrue(result.directChildReaped); XCTAssertTrue(result.pipesDrained)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "mutation-after-ack")
    }
    func testBoundedPrivateFrameFollowsAcknowledgementWithoutArgvEnvironmentOrOutput() async throws {
        let (root, python, script, ready) = try fixture("private-frame"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let frame = Data(("{\"value\":\"private-sentinel-" + String(repeating: "x", count: 100000) + "\"}\n").utf8)
        let result = try await command.run(executable: python, arguments: [script.path, "private-frame", ready.path, marker.path], directory: root,
            environment: [:], timeout: .seconds(5), ownershipGateNonce: nonce, privateInputFrame: frame, didStart: { identity in
                try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
            })
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "synthetic-success\n")
        XCTAssertTrue(result.stderr.isEmpty); XCTAssertTrue(result.directChildReaped); XCTAssertTrue(result.pipesDrained)
    }
    func testStopDuringBackpressuredPrivateFrameIsPromptAndRetainsAcknowledgement() async throws {
        let (root, python, script, ready) = try fixture("block-private"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let frame = Data(("{\"value\":\"" + String(repeating: "x", count: 130000) + "\"}\n").utf8)
        let task = Task {
            try await command.run(executable: python, arguments: [script.path, "block-private", ready.path, marker.path], directory: root,
                environment: [:], timeout: .seconds(10), ownershipGateNonce: nonce, privateInputFrame: frame, didStart: { identity in
                    try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
                })
        }
        let wait = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < wait { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let started = ContinuousClock.now
        let stopped = await command.stopOwned(); XCTAssertTrue(stopped)
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        do { _ = try await task.value; XCTFail("Blocked frame succeeded") } catch {}
        let logs = await command.retainedLogs(); XCTAssertTrue(logs.startupAcknowledged)
        XCTAssertNotNil(logs.ownedIdentity)
    }
    func testPrivateFrameRejectsUngatedOversizedMultipleOrIncompleteInputBeforeLaunch() async throws {
        let (root, python, script, ready) = try fixture("valid"), marker = root.appendingPathComponent("marker")
        for (frame, nonce) in [(Data("{}\n".utf8), Optional<String>.none),
                               (Data("{}".utf8), UUID().uuidString.lowercased()),
                               (Data("{}\n{}\n".utf8), UUID().uuidString.lowercased()),
                               (Data((String(repeating: "x", count: 131072) + "\n").utf8), UUID().uuidString.lowercased())] {
            let command = AutomationOwnedCommand()
            do {
                _ = try await command.run(executable: python, arguments: [script.path, "valid", ready.path, marker.path], directory: root,
                    environment: [:], timeout: .seconds(1), ownershipGateNonce: nonce, privateInputFrame: frame)
                XCTFail("Invalid private frame launched")
            } catch {}
            let logs = await command.retainedLogs(); XCTAssertNil(logs.ownedIdentity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
    func testForeignOrMissingReadinessCannotWriteMutationMarker() async throws {
        for mode in ["foreign", "missing"] {
            let (root, python, script, ready) = try fixture(mode), marker = root.appendingPathComponent("marker")
            let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
            do {
                _ = try await command.run(executable: python, arguments: [script.path, mode, ready.path, marker.path], directory: root,
                    environment: [:], timeout: .milliseconds(500), ownershipGateNonce: nonce, didStart: { identity in
                        try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
                    })
                XCTFail("Invalid startup admitted")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            let logs = await command.retainedLogs(); XCTAssertNotNil(logs.ownedIdentity); XCTAssertFalse(logs.startupAcknowledged)
            let stopped = await command.stopOwned(); XCTAssertTrue(stopped)
        }
    }
    func testFailureAfterAcknowledgementRetainsTheSubmittedStartupPhase() async throws {
        let (root, python, script, ready) = try fixture("hang-after-ack"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        do {
            _ = try await command.run(executable: python, arguments: [script.path, "hang-after-ack", ready.path, marker.path], directory: root,
                environment: [:], timeout: .milliseconds(500), ownershipGateNonce: nonce, didStart: { identity in
                    try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
                })
            XCTFail("Hanging helper admitted")
        } catch {}
        let logs = await command.retainedLogs()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path)); XCTAssertTrue(logs.startupAcknowledged)
        XCTAssertNotNil(logs.ownedIdentity); XCTAssertFalse(logs.pipesDrained)
    }
}
#endif
