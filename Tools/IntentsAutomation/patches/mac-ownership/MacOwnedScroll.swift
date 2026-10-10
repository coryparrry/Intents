// Private recipient-scoped experiment. Submission is never proof of visible progress.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct MacOwnedScrollRequest: Equatable {
  let x: Double
  let y: Double
  let direction: String
  var vertical: Int32 { direction == "up" ? 40 : direction == "down" ? -40 : 0 }
  var horizontal: Int32 { direction == "left" ? 40 : direction == "right" ? -40 : 0 }
  func validate() throws {
    guard x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000,
      ["up", "down", "left", "right"].contains(direction) else {
      throw HelperError.invalidArgs("invalid exact-process scroll bounds")
    }
  }
  static func from(_ arguments: [String]) throws -> (Self, MacApplicationTarget) {
    let names = ["--x", "--y", "--direction", "--surface", "--bundle-id"] + MacApplicationTarget.argumentNames
    var values: [String: String] = [:], index = 0
    while index < arguments.count {
      let name = arguments[index]
      guard names.contains(name), values[name] == nil, index + 1 < arguments.count,
        !arguments[index + 1].hasPrefix("--") else { throw HelperError.invalidArgs("invalid exact-process scroll arguments") }
      values[name] = arguments[index + 1]; index += 2
    }
    guard values["--surface"] == "frontmost-app", let target = try MacApplicationTarget.from(arguments: arguments),
      let x = values["--x"].flatMap(Double.init), let y = values["--y"].flatMap(Double.init), let direction = values["--direction"] else {
      throw HelperError.invalidArgs("scroll requires its complete exact-process identity and application surface")
    }
    let request = Self(x: x, y: y, direction: direction); try request.validate(); return (request, target)
  }
}
struct MacOwnedScrollReceipt: Encodable {
  let applicationTarget: MacApplicationTarget
  let x: Double
  let y: Double
  let direction: String
  let disposition = "submittedUnconfirmed"
}
struct MacOwnedScrollDelivery<Event> {
  let prepare: (MacOwnedScrollRequest) throws -> Event
  let verify: (MacOwnedScrollRequest, MacApplicationTarget) throws -> Void
  let submit: (Event, MacApplicationTarget) throws -> Void
  func scroll(_ request: MacOwnedScrollRequest, target: MacApplicationTarget) throws -> MacOwnedScrollReceipt {
    try request.validate(); try target.validate(); try verify(request, target)
    let event = try prepare(request)
    try verify(request, target)
    do { try submit(event, target) } catch {
      throw HelperError.commandFailed("exact-process scroll delivery is unknown", details: ["deliveryUnknown": "true", "mayHaveCommitted": "true"])
    }
    return .init(applicationTarget: target, x: request.x, y: request.y, direction: request.direction)
  }
}

// Resolve the current hit-tested element in the selected process, then require a
// scroll-area ancestor. A cached semantic reference alone grants no native input.
func verifyMacOwnedScrollArea(_ request: MacOwnedScrollRequest, target: MacApplicationTarget) throws {
  _ = try target.application()
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
    throw HelperError.commandFailed("selected Mac app is not frontmost")
  }
  let app = AXUIElementCreateApplication(target.pid)
  var hit: AXUIElement?
  guard AXUIElementCopyElementAtPosition(app, Float(request.x), Float(request.y), &hit) == .success, var element = hit else {
    throw HelperError.commandFailed("selected scroll area unavailable")
  }
  for _ in 0..<12 {
    var pid: pid_t = 0, role: CFTypeRef?, parent: CFTypeRef?
    guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid,
      AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
      throw HelperError.commandFailed("selected scroll area ownership unavailable")
    }
    if role as? String == kAXScrollAreaRole as String {
      _ = try target.application()
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
        throw HelperError.commandFailed("selected Mac app changed before scroll")
      }
      return
    }
    guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
    element = unsafeBitCast(parent, to: AXUIElement.self)
  }
  throw HelperError.commandFailed("input is outside a current selected scroll area")
}
func postMacOwnedScroll(_ request: MacOwnedScrollRequest, target: MacApplicationTarget) throws -> MacOwnedScrollReceipt {
  try MacOwnedScrollDelivery<CGEvent>(prepare: { request in
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
      wheel1: request.vertical, wheel2: request.horizontal, wheel3: 0) else {
      throw HelperError.commandFailed("exact-process scroll event creation failed")
    }
    event.location = .init(x: request.x, y: request.y); return event
  }, verify: verifyMacOwnedScrollArea, submit: { event, target in
    _ = try target.application()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
      throw HelperError.commandFailed("selected Mac app changed before scroll submission")
    }
    // PID/start verification and postToPid are separate APIs; qualification remains required.
    event.postToPid(target.pid)
  }).scroll(request, target: target)
}
