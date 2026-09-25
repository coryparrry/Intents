import AppKit
import SwiftUI

/// Shared presentation for the workspace and its evaluation evidence.
enum WorkspaceStyle {
    static let canvas = adaptive(light: (0.961, 0.961, 0.969), dark: (0.110, 0.110, 0.118))
    static let surface = adaptive(light: (1, 1, 1), dark: (0.173, 0.173, 0.180))
    /// Wells inside a surface, such as search fields, editors, and quoted evidence.
    static let inset = adaptive(light: (0.949, 0.949, 0.957), dark: (0.133, 0.133, 0.141))
    static let border = Color.primary.opacity(0.08)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)

    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let pagePadding: CGFloat = 28
    static let readableWidth: CGFloat = 1_200

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

extension View {
    func workspaceSurface(radius: CGFloat = WorkspaceStyle.panelRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .background {
                shape.fill(WorkspaceStyle.surface)
                    .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
            }
            .overlay { shape.strokeBorder(WorkspaceStyle.border, lineWidth: 0.5) }
    }

    func workspaceInset(radius: CGFloat = WorkspaceStyle.controlRadius) -> some View {
        background(WorkspaceStyle.inset, in: .rect(cornerRadius: radius))
    }

    /// A recessed well for multi-line text editors.
    func workspaceTextWell(minHeight: CGFloat) -> some View {
        scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(8)
            .workspaceInset()
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border, lineWidth: 0.5)
            }
    }

    /// Centres page content at a readable width with consistent margins.
    func workspacePage() -> some View {
        padding(.horizontal, WorkspaceStyle.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: WorkspaceStyle.readableWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A rounded, colour-filled symbol tile in the style of System Settings.
struct WorkspaceIconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// A soft, tinted symbol badge for section headings.
struct WorkspaceSymbolBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct WorkspacePill: View {
    let title: String
    let symbol: String?
    let color: Color

    init(_ title: String, symbol: String? = nil, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceStatusBadge: View {
    let state: SuiteCheckState

    var body: some View {
        WorkspacePill(state.title, symbol: state.symbol, color: state.color)
    }
}

struct WorkspaceStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A metadata item for page headers: a quiet symbol followed by text.
struct WorkspaceMetaLabel: View {
    let text: String
    let symbol: String

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.tertiary).imageScale(.small)
            Text(text).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkspacePageHeader<Accessory: View>: View {
    let title: String
    let eyebrow: String?
    let subtitle: String?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.eyebrow = eyebrow
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                if let eyebrow {
                    Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(title)
                    .font(.system(size: 28, weight: .bold)).tracking(-0.3).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension WorkspacePageHeader where Accessory == EmptyView {
    init(_ title: String, eyebrow: String? = nil, subtitle: String? = nil) {
        self.init(title, eyebrow: eyebrow, subtitle: subtitle) { EmptyView() }
    }
}

struct WorkspacePanelHeader<Accessory: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let count {
                Text(count.formatted())
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

extension WorkspacePanelHeader where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }
}

struct WorkspaceSearchField: View {
    let prompt: String
    @Binding var text: String
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier(identifier ?? prompt)
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .workspaceInset(radius: 7)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).imageScale(.small)
                Text(title)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceRingSegment {
    let count: Int
    let color: Color
}

/// A segmented donut that shows how a whole divides into states.
struct WorkspaceRing: View {
    let segments: [WorkspaceRingSegment]
    let total: Int
    var lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
            ForEach(arcs) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }

    private struct Arc: Identifiable {
        let id: Int
        let start: CGFloat
        let end: CGFloat
        let color: Color
    }

    private var arcs: [Arc] {
        let denominator = CGFloat(max(total, 1))
        let gap: CGFloat = segments.filter { $0.count > 0 }.count > 1 ? 0.008 : 0
        var start: CGFloat = 0
        var result: [Arc] = []
        for (index, segment) in segments.enumerated() where segment.count > 0 {
            let length = CGFloat(segment.count) / denominator
            result.append(Arc(id: index, start: start + gap, end: max(start + gap, start + length - gap), color: segment.color))
            start += length
        }
        return result
    }
}

/// A slim proportional bar for pass, fail and unscored counts.
struct WorkspaceProportionBar: View {
    let segments: [WorkspaceRingSegment]
    var height: CGFloat = 6

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.count }, 1)
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.count > 0 {
                        segment.color
                            .frame(width: max(2, (geometry.size.width - 4) * CGFloat(segment.count) / CGFloat(total)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.07))
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

struct WorkspaceEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
                .background(Color.primary.opacity(0.05), in: .circle)
                .padding(.bottom, 6)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36).padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkspaceRowButton(configuration: configuration)
    }
}

private struct WorkspaceRowButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : isHovering && isEnabled ? 0.035 : 0))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
