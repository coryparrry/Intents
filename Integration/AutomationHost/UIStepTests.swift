import Foundation
import XCTest

/// One test retains application continuity across UI, App Intents and entity queries.
@MainActor
final class UIStepTests: XCTestCase {
    private var outputs: [String: [String: UIHostValue]] = [:]
    private var bindings: [String: String] = [:]

    func testUISteps() async throws {
        // Inspect XCTest failures after each action so even an XCTest-recorded UI failure gets
        // our correlated terminal receipt and screenshot before this test stops.
        continueAfterFailure = true
        guard let encoded = ProcessInfo.processInfo.environment["INTENTS_AUTOMATION_UI_PLAN_B64"],
              let bytes = Data(base64Encoded: encoded), bytes.count <= 32768 else { throw UIHostError.invalidPlan }
        let plan = try JSONDecoder().decode(UIHostPlan.self, from: bytes)
        try plan.validate()
        let app = XCUIApplication(bundleIdentifier: plan.bundleID)
        defer { app.terminate() }
        bindings = plan.bindings
        for (index, step) in plan.steps.enumerated() {
            attach("intents-ui-dispatch-\(index)", try JSONEncoder().encode(
                UIHostStepReceipt(plan: plan, index: index, dispatched: true, completed: false)))
            var value: UIHostValue?
            do {
                let previousFailures = (testRun?.failureCount ?? 0) + (testRun?.unexpectedExceptionCount ?? 0)
                value = try await execute(step, app: app, plan: plan)
                guard (testRun?.failureCount ?? 0) + (testRun?.unexpectedExceptionCount ?? 0) == previousFailures else { throw UIHostError.assertionFailed }
                if let value { outputs[step.segmentID, default: [:]][step.id] = value }
                for check in step.setupChecks ?? [] {
                    guard let output = outputs[step.segmentID]?[check.outputID] else { throw UIHostError.bindingUnavailable }
                    try check.validate(output: output)
                }
                attach("intents-ui-step-\(index)", try JSONEncoder().encode(
                    UIHostStepReceipt(plan: plan, index: index, dispatched: true, completed: true, value: value)))
            } catch {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "intents-ui-failure-\(index)"; screenshot.lifetime = .keepAlways; add(screenshot)
                attach("intents-ui-step-\(index)", try JSONEncoder().encode(
                    UIHostStepReceipt(plan: plan, index: index, dispatched: true, completed: false, value: value,
                                      error: String(String(describing: error).prefix(4096)))))
                throw error
            }
        }
    }

