import SwiftUI

/// Keeps all phase content structurally stable and interpolates the capsule's
/// width directly from SwiftUI's layout proposal and each phase's ideal size.
struct QuickActionsPillPhaseLayout: Layout {
    var position: CGFloat

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    /// Interpolates the measured width between the three phase views, using the tallest ideal height unless one is proposed.
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 3 else { return .zero }

        let availableWidth = resolvedWidth(for: proposal, subviews: subviews)
        let widths = phaseWidths(availableWidth: availableWidth, subviews: subviews)
        let clampedPosition = min(max(position, 0), 2)
        let lowerIndex = Int(clampedPosition.rounded(.down))
        let upperIndex = min(lowerIndex + 1, 2)
        let progress = clampedPosition - CGFloat(lowerIndex)
        let width = widths[lowerIndex] + (widths[upperIndex] - widths[lowerIndex]) * progress
        let idealHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0

        return CGSize(width: width, height: proposal.height ?? idealHeight)
    }

    /// Centers each of the three phase views in the bounds using its phase-specific width.
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 3 else { return }

        let proposedWidth = proposal.width.map { $0.isFinite ? $0 : bounds.width } ?? bounds.width
        let widths = phaseWidths(availableWidth: proposedWidth, subviews: subviews)

        for index in subviews.indices {
            let width = widths[index]
            subviews[index].place(
                at: CGPoint(x: bounds.midX - width / 2, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }

    /// Reserves the full width for editing and caps the other phase widths at their ideal sizes.
    private func phaseWidths(
        availableWidth: CGFloat,
        subviews: Subviews
    ) -> [CGFloat] {
        [
            availableWidth,
            min(availableWidth, subviews[1].sizeThatFits(.unspecified).width),
            min(availableWidth, subviews[2].sizeThatFits(.unspecified).width)
        ]
    }

    /// Uses a finite proposed width, falling back to the editing view ideal width when the proposal is unbounded.
    private func resolvedWidth(
        for proposal: ProposedViewSize,
        subviews: Subviews
    ) -> CGFloat {
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return subviews[0].sizeThatFits(.unspecified).width
        }
        return proposedWidth
    }
}
