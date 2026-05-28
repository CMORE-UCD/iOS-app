//
//  VisionExtensions.swift
//  CMORE
//

import Vision

extension HumanHandPoseObservation {
    var fingerTips: [Joint] {
        [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
            .compactMap { joint(for: $0) }
    }
}

extension NormalizedRect {
    nonisolated func percentCovered(by other: NormalizedRect) -> CGFloat {
        let x1 = max(self.origin.x, other.origin.x)
        let y1 = max(self.origin.y, other.origin.y)
        let x2 = min(self.origin.x + self.width, other.origin.x + other.width)
        let y2 = min(self.origin.y + self.height, other.origin.y + other.height)

        let intersectionArea = max(0, x2 - x1) * max(0, y2 - y1)

        let selfArea = self.width * self.height

        return selfArea > 0 ? intersectionArea / selfArea : 0.0
    }

    /// Symmetric intersection-over-union, in [0, 1].
    nonisolated func iou(_ other: NormalizedRect) -> CGFloat {
        let x1 = max(self.origin.x, other.origin.x)
        let y1 = max(self.origin.y, other.origin.y)
        let x2 = min(self.origin.x + self.width, other.origin.x + other.width)
        let y2 = min(self.origin.y + self.height, other.origin.y + other.height)

        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = self.width * self.height + other.width * other.height - intersection

        return union > 0 ? intersection / union : 0.0
    }
}

