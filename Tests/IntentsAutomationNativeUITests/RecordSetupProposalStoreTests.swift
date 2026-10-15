#if os(macOS)
import Foundation
import XCTest
@testable import IntentsAutomationNativeUI
@testable import IntentsAutomationCore

/// Metadata proposals only; no app launch or claim of a qualified setup recipe.
@MainActor final class RecordSetupProposalStoreTests: XCTestCase {
    private func catalog(properties: [String: String] = ["label": "text", "enabled": "bool"],
                         titles: [String: String] = ["label": "Name", "enabled": "Enabled"]) -> ApplicationSurfaceCatalog {
        .init(app: .init(logicalID: "proposal.subject", bundleID: "example.Proposal", platform: "ios", productDigest: String(repeating: "a", count: 64)),
              systemActions: [.init(id: "Change", typeName: "Change", title: "Change record",
                parameters: [.init(name: "record", family: "entity", optional: false, typeID: "Record")],
                parametersComplete: true, compiled: true, registered: false, executed: false)],
              systemDiscoveryComplete: false, uiDiscoveryComplete: false, gaps: [],
              entities: [.init(typeID: "Record", title: "Record", queryIdentifier: "RecordQuery", properties: properties, propertyTitles: titles)])
    }

    private func store(_ catalog: ApplicationSurfaceCatalog) -> AppAutomationStore {
        let root = URL(fileURLWithPath: "/private/tmp/record-proposal-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppAutomationStore(supportDirectory: root, savedCasesReader: { [] })
        model.catalog = catalog
        model.actionID = "Change"
        return model
    }

    func testUniqueTypedFieldsFillWithoutInventingBusinessOrUIValues() {
        let model = store(catalog())
        model.effectsConfirmed = true
        model.applyFreshRecordSetupProposal()
        XCTAssertEqual(model.freshNameProperty, "label")
        XCTAssertEqual(model.freshStateProperty, "enabled")
        XCTAssertEqual(model.freshInitialState, "")
        XCTAssertEqual(model.freshExpectedState, "")
        XCTAssertEqual(model.freshNamePrefix, "")
        XCTAssertEqual(model.uiInstruction, "")
        XCTAssertEqual(model.uiEndpoint, "")
        XCTAssertEqual(model.freshSaveControl, "")
        XCTAssertEqual(model.freshContextProperty, "")
        XCTAssertEqual(model.freshSelectedContext, "")
        XCTAssertEqual(model.freshProtectedContext, "")
        XCTAssertFalse(model.effectsConfirmed)
        XCTAssertFalse(model.canRun)
    }

    func testAmbiguousFieldsRemainAnExplicitChoiceRegardlessOfNames() throws {
        let model = store(catalog(properties: ["title": "text", "owner": "text", "completed": "bool", "selected": "bool"]))
        let proposal = try XCTUnwrap(model.freshRecordSetupProposal)
        XCTAssertNil(proposal.proposedNameField)
        XCTAssertNil(proposal.proposedStateField)
        model.applyFreshRecordSetupProposal()
        XCTAssertEqual(model.freshNameProperty, "")
        XCTAssertEqual(model.freshStateProperty, "")
        XCTAssertEqual(proposal.nameFields, ["owner", "title"])
        XCTAssertEqual(proposal.stateFields, ["completed", "selected"])
    }

    func testOnlyUnambiguousFieldFillsWhenOtherChoiceIsAmbiguous() {
        let model = store(catalog(properties: ["title": "text", "owner": "text", "completed": "bool"]))
        model.applyFreshRecordSetupProposal()
        XCTAssertEqual(model.freshNameProperty, "")
        XCTAssertEqual(model.freshStateProperty, "completed")
        XCTAssertEqual(model.freshInitialState, "")
        XCTAssertEqual(model.freshExpectedState, "")
    }

    func testManualChoicesAndDomainValuesArePreservedIncludingInvalidInputs() {
        let model = store(catalog())
        model.freshNameProperty = "manual-name"
        model.freshStateProperty = "manual-state"
        model.freshInitialState = "false"
        model.freshExpectedState = "true"
        model.freshNamePrefix = "Approved name"
        model.uiInstruction = "Approved setup"
        model.uiEndpoint = "Approved destination"
        model.freshSaveControl = "Approved save"
        model.freshContextProperty = "owner"
        model.freshSelectedContext = "Work"
        model.freshProtectedContext = "Home"
        model.effectsConfirmed = true
        model.applyFreshRecordSetupProposal()
        XCTAssertEqual(model.freshNameProperty, "manual-name")
        XCTAssertEqual(model.freshStateProperty, "manual-state")
        XCTAssertEqual(model.freshInitialState, "false")
        XCTAssertEqual(model.freshExpectedState, "true")
        XCTAssertEqual(model.freshNamePrefix, "Approved name")
        XCTAssertEqual(model.uiInstruction, "Approved setup")
        XCTAssertEqual(model.uiEndpoint, "Approved destination")
        XCTAssertEqual(model.freshSaveControl, "Approved save")
        XCTAssertEqual(model.freshContextProperty, "owner")
        XCTAssertEqual(model.freshSelectedContext, "Work")
        XCTAssertEqual(model.freshProtectedContext, "Home")
        XCTAssertTrue(model.effectsConfirmed)
    }

    func testIncompatibleOrAmbiguousDeclarationCannotProposeFields() {
        for variation in 0..<8 {
            var value = catalog()
            switch variation {
            case 0: value.systemActions[0].compiled = false
            case 1: value.systemActions[0].parametersComplete = false
            case 2: value.systemActions[0].parameters[0].family = "text"
            case 3: value.systemActions[0].parameters.append(.init(name: "extra", family: "bool", optional: true))
            case 4: value.entities = nil
            case 5: value.entities?[0].properties = ["label": "text", "enabled": "integer"]
            case 6: value.systemActions.append(value.systemActions[0])
            default:
                let duplicate = value.entities![0]
                value.entities?.append(duplicate)
            }
            let model = store(value)
            XCTAssertNil(model.freshRecordSetupProposal, "Variation \(variation)")
            model.applyFreshRecordSetupProposal()
            XCTAssertEqual(model.freshNameProperty, "")
            XCTAssertEqual(model.freshStateProperty, "")
        }
    }

    func testSemanticLabelsUseTitlesAndKeepUnknownIdentifiersInAdvancedDetails() throws {
        let entity = try XCTUnwrap(catalog(properties: ["internalA": "text", "internalB": "text", "isActive": "bool"],
            titles: ["internalA": "Name", "internalB": "Name", "isActive": "Active"]).entities?.first)
        XCTAssertEqual(AutomationNativeRecordSetupProposal.title(for: "isActive", in: entity), "Active")
        XCTAssertEqual(AutomationNativeRecordSetupProposal.title(for: "internalA", in: entity), "Name (field 1)")
        XCTAssertEqual(AutomationNativeRecordSetupProposal.title(for: "internalB", in: entity), "Name (field 2)")
        var untitled = entity
        untitled.propertyTitles = [:]
        XCTAssertEqual(AutomationNativeRecordSetupProposal.title(for: "internalB", in: untitled), "Text field 2")
        XCTAssertEqual(AutomationNativeRecordSetupProposal.title(for: "isActive", in: untitled), "Yes/no field 1")
    }
}
#endif
