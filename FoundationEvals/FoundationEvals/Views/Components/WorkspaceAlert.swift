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
        private var panel: NSPanel?
        private var hostingView: NSHostingView<WorkspaceAlertContent>?
        private weak var owner: NSWindow?
        private var scheduled = false
        private var sheetObserver: (any NSObjectProtocol)?

        func schedulePresentation(from view: NSView) {
            guard !scheduled, panel == nil, presentation?.isPresented == true else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.scheduled = false
                guard self.panel == nil, let presentation = self.presentation,
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
            guard let panel, let hostingView, let presentation else { return }
            hostingView.rootView = content(for: presentation, panel: panel)
            layout(panel, hostingView: hostingView)
        }

        private func content(for presentation: WorkspaceAlertPresenter, panel: NSPanel) -> WorkspaceAlertContent {
            WorkspaceAlertContent(title: presentation.title, message: presentation.message,
                                  buttons: presentation.buttons) { [weak self, weak panel] index in
                guard let self, let panel, self.panel === panel else { return }
                self.owner?.endSheet(panel, returnCode: .init(
                    rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
                ))
            }
        }

        private func layout(_ panel: NSPanel, hostingView: NSHostingView<WorkspaceAlertContent>) {
            hostingView.layoutSubtreeIfNeeded()
            panel.setContentSize(hostingView.fittingSize)
            hostingView.needsDisplay = true
            panel.displayIfNeeded()
        }

        private func present(_ presentation: WorkspaceAlertPresenter, on window: NSWindow) {
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: content(for: presentation, panel: panel))
            hostingView.sizingOptions = .intrinsicContentSize
            panel.contentView = hostingView
            self.panel = panel
            self.hostingView = hostingView
            owner = window
            layout(panel, hostingView: hostingView)
            window.beginSheet(panel) { [weak self] response in
                guard let self, self.panel === panel else { return }
                self.panel = nil
                self.hostingView = nil
                self.owner = nil
                let current = self.presentation ?? presentation
                current.isPresented = false
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                if current.buttons.indices.contains(index) {
                    current.buttons[index].action()
                }
            }
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel, let hostingView = self.hostingView else { return }
                self.layout(panel, hostingView: hostingView)
            }
        }

        func dismiss() {
            removeSheetObserver()
            guard let panel else { return }
            self.panel = nil
            hostingView = nil
            if let owner { owner.endSheet(panel, returnCode: .abort) }
            owner = nil
        }

        private func removeSheetObserver() {
            if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
            sheetObserver = nil
        }
    }
}

private struct WorkspaceAlertContent: View {
    let title: String
    let message: String
    let buttons: [WorkspaceAlertButton]
    let selectButton: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                ForEach(buttons.indices, id: \.self) { index in
                    if buttons[index].isCancel {
                        Button(buttons[index].title, role: .cancel) { selectButton(index) }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button(buttons[index].title) { selectButton(index) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
