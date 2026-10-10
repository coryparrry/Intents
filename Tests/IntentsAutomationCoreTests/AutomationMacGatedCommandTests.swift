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
        let node = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/IntentsAutomation/.runtime/node-v24.21.0-darwin-arm64/bin/node")
        let script = root.appendingPathComponent("synthetic-helper.mjs"), ready = root.appendingPathComponent("ready.json")
        let source = """
        import fs from 'node:fs';
        const mode = process.argv[2], readyPath = process.argv[3], marker = process.argv[4];
        const nonce = process.env.INTENTS_MAC_HELPER_OWNERSHIP_NONCE;
        const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
        if (mode === 'missing') { await sleep(60000); process.exit(1); }
        while (!fs.existsSync(readyPath)) await sleep(5);
        let ready = fs.readFileSync(readyPath, 'utf8');
        if (JSON.parse(ready).identity.pid !== process.pid) process.exit(2);
        if (mode === 'foreign') ready = ready.replace(nonce, 'aaaaaaaa-1234-1234-1234-123456789abc');
        process.stdout.write(ready);
        if (mode === 'block-private') {
          let line = ''; const byte = Buffer.alloc(1);
          while (!line.endsWith('\\n')) { if (fs.readSync(0, byte, 0, 1, null) !== 1) process.exit(6); line += byte.toString(); }
          if (JSON.parse(line).nonce !== nonce) process.exit(7);
          fs.writeFileSync(marker, 'ack-read'); await sleep(60000); process.exit(1);
        }
        let input = ''; for await (const chunk of process.stdin) input += chunk;
        const lines = input.trimEnd().split('\\n');
        const ack = JSON.parse(lines[0]);
        if (mode === 'private-frame') {
          if (lines.length !== 2 || JSON.parse(lines[1]).value !== 'private-sentinel-' + 'x'.repeat(100000)) process.exit(4);
          if (process.argv.some(value => value.includes('private-sentinel')) || Object.values(process.env).some(value => value.includes('private-sentinel'))) process.exit(5);
        }
        if (ack.kind !== 'ack' || ack.nonce !== nonce || ack.identity.pid !== process.pid) process.exit(3);
        fs.writeFileSync(marker, 'mutation-after-ack');
        if (mode === 'hang-after-ack') await sleep(60000);
        process.stdout.write('synthetic-success\\n');
        """
        try Data(source.utf8).write(to: script)
        return (root, try AutomationPath.canonical(node), script, ready)
    }
    func testActualSyntheticChildWaitsForOwnedIdentityAcknowledgementAndIsReaped() async throws {
        let (root, node, script, ready) = try fixture("valid"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let result = try await command.run(executable: node, arguments: [script.path, "valid", ready.path, marker.path], directory: root,
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
        let (root, node, script, ready) = try fixture("private-frame"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let frame = Data(("{\"value\":\"private-sentinel-" + String(repeating: "x", count: 100000) + "\"}\n").utf8)
        let result = try await command.run(executable: node, arguments: [script.path, "private-frame", ready.path, marker.path], directory: root,
            environment: [:], timeout: .seconds(5), ownershipGateNonce: nonce, privateInputFrame: frame, didStart: { identity in
                try AutomationMacHelperHandshake.ready(nonce: nonce, identity: identity).write(to: ready, options: .atomic)
            })
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "synthetic-success\n")
        XCTAssertTrue(result.stderr.isEmpty); XCTAssertTrue(result.directChildReaped); XCTAssertTrue(result.pipesDrained)
    }
    func testStopDuringBackpressuredPrivateFrameIsPromptAndRetainsAcknowledgement() async throws {
        let (root, node, script, ready) = try fixture("block-private"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        let frame = Data(("{\"value\":\"" + String(repeating: "x", count: 130000) + "\"}\n").utf8)
        let task = Task {
            try await command.run(executable: node, arguments: [script.path, "block-private", ready.path, marker.path], directory: root,
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
        let (root, node, script, ready) = try fixture("valid"), marker = root.appendingPathComponent("marker")
        for (frame, nonce) in [(Data("{}\n".utf8), Optional<String>.none),
                               (Data("{}".utf8), UUID().uuidString.lowercased()),
                               (Data("{}\n{}\n".utf8), UUID().uuidString.lowercased()),
                               (Data((String(repeating: "x", count: 131072) + "\n").utf8), UUID().uuidString.lowercased())] {
            let command = AutomationOwnedCommand()
            do {
                _ = try await command.run(executable: node, arguments: [script.path, "valid", ready.path, marker.path], directory: root,
                    environment: [:], timeout: .seconds(1), ownershipGateNonce: nonce, privateInputFrame: frame)
                XCTFail("Invalid private frame launched")
            } catch {}
            let logs = await command.retainedLogs(); XCTAssertNil(logs.ownedIdentity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }
    func testForeignOrMissingReadinessCannotWriteMutationMarker() async throws {
        for mode in ["foreign", "missing"] {
            let (root, node, script, ready) = try fixture(mode), marker = root.appendingPathComponent("marker")
            let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
            do {
                _ = try await command.run(executable: node, arguments: [script.path, mode, ready.path, marker.path], directory: root,
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
        let (root, node, script, ready) = try fixture("hang-after-ack"), marker = root.appendingPathComponent("marker")
        let command = AutomationOwnedCommand(), nonce = UUID().uuidString.lowercased()
        do {
            _ = try await command.run(executable: node, arguments: [script.path, "hang-after-ack", ready.path, marker.path], directory: root,
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
