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

    var movementThreshold: Double = 0.25
    var activeCountingState = false
    var previousFrameState: BlockCountingState?
    var crossedBack = false
    var countedIDs = Set<UUID>()
    var currentTargetIDs = Set<UUID>()
    var coordsLastBlock: CGRect?

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
        if let boxDetection = detection.boxDetection {
            box = boxDetection
            box.updateTargetZone(in: CameraSettings.resolution, handedness: handedness)
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

    private mutating func updatePreviousBlocksInTarget() {
        for id in Array(targetBlockRegistry.keys) where !currentTargetIDs.contains(id) {
            var history = targetBlockRegistry[id, default: []]
            history.append(.zero)
            targetBlockRegistry[id] = Array(history.suffix(5))
        }
        currentTargetIDs.removeAll()
    }

    private mutating func updateBlockCounts() {
        var countChanged = false
        dprint("Counter: \(blockCounts) valid blocks")
        for (id, history) in targetBlockRegistry {
            guard !activeCountingState,
                  !countedIDs.contains(id),
                  hasMovement(in: history) else { continue }
    
            blockCounts += 1
            countedIDs.insert(id)
            coordsLastBlock = history.last
            activeCountingState = true
            crossedBack = false
            countChanged = true
        }

        if !countChanged {
            coordsLastBlock = nil
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
        return relativeDisplacement >= movementThreshold && relativeDisplacement <= 3
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

    private func blockIsInTargetZone(_ normalizedRect: NormalizedRect) -> Bool {
        let zoneKeys = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        guard zoneKeys.allSatisfy({ box.targetZone[$0] != nil }) else { return false }

        let size = CameraSettings.resolution
        let polygon = zoneKeys.compactMap { box.targetZone[$0] }
        let rect = normalizedRect.toImageCoordinates(size)
        let corners = [
            SIMD2<Float>(Float(rect.minX), Float(rect.minY)),
            SIMD2<Float>(Float(rect.maxX), Float(rect.minY)),
            SIMD2<Float>(Float(rect.minX), Float(rect.maxY)),
            SIMD2<Float>(Float(rect.maxX), Float(rect.maxY))
        ]

        return corners.contains { pointInPolygon($0, polygon) }
    }

    private func pointInPolygon(_ point: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false

        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let edge = end - start
            let offset = point - start
            let cross = edge.x * offset.y - edge.y * offset.x

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

private extension NormalizedRect {
    var cgRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }
}
