// Private upstream extension. Launch/activation requires the caller's target lease and approval.
import AppKit
import Foundation

struct MacApplicationSelection: Equatable {
  let bundleId: String
  let canonicalBundlePath: String

  func validate() throws {
    try MacApplicationTarget.validateSelection(bundleId: bundleId, path: canonicalBundlePath)
  }

  static func from(arguments: [String]) throws -> Self {
    guard arguments.count == 4 else { throw HelperError.invalidArgs("exact app selection requires bundle ID and path") }
    var values: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let key = arguments[index], value = arguments[index + 1]
      guard ["--bundle-id", "--bundle-path"].contains(key), values[key] == nil,
        !value.hasPrefix("--") else { throw HelperError.invalidArgs("invalid exact app selection arguments") }
      values[key] = value
    }
    guard let id = values["--bundle-id"], let path = values["--bundle-path"] else {
      throw HelperError.invalidArgs("exact app selection requires bundle ID and path")
    }
    let selection = Self(bundleId: id, canonicalBundlePath: path)
    try selection.validate()
    return selection
  }
}

struct MacApplicationOwnership {
  let running: (MacApplicationSelection) throws -> [MacApplicationTarget]
  let launch: (MacApplicationSelection) throws -> MacApplicationTarget
  let verify: (MacApplicationTarget) throws -> Void
  let activate: (MacApplicationTarget) throws -> Void

  private func existing(_ selection: MacApplicationSelection) throws -> MacApplicationTarget? {
    try selection.validate()
    let candidates = try running(selection).filter {
      $0.bundleId == selection.bundleId && $0.canonicalBundlePath == selection.canonicalBundlePath
    }
    guard candidates.count <= 1 else { throw HelperError.commandFailed("selected app has multiple running instances") }
    guard let target = candidates.first else { return nil }
    try target.validate()
    try verify(target)
    return target
  }

  func identity(_ selection: MacApplicationSelection) throws -> MacApplicationTarget {
    guard let target = try existing(selection) else { throw HelperError.commandFailed("selected app instance is not running") }
    return target
  }

  func open(_ selection: MacApplicationSelection) throws -> MacApplicationTarget {
    let target: MacApplicationTarget
    if let current = try existing(selection) { target = current }
    else {
      // Validate immediately before dispatch as well as before inspecting running instances.
      try selection.validate()
      do { target = try launch(selection) }
      catch {
        throw HelperError.commandFailed("exact-path launch outcome is unresolved",
          details: ["acquisitionUncertain": "true", "reason": String(describing: error)])
      }
    }
    do {
      try target.validate()
      guard target.bundleId == selection.bundleId, target.canonicalBundlePath == selection.canonicalBundlePath else {
        throw HelperError.commandFailed("open returned a different app copy")
      }
      try verify(target)
      try activate(target)
      try verify(target)
      return target
    } catch {
      // Launch/activation may already have occurred. Never substitute or retry automatically.
      throw HelperError.commandFailed("exact app acquisition outcome is unresolved",
        details: ["acquisitionUncertain": "true", "reason": String(describing: error)])
    }
  }

  static var live: Self {
    Self(running: { selection in
      try NSRunningApplication.runningApplications(withBundleIdentifier: selection.bundleId)
        .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == selection.canonicalBundlePath }
        .map { try MacApplicationTarget.capture($0, expectedBundleId: selection.bundleId, expectedBundlePath: selection.canonicalBundlePath) }
    }, launch: launchExact, verify: { _ = try $0.application() }, activate: { target in
      let app = try target.application()
      guard app.activate(options: [.activateIgnoringOtherApps]) else { throw HelperError.commandFailed("selected app activation refused") }
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
        _ = try target.application()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw HelperError.commandFailed("selected app activation timed out") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      }
    })
  }

  static func launchConfiguration() -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.createsNewApplicationInstance = true
    configuration.promptsUserIfNeeded = false
    configuration.addsToRecentItems = false
    return configuration
  }

  private final class LaunchResult {
    let lock = NSLock()
    var completed = false
    var app: NSRunningApplication?
    var error: Error?
  }

  private static func launchExact(_ selection: MacApplicationSelection) throws -> MacApplicationTarget {
    try selection.validate()
    let configuration = launchConfiguration()
    let result = LaunchResult()
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: selection.canonicalBundlePath), configuration: configuration) { app, error in
      result.lock.lock(); defer { result.lock.unlock() }
      result.app = app; result.error = error; result.completed = true
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while true {
      result.lock.lock()
      let completed = result.completed, app = result.app, error = result.error
      result.lock.unlock()
      if completed {
        guard error == nil, let app else {
          throw HelperError.commandFailed("exact-path launch failed", details: ["acquisitionUncertain": "true"])
        }
        do { return try MacApplicationTarget.capture(app, expectedBundleId: selection.bundleId, expectedBundlePath: selection.canonicalBundlePath) }
        catch { throw HelperError.commandFailed("launched app identity is unresolved", details: ["acquisitionUncertain": "true"]) }
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw HelperError.commandFailed("exact-path launch timed out", details: ["acquisitionUncertain": "true"])
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
  }
}
