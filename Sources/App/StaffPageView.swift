// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI
import UIKit

/// The engraved staff page, with playhead highlighting driven by the player's
/// `activeNoteIDs` (each id is the index into `score.notes`).
struct StaffPageView: UIViewRepresentable {
    var score: QuantizedScore
    var highlighted: Set<Int>

    func makeUIView(context: Context) -> StaffRenderView {
        StaffRenderView()
    }

    func updateUIView(_ view: StaffRenderView, context: Context) {
        view.score = score
        view.highlighted = highlighted
    }
}

final class StaffRenderView: UIView {
    var score: QuantizedScore? {
        didSet { if score != oldValue { relayout() } }
    }
    var highlighted: Set<Int> = [] {
        didSet { if highlighted != oldValue { setNeedsDisplay() } }
    }

    private var page: Engraver.Page?
    private var laidOutWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        guard let page else { return CGSize(width: UIView.noIntrinsicMetric, height: 240) }
        return page.size
    }

    private func relayout() {
        let w = bounds.width > 0 ? bounds.width : 350
        laidOutWidth = w
        page = score.map { Engraver.layout(score: $0, width: w) }
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - laidOutWidth) > 0.5, score != nil {
            relayout()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let score, let page, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.systemBackground.cgColor)
        ctx.fill(rect)
        Engraver.draw(score: score, page: page, in: ctx, flipped: false)
        if !highlighted.isEmpty {
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.45).cgColor)
            for n in page.notes + page.tiedSegments where highlighted.contains(n.noteIndex) {
                ctx.fillEllipse(in: n.frame.insetBy(dx: -4, dy: -4))
            }
        }
    }
}

/// The piano-roll second view.
struct PianoRollPageView: UIViewRepresentable {
    var score: QuantizedScore
    var highlighted: Set<Int>
    /// Beat/bar lines at the score's tempo; only once the tempo has been analyzed.
    var beatGrid: Bool = false

    func makeUIView(context: Context) -> PianoRollRenderView {
        PianoRollRenderView()
    }

    func updateUIView(_ view: PianoRollRenderView, context: Context) {
        view.score = score
        view.highlighted = highlighted
        view.beatGrid = beatGrid
    }
}

final class PianoRollRenderView: UIView {
    var score: QuantizedScore? {
        didSet { setNeedsDisplay() }
    }
    var highlighted: Set<Int> = [] {
        didSet { if highlighted != oldValue { setNeedsDisplay() } }
    }
    var beatGrid = false {
        didSet { if beatGrid != oldValue { setNeedsDisplay() } }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 260)
    }

    override func draw(_ rect: CGRect) {
        guard let score, let ctx = UIGraphicsGetCurrentContext() else { return }
        PianoRoll.draw(score: score, in: ctx, rect: bounds, highlighted: highlighted, beatGrid: beatGrid)
    }
}
