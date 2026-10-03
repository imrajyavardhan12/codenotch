import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    /// Whether anyone can see this ring. The notch folds by fading its cells to
    /// nothing, not by removing them, so a ring is still in the tree — and its
    /// activity arc still animating — while folded shut, which is most of the
    /// time. A `repeatForever` animation costs a layout pass every frame whether
    /// or not it is seen: with one agent working it was the whole of the app's
    /// idle CPU, around 4% of a core, spent drawing nothing.
    var isVisible: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }
    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only. Whether Claude is
            // working right now is known first-hand and stays at full strength
            // even when the percentage behind it has gone stale.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if usedFraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            band.color,
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Refreshing spins the reading itself rather than
                        // overlaying a separate spinner: the thing being
                        // refetched is the thing that should move, and a second
                        // arc on the same track only competes with it.
                        .rotationEffect(.degrees(-90 + spin))
                        // A ring that snaps to a new value reads as a glitch; one
                        // that sweeps reads as a measurement being taken.
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                }

                ProviderGlyphView(glyph: glyph)
                    .foregroundStyle(Palette.textPrimary)
                    // A spent limit dims its glyph so the ring reads as "waiting".
                    .opacity(band == .exhausted ? 0.35 : 1)
            }
            .opacity(isStale ? 0.45 : 1)

            if let activity, activity.state != .idle, isVisible {
                ActivityArc(summary: activity)
                    .transition(.opacity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself.
            //
            // The obvious spelling is a `repeatForever` linear spin started on
            // the way in and cancelled on the way out — but `repeatForever` does
            // not stop when you set the value back, and if the value you set is
            // the one it is already animating toward, nothing changes and it
            // simply keeps going. The ring then spins for ever after a refresh
            // that finished half a second in.
            //
            // A single finite turn has no cancellation problem at all: 360° is
            // the same angle as 0°, so it lands exactly where the reading
            // belongs. It eases out, so it settles rather than stopping dead.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) {
                spin += 360
            }
        }
    }
}

/// The inner indicator: a short arc that spins while work is happening, and a
/// full pulsing ring when something is blocked waiting on you.
///
/// Both run as Core Animation animations (see `LayerArc`), not SwiftUI ones:
/// a `repeatForever` here re-ran the view graph every frame and was most of the
/// open notch's CPU.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the circle the moving arc covers.
    private let arcFraction: CGFloat = 0.25

    private var radius: CGFloat { NotchLayout.activityDiameter / 2 }

    var body: some View {
        Group {
            switch summary.state {
            case .working:
                LayerArc(color: summary.color, radius: radius,
                         lineWidth: NotchLayout.activityStroke, fraction: arcFraction,
                         motion: reduceMotion ? .still : .spin(period: 1.1))
            case .waiting:
                LayerArc(color: summary.color, radius: radius,
                         lineWidth: NotchLayout.activityStroke, fraction: 1,
                         motion: reduceMotion ? .still : .pulse(period: 0.9, low: 0.3))
            case .idle:
                EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }
}

/// A ring and the percent burned underneath it.
struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var isVisible: Bool = true

    /// A dash, not "0%": nothing read is not the same as nothing used.
    private var percentText: String {
        snapshot.hasReading ? snapshot.headlineText : "—"
    }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                isVisible: isVisible
            )
            Text(percentText)
                .font(Typography.percent)
                .foregroundStyle(Palette.textPrimary)
                // Never squeezed: across a horizontal edge the cell is only as
                // wide as the ring, and a label wider than that would be
                // truncated rather than allowed to overhang into the spacing
                // that is already there for it.
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: percentText)
        }
        .frame(height: NotchLayout.cellExtent)
    }
}
