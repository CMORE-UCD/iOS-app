//
//  BoxShapeConstants.swift
//  CMORE
//

import CoreGraphics

enum LiveUIConstants {
    // X-axis is mirrored exactly around 0.5
    static let backLeftX: CGFloat = 0.228
    static let backRightX: CGFloat = 1 - backLeftX

    static let frontTopLeftX: CGFloat = 0.07
    static let frontTopRightX: CGFloat = 1.0 - frontTopLeftX

    static let frontBottomLeftX: CGFloat = 0.09
    static let frontBottomRightX: CGFloat = 1 - frontBottomLeftX

    static let centerX: CGFloat = 0.5

    static let stickTopY: CGFloat = 0.34
    static let backRimY: CGFloat = 0.5
    static let frontRimY: CGFloat = 0.75
    static let bottomY: CGFloat = 0.95
    
    // Maximum normalized distance from keypoint to the UI guide.
    static let offTolerant: Double = 0.12
}
