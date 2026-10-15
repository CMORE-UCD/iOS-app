//
// TargetZone.swift
// CMORE
//
// Created by QUYEN TAN on 10/9/26.
//
import Vision

/// The four corners of the target compartment, stored normalized like every other box keypoint.
/// The corners go around the zone in order (TL → TR → BR → BL), so consecutive corners form its edges.
nonisolated struct TargetZone: Codable, Sendable {
    let topLeft: Keypoint
    let topRight: Keypoint
    let bottomRight: Keypoint
    let bottomLeft: Keypoint
}

extension TargetZone {
    /// The four corners in order (TL → TR → BR → BL).
    var corners: [Keypoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// True if any corner of `rect` is inside the zone (or within
    /// `FrameProcessingThresholds.targetZoneEdgeTolerance` px of its edges).
    /// - Parameters:
    ///   - rect: Block bounding box in pixel space for `size`.
    ///   - size: Image size used to convert the zone's normalized corners to pixels.
    ///           Required because the edge tolerance is measured in pixels.
    func inside(_ rect: CGRect, in size: CGSize) -> Bool {
        let tl = topLeft.location.toImageCoordinates(size)
        let tr = topRight.location.toImageCoordinates(size)
        let br = bottomRight.location.toImageCoordinates(size)
        let bl = bottomLeft.location.toImageCoordinates(size)

        // Walking the corners in order gives the four edges, each as (start, end).
        let edges = [(tl, tr), (tr, br), (br, bl), (bl, tl)]

        let rectCorners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        // A block counts as in the zone if any part of it overlaps, approximated by any of its corners.
        return rectCorners.contains { point in
            let distances = edges.map { start, end in
                Self.signedDistance(from: point, toLineThrough: start, end)
            }

            // The zone is convex, so a point is inside exactly when it is on the same side of
            // all four edges. Which side counts as "inside" (+ or -) depends on whether the
            // corners run clockwise or counterclockwise. That flips between y-up (Vision) and
            // y-down (screen) coordinates, so accept either, as long as all four agree.
            // The tolerance lets points just outside an edge still pass.
            let tolerance = FrameProcessingThresholds.targetZoneEdgeTolerance
            return distances.allSatisfy { $0 >= -tolerance }
                || distances.allSatisfy { $0 <= tolerance }
        }
    }

    /// Signed perpendicular distance from `point` to the infinite line through `start` and `end`.
    ///
    /// The 2D cross product of the edge vector (end - start) with the offset vector (point - start)
    ///
    ///     cross = edge.x * offset.y - edge.y * offset.x
    ///
    /// is positive when `point` is to the left of the edge (walking from start to end), negative
    /// when it's to the right, and 0 when it's on the line. Its magnitude is the area of the
    /// parallelogram spanned by the two vectors, i.e. |edge| * (perpendicular distance), so
    /// dividing by |edge| gives the distance itself, in the same units as the inputs.
    static func signedDistance(from point: CGPoint, toLineThrough start: CGPoint, _ end: CGPoint) -> CGFloat {
        let edgeX = end.x - start.x
        let edgeY = end.y - start.y
        let offsetX = point.x - start.x
        let offsetY = point.y - start.y

        let cross = edgeX * offsetY - edgeY * offsetX
        let edgeLength = hypot(edgeX, edgeY)

        // Guard against two corners landing on the same pixel (zero-length edge).
        return cross / max(edgeLength, .ulpOfOne)
    }
}
