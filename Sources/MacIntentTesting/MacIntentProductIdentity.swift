import CryptoKit
import Foundation
import Security

/// Binds selection and results to bytes, including resources and nested code.
public struct MacIntentProductIdentity: Codable, Equatable, Sendable {
    public let bundlePath: String
    public let sha256: String

    static func capture(_ app: URL) throws -> Self {
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var enumerationFailed = false
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw MacIntentTestingError("The selected app's files could not be inspected.")
        }
        struct Entry: Encodable { let path: String; let digest: String; let link: String? }
        var entries: [Entry] = [], bytes: UInt64 = 0
        for case let file as URL in files {
            guard entries.count < 100_000 else { throw MacIntentTestingError("The selected app exceeds the file limit.") }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let destination = file.resolvingSymlinksInPath().path
                guard destination.hasPrefix(root.path + "/") else {
                    throw MacIntentTestingError("The selected app contains a link outside its bundle.")
                }
                entries.append(.init(path: relative, digest: "", link: try FileManager.default.destinationOfSymbolicLink(atPath: file.path)))
            } else if values.isRegularFile == true {
                let before = try FileManager.default.attributesOfItem(atPath: file.path)
                let input = try FileHandle(forReadingFrom: file)
                var hash = SHA256()
                do {
                    while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
                        bytes += UInt64(block.count)
                        guard bytes <= 8_589_934_592 else { throw MacIntentTestingError("The selected app exceeds the size limit.") }
                        hash.update(data: block)
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                let after = try FileManager.default.attributesOfItem(atPath: file.path)
                for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
                    guard (before[key] as? NSObject) == (after[key] as? NSObject) else {
                        throw MacIntentTestingError("The selected app changed while its build identity was being read.")
                    }
                }
                entries.append(.init(path: relative, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), link: nil))
            } else if values.isDirectory == true {
                entries.append(.init(path: relative, digest: "directory", link: nil))
            } else {
                throw MacIntentTestingError("The selected app contains an unsupported file type.")
            }
        }
        guard !enumerationFailed else { throw MacIntentTestingError("The selected app's files could not all be read.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(entries.sorted { $0.path < $1.path }))
        return .init(bundlePath: root.path, sha256: digest.map { String(format: "%02x", $0) }.joined())
    }

    func validate() throws {
        guard try Self.capture(URL(fileURLWithPath: bundlePath)) == self else {
            throw MacIntentTestingError("The selected app changed. Reload its catalog before testing this build.")
        }
    }
}

/// Public Security APIs validate the running code against the selected signed code.
/// Dynamic validation checks kernel-held identity, including replaced executables.
struct MacIntentCodeIdentity {
    private let requirement: SecRequirement

    init(appURL: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw MacIntentTestingError("The selected app's signed build identity could not be verified.")
        }
        // The running slice may differ from Security's default static slice
        // (for example arm64e system binaries or a translated x86_64 app).
        var hashes = Set<Data>()
        for architecture in ["arm64", "arm64e", "x86_64", "x86_64h"] {
            var slice: SecStaticCode?, information: CFDictionary?
            let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(appURL as CFURL, [], attributes, &slice) == errSecSuccess,
                  let slice, SecCodeCopySigningInformation(slice, [], &information) == errSecSuccess,
                  let values = (information as? [String: Any])?[kSecCodeInfoCdHashes as String] as? [Data] else { continue }
            hashes.formUnion(values)
        }
        guard !hashes.isEmpty else { throw MacIntentTestingError("The selected app has no supported signed architecture.") }
        let expression = hashes.map { "cdhash H\"" + $0.map { String(format: "%02x", $0) }.joined() + "\"" }.joined(separator: " or ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw MacIntentTestingError("The selected app's code requirement could not be created.")
        }
        self.requirement = requirement
    }

    func validate(processIdentifier: Int32) throws {
        var code: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: processIdentifier] as CFDictionary, [], &code)
        guard lookup == errSecSuccess, let code else {
            throw MacIntentTestingError("The running app's code identity could not be read (Security error \(lookup)). Quit it and reload the app before testing.")
        }
        let validation = SecCodeCheckValidity(code, [], requirement)
        guard validation == errSecSuccess else {
            throw MacIntentTestingError("The running app could not be verified as the selected signed build (Security error \(validation)). Quit it and reload the app before testing.")
        }
    }
}
