//
//  Counter.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 5/12/26.
//

import Vision

struct Counter {
    let handedness: HumanHandPoseObservation.Chirality

    var state: BlockCountingState
    var blockCounts: Int
    var box: BoxDetection
    var results: [FrameResult]
    
    /// if we have identified a valid block crossing, we are actively counting it
    /// and should not consider any further blocks until the next attempt
    var activeCountingState = false 
    var previousFrameState: BlockCountingState?

    /// tracks when we have ended the previous attempt and started a new one 
    /// by crossing from the target side, to non-target side, and 'crossed back' to target side
    var crossedBack = false
    private var targetBlockRegistry = TargetBlockRegistry()

    init(
        handedness: HumanHandPoseObservation.Chirality,
        state: BlockCountingState,
        blockCounts: Int,
        box: BoxDetection,
        results: [FrameResult]
    ) {
        self.handedness = handedness
        self.state = state
        self.blockCounts = blockCounts
        self.box = box
        self.results = results
    }
    
    /// All geometry (target zone, block positions) is done in pixel space for `resolution`,
    /// matching `BlockCountingState.transition` and the `BoxDetection` line helpers.
    mutating func update(with detection: FrameResult, in resolution: CGSize = CameraSettings.resolution) -> FrameResult {
        dprint("Counter: updating counter!")
        if detection.boxDetection != nil {
            box = detection.boxDetection!
        }
        let hands = detection.hands?.filter { $0.chirality == handedness } ?? []
        state = state.transition(by: hands, box, detection.blockDetections, in: resolution)

        let moved = targetBlockRegistry.hasMovement(blocksInTarget(detection.blockDetections, in: resolution))
        if moved && !activeCountingState {
            blockCounts += 1
            activeCountingState = true
            crossedBack = false
        }
        dprint("Counter: \(blockCounts) valid blocks")
        resetCountingState(for: state)

        let result = FrameResult(
            presentationTime: detection.presentationTime,
            state: state,
            blockTransfered: blockCounts,
            boxDetection: box,
            hands: detection.hands,
            blockDetections: detection.blockDetections
        )
        results.append(result)
        return result
    }

    /// This frame's tracked blocks that are inside the target zone, keyed by id (pixel space).
    private func blocksInTarget(_ blocks: [BlockObservation], in resolution: CGSize) -> [UUID: CGRect] {
        let zone = box.targetZone(handedness: handedness)
        var inTarget: [UUID: CGRect] = [:]

        for block in blocks {
            let rect = block.boundingBox.toImageCoordinates(resolution)
            guard let id = block.id, zone.inside(rect, in: resolution) else { continue }
            inTarget[id] = rect
        }

        dprint("Counter: \(blocks.count) blocks detected")
        dprint("Counter: \(inTarget.count) block ids in target")
        return inTarget
    }

    private mutating func resetCountingState(for frameState: BlockCountingState) {
        if activeCountingState && crossedBack && frameState == .crossed {
            activeCountingState = false
        }

        if previousFrameState == .notCrossed && frameState == .crossed {
            crossedBack = true
        }

        previousFrameState = frameState
    }
}

/// Short position history of the blocks in the target zone, used to decide when a block has
/// moved enough to be counted. Each block can only be reported once.
struct TargetBlockRegistry {
    /// Number of frames of history kept per block.
    let historyLength: Int

    /// Last `historyLength` boxes (pixel space) per block. `nil` marks a frame where the
    /// block wasn't seen in the zone, so short gaps don't erase its history.
    private var history: [UUID: [CGRect?]] = [:]

    /// Blocks already reported as moved; never reported again.
    private var countedIDs = Set<UUID>()

    init(historyLength: Int = FrameProcessingThresholds.blockHistoryLength) {
        precondition(historyLength >= 2, "Movement needs at least two frames of history")
        self.historyLength = historyLength
    }

    /// Records this frame's blocks in the target zone, then returns true if a not-yet-counted block
    /// has moved enough. That block is marked counted, so it's never reported again.
    /// Call once per frame, even with no blocks, so unseen blocks age out.
    mutating func hasMovement(_ blocksInTarget: [UUID: CGRect]) -> Bool {
        record(blocksInTarget)

        guard let id = history.first(where: { id, boxes in
            !countedIDs.contains(id) && Self.moved(boxes)
        })?.key else { return false }

        countedIDs.insert(id)
        return true
    }

    /// Appends this frame's box for every block seen, and `nil` for every block not seen.
    /// A block unseen for the whole window (all `nil`) is dropped.
    private mutating func record(_ blocksInTarget: [UUID: CGRect]) {
        for id in Set(history.keys).union(blocksInTarget.keys) {
            // Modified in place through the dictionary, so no copy. At most one entry over the
            // limit, so a single removeFirst (shifting at most `historyLength` items) trims it.
            history[id, default: []].append(blocksInTarget[id])
            if history[id]!.count > historyLength {
                history[id]!.removeFirst()
            }
        }
        history = history.filter { $0.value.contains { $0 != nil } }
    }

    /// True if the block is seen this frame and moved between `movementThreshold` and
    /// `maxMovement` times its size, measured from its oldest to its newest real box.
    private static func moved(_ boxes: [CGRect?]) -> Bool {
        // Only count a block while it's in the zone this frame.
        // (`boxes.last` is a double optional, so unwrap it before checking the entry itself.)
        guard let newest = boxes.last, newest != nil else { return false }

        // Gaps (nil) are skipped: movement is measured between the oldest and newest real boxes.
        let seen = boxes.compactMap { $0 }
        guard seen.count >= 2, let first = seen.first, let last = seen.last else { return false }

        let meanWidth = seen.reduce(0.0) { $0 + Double($1.width) } / Double(seen.count)
        let meanHeight = seen.reduce(0.0) { $0 + Double($1.height) } / Double(seen.count)
        let referenceSize = max(meanWidth, meanHeight)
        guard referenceSize > 0 else { return false }

        let displacement = hypot(Double(last.midX - first.midX), Double(last.midY - first.midY))
        let relativeDisplacement = displacement / referenceSize
        return relativeDisplacement >= FrameProcessingThresholds.movementThreshold
            && relativeDisplacement <= FrameProcessingThresholds.maxMovement
    }
}
