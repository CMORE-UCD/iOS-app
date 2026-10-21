//
//  FrameProcessorState.swift
//  CMORE
//

import Foundation
import Vision
import simd

/// Everything the counter remembers between frames: where the hand is, and whether the
/// current attempt has already counted a block. Allows at most one count per attempt.
///
/// Phase flow:
///   awaitingBlockMovement --(block moves in target zone)--> awaitingHandReturn
///   awaitingHandReturn --(hand goes notCrossed -> crossed)--> awaitingBlockMovement
struct AttemptState {
    enum Phase {
        /// Nothing counted yet this attempt; the next block movement in the target zone counts
        case awaitingBlockMovement
        /// Already counted; locked until the hand crosses back over the divider
        case awaitingHandReturn
    }

    private(set) var hand: HandPosition = .inital
    private(set) var phase: Phase = .awaitingBlockMovement

    /// Called when the hand moves onto the crossed side
    private let onCross: () -> Void

    init(onCross: @escaping () -> Void = {}) {
        self.onCross = onCross
    }

    /// Advances one frame and returns true if this frame counts a block.
    /// - Parameters:
    ///   - newHand: This frame's hand position, from `HandPosition.transition`.
    ///   - registry: Must already hold this frame's blocks. A moved block is only claimed while
    ///               awaiting block movement, so one that moves while locked can still count later.
    mutating func countsBlock(
        handAt newHand: HandPosition,
        registry: inout TargetBlockRegistry
    ) -> Bool {
        let previous = hand
        hand = newHand

        if previous != .crossed && hand == .crossed {
            onCross()
        }

        if phase == .awaitingHandReturn && previous == .notCrossed && hand == .crossed {
            phase = .awaitingBlockMovement
        }

        guard phase == .awaitingBlockMovement, registry.blockMoved() else { return false }
        phase = .awaitingHandReturn
        return true
    }
}

/// Where the hand is relative to the box divider.
/// Stored in saved results JSON, so the raw values (including "inital") must not change.
///
/// Flow:
///   inital -> crossed -> notCrossed -> crossed -> notCrossed -> ...
enum HandPosition: String, Codable {
    case inital
    case crossed
    case notCrossed

    /// Compute the next position given the current hand observations and box geometry.
    func transition(by hands: [HumanHandPoseObservation], _ box: BoxDetection, in resolution: CGSize = CameraSettings.resolution) -> HandPosition {
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
        let point = joint.location.toImageCoordinates(resolution)
        let x = Float(point.x)
        let y = Float(point.y)
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
        let point = joint.location.toImageCoordinates(resolution)
        let x = Float(point.x)
        let y = Float(point.y)
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
