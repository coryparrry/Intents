import SwiftUI

/// SF Symbols for workspace navigation and section headings.
/// Foreground style is inherited so native sidebar selection and dark mode work.
struct WorkspaceIcon: View {
    enum Presentation {
        /// The symbol alone, inheriting the surrounding foreground style.
        case plain
        /// An accent-coloured symbol for panel and popover headings.
        case header
        /// A quiet secondary symbol for rows and optional sections.
        case soft
    }

    let symbol: String
    var size: CGFloat = 28
    var presentation: Presentation = .header
    var tint: Color?

    var body: some View {
        Image(systemName: WorkspaceIcon.systemName(for: symbol))
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.7, weight: .regular))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var foreground: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        switch presentation {
        case .plain: return AnyShapeStyle(.foreground)
        case .header: return AnyShapeStyle(Color.accentColor)
        case .soft: return AnyShapeStyle(.secondary)
        }
    }

    /// Maps the app's internal names onto SF Symbols.
    static func systemName(for symbol: String) -> String {
        switch symbol {
        case "intent-lab": "testtube.2"
        case "app-automation", "play": "macwindow.and.cursorarrow"
        case "square.stack.3d.up.fill": "square.stack.3d.up"
        case "wrench.and.screwdriver.fill": "wrench.and.screwdriver"
        case "checkmark.seal.fill": "checkmark.seal"
        case "play.circle.fill": "play.circle"
        default: symbol
        }
    }
}
