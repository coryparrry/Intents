import SwiftUI

/// Lucide's original vector icons for workspace navigation and section headings.
/// Foreground style is inherited so native sidebar selection and dark mode work.
struct WorkspaceIcon: View {
    enum Presentation {
        case plain
        case header
    }

    let symbol: String
    var size: CGFloat = 28
    var presentation: Presentation = .plain
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            switch presentation {
            case .plain:
                glyph.padding(size * 0.1)
            case .header:
                glyph
                    .padding(size * 0.19)
                    .foregroundStyle(Color.accentColor)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        shape
                            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.065))
                            .background(.background, in: shape)
                            .overlay {
                                shape.strokeBorder(
                                    Color.accentColor.opacity(contrast == .increased ? 0.5 : 0.18),
                                    lineWidth: 0.75
                                )
                            }
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.05), radius: 2, y: 1)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Group {
            if let asset = lucideAsset {
                SwiftUI.Image("Lucide-\(asset)")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                SwiftUI.Image(systemName: symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: size * 0.64, weight: .regular))
            }
        }
    }

    /// Existing pane definitions also use these names in native menus and controls.
    /// Keep that system-symbol contract while using Lucide in the workspace.
    private var lucideAsset: String? {
        switch symbol {
        case "square.grid.2x2": "layout-dashboard"
        case "square.stack.3d.up.fill": "layers"
        case "intent-lab": "workflow"
        case "checklist": "list-checks"
        case "laptopcomputer.and.iphone": "monitor-smartphone"
        case "iphone": "smartphone"
        case "slider.horizontal.3": "sliders-horizontal"
        case "checkmark.shield", "checkmark.seal", "checkmark.seal.fill", "person.badge.shield.checkmark": "file-check"
        case "text.alignleft": "text-align-start"
        case "text.quote": "quote"
        case "paperclip": "paperclip"
        case "cpu": "cpu"
        case "wrench.and.screwdriver.fill": "wrench"
        case "curlybraces": "braces"
        case "arrow.triangle.branch": "git-branch"
        case "gauge.with.dots.needle.50percent": "gauge"
        case "flask": "git-compare-arrows"
        case "waveform": "text-cursor-input"
        case "play.circle.fill": "play"
        case "shippingbox": "package"
        default: nil
        }
    }
}
