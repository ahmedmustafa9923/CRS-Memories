//
//  MontageTimeline.swift
//
//  The timing maths, on its own.
//
//  Both the live preview and the exported file need to answer the same
//  question — at time t, which photo is showing, how far through its move is
//  it, and how much is it faded? Keeping that in one place is what stops the
//  preview and the export from drifting apart, which is the classic failure
//  of editors like this: what you saw isn't what you shared.
//

import Foundation
import CoreGraphics

struct MontageTimeline {

    struct Slot {
        let index: Int          // -1 title card, photos 0..<n, n credits
        let start: Double
        let duration: Double
        let zoomIn: Bool
        let panUp: Bool
        let moves: Bool
    }

    let slots: [Slot]
    let total: Double
    let crossfade: Double

    static let titleDuration: Double = 2.6
    static let creditsDuration: Double = 3.4

    /// A montage with no title typed gets no title card at all — better than
    /// opening on today's date, which tells a viewer nothing. Same for
    /// credits: an empty credit line is a card of blank colour.
    init(
        photoCount: Int,
        theme: MontageTheme,
        includeTitle: Bool = true,
        includeCredits: Bool = true,
        creditsDuration: Double = MontageTimeline.creditsDuration
    ) {
        var built: [Slot] = []
        var cursor: Double = 0
        let fade = theme.crossfade

        func add(index: Int, duration: Double, moves: Bool, variant: Int) {
            built.append(
                Slot(
                    index: index,
                    start: cursor,
                    duration: duration,
                    zoomIn: variant % 2 == 0,
                    panUp: (variant / 2) % 2 == 0,
                    moves: moves
                )
            )
            cursor += duration - fade
        }

        if includeTitle {
            add(index: -1, duration: Self.titleDuration, moves: false, variant: 0)
        }
        for i in 0..<max(photoCount, 0) {
            add(index: i, duration: theme.secondsPerPhoto + fade, moves: true, variant: i)
        }
        if includeCredits {
            add(index: photoCount, duration: max(creditsDuration, 1), moves: false, variant: 0)
        }

        self.slots = built
        self.crossfade = fade
        self.total = built.last.map { $0.start + $0.duration } ?? 0
    }

    /// What's on screen at `time`. Usually one slot; two during a crossfade.
    func active(at time: Double) -> [(slot: Slot, progress: Double, alpha: Double)] {
        slots.compactMap { slot in
            let end = slot.start + slot.duration
            guard time >= slot.start, time < end else { return nil }

            let progress = (time - slot.start) / slot.duration
            let alpha = Self.alpha(
                progress: progress,
                duration: slot.duration,
                crossfade: crossfade,
                isFirst: slot.start == 0
            )
            guard alpha > 0.001 else { return nil }
            return (slot, progress, alpha)
        }
    }

    static func alpha(progress: Double, duration: Double, crossfade: Double, isFirst: Bool) -> Double {
        guard crossfade > 0 else { return 1 }
        let portion = min(0.49, crossfade / duration)

        // No fade up from black on the very first frame — a montage that
        // starts dark for a quarter second reads as a glitch.
        if !isFirst, progress < portion { return progress / portion }
        if progress > 1 - portion { return (1 - progress) / portion }
        return 1
    }

    /// Where rolling credits sit, as a multiple of the frame height, measured
    /// the way SwiftUI measures: positive is down. Starts just below the
    /// bottom edge and ends just above the top.
    ///
    /// Linear on purpose — eased credits look like the projector is failing.
    static func creditRoll(progress: Double) -> Double {
        1 - 2 * progress
    }

    /// Scale and vertical drift for the Ken Burns move, eased.
    static func motion(progress: Double, zoom: Double, zoomIn: Bool, panUp: Bool)
    -> (scale: Double, drift: Double) {
        let eased = progress * progress * (3 - 2 * progress)   // smoothstep
        let amount = zoomIn ? eased : (1 - eased)
        return (1 + zoom * amount, zoom * 0.25 * (panUp ? amount : -amount))
    }
}

