#if os(macOS)
import AppKit
import SwiftUI

@MainActor protocol AutomationSecretConsentPresenting: AnyObject {
    func present() async throws -> AutomationSecretFillRequest
    func cancelAndDrain() async
}

/// Internal, one-shot native presenter. Non-activating panel keeps the selected
/// app frontmost; actual focus and privacy behavior still require UI qualification.
@MainActor final class AutomationSecretConsentPresenter: NSObject, NSWindowDelegate, AutomationSecretConsentPresenting {
    private final class ConsentPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private let model: AutomationSecretConsentModel
    private let drainNativeOwner: @Sendable () async -> Void
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<AutomationSecretFillRequest, Error>?
    private var closingTask: Task<Void, Never>?
    private var presented = false, finished = false, closing = false
    init(model: AutomationSecretConsentModel, drainNativeOwner: @escaping @Sendable () async -> Void) {
        self.model = model; self.drainNativeOwner = drainNativeOwner
    }
    func present() async throws -> AutomationSecretFillRequest {
        guard !presented, !closing, !Task.isCancelled else { throw AutomationSecretFillSession.Failure.denied }
        presented = true
        let request = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let panel = ConsentPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Secure fill permission"; panel.delegate = self
                panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
                panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
                panel.contentView = NSHostingView(rootView: AutomationSecretConsentView(model: model,
                    onApproved: { [weak self] request in self?.approve(request) },
                    onCancelled: { [weak self] in Task { await self?.cancelAndDrain() } }))
                self.panel = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
            }
        } onCancel: { Task { await self.cancelAndDrain() } }
        guard !Task.isCancelled, !closing else { throw AutomationSecretFillSession.Failure.revoked }
        return request
    }
    func cancelAndDrain() async {
        closing = true; panel?.orderOut(nil)
        if let closingTask { await closingTask.value; return }
        let task = Task {
            await model.cancelAndDrain(); await drainNativeOwner()
            finish(.failure(AutomationSecretFillSession.Failure.revoked))
        }
        closingTask = task; await task.value
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closing = true; panel?.orderOut(nil)
        Task { await cancelAndDrain() }; return false
    }
    func windowDidResignKey(_ notification: Notification) {
        if !finished { closing = true; panel?.orderOut(nil); Task { await cancelAndDrain() } }
    }
    private func approve(_ request: AutomationSecretFillRequest) {
        guard !closing, !finished, panel?.isKeyWindow == true, model.state == .approved,
              request.scope == model.review.scope, request.sinkID == model.review.sinkID,
              request.sinkFingerprint == model.review.sinkFingerprint else {
            Task { await cancelAndDrain() }; return
        }
        finish(.success(request))
    }
    private func finish(_ result: Result<AutomationSecretFillRequest, Error>) {
        guard !finished else { return }; finished = true
        let continuation = self.continuation; self.continuation = nil
        let panel = self.panel; self.panel = nil
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close()
        continuation?.resume(with: result)
    }
}
#endif
