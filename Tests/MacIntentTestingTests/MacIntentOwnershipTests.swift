import Darwin
import Foundation
import Testing
@testable import MacIntentTesting

@MainActor struct MacIntentOwnershipTests {
    private func fixture() throws -> (URL, FileHandle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-intent-ownership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return (root, try FileHandle(forWritingTo: log))
    }

    @Test func timeoutDrainsChildrenThatIgnoreParentSignalsAndPreservesUnrelatedWork() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["10"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let command = MacIntentOwnedCommand(cleanupGrace: .milliseconds(200))
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap 'exit 0' INT TERM; (trap '' INT TERM; sleep 1.3; echo escaped > marker) & wait"],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 0.1)
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("timeout")) }
        #expect(!command.hasUnresolvedResources)
        #expect(unrelated.isRunning)
        try await Task.sleep(for: .seconds(1.4))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
        let next = try await command.execute(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["next"],
            directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
        #expect(next == 0)
    }

    @Test func cancellationDrainsChildAfterItsParentExits() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        let command = MacIntentOwnedCommand(cleanupGrace: .milliseconds(200))
        let task = Task {
            try await command.execute(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap 'exit 0' INT TERM; (trap '' INT TERM; sleep 1.3; echo escaped > marker) & echo ready > ready; wait"],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 10)
        }
        let ready = root.appendingPathComponent("ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(!command.hasUnresolvedResources)
        try await Task.sleep(for: .seconds(1.4))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func successfulParentExitCannotLeaveBackgroundWork() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        let command = MacIntentOwnedCommand(cleanupGrace: .milliseconds(200))
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(sleep 1.3; echo escaped > marker) & exit 0"], directory: root,
                environment: ProcessInfo.processInfo.environment, log: log, timeout: 3)
            Issue.record("Expected background-work rejection")
        } catch { #expect(error.localizedDescription.contains("child work")) }
        #expect(!command.hasUnresolvedResources)
        try await Task.sleep(for: .seconds(1.4))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func exitedLeaderRemainsWaitableThroughEveryDescendantSignal() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        var anchoredPID: pid_t?
        var signals: [Int32] = []
        let command = MacIntentOwnedCommand(cleanupGrace: .milliseconds(200), signalGroup: { pid, signal in
            var info = siginfo_t()
            let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
            #expect(observed == 0)
            #expect(info.si_pid == pid)
            #expect(info.si_code == CLD_EXITED)
            anchoredPID = pid; signals.append(signal)
            return kill(-pid, signal)
        })
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(trap '' INT TERM; echo ready > ready; sleep 1.3; echo escaped > marker) & while [ ! -f ready ]; do sleep 0.01; done; exit 0"],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 3)
            Issue.record("Expected background-work rejection")
        } catch { #expect(error.localizedDescription.contains("child work")) }
        #expect(!signals.isEmpty)
        #expect(!command.hasUnresolvedResources)
        let pid = try #require(anchoredPID)
        var info = siginfo_t()
        let after = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
        let afterErrno = errno
        #expect(after == -1 && afterErrno == ECHILD)
        try await Task.sleep(for: .seconds(1.4))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func reusedGroupAfterFinalReapCannotReceiveAnySignal() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        var probes = 0, signals = 0
        let command = MacIntentOwnedCommand(probeGroup: { _ in
            probes += 1
            // The zombie-only observations permit final reap. A new group
            // then appears under that number: it supplies no signal authority.
            return probes <= 2 ? .unknown : .present
        }, signalGroup: { _, _ in signals += 1; return 0 })
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
            Issue.record("Expected unresolved reused group")
        } catch { #expect(error.localizedDescription.contains("remaining group will not be signalled")) }
        #expect(command.hasUnresolvedResources)
        #expect(!command.confirmReleased())
        #expect(signals == 0)
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
            Issue.record("Expected unresolved ownership to block another launch")
        } catch { #expect(error.localizedDescription.contains("unresolved processes")) }
        #expect(signals == 0)
    }

    @Test(arguments: ["normal", "signal", "esrch"], ["eventual-absence", "unknown", "present"])
    func retiredGroupSettlesWithoutAnyFurtherSignals(entry: String, outcome: String) async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        var retiredProbes = 0, signals = 0
        var allowAbsence = false
        let command = MacIntentOwnedCommand(cleanupGrace: .milliseconds(80), probeGroup: { pid in
            // WNOWAIT identifies the actual owned child's reap without consuming
            // it. Only confirmReleased retires that anchor with waitpid.
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
            if result == -1 && errno == ECHILD {
                retiredProbes += 1
                if allowAbsence || (outcome == "eventual-absence" && retiredProbes >= 3) { return .absent }
                return outcome == "unknown" ? .unknown : .present
            }
            return entry == "normal" || signals > 0 ? .unknown : .present
        }, signalGroup: { _, _ in
            #expect(retiredProbes == 0)
            signals += 1
            if entry == "esrch" { errno = ESRCH; return -1 }
            return 0
        })
        do {
            let status = try await command.execute(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
            #expect(entry == "normal" && outcome == "eventual-absence")
            #expect(status == 0)
        } catch {
            #expect(error.localizedDescription.contains(outcome == "eventual-absence" ? "child work" : "termination could not be verified"))
        }
        #expect(retiredProbes >= 3)
        #expect(signals == (entry == "normal" ? 0 : 1))
        #expect(command.hasUnresolvedResources == (outcome != "eventual-absence"))
        allowAbsence = true
        #expect(command.confirmReleased())
    }

    @Test func missingChildAnchorCannotAuthorizeAReusedGroup() async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        var signals = 0
        let command = MacIntentOwnedCommand(observeChild: { pid in
            // Simulate another reaper consuming the owned child, followed by
            // a reused PGID observation. Only our own short-lived child is reaped.
            var status: Int32 = 0
            #expect(waitpid(pid, &status, 0) == pid)
            return .unowned
        }, probeGroup: { _ in .present }, signalGroup: { _, _ in signals += 1; return 0 })
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
            Issue.record("Expected lost anchor to fail closed")
        } catch { #expect(error.localizedDescription.contains("ownership could not be verified")) }
        #expect(command.hasUnresolvedResources)
        #expect(!command.confirmReleased())
        #expect(signals == 0)
    }

    @Test(arguments: [true, false])
    func groupExitDuringSignalRequiresVerifiedRelease(groupActuallyExited: Bool) async throws {
        let (root, log) = try fixture()
        defer { try? log.close(); try? FileManager.default.removeItem(at: root) }
        var attemptedSignal = false
        var permitRealProbe = false
        let command = MacIntentOwnedCommand(probeGroup: { pid in
            guard permitRealProbe else { return .present }
            if kill(-pid, 0) == 0 { return .present }
            return errno == ESRCH ? .absent : .unknown
        }, signalGroup: { _, _ in
            attemptedSignal = true
            permitRealProbe = groupActuallyExited
            errno = ESRCH
            return -1
        })
        do {
            _ = try await command.execute(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                directory: root, environment: ProcessInfo.processInfo.environment, log: log, timeout: 2)
            Issue.record("Expected the command's observed background work to invalidate its exit")
        } catch {
            #expect(error.localizedDescription.contains(groupActuallyExited ? "child work" : "termination could not be verified"))
        }
        #expect(attemptedSignal)
        #expect(command.hasUnresolvedResources == !groupActuallyExited)
        // Release the real fixture child even when the injected group remained.
        permitRealProbe = true
        #expect(command.confirmReleased())
    }

    @Test func alreadyRunningSubjectIsRejectedWithoutRestartingIt() throws {
        #expect(throws: MacIntentTestingError.self) {
            try MacIntentRunner.requireStoppedSubject(bundleIdentifier: "example.running", isRunning: { $0 == "example.running" })
        }
        try MacIntentRunner.requireStoppedSubject(bundleIdentifier: "example.stopped", isRunning: { _ in false })
    }

    @Test func generatedHostTrackingIncludesXcodeRunnerIdentity() {
        let identifier = UUID().uuidString.lowercased()
        let ids = MacIntentRunner.generatedHostBundleIdentifiers(identifier)
        #expect(ids.contains("dev.intents.testing.tests." + identifier + ".xctrunner"))
        #expect(ids.contains("dev.intents.testing.host." + identifier))
        #expect(ids.allSatisfy { $0.contains(identifier) })
    }
}
