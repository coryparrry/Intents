import Foundation

/// Copies only manifest-bound bytes into private installation state. The source app is never installed directly.
enum AutomationPhysicalInstallPayload {
    static func stage(_ selected: AutomationInstalledUIApplication, into directory: URL) throws -> URL {
        try AutomationPhysicalExecutable.validateTarget(selected.target)
        guard selected.app.productDigestVersion == nil || selected.app.productDigestVersion == 1,
              let digest = selected.app.productDigest,
              !FileManager.default.fileExists(atPath: directory.path) else { throw AutomationContractError.invalidIdentity }
        let data = try AutomationProductDigest.manifestData(bundle: selected.bundleURL, version: selected.app.productDigestVersion)
        guard AutomationArtifactRegistry.digest(data) == digest,
              let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], (1...20_000).contains(files.count) else {
            throw AutomationContractError.conflictingOperation
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let bundle = directory.appendingPathComponent("Payload.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        var total = 0
        for record in files {
            try Task.checkCancellation()
            guard let path = record["path"] as? String, let size = record["bytes"] as? Int,
                  let hash = record["sha256"] as? String, (0...536_870_912).contains(size),
                  total <= 536_870_912 - size else { throw AutomationContractError.invalidIdentity }
            total += size
            let permissions = (try FileManager.default.attributesOfItem(atPath: selected.bundleURL.appendingPathComponent(path).path)[.posixPermissions] as? NSNumber)?.intValue
            guard let permissions else { throw AutomationContractError.invalidIdentity }
            // The bounded no-link reader plus the manifest hash checks the returned bytes,
            // including a replace/read/restore race in the customer-controlled source.
            let bytes = try AutomationReadOnlyFile.read(root: selected.bundleURL, relativePath: path, maximumBytes: max(size, 1))
            guard bytes.count == size, AutomationArtifactRegistry.digest(bytes) == hash else { throw AutomationContractError.conflictingOperation }
            let destination = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try bytes.write(to: destination, options: .withoutOverwriting)
            // Preserve executable bits for embedded frameworks/extensions; never copy special mode bits.
            try FileManager.default.setAttributes([.posixPermissions: permissions & 0o777], ofItemAtPath: destination.path)
        }
        guard let info = try PropertyListSerialization.propertyList(from: AutomationReadOnlyFile.read(root: bundle, relativePath: "Info.plist", maximumBytes: 1_048_576), format: nil) as? [String: Any],
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), !executable.contains("\\"), !executable.contains("\0"), executable != ".", executable != ".." else {
            throw AutomationContractError.invalidIdentity
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent(executable).path)
        try selected.verifySelectedProduct()
        guard try AutomationProductDigest.compute(bundle: bundle, version: selected.app.productDigestVersion) == digest else {
            throw AutomationContractError.conflictingOperation
        }
        return try AutomationPath.canonical(bundle)
    }
}
