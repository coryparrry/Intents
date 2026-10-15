#if os(macOS)
import Darwin
import Foundation
import Security

/// A deleted executable can still run while proc_pidpath returns ENOENT.
/// Exclude it only with a different kernel-held CodeDirectory identity, never
/// because its path is missing. Owned PID drain remains a separate requirement.
enum AutomationMacExecutableCodeIdentity {
    // Bundled Node 24 is larger than the small native helper. Match the
    // selected served-JavaScript executable bound; reads remain regular-file,
    // non-symlink, stable and followed by strict per-architecture signatures.
    static let maximumExecutableBytes = 128 * 1024 * 1024
    static func excludes(pid: Int32, userID: UInt32, paths: Set<String>) throws -> Bool {
        let hashes = try helperHashes(paths)
        let excluded = try excludes(pid: pid, userID: userID, hashes: hashes,
            identity: { try AutomationMacProcessInventory.info(pid: $0, userID: $1) }, hash: activeHash)
        guard try helperHashes(paths) == hashes else { throw AutomationContractError.terminationUnverified }
        return excluded
    }

    static func excludes(pid: Int32, userID: UInt32, hashes: Set<Data>,
                         identity: (Int32, UInt32) throws -> AutomationProcessIdentity,
                         hash: (Int32) throws -> Data) throws -> Bool {
        guard !hashes.isEmpty, hashes.count <= 160,
              hashes.allSatisfy({ $0.count == 20 && $0.contains(where: { $0 != 0 }) }) else {
            throw AutomationContractError.terminationUnverified
        }
        let before = try identity(pid, userID), first = try hash(pid), second = try hash(pid)
        guard before.pid == pid, try identity(pid, userID) == before,
              first.count == 20, first.contains(where: { $0 != 0 }), first == second else {
            throw AutomationContractError.terminationUnverified
        }
        return !hashes.contains(first)
    }

    static func helperHashes(_ paths: Set<String>) throws -> Set<Data> {
        guard (1...10).contains(paths.count), paths.allSatisfy(AutomationMacProcessInventory.validExecutablePath) else {
            throw AutomationContractError.invalidIdentity
        }
        var hashes = Set<Data>()
        for path in paths.sorted() {
            let url = URL(fileURLWithPath: path)
            let bytes = try AutomationReadOnlyFile.read(root: url.deletingLastPathComponent(),
                relativePath: url.lastPathComponent, maximumBytes: maximumExecutableBytes)
            for architecture in try AutomationMachOIdentity.architectures(bytes) {
                var code: SecStaticCode?, info: CFDictionary?
                let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
                guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &code) == errSecSuccess, let code,
                      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
                      SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
                      let entries = (info as? [String: Any])?[kSecCodeInfoCdHashes as String] as? [Data],
                      !entries.isEmpty, entries.count <= 8,
                      entries.allSatisfy({ $0.count == 20 && $0.contains(where: { $0 != 0 }) }) else {
                    throw AutomationContractError.terminationUnverified
                }
                hashes.formUnion(entries)
            }
        }
        return hashes
    }

    static func activeHash(_ pid: Int32) throws -> Data {
        // XNU CS_OPS_CDHASH (5) reads p_textvp/p_textoff, including unlinked code.
        // Bind only this read operation; no code-signing state is modified.
        typealias Query = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else {
            throw AutomationContractError.terminationUnverified
        }
        let query = unsafeBitCast(symbol, to: Query.self)
        var bytes = [UInt8](repeating: 0, count: 20)
        let observation = bytes.withUnsafeMutableBytes { buffer -> (result: Int32, errorNumber: Int32) in
            errno = 0
            let result = query(pid, 5, buffer.baseAddress, buffer.count)
            // Capture immediately: subsequent diagnostics may perform syscalls.
            return (result, errno)
        }
        guard observation.result == 0 else {
            throw AutomationMacProcessInventory.KernelObservationFailure(stage: .codeIdentity,
                pid: pid, errorNumber: observation.errorNumber)
        }
        return Data(bytes)
    }
}
#endif
