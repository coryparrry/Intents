import SwiftUI

/// A brief arrival for changed pages without replacing the view's identity or
/// retaining a second, outgoing toolbar and its interactive controls.
private struct WorkspacePageTransition<Value: Equatable>: ViewModifier {
    let value: Value
    let animatesOnAppearance: Bool
    @State private var appearance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Change: Equatable {
        let value: Value
        let appearance: Bool
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: Change(value: value, appearance: appearance)) { page, progress in
            page
                .opacity(reduceMotion ? 1 : Double(progress))
                .offset(y: reduceMotion ? 0 : 8 * (1 - progress))
        } keyframes: { _ in
            MoveKeyframe(CGFloat(0))
            CubicKeyframe(CGFloat(1), duration: 0.3)
        }
        .onAppear { if animatesOnAppearance { appearance.toggle() } }
    }
}

extension View {
    func workspacePageTransition<Value: Equatable>(value: Value, animatesOnAppearance: Bool = false) -> some View {
        modifier(WorkspacePageTransition(value: value, animatesOnAppearance: animatesOnAppearance))
    }
}
