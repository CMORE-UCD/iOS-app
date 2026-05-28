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
///   inital -> crossed -> notCrossed -> crossed -> notCrossed -> ...
/// Each transition INTO `.crossed` is treated as one block crossing by
/// `FrameProcessor.processInOrder`.
enum BlockCountingState: String, Codable {
    case inital
    case crossed
    case notCrossed

    /// Compute the next state given the current hand observations and box geometry.
    func transition(by hands: [HumanHandPoseObservation], _ box: BoxDetection, _ blockDetections: [BlockObservation], in resolution: CGSize = CameraSettings.resolution) -> BlockCountingState {
        let lineY = box.frontTopLineY(in: resolution)
        
        guard let hand = hands.first(where: { isValidHand(hand: $0, above: lineY) }) else {
            return self
        }

        // Box keypoints are stored normalized; denormalize once here so the
        // helpers below can stay in pixel space alongside the hand-joint math.
        let dividerX = box.dividerX(in: resolution)
        let chirality = hand.chirality!
        let tips = hand.fingerTips
        let crossing = isCrossed(dividerX: dividerX, tips, handedness: chirality)

        switch self {
        case .inital, .notCrossed:
            return crossing ? .crossed : self
        case .crossed:
            return crossing ? .crossed : .notCrossed
        }
    }
}

/// A hand is "valid" if all of its joints sit above the given line — typically
/// the box's front-top edge (via `BoxDetection.frontTopLineY(in:)`). Anything
/// below it is treated as not being inside the counting region.
func isValidHand(hand: HumanHandPoseObservation, above lineY: (Float) -> Float, in resolution: CGSize = CameraSettings.resolution) -> Bool {
    let joints = Array(hand.allJoints().values)
    return isAbove(lineY: lineY, joints, in: resolution)
}

/// Returns true if every joint lies above the line (Vision Y-up: above = larger y).
/// - Parameters:
///   - lineY: Closure mapping a joint x (pixel) to the line's y (pixel) at that x.
///   - joints: Hand joints to test.
func isAbove(lineY: (Float) -> Float, _ joints: [Joint], in resolution: CGSize = CameraSettings.resolution) -> Bool {
    return joints.allSatisfy { joint in
        let x = Float(joint.location.x * resolution.width)
        let y = Float(joint.location.y * resolution.height)
        return y > lineY(x)
    }
}

/// Returns true if any fingertip crosses the divider polyline.
/// - Parameters:
///   - dividerX: Closure mapping a y (pixel) to the divider's x (pixel); produced by
///               `BoxDetection.dividerX(in:)`.
///   - joints: Hand joints to test.
func isCrossed(dividerX: (Float) -> Float, _ joints: [Joint], handedness: HumanHandPoseObservation.Chirality, in resolution: CGSize = CameraSettings.resolution) -> Bool {
    return joints.contains { joint in
        let x = Float(joint.location.x * resolution.width)
        let y = Float(joint.location.y * resolution.height)
        switch handedness {
            case .left:
                return x < dividerX(y)
            case .right:
                return x > dividerX(y)
            @unknown default:
                fatalError("Unknown handedness")
        }
    }
}
