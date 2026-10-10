import Foundation
import CryptoKit
import MachO

struct HostReceipt: Codable {
    #if os(macOS)
    var schemaVersion = 3
    #else
    var schemaVersion = 2
    #endif
    struct Runner: Codable { let pid: Int32; let startIdentity: String; let executablePath: String }
    let runner: Runner
    let runID: String
    let attemptID: String
    let segmentID: String
    let leaseGeneration: Int
    let bundleID: String
    let productDigest: String
    var productDigestVersion: Int? = nil
    var operations: [OperationReceipt] = []
    var complete = false
    var runtimeContext: RuntimeContext? = nil
    struct OperationReceipt: Codable {
        let operationID: String
        let dispatched: Bool
        let value: HostValue?
        let error: String?
    }
}

// Observed inside the hashed host; customer-supplied target labels are never copied here.
extension HostReceipt {
    struct RuntimeContext: Codable {
        let processOSVersion: String
        let processOSBuild: String
        let architecture: String
        let sdkPlatform: String
        let xcodeBuild: String
        let sdkBuild: String
        let frameworkPath: String
        let frameworkSHA256: String
        let frameworkUUID: String
        let frameworkCPUType: UInt32
        let frameworkCPUSubtype: UInt32
        static func observe() -> Self? {
            #if !os(macOS)
            return nil
            #else
            guard let info = Bundle.main.infoDictionary,
                  let platform = info["DTPlatformName"] as? String,
                  let xcode = info["DTXcodeBuild"] as? String,
                  let sdk = info["DTSDKBuild"] as? String,
                  !platform.isEmpty, !xcode.isEmpty, !sdk.isEmpty,
                  _dyld_image_count() <= 2048 else { return nil }
            var candidates: [(URL, UnsafePointer<mach_header>)] = []
            for index in 0..<_dyld_image_count() {
                guard let pointer = _dyld_get_image_name(index), let path = String(validatingUTF8: pointer),
                      path.hasPrefix("/"), path.utf16.count <= 4096 else { continue }
                if path.contains("/AppIntentsTesting.framework/"), path.hasSuffix("/AppIntentsTesting") {
                    guard let header = _dyld_get_image_header(index) else { return nil }
                    candidates.append((URL(fileURLWithPath: path).resolvingSymlinksInPath(), header))
                }
            }
            guard candidates.count == 1, let (image, pointer) = candidates.first,
                  let identity = loadedIdentity(pointer),
                  let osBuild = kernelBuild(),
                  let values = try? image.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 134_217_728,
                  let handle = try? FileHandle(forReadingFrom: image) else { return nil }
            defer { try? handle.close() }
            var digest = SHA256(), bytes = 0
            do {
                while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                    bytes += block.count; guard bytes <= 134_217_728 else { return nil }
                    digest.update(data: block)
                }
            } catch { return nil }
            guard bytes == size else { return nil }
            return .init(processOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                processOSBuild: osBuild, architecture: identity.cpu == 0x0100000c ? "arm64" : "x86_64",
                sdkPlatform: platform, xcodeBuild: xcode, sdkBuild: sdk,
                frameworkPath: image.path, frameworkSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                frameworkUUID: identity.uuid, frameworkCPUType: identity.cpu, frameworkCPUSubtype: identity.subtype)
            #endif
        }
        private static func loadedIdentity(_ pointer: UnsafePointer<mach_header>) -> (uuid: String, cpu: UInt32, subtype: UInt32)? {
            let raw = UnsafeRawPointer(pointer)
            guard pointer.pointee.magic == MH_MAGIC_64 else { return nil }
            let header = raw.loadUnaligned(as: mach_header_64.self)
            guard [UInt32(0x0100000c), UInt32(0x01000007)].contains(UInt32(bitPattern: header.cputype)),
                  header.ncmds > 0, header.ncmds <= 4096, header.sizeofcmds <= 1_048_576,
                  header.sizeofcmds >= header.ncmds * 8 else { return nil }
            let commands = UnsafeRawBufferPointer(start: raw.advanced(by: MemoryLayout<mach_header_64>.size), count: Int(header.sizeofcmds))
            var offset = 0, uuid: String?
            for _ in 0..<header.ncmds {
                guard offset <= commands.count - 8 else { return nil }
                let cmd = commands.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let size = Int(commands.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                guard size >= 8, size % 8 == 0, size <= commands.count - offset else { return nil }
                if cmd == LC_UUID {
                    guard size == 24, uuid == nil else { return nil }
                    uuid = commands[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
                }
                offset += size
            }
            guard offset == commands.count, let uuid else { return nil }
            return (uuid, UInt32(bitPattern: header.cputype), UInt32(bitPattern: header.cpusubtype))
        }
        private static func kernelBuild() -> String? {
            var bytes = [CChar](repeating: 0, count: 256), size = 256
            guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0, size > 1, size <= bytes.count,
                  bytes[size - 1] == 0 else { return nil }
            return String(validating: bytes.prefix(size - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
