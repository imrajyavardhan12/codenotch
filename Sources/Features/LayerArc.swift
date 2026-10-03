import AppKit
import SwiftUI

/// An arc that animates on the render server instead of in SwiftUI.
///
/// A SwiftUI `repeatForever` or `TimelineView(.animation)` is driven from the
/// app's own main thread: every frame re-evaluates the view graph and runs a
/// layout pass, whether or not anything on screen changed except an angle. One
/// working agent made that the whole of the open notch's cost — measured on the
/// same build, 11.4% of a core with the spinner and 3.1% without it. A Core
/// Animation animation is handed to the render server once and runs there, so
/// the app does no work per frame at all.
struct LayerArc: NSViewRepresentable {
    enum Motion: Equatable {
        case still
        /// One clockwise turn every `period` seconds.
        case spin(period: TimeInterval)
        /// Opacity easing between full and `low` and back, `period` each way.
        case pulse(period: TimeInterval, low: CGFloat)
    }

    var color: Color
    /// The radius of the stroke's centre line, as `Circle().stroke` has it: the
    /// stroke straddles this, so half of it lies outside.
    var radius: CGFloat
    var lineWidth: CGFloat
    /// How much of the circle is drawn, 0...1, starting at 12 o'clock and
    /// running clockwise.
    var fraction: CGFloat
    var motion: Motion

    func makeNSView(context: Context) -> LayerArcView { LayerArcView() }

    func updateNSView(_ view: LayerArcView, context: Context) {
        view.configure(color: NSColor(color).cgColor, radius: radius, lineWidth: lineWidth,
                       fraction: fraction, motion: motion)
    }
}

final class LayerArcView: NSView {
    let shape = CAShapeLayer()
    private var radius: CGFloat = 0
    private var fraction: CGFloat = 1
    private var motion: LayerArc.Motion = .still

    private static let spinKey = "codenotch.spin"
    private static let pulseKey = "codenotch.pulse"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = nil
        shape.lineCap = .round
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Purely decorative: clicks belong to the notch beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: CGColor, radius: CGFloat, lineWidth: CGFloat,
                   fraction: CGFloat, motion: LayerArc.Motion) {
        shape.strokeColor = color
        shape.lineWidth = lineWidth
        let geometryChanged = radius != self.radius || fraction != self.fraction
        self.radius = radius
        self.fraction = fraction
        if geometryChanged { rebuildPath() }
        if motion != self.motion || shape.animationKeys() == nil {
            apply(motion)
            self.motion = motion
        }
    }

    override func layout() {
        super.layout()
        // Rotation is about the layer's centre, so it spans the view exactly.
        shape.frame = bounds
        rebuildPath()
    }

    private func rebuildPath() {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        // 12 o'clock is +90° in this (unflipped) space; clockwise sweeps down.
        path.addArc(center: centre, radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * fraction,
                    clockwise: true)
        shape.path = path
    }

    private func apply(_ motion: LayerArc.Motion) {
        shape.removeAllAnimations()
        shape.opacity = 1
        switch motion {
        case .still:
            break
        case .spin(let period):
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi          // negative: clockwise
            spin.duration = period
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            // Survives the view leaving and re-entering a window.
            spin.isRemovedOnCompletion = false
            shape.add(spin, forKey: Self.spinKey)
        case .pulse(let period, let low):
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = low
            pulse.duration = period
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            shape.add(pulse, forKey: Self.pulseKey)
        }
    }
}
