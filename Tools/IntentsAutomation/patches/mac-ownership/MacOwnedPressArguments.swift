import AgentDeviceMacOSInput
import Foundation

struct MacOwnedPressArguments {
  let request: MouseClickRequest
  let target: MacApplicationTarget

  static func from(_ arguments: [String]) throws -> Self {
    let names = ["--x", "--y", "--hold-ms", "--clicks", "--interval-ms", "--surface", "--bundle-id"] + MacApplicationTarget.argumentNames
    var values: [String: String] = [:]
    var doubleClick = false, index = 0
    while index < arguments.count {
      let name = arguments[index]
      if name == "--double-click" {
        guard !doubleClick else { throw HelperError.invalidArgs("duplicate exact-process press flag") }
        doubleClick = true; index += 1; continue
      }
      guard names.contains(name), values[name] == nil, index + 1 < arguments.count,
        !arguments[index + 1].hasPrefix("--") else { throw HelperError.invalidArgs("invalid exact-process press arguments") }
      values[name] = arguments[index + 1]; index += 2
    }
    guard let target = try MacApplicationTarget.from(arguments: arguments), values["--surface"] == "frontmost-app",
      let rawX = values["--x"], let rawY = values["--y"], let x = Double(rawX), let y = Double(rawY), x.isFinite, y.isFinite
    else { throw HelperError.invalidArgs("press requires its complete exact-process identity and application surface") }
    func integer(_ name: String, default defaultValue: Int) throws -> Int {
      guard let raw = values[name] else { return defaultValue }
      guard let number = Int(raw), String(number) == raw else { throw HelperError.invalidArgs("noncanonical exact-process press integer") }
      return number
    }
    return .init(request: .init(x: x, y: y, holdMs: try integer("--hold-ms", default: 0),
      clicks: try integer("--clicks", default: 1), doubleClick: doubleClick, intervalMs: try integer("--interval-ms", default: 120)), target: target)
  }
}
