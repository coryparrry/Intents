// Approved public literals only. Credential handles use a separate consent route.
import AppKit
import ApplicationServices
import Foundation

struct MacOwnedFillReceipt: Encodable {
  let applicationTarget: MacApplicationTarget
  let x: Double
  let y: Double
  let disposition = "replacementVerified"
}
struct MacOwnedFillDelivery<Element> {
  let resolve: () throws -> Element
  let verify: (Element) throws -> Void
  let replace: (Element, String) throws -> Void
  let readback: (Element) throws -> String
  func fill(_ frame: MacOrdinaryFillFrame) throws -> MacOwnedFillReceipt {
    let element = try resolve()
    try verify(element)
    do {
      try replace(element, frame.value)
      try verify(element)
      // Swift == permits Unicode canonical equivalence. Require exact UTF-16 units.
      guard try readback(element).utf16.elementsEqual(frame.value.utf16) else { throw HelperError.commandFailed("replacement mismatch") }
    } catch {
      throw HelperError.commandFailed("ordinary replacement outcome is unknown", details: ["deliveryUnknown": "true", "mayHaveCommitted": "true"])
    }
    return .init(applicationTarget: frame.applicationTarget, x: frame.x, y: frame.y)
  }
}

func resolveMacOrdinaryFill(_ frame: MacOrdinaryFillFrame) throws -> AXUIElement {
  _ = try frame.applicationTarget.application()
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frame.applicationTarget.pid else { throw HelperError.commandFailed("selected app is not frontmost") }
  var hit: AXUIElement?
  guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(frame.applicationTarget.pid), Float(frame.x), Float(frame.y), &hit) == .success,
    let hit else { throw HelperError.commandFailed("ordinary field unavailable") }
  try verifyMacOrdinaryField(hit, target: frame.applicationTarget)
  return hit
}
struct MacOrdinaryFieldAccessor<Element> {
  let pid: (Element) -> pid_t?
  let role: (Element) throws -> String?
  let enabled: (Element) throws -> Bool?
  let valueSettable: (Element) -> Bool
  let subrole: (Element) -> (status: AXError, value: String?)
  let parent: (Element) throws -> Element?
  let confirmFrontmost: () throws -> Void
}
extension MacOrdinaryFieldAccessor where Element == AXUIElement {
  static func live(target: MacApplicationTarget) -> Self {
    func attribute(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, name, &value) == .success, let value else { throw HelperError.commandFailed("ordinary field metadata unavailable") }
      return value
    }
    return Self(pid: { element in
      var pid: pid_t = 0
      return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }, role: { element in
      try attribute(element, kAXRoleAttribute as CFString) as? String
    }, enabled: { element in
      try attribute(element, kAXEnabledAttribute as CFString) as? Bool
    }, valueSettable: { element in
      var settable = DarwinBoolean(false)
      return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }, subrole: { element in
      var subrole: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
      return (status, subrole as? String)
    }, parent: { element in
      let parent = try attribute(element, kAXParentAttribute as CFString)
      guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
      return unsafeBitCast(parent, to: AXUIElement.self)
    }, confirmFrontmost: {
      _ = try target.application()
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw HelperError.commandFailed("selected app changed before fill") }
    })
  }
}
func verifyMacOrdinaryField(_ element: AXUIElement, target: MacApplicationTarget) throws {
  try verifyMacOrdinaryField(element, target: target, accessor: .live(target: target))
}
func verifyMacOrdinaryField<Element>(_ element: Element, target: MacApplicationTarget, accessor: MacOrdinaryFieldAccessor<Element>) throws {
  guard accessor.pid(element) == target.pid,
    [kAXTextFieldRole as String, kAXTextAreaRole as String].contains(try accessor.role(element) ?? ""),
    (try accessor.enabled(element)) == true,
    accessor.valueSettable(element) else {
    throw HelperError.commandFailed("selected field cannot accept ordinary replacement")
  }
  // Refuse secure ancestors and incomplete ancestry before ever reading a value.
  var current = element
  for _ in 0..<32 {
    guard accessor.pid(current) == target.pid else { throw HelperError.commandFailed("ordinary field owner changed") }
    let subrole = accessor.subrole(current)
    guard subrole.status == .success || subrole.status == .attributeUnsupported || subrole.status == .noValue,
      subrole.value != kAXSecureTextFieldSubrole as String else { throw HelperError.commandFailed("secure field is outside ordinary fill") }
    if try accessor.role(current) == kAXApplicationRole as String {
      try accessor.confirmFrontmost()
      return
    }
    guard let parent = try accessor.parent(current) else { throw HelperError.commandFailed("ordinary field ancestry unavailable") }
    current = parent
  }
  throw HelperError.commandFailed("ordinary field ancestry exceeds bound")
}
func performMacOwnedFill(arguments: [String]) throws -> MacOwnedFillReceipt {
  // Reuse strict target/point parsing; the fixed direction is not supplied by the caller.
  guard !arguments.contains("--direction") else { throw HelperError.invalidArgs("invalid ordinary fill arguments") }
  let (point, target) = try MacOwnedScrollRequest.from(arguments + ["--direction", "up"])
  guard let nonce = ProcessInfo.processInfo.environment["INTENTS_MAC_HELPER_OWNERSHIP_NONCE"] else { throw HelperError.invalidArgs("private fill startup missing") }
  let bytes = try MacPrivateInput.readLine(descriptor: STDIN_FILENO, maximum: MacPrivateInput.maximumFrameBytes, deadline: .now.advanced(by: .seconds(5)))
  let frame = try MacOrdinaryFillFrame.decode(bytes, nonce: nonce, target: target, x: point.x, y: point.y)
  return try MacOwnedFillDelivery<AXUIElement>(resolve: { try resolveMacOrdinaryFill(frame) }, verify: { element in
    let fresh = try resolveMacOrdinaryFill(frame)
    guard CFEqual(fresh, element) else { throw HelperError.commandFailed("ordinary field changed") }
  }, replace: { element, value in
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else { throw HelperError.commandFailed("ordinary replacement failed") }
  }, readback: { element in
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let text = value as? String else { throw HelperError.commandFailed("ordinary replacement readback unavailable") }
    return text
  }).fill(frame)
}

// Metadata only. It never reads the existing field value or discloses its content.
enum MacOrdinaryFillCapability {
  static func probe(role: String?, subrole: String?, enabled: Bool?, inherited: Bool, settable: () -> Bool) -> Bool {
    guard !inherited, enabled == true, [kAXTextFieldRole as String, kAXTextAreaRole as String].contains(role ?? ""),
      subrole != kAXSecureTextFieldSubrole as String else { return false }
    return settable()
  }
}
func macOrdinaryFillEditable(_ element: AXUIElement, role: String?, subrole: String?, enabled: Bool?, inherited: Bool) -> Bool {
  MacOrdinaryFillCapability.probe(role: role, subrole: subrole, enabled: enabled, inherited: inherited) {
    var freshSubrole: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &freshSubrole)
    guard status == .success || status == .attributeUnsupported || status == .noValue,
      status != .success || freshSubrole is String,
      freshSubrole as? String != kAXSecureTextFieldSubrole as String else { return false }
    var value = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value) == .success && value.boolValue
  }
}
