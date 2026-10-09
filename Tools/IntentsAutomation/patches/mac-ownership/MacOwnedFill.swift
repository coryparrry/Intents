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
func verifyMacOrdinaryField(_ element: AXUIElement, target: MacApplicationTarget) throws {
  func attribute(_ element: AXUIElement, _ name: CFString) throws -> CFTypeRef {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success, let value else { throw HelperError.commandFailed("ordinary field metadata unavailable") }
    return value
  }
  var pid: pid_t = 0, settable = DarwinBoolean(false)
  guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid,
    [kAXTextFieldRole as String, kAXTextAreaRole as String].contains(try attribute(element, kAXRoleAttribute as CFString) as? String ?? ""),
    (try attribute(element, kAXEnabledAttribute as CFString) as? Bool) == true,
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else {
    throw HelperError.commandFailed("selected field cannot accept ordinary replacement")
  }
  // Refuse secure ancestors and incomplete ancestry before ever reading a value.
  var current = element
  for _ in 0..<32 {
    guard AXUIElementGetPid(current, &pid) == .success, pid == target.pid else { throw HelperError.commandFailed("ordinary field owner changed") }
    var subrole: CFTypeRef?
    let subroleStatus = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
    guard subroleStatus == .success || subroleStatus == .attributeUnsupported || subroleStatus == .noValue,
      subrole as? String != kAXSecureTextFieldSubrole as String else { throw HelperError.commandFailed("secure field is outside ordinary fill") }
    let role = try attribute(current, kAXRoleAttribute as CFString) as? String
    if role == kAXApplicationRole as String {
      _ = try target.application()
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw HelperError.commandFailed("selected app changed before fill") }
      return
    }
    let parent = try attribute(current, kAXParentAttribute as CFString)
    guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { throw HelperError.commandFailed("ordinary field ancestry unavailable") }
    current = unsafeBitCast(parent, to: AXUIElement.self)
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
