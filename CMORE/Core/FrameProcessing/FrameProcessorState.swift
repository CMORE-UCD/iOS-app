//
//  FrameProcessorState.swift
//  CMORE
//

import Foundation
import Vision
import simd

/// The hand-crossing state machine for block counting.
///
/// State flow:
///   free -> detecting -> crossed -> crossedBack?-> released -> free
enum BlockCountingState: String, Codable {
    case free
    case detecting
    case crossed
    case crossedBack
    case released

    /// Compute the next state given the current hand observations, box geometry,
    /// and recent block detections.
    func transition(by hands: [HumanHandPoseObservation], _ box: BoxDetection, _ blockDetections: [BlockObservation]) -> BlockCountingState {
        guard let hand = hands.first else {
            return self
        }

        let divider = (
            box["Front divider top"],
            box["Front top middle"],
            box["Back divider top"]
        )
        let backHorizon = max(
            box["Back top left"].position.y,
            box["Back top right"].position.y
        )
        let chirality = hand.chirality!
        let tips = hand.fingerTips

        /// Block centers in frame coordinates (lazily computed).
        var blockCenters: [SIMD2<Double>] {
            blockDetections.map { block in
                let center = block.boundingBox.toImageCoordinates(CameraSettings.resolution)
                return SIMD2<Double>(x: center.midX, y: center.midY)
            }
        }

        switch self {
        case .free:
            if isAbove(of: box["Front divider top"].position.y, tips) &&
                !isCrossed(divider: divider, tips, handedness: chirality) {
                return .detecting
            }

        case .released:
            if !isAbove(of: backHorizon, tips) &&
                !isCrossed(divider: divider, tips, handedness: chirality) {
                return .free
            }

        case .crossedBack:
            if isBlockApart(from: hand, distanceThreshold: FrameProcessingThresholds.releasedDistanceMultiplier * blockLengthInPixels(scale: box.cmPerPixel), blockCenters) {
                return .released
            }
            if !isAbove(of: backHorizon, tips) {
                return .free
            }
            if isCrossed(divider: divider, tips, handedness: chirality) {
                return .crossed
            }

        case .detecting:
            if !isAbove(of: backHorizon, tips) &&
                !isCrossed(divider: divider, tips, handedness: chirality) {
                return .free
            }
            if isCrossed(divider: divider, tips, handedness: chirality) {
                return .crossed
            }

        case .crossed:
            if isBlockApart(from: hand, distanceThreshold: FrameProcessingThresholds.releasedDistanceMultiplier * blockLengthInPixels(scale: box.cmPerPixel), blockCenters) {
                return .released
            }
            if !isCrossed(divider: divider, tips, handedness: chirality) {
                return .crossedBack
            }
        }
        return self
    }
}

/// Returns true if any fingertip crosses the divider polyline.
/// - Parameters:
///   - divider: Tuple of three points (front/top, front/middle, back/top) as [x, y] in image space.
///   - keypoints: Hand joints to test.
func isCrossed(divider: (Keypoint, Keypoint, Keypoint), _ joints: [Joint], handedness: HumanHandPoseObservation.Chirality) -> Bool {
    let (frontTop, frontMiddle, backTop) = divider

    // Compute the divider's x-position for a given y by clamping to the end points
    // and linearly interpolating between them.
    func dividerX(at y: Float) -> Float {
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        
        if y <= frontTop.position.y {
            // Case A: Top Section
            start = frontTop.position
            end = frontMiddle.position
        }
        else if y >= backTop.position.y {
            // Case B: Bottom Section (Parallel Projection)
            // Vector Math: Calculate direction (B - A) and add to C
            // No manual loops needed; SIMD handles the subtraction/addition.
            let direction = frontMiddle.position - frontTop.position
            
            start = backTop.position
            end = backTop.position + direction
        }
        else {
            // Case C: Middle Section
            start = frontTop.position
            end = backTop.position
        }
        
        // 2. Solve for X
        // Calculate vertical progress 't' (0.0 to 1.0)
        let dy = end.y - start.y
        
        // Safety: Avoid division by zero
        guard abs(dy) > .leastNormalMagnitude else { return start.x }
        
        let t = (y - start.y) / dy
        
        // 3. Built-in Interpolation
        // simd_mix(a, b, t) is the hardware-optimized version of "a + (b - a) * t"
        return simd_mix(start.x, end.x, t)
    }

    return joints.contains { joint in
        let x = Float(joint.location.x * CameraSettings.resolution.width)
        let y = Float(joint.location.y * CameraSettings.resolution.height)
        switch handedness {
            case .left:
                return x < dividerX(at: y)
            case .right:
                return x > dividerX(at: y)
            @unknown default:
                fatalError("Unknown handedness")
        }
    }
}

/// Returns true if any joints if above the horizon. Assume y increase upwards
func isAbove(of horizon: Float, _ keypoints: [Joint]) -> Bool {
    for joint in keypoints {
        if Float(joint.location.y * CameraSettings.resolution.height) > horizon {
            return true
        }
    }
    return false
}

func isBlockApart(from hand: HumanHandPoseObservation, distanceThreshold: Double, _ blockCenters: [SIMD2<Double>]) -> Bool {
    
    guard !blockCenters.isEmpty else { return false }
    
    let fingerTips = hand.fingerTips.map { joint in
        SIMD2<Double>(
            x: joint.location.x * CameraSettings.resolution.width,
            y: joint.location.y * CameraSettings.resolution.height
        )
    }

    let thresholdSquared = distanceThreshold * distanceThreshold

    
    for blockCenter in blockCenters {
        // Returns .released ONLY if EVERY fingertip is further than the threshold
        if fingerTips.allSatisfy({ simd_distance_squared($0, blockCenter) > thresholdSquared }) {
            return true
        }
    }
    return false
}
