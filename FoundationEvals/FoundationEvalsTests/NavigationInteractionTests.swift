import AppKit
import Combine
import SwiftUI
import Testing
#if canImport(FoundationEvalsUIComponents)
@testable import FoundationEvalsUIComponents
#else
@testable import FoundationEvals
#endif

/// Exercises the native sidebar table without displaying a window or activating the app.
@MainActor
@Suite(.serialized)
struct NavigationInteractionTests {
    @Test func runHistorySelectionWorksInBothDirectionsWithInheritedDisclosureStyle() throws {
        let fixture = SidebarFixture()
        defer { fixture.close() }
        let table = try #require(fixture.table)
        try #require(table.numberOfRows == 5)

        for (row, expected) in [(3, Destination.firstRun), (4, .secondRun), (1, .suite), (3, .firstRun)] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            fixture.settle()
            #expect(fixture.state.selection == expected)
            #expect(table.selectedRow == row)
        }
        #expect(!fixture.window.isVisible)
    }
}

private enum Destination: Hashable {
    case suite, firstRun, secondRun
}

@MainActor
private final class SidebarState: ObservableObject {
    @Published var selection: Destination = .suite
}

private struct SidebarProbe: View {
    @ObservedObject var state: SidebarState

    var body: some View {
        SidebarNavigationList(selection: $state.selection) {
            Section {
                Text("Suite").tag(Destination.suite)
            }
            Section("Run History") {
                Text("First run").tag(Destination.firstRun)
                Text("Second run").tag(Destination.secondRun)
            }
        }
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .frame(width: 280, height: 400)
    }
}

@MainActor
private final class SidebarFixture {
    let state = SidebarState()
    let window: NSWindow
    let previousActivationPolicy: NSApplication.ActivationPolicy
    let hostingView: NSHostingView<SidebarProbe>

    init() {
        previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        hostingView = NSHostingView(rootView: SidebarProbe(state: state))
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        settle()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        NSApplication.shared.setActivationPolicy(previousActivationPolicy)
    }

    var table: NSTableView? {
        descendantTable(in: hostingView)
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()
    }

    private func descendantTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = descendantTable(in: child) { return table }
        }
        return nil
    }
}

@MainActor
extension NavigationInteractionTests {
    @Test func headingWordsAndTrailingSpaceBothToggleExpansion() {
        let fixture = DisclosureFixture()
        defer { fixture.close() }

        fixture.click(x: 95, y: 14)
        #expect(fixture.state.expanded)
        fixture.click(x: 250, y: 14)
        #expect(!fixture.state.expanded)
        #expect(!fixture.window.isKeyWindow)
    }

    @Test func disabledHeadingDoesNotExpand() {
        let fixture = DisclosureFixture()
        defer { fixture.close() }
        fixture.state.disabled = true
        fixture.settle()

        fixture.click(x: 95, y: 14)
        fixture.click(x: 250, y: 14)
        #expect(!fixture.state.expanded)
    }

    @Test func nestedHeadingsAndContentHaveIndependentActions() {
        let fixture = DisclosureFixture()
        defer { fixture.close() }

        fixture.click(x: 95, y: 14)
        #expect(fixture.state.expanded)
        fixture.click(x: 250, y: 42)
        #expect(fixture.state.nestedExpanded)
        #expect(fixture.state.expanded)
        fixture.click(x: 95, y: 70)
        #expect(fixture.state.contentPresses == 1)
        #expect(fixture.state.expanded)
        #expect(fixture.state.nestedExpanded)
        fixture.click(x: 95, y: 42)
        #expect(!fixture.state.nestedExpanded)
        #expect(fixture.state.expanded)
    }
}

@MainActor
private final class DisclosureState: ObservableObject {
    @Published var expanded = false
    @Published var nestedExpanded = false
    @Published var disabled = false
    @Published var contentPresses = 0
}

private struct DisclosureProbe: View {
    @ObservedObject var state: DisclosureState

    var body: some View {
        DisclosureGroup("Conversation setup", isExpanded: $state.expanded) {
            DisclosureGroup("Nested settings", isExpanded: $state.nestedExpanded) {
                Button { state.contentPresses += 1 } label: {
                    Text("Content action")
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .disclosureGroupStyle(FullWidthDisclosureStyle())
        .disabled(state.disabled)
        .frame(width: 280, height: 160, alignment: .topLeading)
    }
}

/// SwiftUI gesture delivery needs an ordered window. Keep this test-only window
/// entirely outside every display, never key, with app activation prohibited.
@MainActor
private final class DisclosureFixture {
    let state = DisclosureState()
    let window: NSWindow
    let previousActivationPolicy: NSApplication.ActivationPolicy
    let hostingView: NSHostingView<DisclosureProbe>

    init() {
        previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        hostingView = NSHostingView(rootView: DisclosureProbe(state: state))
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 280, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
        settle()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        NSApplication.shared.setActivationPolicy(previousActivationPolicy)
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()
    }

    func click(x: CGFloat, y: CGFloat) {
        let point = NSPoint(x: x, y: hostingView.isFlipped ? y : hostingView.bounds.height - y)
        let location = hostingView.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: timestamp + Double(index) * 0.01,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: index + 1, clickCount: 1, pressure: index == 0 ? 1 : 0
            )!
            window.sendEvent(event)
        }
        settle()
    }
}
