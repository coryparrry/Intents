// Intents extension for the pinned MIT-licensed agent-device Mac helper.
// This identity grants no input authority; the session and action policy do.
import AppKit
import Darwin
import Foundation

struct MacApplicationTarget: Codable, Equatable, Sendable {
  let bundleId: String
  let canonicalBundlePath: String
  let pid: Int32
  let processStartIdentity: String

  static func validateSelection(bundleId: String, path: String) throws {
    guard bundleId.utf8.count <= 256, bundleId.range(of: #"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+\z"#, options: .regularExpression) != nil,
      path.utf8.count <= 4096, path.hasPrefix("/"), !path.contains("\0")
    else { throw HelperError.invalidArgs("invalid exact Mac application selection") }
    let selected = URL(fileURLWithPath: path)
    guard selected.path == path, selected.pathExtension.lowercased() == "app",
      selected.standardizedFileURL.resolvingSymlinksInPath().path == path,
      Bundle(url: selected)?.bundleIdentifier == bundleId
    else { throw HelperError.invalidArgs("exact Mac target must name its canonical app bundle") }
  }

  func validate() throws {
    try Self.validateSelection(bundleId: bundleId, path: canonicalBundlePath)
    guard pid > 0,
      processStartIdentity.range(of: #"^[1-9][0-9]{0,19}:(?:0|[1-9][0-9]{0,5})\z"#, options: .regularExpression) != nil,
      let seconds = UInt64(processStartIdentity.split(separator: ":")[0]), seconds > 0
    else { throw HelperError.invalidArgs("invalid exact Mac application identity") }
  }

  static func kernelStartIdentity(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
  }

  func application() throws -> NSRunningApplication {
    try validate()
    guard Self.kernelStartIdentity(pid: pid) == processStartIdentity,
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
      app.bundleIdentifier == bundleId,
      app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == canonicalBundlePath,
      Self.kernelStartIdentity(pid: pid) == processStartIdentity
    else { throw HelperError.commandFailed("exact Mac application instance is absent or changed") }
    return app
  }

  static func capture(_ app: NSRunningApplication, expectedBundleId: String, expectedBundlePath: String) throws -> Self {
    guard app.bundleIdentifier == expectedBundleId,
      app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == expectedBundlePath,
      let start = kernelStartIdentity(pid: app.processIdentifier)
    else { throw HelperError.commandFailed("selected Mac application identity is unavailable") }
    let identity = Self(bundleId: expectedBundleId, canonicalBundlePath: expectedBundlePath,
      pid: app.processIdentifier, processStartIdentity: start)
    _ = try identity.application()
    return identity
  }

  static let argumentNames = ["--target-bundle-path", "--target-pid", "--target-process-start"]
  static func hasTargetArguments(_ arguments: [String]) -> Bool {
    arguments.contains { $0.hasPrefix("--target-") }
  }
  static func from(arguments: [String]) throws -> Self? {
    guard hasTargetArguments(arguments) else { return nil }
    func required(_ name: String) throws -> String {
      let positions = arguments.indices.filter { arguments[$0] == name }
      guard positions.count == 1, let index = positions.first, index + 1 < arguments.count,
        !arguments[index + 1].hasPrefix("--")
      else { throw HelperError.invalidArgs("exact Mac targeting requires one complete identity") }
      return arguments[index + 1]
    }
    let bundleId = try required("--bundle-id")
    let path = try required("--target-bundle-path")
    let start = try required("--target-process-start")
    let rawPid = try required("--target-pid")
    guard let pid = Int32(rawPid), String(pid) == rawPid else {
      throw HelperError.invalidArgs("exact Mac targeting requires a canonical positive PID")
    }
    let target = Self(bundleId: bundleId, canonicalBundlePath: path, pid: pid, processStartIdentity: start)
    try target.validate()
    return target
  }
}
