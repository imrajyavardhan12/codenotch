import XCTest
import SwiftUI
@testable import Codenotch

/// The activity indicators moved from SwiftUI animations to Core Animation to
/// stop re-running the view graph every frame. What has to stay true is what
/// they draw and that they keep moving, neither of which a visual glance at a
/// 44pt ring would catch.
@MainActor
final class LayerArcTests: XCTestCase {

    private func makeView(fraction: CGFloat, motion: LayerArc.Motion) -> LayerArcView {
        let view = LayerArcView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.configure(color: NSColor.red.cgColor, radius: 40, lineWidth: 8,
                       fraction: fraction, motion: motion)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    /// Whether anything was drawn at a point, in y-up coordinates.
    private func isDrawn(_ view: LayerArcView, x: Int, y: Int) -> Bool {
        let size = 100
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { XCTFail("no bitmap"); return false }
        view.layer?.render(in: context)
        // Memory row 0 is the top of the image.
        let row = size - 1 - y
        return data[(row * size + x) * 4 + 3] > 0
    }

    /// A quarter circle from 12 o'clock, clockwise: it covers the top and the
    /// right, and neither the bottom nor the left.
    func testAQuarterArcStartsAtTwelveAndRunsClockwise() {
        let view = makeView(fraction: 0.25, motion: .still)
        XCTAssertTrue(isDrawn(view, x: 50, y: 90), "12 o'clock should be drawn")
        XCTAssertTrue(isDrawn(view, x: 90, y: 50), "3 o'clock should be drawn")
        XCTAssertFalse(isDrawn(view, x: 50, y: 10), "6 o'clock should be empty")
        XCTAssertFalse(isDrawn(view, x: 10, y: 50), "9 o'clock should be empty")
    }

    func testAFullRingCoversEveryQuarter() {
        let view = makeView(fraction: 1, motion: .still)
        for (x, y) in [(50, 90), (90, 50), (50, 10), (10, 50)] {
            XCTAssertTrue(isDrawn(view, x: x, y: y), "(\(x),\(y)) should be drawn")
        }
    }

    func testSpinningHandsTheAnimationToTheRenderServer() {
        let view = makeView(fraction: 0.25, motion: .spin(period: 1.1))
        let spin = view.shape.animation(forKey: "codenotch.spin") as? CABasicAnimation
        XCTAssertNotNil(spin, "no spin animation attached")
        XCTAssertEqual(spin?.repeatCount, .infinity)
        XCTAssertEqual(spin?.duration ?? 0, 1.1, accuracy: 0.0001)
        XCTAssertLessThan((spin?.toValue as? Double) ?? 0, 0, "clockwise is negative about z")
    }

    func testPulsingAnimatesOpacityAndBounces() {
        let view = makeView(fraction: 1, motion: .pulse(period: 0.9, low: 0.3))
        let pulse = view.shape.animation(forKey: "codenotch.pulse") as? CABasicAnimation
        XCTAssertEqual(pulse?.keyPath, "opacity")
        XCTAssertEqual(pulse?.autoreverses, true)
        XCTAssertEqual(pulse?.repeatCount, .infinity)
    }

    /// Reduce Motion, or a state change from working to idle, must really stop
    /// the movement — a leftover animation is a ring that never stops.
    func testChangingToStillRemovesTheAnimation() {
        let view = makeView(fraction: 0.25, motion: .spin(period: 1.1))
        view.configure(color: NSColor.red.cgColor, radius: 40, lineWidth: 8,
                       fraction: 0.25, motion: .still)
        XCTAssertNil(view.shape.animationKeys())
    }

    /// Re-rendering with the same motion must not restart it: SwiftUI calls
    /// update on every change, and a restart each time is a visible stutter.
    func testReconfiguringWithTheSameMotionKeepsTheRunningAnimation() {
        let view = makeView(fraction: 0.25, motion: .spin(period: 1.1))
        let first = view.shape.animation(forKey: "codenotch.spin")
        view.configure(color: NSColor.blue.cgColor, radius: 40, lineWidth: 8,
                       fraction: 0.25, motion: .spin(period: 1.1))
        XCTAssertTrue(first === view.shape.animation(forKey: "codenotch.spin"))
    }

    func testItNeverSwallowsAClick() {
        let view = makeView(fraction: 0.25, motion: .still)
        XCTAssertNil(view.hitTest(CGPoint(x: 50, y: 90)))
    }
}
