import SwiftUI

/// Its views side by side across the whole width offered, each the same width. Its ideal width is the widest one's,
/// times their number, so `ViewThatFits` knows when the widest no longer fits its share.
struct EqualWidths: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else {
            return .zero
        }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width ?? widest * CGFloat(subviews.count) + gaps
        let slot = ProposedViewSize(width: share(of: width, subviews.count), height: proposal.height)
        let height = subviews.map { $0.sizeThatFits(slot).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = share(of: bounds.width, subviews.count)
        for (index, subview) in subviews.enumerated() {
            let leading = bounds.minX + (width + spacing) * CGFloat(index)
            subview.place(
                at: CGPoint(x: leading, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
        }
    }

    private func share(of width: CGFloat, _ count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}
