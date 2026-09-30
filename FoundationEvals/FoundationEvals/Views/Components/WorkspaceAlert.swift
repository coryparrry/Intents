import AppKit
import SwiftUI

struct WorkspaceAlertButton {
    let title: String
    let isCancel: Bool
    let action: @MainActor () -> Void

    init(_ title: String, isCancel: Bool = false, action: @escaping @MainActor () -> Void = {}) {
        self.title = title
        self.isCancel = isCancel
        self.action = action
    }
}

extension View {
    func workspaceAlert(
        _ title: String,
        message: String,
        isPresented: Binding<Bool>,
        buttons: [WorkspaceAlertButton]
    ) -> some View {
        background(WorkspaceAlertPresenter(
            title: title, message: message, isPresented: isPresented, buttons: buttons
        ).frame(width: 0, height: 0))
    }
}

/// SwiftUI owns presentation state; AppKit lays out and draws the attached sheet.
private struct WorkspaceAlertPresenter: NSViewRepresentable {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    let buttons: [WorkspaceAlertButton]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.windowChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.schedulePresentation(from: view)
        }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.presentation = self
        if isPresented {
            context.coordinator.updateVisibleContent()
            context.coordinator.schedulePresentation(from: view)
        } else {
            context.coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.dismiss()
        coordinator.presentation = nil
    }

    final class AnchorView: NSView {
        var windowChanged: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?()
        }
    }

    @MainActor
    final class Coordinator {
        var presentation: WorkspaceAlertPresenter?
        private var alert: NSAlert?
        private weak var owner: NSWindow?
        private var scheduled = false
        private var sheetObserver: (any NSObjectProtocol)?

        func schedulePresentation(from view: NSView) {
            guard !scheduled, alert == nil, presentation?.isPresented == true else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.scheduled = false
                guard self.alert == nil, let presentation = self.presentation,
                      presentation.isPresented, let window = view?.window else { return }
                guard window.attachedSheet == nil else {
                    self.waitForSheetDismissal(on: window, from: view)
                    return
                }
                self.removeSheetObserver()
                self.present(presentation, on: window)
            }
        }

        private func waitForSheetDismissal(on window: NSWindow, from view: NSView?) {
            guard sheetObserver == nil else { return }
            sheetObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndSheetNotification, object: window, queue: .main
            ) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let view else { return }
                    self.removeSheetObserver()
                    self.schedulePresentation(from: view)
                }
            }
        }

        func updateVisibleContent() {
            guard let alert, let presentation else { return }
            alert.messageText = presentation.title
            alert.informativeText = presentation.message
            alert.layout()
            alert.window.contentView?.needsDisplay = true
            alert.window.displayIfNeeded()
        }

        private func present(_ presentation: WorkspaceAlertPresenter, on window: NSWindow) {
            let alert = NSAlert()
            alert.messageText = presentation.title
            alert.informativeText = presentation.message
            alert.alertStyle = .informational
            for button in presentation.buttons {
                let control = alert.addButton(withTitle: button.title)
                control.keyEquivalent = button.isCancel ? "\u{1b}" : "\r"
            }
            alert.layout()
            alert.window.contentView?.layoutSubtreeIfNeeded()
            self.alert = alert
            owner = window
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === alert else { return }
                self.alert = nil
                self.owner = nil
                let current = self.presentation ?? presentation
                current.isPresented = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if current.buttons.indices.contains(index) {
                    current.buttons[index].action()
                }
            }
            // Draw the first frame without waiting for an unrelated screenshot or expose event.
            DispatchQueue.main.async { [weak self, weak alert] in
                guard let self, let alert, self.alert === alert else { return }
                alert.window.contentView?.needsDisplay = true
                alert.window.displayIfNeeded()
            }
        }

        func dismiss() {
            removeSheetObserver()
            guard let alert else { return }
            self.alert = nil
            if let owner { owner.endSheet(alert.window, returnCode: .abort) }
            owner = nil
        }

        private func removeSheetObserver() {
            if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
            sheetObserver = nil
        }
    }
}
