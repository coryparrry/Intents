import AppKit
import SwiftUI

/// Shared presentation for the workspace and its evaluation evidence.
///
/// The system's Liquid Glass sidebar and toolbar are the navigation layer. Content sits
/// beneath them on one calm canvas: neutral grouped surfaces, the accent colour for
/// interaction, and status colour only on the marks that report a result.
enum WorkspaceStyle {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Grouped content, raised slightly from the canvas.
    static let surface = adaptive(light: (1, 1, 1), dark: (0.157, 0.157, 0.165))
    /// Wells inside a surface, such as search fields, editors, and quoted evidence.
    static let inset = adaptive(light: (0.953, 0.953, 0.961), dark: (0.118, 0.118, 0.125))
    static let border = Color.primary.opacity(0.08)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)

    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let pagePadding: CGFloat = 32
    static let readableWidth: CGFloat = 1_160

    /// System-feeling springs. Callers pass `nil` when Reduce Motion is on.
    static let pageMotion: Animation = .smooth(duration: 0.35)
    static let stateMotion: Animation = .snappy(duration: 0.28)

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
            .background(WorkspaceStyle.surface, in: shape)
            .overlay { shape.strokeBorder(WorkspaceStyle.border, lineWidth: 1).allowsHitTesting(false) }
    }

    /// Liquid Glass for controls that float above content, never for the content itself.
    func workspaceGlass(in shape: some Shape = Capsule(), interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }

    func workspaceInset(radius: CGFloat = WorkspaceStyle.controlRadius) -> some View {
        background(WorkspaceStyle.inset, in: .rect(cornerRadius: radius, style: .continuous))
    }

    /// A recessed well for multi-line text editors.
    func workspaceTextWell(minHeight: CGFloat) -> some View {
        scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .workspaceInset()
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// Centres page content at a readable width with consistent margins.
    func workspacePage() -> some View {
        padding(.horizontal, WorkspaceStyle.pagePadding)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: WorkspaceStyle.readableWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension AttributedString {
    /// Model responses often use light Markdown. Show emphasis, code and links, and turn
    /// headings and bullets into plain styled lines, while keeping the response's own line breaks.
    static func workspaceMarkdown(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }
                if heading.first == " ", !heading.dropFirst().isEmpty { return "**\(heading.dropFirst())**" }
            }
            for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
                return String(line.prefix(line.count - trimmed.count)) + "• " + trimmed.dropFirst(2)
            }
            return line
        }
        let source = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}

/// A compact label for a state or attribute: a coloured symbol and quiet text on a neutral capsule.
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
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(color)
            }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(.fill.tertiary, in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct WorkspaceStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
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

/// Places items left to right, wrapping onto new lines when the width runs out.
struct WorkspaceFlowLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
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
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(title)
                    .font(.largeTitle.weight(.bold)).lineLimit(2)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
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

/// A heading for a group of content on the page, with an optional count and trailing controls.
struct WorkspaceSectionTitle<Accessory: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder let accessory: Accessory

    init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let count {
                Text(count.formatted()).font(.title3).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 8)
            accessory
        }
        .frame(minHeight: 28)
    }
}

extension WorkspaceSectionTitle where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }
}

/// The number badge for a guided step. The current step takes the accent colour; finished steps show a check.
struct WorkspaceStepNumber: View {
    let number: Int
    var isDone = false
    var isCurrent = false

    var body: some View {
        ZStack {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, WorkspaceStyle.success)
                    .transition(.symbolEffect(.drawOn))
            } else {
                Circle().fill(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary))
                Text(number.formatted())
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
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
                    .foregroundStyle(.tertiary)
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
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.fill.quaternary, in: .capsule)
    }
}

/// An inline message inside page content. Colour stays on the symbol so the message reads calmly.
struct WorkspaceNotice<Accessory: View>: View {
    enum Kind {
        case info, success, warning, failure

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: .accentColor
            case .success: WorkspaceStyle.success
            case .warning: WorkspaceStyle.warning
            case .failure: WorkspaceStyle.failure
            }
        }
    }

    let kind: Kind
    let title: String?
    let message: String
    @ViewBuilder let accessory: Accessory

    init(_ kind: Kind, title: String? = nil, message: String, @ViewBuilder accessory: () -> Accessory) {
        self.kind = kind
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: WorkspaceStyle.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension WorkspaceNotice where Accessory == EmptyView {
    init(_ kind: Kind, title: String? = nil, message: String) {
        self.init(kind, title: title, message: message) { EmptyView() }
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
            Circle().stroke(.fill.tertiary, lineWidth: lineWidth)
            ForEach(arcs) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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
        let gap: CGFloat = segments.filter { $0.count > 0 }.count > 1 ? 0.012 : 0
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
        let gapWidth = CGFloat(max(segments.filter { $0.count > 0 }.count - 1, 0)) * 2
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.count > 0 {
                        segment.color
                            .frame(width: max(0, geometry.size.width - gapWidth) * CGFloat(segment.count) / CGFloat(total))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(.fill.tertiary)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

struct WorkspaceEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color?
    var actionTitle: String?
    var actionSymbol: String?
    var action: (() -> Void)?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? .secondary)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared && !reduceMotion)
                .frame(height: 44)
                .accessibilityHidden(true)
                .onAppear { appeared = true }
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionSymbol {
                        Label(actionTitle, systemImage: actionSymbol).labelStyle(.titleAndIcon)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40).padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

/// Presents a native GroupBox as a workspace card with a clear heading.
/// Group box content brings its own 10-point inset, so the heading is inset to match it.
struct WorkspaceGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.label
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)
            configuration.content
        }
        .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceSurface()
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
