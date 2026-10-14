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
    var countedIDs = Set<UUID>()
    var currentTargetIDs = Set<UUID>()

    private var targetBlockRegistry: [UUID: [CGRect]] = [:]

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
    
    mutating func update(with detection: FrameResult) -> FrameResult {
        dprint("Counter: updating counter!")
        if detection.boxDetection != nil {
            box = detection.boxDetection!
        }
        let hands = detection.hands?.filter { $0.chirality == handedness } ?? []
        state = state.transition(by: hands, box, detection.blockDetections)

        updateCurrentBlocksInTarget(detection.blockDetections)
        updatePreviousBlocksInTarget()
        updateBlockCounts()
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

    /// adds all currently tracked block ids in the target to list, 
    /// then updates the position history for all block ids 
    private mutating func updateCurrentBlocksInTarget(_ blocks: [BlockObservation]) {
        for block in blocks {
            guard let id = block.id,
                  blockIsInTargetZone(block.boundingBox) else { continue }

            currentTargetIDs.insert(id)
            var history = targetBlockRegistry[id, default: []]
            history.append(block.boundingBox.cgRect)
            targetBlockRegistry[id] = Array(history.suffix(5))
        }
        dprint("Counter: \(blocks.count) blocks detected")
        dprint("Counter: \(currentTargetIDs.count) block ids in target")
    }

    /// identifies stale block ids: no longer tracked in target because its outside or due to 
    /// tracking failure, sets stale block positions to 0 so it goes out of the bounds required for "hasMovement"
    private mutating func updatePreviousBlocksInTarget() {
        for id in Array(targetBlockRegistry.keys) where !currentTargetIDs.contains(id) {
            var history = targetBlockRegistry[id, default: []]
            history.append(.zero)
            targetBlockRegistry[id] = Array(history.suffix(5))
        }
        currentTargetIDs.removeAll()
    }

    private mutating func updateBlockCounts() {
        dprint("Counter: \(blockCounts) valid blocks")
        for (id, history) in targetBlockRegistry {
            guard !activeCountingState,
                  !countedIDs.contains(id),
                  hasMovement(in: history) else { continue }
    
            blockCounts += 1
            countedIDs.insert(id)
            activeCountingState = true
            crossedBack = false
        }
    }

    private func hasMovement(in history: [CGRect]) -> Bool {
        guard history.count >= 2 else { return false }

        let meanWidth = history.reduce(0.0) { $0 + Double($1.width) } / Double(history.count)
        let meanHeight = history.reduce(0.0) { $0 + Double($1.height) } / Double(history.count)
        let referenceSize = max(meanWidth, meanHeight)
        guard referenceSize > 0 else { return false }

        guard let first = history.first, let last = history.last else { return false }
        let firstX = Double(first.midX)
        let firstY = Double(first.midY)
        let lastX = Double(last.midX)
        let lastY = Double(last.midY)
        let displacement = hypot(lastX - firstX, lastY - firstY)
        let relativeDisplacement = displacement / referenceSize
        return relativeDisplacement >= FrameProcessingThresholds.movementThreshold && relativeDisplacement <= 3
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

    private func blockIsInTargetZone(_ rect: NormalizedRect) -> Bool {
        let target = box.getTargetZone(handedness: handedness)

        let x = rect.origin.x
        let y = rect.origin.y
        let width = rect.width
        let height = rect.height

        let corners = [
            NormalizedPoint(x: x,         y: y),
            NormalizedPoint(x: x + width, y: y),
            NormalizedPoint(x: x,         y: y + height),
            NormalizedPoint(x: x + width, y: y + height)
        ]

        return corners.contains { pointInTarget($0, target) }
    }

    private func pointInTarget(_ point: NormalizedPoint, _ target: [NormalizedPoint]) -> Bool {
        guard target.count >= 3 else { return false }
        var isInside = false

        for index in target.indices {
            let start = target[index]
            let end = target[(index + 1) % target.count]
            let edgeX = end.x - start.x
            let edgeY = end.y - start.y
            let offsetX = point.x - start.x
            let offsetY = point.y - start.y
            let cross = edgeX * offsetY - edgeY * offsetX

            if abs(cross) < 0.001,
               point.x >= min(start.x, end.x), point.x <= max(start.x, end.x),
               point.y >= min(start.y, end.y), point.y <= max(start.y, end.y) {
                return true
            }

            let crossesEdge = (start.y > point.y) != (end.y > point.y)
            if crossesEdge {
                let intersectionX = start.x + (point.y - start.y) * (end.x - start.x) / (end.y - start.y)
                if point.x < intersectionX {
                    isInside.toggle()
                }
            }
        }

        return isInside
    }
}
