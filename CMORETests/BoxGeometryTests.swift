//
//  BoxGeometryTests.swift
//  CMORETests
//

import Testing
import Vision
@testable import CMORE

@Suite("Box Geometry")
struct BoxGeometryTests {
    let size = CGSize(width: 1920, height: 1080)

    private func kp(_ x: CGFloat, _ y: CGFloat) -> Keypoint {
        Keypoint(confidence: 1, location: NormalizedPoint(x: x, y: y))
    }

    private var box: BoxDetection {
        BoxDetection(
            centerX: 0, centerY: 0, width: 0, height: 0, objectConf: 1,
            frontTopLeft: kp(0.20, 0.30), frontBottomLeft: kp(0.20, 0.10),
            frontTopMiddle: kp(0.50, 0.28), frontBottomMiddle: kp(0.50, 0.08),
            frontTopRight: kp(0.80, 0.32), frontBottomRight: kp(0.80, 0.12),
            backDividerTop: kp(0.51, 0.61), frontDividerTop: kp(0.50, 0.40),
            backTopLeft: kp(0.30, 0.62), backTopRight: kp(0.72, 0.60)
        )
    }

    @Test("toImageCoordinates matches manual x * width, y * height")
    func toImageCoordinatesMatchesManualScaling() {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (1, 1), (0.25, 0.75), (-0.1, 1.2)]
        for (x, y) in points {
            let p = NormalizedPoint(x: x, y: y).toImageCoordinates(size)
            #expect(p.x == x * size.width)
            #expect(p.y == y * size.height)
        }
    }

    @Test("Line passes through its endpoints")
    func linePassesThroughEndpoints() {
        let front = box.frontTopLineY()
        #expect(abs(front(0.20) - 0.30) < 1e-6)
        #expect(abs(front(0.80) - 0.32) < 1e-6)
    }

    @Test("Pixel and normalized results agree")
    func pixelMatchesNormalized() {
        let w = Float(size.width), h = Float(size.height)
        for t: Float in [0.1, 0.45, 0.7, 0.9] {
            #expect(abs(box.frontTopLineY(in: size)(t * w) - box.frontTopLineY()(t) * h) < 1e-2)
            #expect(abs(box.backTopLineY(in: size)(t * w) - box.backTopLineY()(t) * h) < 1e-2)
            #expect(abs(box.dividerX(in: size)(t * h) - box.dividerX()(t) * w) < 1e-2)
        }
    }
}
