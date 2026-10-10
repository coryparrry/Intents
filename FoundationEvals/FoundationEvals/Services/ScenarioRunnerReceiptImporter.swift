import Darwin
import Foundation
import IntentsAutomationCore
import IntentLabContracts

enum ScenarioRunnerReceiptImporter {
    static func loadForOwnership(directory: URL, invocation: ScenarioInvocationIdentity, runner: ScenarioProductIdentity) -> (receipt: AutomationLegacyRunnerReceipt?, error: String?) {
        do { return (try load(directory: directory, invocation: invocation, runner: runner), nil) }
        catch { return (nil, String(error.localizedDescription.prefix(2048))) }
    }
    static func load(directory: URL, invocation: ScenarioInvocationIdentity, runner: ScenarioProductIdentity) throws -> AutomationLegacyRunnerReceipt? {
        let root = directory.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else { throw AutomationContractError.invalidIdentity }
        let manifest = try read(root.appendingPathComponent("manifest.json"), limit: 2_097_152)
        guard let entries = try JSONSerialization.jsonObject(with: manifest) as? [[String: Any]] else {
            throw AutomationContractError.invalidIdentity
        }
        let testID = invocation.testIdentity.className + "/" + invocation.testIdentity.methodName + "()"
        let receipts = entries.filter { $0["testIdentifier"] as? String == testID }
            .flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
            .filter { ($0["suggestedHumanReadableName"] as? String)?.hasPrefix("IntentLabRunnerReceipt-" + invocation.id.uuidString) == true }
        guard !receipts.isEmpty else { return nil }
        guard receipts.count == 1, let filename = receipts[0]["exportedFileName"] as? String,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".json"), !filename.contains("\0") else { throw AutomationContractError.invalidIdentity }
        let receipt = try JSONDecoder().decode(AutomationLegacyRunnerReceipt.self, from: read(root.appendingPathComponent(filename), limit: 65_536))
        try ScenarioPhysicalRunnerLeaseManager.validate(receipt, invocation: invocation, runner: runner)
        return receipt
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AutomationContractError.invalidIdentity }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_mode & 0o022 == 0,
              before.st_size >= 0, before.st_size <= limit else { throw AutomationContractError.invalidIdentity }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        var after = stat()
        guard fstat(descriptor, &after) == 0, data.count == before.st_size,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw AutomationContractError.invalidIdentity }
        return data
    }
}