    private func execute(_ step: UIHostStep, app: XCUIApplication, plan: UIHostPlan) async throws -> UIHostValue? {
        for binding in step.inputBindings ?? [] where binding.destination == "uiBinding" {
            let value = try boundValue(binding)
            guard value.kind == "text", let text = value.value else { throw UIHostError.bindingUnavailable }
            bindings[step.segmentID + "/" + binding.name] = text
        }
        switch step.kind {
        case .checkFreshness: try plan.validateFreshSubject(outputs: outputs)
        case .launch:
            app.launchArguments = step.arguments ?? []; app.launchEnvironment = step.environment ?? [:]; app.launch()
        case .tap: try element(step.query, app: app).tap()
        case .typeText, .clearAndType:
            let element = try element(step.query, app: app)
            guard let text = step.text ?? step.binding.flatMap({ bindings[step.segmentID + "/" + $0] }) else { throw UIHostError.bindingUnavailable }
            element.tap()
            if step.kind == .clearAndType {
                guard let current = element.value as? String else { throw UIHostError.missingElement }
                // UITextInput cursor is placed explicitly; the placeholder is not entered text.
                #if os(macOS)
                element.typeKey("a", modifierFlags: .command)
                element.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
                #else
                if current != element.placeholderValue {
                    // Move to the end before deleting so a cursor retained from a previous edit cannot leave a suffix.
                    element.press(forDuration: 1.1)
                    let selectAll = app.menuItems["Select All"]
                    let selectAllButton = app.buttons["Select All"]
                    if selectAll.waitForExistence(timeout: 1) { selectAll.tap(); element.typeText(XCUIKeyboardKey.delete.rawValue) }
                    else if selectAllButton.exists { selectAllButton.tap(); element.typeText(XCUIKeyboardKey.delete.rawValue) }
                    else { element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
                }
                #endif
            }
            element.typeText(text)
            if step.kind == .clearAndType, element.elementType != .secureTextField,
               let actual = element.value as? String, actual != text { throw UIHostError.assertionFailed }
        case .swipe:
            let target = try step.query.map { try element($0, app: app) } ?? app
            switch step.direction {
            case "up": target.swipeUp()
            case "down": target.swipeDown()
            case "left": target.swipeLeft()
            case "right": target.swipeRight()
            default: throw UIHostError.invalidPlan
            }
        case .waitFor:
            let deadline = Date().addingTimeInterval(step.timeout ?? 10)
            while true {
                let matches = try query(step.query, app: app)
                let exists = matches.count > (step.query?.index ?? 0)
                let satisfied: Bool
                switch step.property {
                case "exists": satisfied = exists
                case "hittable":
                    if exists { satisfied = try element(step.query, app: app).isHittable }
                    else { satisfied = false }
                case "absent": satisfied = !exists
                default: throw UIHostError.invalidPlan
                }
                if satisfied { return .init(kind: "bool", boolValue: step.property != "absent") }
                guard Date() < deadline else { throw UIHostError.timedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
        case .assert:
            let actual = try property(step.property, locator: step.query, app: app)
            guard actual == step.equals else { throw UIHostError.assertionFailed }; return actual
        case .readProperty: return try property(step.property, locator: step.query, app: app)
        case .screenshot:
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "intents-ui-screenshot-" + step.id; attachment.lifetime = .keepAlways; add(attachment)
        case .invokeIntent, .query:
            guard let bytes = step.operation, var fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw UIHostError.invalidPlan }
            for binding in step.inputBindings ?? [] {
                let value = try boundValue(binding)
                if binding.destination == "hostParameter" {
                    var parameters = fields["parameters"] as? [String: Any] ?? [:]
                    parameters[binding.name] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                    fields["parameters"] = parameters
                    if let codec = binding.parameterCodec {
                        var codecs = fields["parameterCodecs"] as? [String: String] ?? [:]
                        codecs[binding.name] = codec; fields["parameterCodecs"] = codecs
                    }
                } else if binding.destination == "hostQueryIDs" {
                    guard value.kind == "entity", let id = value.value else { throw UIHostError.bindingUnavailable }
                    fields["queryIDs"] = [id]
                    fields.removeValue(forKey: "queryText"); fields.removeValue(forKey: "querySuggested")
                }
            }
            let operation = try JSONDecoder().decode(HostOperation.self, from: JSONSerialization.data(withJSONObject: fields))
            guard operation.id == step.id, (operation.kind == .query) == (step.kind == .query) else { throw UIHostError.invalidPlan }
            let value = try await IntentDefinitionsHost.execute(operation, bundleID: plan.bundleID)
            try HostValueBudget.validate([value])
            return try JSONDecoder().decode(UIHostValue.self, from: JSONEncoder().encode(value))
        }
        return nil
    }

    private func boundValue(_ binding: UIHostBinding) throws -> UIHostValue {
        guard let output = outputs[binding.producerSegmentID]?[binding.outputID] else { throw UIHostError.bindingUnavailable }
        return try binding.selection?.resolve(output) ?? output
    }
    private func query(_ locator: UIHostQuery?, app: XCUIApplication) throws -> XCUIElementQuery {
        guard let locator else { throw UIHostError.invalidPlan }
        let type: XCUIElement.ElementType
        switch locator.elementType {
        case nil, "any": type = .any
        case "button": type = .button
        case "textField", "textbox": type = .textField
        case "secureTextField": type = .secureTextField
        case "searchField", "searchbox": type = .searchField
        case "textView": type = .textView
        case "staticText": type = .staticText
        case "switch": type = .switch
        case "cell": type = .cell
        case "window": type = .window
        case "other": type = .other
        default: throw UIHostError.invalidPlan
        }
        var result = app.descendants(matching: type)
        if let id = locator.identifier { result = result.matching(identifier: id) }
        if let label = locator.label { result = result.matching(NSPredicate(format: "label == %@", label)) }
        if let contains = locator.labelContains { result = result.matching(NSPredicate(format: "label CONTAINS %@", contains)) }
        return result
    }
    private func element(_ locator: UIHostQuery?, app: XCUIApplication) throws -> XCUIElement {
        let result = try query(locator, app: app)
        if result.count == 0 { guard result.firstMatch.waitForExistence(timeout: 10) else { throw UIHostError.missingElement } }
        if let index = locator?.index {
            guard index >= 0, index < result.count else { throw UIHostError.missingElement }
            return result.element(boundBy: index)
        }
        guard result.count > 0 else { throw UIHostError.missingElement }
        guard result.count == 1 else { throw UIHostError.ambiguousElement }
        return result.element(boundBy: 0)
    }
    private func property(_ name: String?, locator: UIHostQuery?, app: XCUIApplication) throws -> UIHostValue {
        if name == "exists" { return .init(kind: "bool", boolValue: try query(locator, app: app).count > (locator?.index ?? 0)) }
        let element = try element(locator, app: app)
        switch name {
        case "label", "text": return .init(kind: "text", value: element.label)
        case "value": guard let value = element.value as? String else { throw UIHostError.missingElement }; return .init(kind: "text", value: value)
        case "selected": return .init(kind: "bool", boolValue: element.isSelected)
        case "checked": return .init(kind: "bool", boolValue: (element.value as? String) == "1")
        default: throw UIHostError.invalidPlan
        }
    }
    private func attach(_ name: String, _ data: Data) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
