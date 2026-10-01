import SwiftUI

/// Shared presentation for the workspace and its evaluation evidence.
enum WorkspaceStyle {
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
}

extension View {
    func workspaceSurface() -> some View {
        background(WorkspaceStyle.surface, in: .rect(cornerRadius: 14))
            .clipShape(.rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspaceStyle.border, lineWidth: 1) }
    }
}

struct WorkspaceMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: symbol).foregroundStyle(color).font(.system(size: 14, weight: .medium))
            }
            Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceStatusBadge: View {
    let state: SuiteCheckState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.color.opacity(0.09), in: .capsule)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkspaceEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.07) : .clear)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
