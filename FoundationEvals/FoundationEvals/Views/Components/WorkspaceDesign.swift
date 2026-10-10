import SwiftUI

/// The app's one status vocabulary: an SF Symbol per state, coloured only by what it means.
/// State changes morph the symbol in place, and running work spins until it settles.
struct WorkspaceStatusMark: View {
    enum State: Hashable { case idle, running, passed, failed, attention }

    let state: State
    var size: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(state.isResult ? .palette : .monochrome)
            .foregroundStyle(glyph, fill)
            .font(.system(size: size * 0.86))
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state == .running && !reduceMotion)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: state)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .idle: "circle.dashed"
        case .running: "progress.indicator"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        }
    }

    private var glyph: AnyShapeStyle {
        switch state {
        case .idle: AnyShapeStyle(.tertiary)
        case .running: AnyShapeStyle(.secondary)
        case .passed, .failed, .attention: AnyShapeStyle(.white)
        }
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .passed: AnyShapeStyle(WorkspaceStyle.success)
        case .failed: AnyShapeStyle(WorkspaceStyle.failure)
        case .attention: AnyShapeStyle(WorkspaceStyle.warning)
        case .idle: AnyShapeStyle(.tertiary)
        case .running: AnyShapeStyle(.secondary)
        }
    }
}

extension WorkspaceStatusMark.State {
    var isResult: Bool { self == .passed || self == .failed || self == .attention }
}

extension SuiteCheckState {
    var mark: WorkspaceStatusMark.State {
        switch self {
        case .passed: .passed
        case .failed: .failed
        case .changed, .incomplete, .unavailable: .attention
        case .notRun, .collected: .idle
        }
    }
}

/// A headline figure: a quiet label above a confident number that rolls between values.
struct WorkspaceFigure: View {
    let title: String
    let value: String
    var detail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : WorkspaceStyle.stateMotion, value: value)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Turns any placeholder layout into one quiet shape with a soft, sweeping highlight.
struct WorkspaceShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        GeometryReader { geometry in
                            LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.4)
                                .offset(x: -geometry.size.width * 0.4 + geometry.size.width * 1.4 * phase)
                        }
                    }
                    .blendMode(.plusLighter)
                    .mask(content.redacted(reason: .placeholder))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .allowsHitTesting(false)
    }
}

extension View {
    func workspaceShimmer(_ active: Bool = true) -> some View {
        Group { if active { modifier(WorkspaceShimmer()) } else { self } }
    }
}
