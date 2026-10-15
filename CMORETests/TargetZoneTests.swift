//
//  TargetZoneTests.swift
//  CMORETests
//

import Testing
import Vision
@testable import CMORE

@Suite("Target Zone")
struct TargetZoneTests {
    /// 1000x1000 so normalized 0.25 == 250 px, which keeps the expected values easy to read.
    let size = CGSize(width: 1000, height: 1000)

    private func kp(_ x: CGFloat, _ y: CGFloat) -> Keypoint {
        Keypoint(confidence: 1, location: NormalizedPoint(x: x, y: y))
    }

    /// Square zone spanning 250...750 px on both axes.
    private var square: TargetZone {
        TargetZone(topLeft: kp(0.25, 0.75), topRight: kp(0.75, 0.75),
                   bottomRight: kp(0.75, 0.25), bottomLeft: kp(0.25, 0.25))
    }

    /// Trapezoid: top edge 300...700 px at y = 700, bottom edge 200...800 px at y = 300.
    private var trapezoid: TargetZone {
        TargetZone(topLeft: kp(0.3, 0.7), topRight: kp(0.7, 0.7),
                   bottomRight: kp(0.8, 0.3), bottomLeft: kp(0.2, 0.3))
    }

    /// 10x10 px rect centered on (x, y).
    private func block(_ x: CGFloat, _ y: CGFloat, side: CGFloat = 10) -> CGRect {
        CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }

    // MARK: - inside

    @Test func fullyInside() {
        #expect(square.inside(block(500, 500), in: size))
    }

    @Test func fullyOutside() {
        #expect(!square.inside(block(100, 100), in: size))
        #expect(!square.inside(block(900, 500), in: size))
    }

    @Test("One corner overlapping counts as inside")
    func partialOverlap() {
        // Spans 745...755, so only its left corners are inside the 750 px edge.
        #expect(square.inside(block(750, 500), in: size))
    }

    @Test("Block larger than the zone with no corner inside is not counted")
    func coversZoneWithNoCornerInside() {
        // Corners-only check: a block that completely covers the zone has all corners outside.
        #expect(!square.inside(CGRect(x: 0, y: 0, width: 1000, height: 1000), in: size))
    }

    @Test("Edge tolerance: within 1 px outside passes, beyond fails")
    func edgeTolerance() {
        // Zero-size rects so the only corner is the point itself; right edge is at x = 750.
        #expect(square.inside(CGRect(x: 750.5, y: 500, width: 0, height: 0), in: size))
        #expect(!square.inside(CGRect(x: 752, y: 500, width: 0, height: 0), in: size))
    }

    @Test("Slanted edges are respected, not just the bounding box")
    func slantedEdge() {
        // Left edge runs (200, 300) → (300, 700); at y = 650 it is at x = 287.5.
        #expect(!trapezoid.inside(block(250, 650, side: 2), in: size))
        #expect(trapezoid.inside(block(320, 650, side: 2), in: size))
    }

    @Test("Result doesn't depend on corner winding direction")
    func windingIndependent() {
        // Same square, corners listed counterclockwise instead of clockwise.
        let reversed = TargetZone(topLeft: kp(0.25, 0.75), topRight: kp(0.25, 0.25),
                                  bottomRight: kp(0.75, 0.25), bottomLeft: kp(0.75, 0.75))
        for (x, y) in [(500.0, 500.0), (100.0, 100.0), (750.0, 500.0), (900.0, 500.0)] {
            #expect(square.inside(block(x, y), in: size) == reversed.inside(block(x, y), in: size))
        }
    }

    // MARK: - signedDistance

    @Test("Signed distance: left of edge is positive, right is negative, on line is zero")
    func signedDistance() {
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 10, y: 0)   // edge pointing +x
        #expect(TargetZone.signedDistance(from: CGPoint(x: 5, y: 3), toLineThrough: start, end) == 3)
        #expect(TargetZone.signedDistance(from: CGPoint(x: 5, y: -4), toLineThrough: start, end) == -4)
        #expect(TargetZone.signedDistance(from: CGPoint(x: 20, y: 0), toLineThrough: start, end) == 0)
    }

    @Test("Signed distance on a diagonal edge is the true perpendicular distance")
    func signedDistanceDiagonal() {
        let d = TargetZone.signedDistance(from: CGPoint(x: 0, y: 2), toLineThrough: .zero, CGPoint(x: 1, y: 1))
        #expect(abs(d - sqrt(2)) < 1e-9)
    }
}
