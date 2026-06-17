//
//  FrameProcessor.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 8/20/25.
//

import Foundation
import CoreImage
import Vision
import simd

// MARK: - constants safe to parallel
fileprivate let handsRequest = DetectHumanHandPoseRequest()
fileprivate let facesRequest = DetectFaceRectanglesRequest()
fileprivate let blockDetector = BlockDetector()
fileprivate let boxDetector = BoxDetector()

// MARK: - Frame Processor
actor FrameProcessor {

    // MARK: - Callbacks

    let onCrossed: @Sendable () -> Void
    let partialResult: @Sendable (FrameResult) -> Void
    let fullResult: @Sendable (FrameResult, CIImage) -> Void

    // MARK: - Stateful properties

    private var countingBlocks = false
    private var counter: Counter?
    private var blockTrackers: [TrackObjectRequest: UUID] = [:]

    /// Single persistent stream consumer — never cancelled/restarted
    private var mainTask: Task<Void, Never>?

    /// Counting pipeline tasks
    private var processingTask: Task<Void, Never>?

    /// Feeds frames into the counting pipeline when countingBlocks == true
    private var resultContinuation: AsyncStream<(Int, FrameResult, CIImage)>.Continuation?

    // MARK: - Computed properties

    private var blockSize: Double {
        guard let box = counter?.box else { fatalError("No box exist!") }
        return blockLengthInPixels(scale: box.cmPerPixel(in: CameraSettings.resolution))
    }

    // MARK: - Public Methods

    init(
        onCross: @escaping @Sendable () -> Void = {},
        partialResult: @escaping @Sendable (FrameResult) -> Void = {_ in },
        fullResult: @escaping @Sendable (FrameResult, CIImage) -> Void = { (_, _) in }
    ) {
        self.onCrossed = onCross
        self.partialResult = partialResult
        self.fullResult = fullResult
    }
    
    nonisolated static func decideHandedness(by box: BoxDetection, and blocks: [BlockObservation], imageSize: CGSize = CameraSettings.resolution) -> HumanHandPoseObservation.Chirality {
        let dividerX: (Float) -> Float = box.dividerX(in: imageSize)
        var left = 0, right = 0
        
        for block in blocks {
            let blockCenterX = block.boundingBox.toImageCoordinates(imageSize)
            
            if Float(blockCenterX.midX) < dividerX(Float(blockCenterX.midY)) {
                left += 1
            } else if Float(blockCenterX.midX) < dividerX(Float(blockCenterX.midY)) {
                right += 1
            }
        }
        
        return left > right ? .right : .left
    }

    /// Start consuming the camera frame stream. A single for-await loop runs for the
    /// stream's entire lifetime, dispatching frames based on the current mode.
    func startProcessing(stream: AsyncStream<(CIImage, CMTime)>) {
        mainTask = Task { [weak self] in
            
            let maxConcurrentTasks = FrameProcessingThresholds.maxConcurrentTasks
            await withTaskGroup(of: Void.self) { group in
                var activeTasks = 0
                var index = 0
                var lastBoxUpdateTime: CMTime = .zero

                for await (image, timestamp) in stream {
                    guard let self, !Task.isCancelled else { break }

                    if activeTasks >= maxConcurrentTasks {
                        await group.next()
                        activeTasks -= 1
                    }

                    if await self.countingBlocks {
                        let taskIndex = index
                        let detectBoxInThisFrame = timestamp - lastBoxUpdateTime > FrameProcessingThresholds.boxUpdateInterval
                        if detectBoxInThisFrame { lastBoxUpdateTime = timestamp; dprint("Frame processor: Re-detecting boxes on this frame") }
                        
                        group.addTask {
                            // Parallel tasks: hand, block, and box detection
                            async let hands = try? handsRequest.perform(on: image)
                            async let blocks = blockDetector.detect(on: image)
                            async let box: BoxDetection? = detectBoxInThisFrame ? boxDetector.detect(on: image) : nil

                            let result = FrameResult(
                                presentationTime: timestamp,
                                boxDetection: await box,
                                hands: await hands,
                                blockDetections: await blocks,
                            )

                            self.partialResult(result)
                            await self.resultContinuation?.yield((taskIndex, result, image))
                        }
                        
                        index += 1
                    } else {
                        // Pre-counting: box detection for overlay
                        group.addTask {
                            async let result = FrameResult(
                                presentationTime: timestamp,
                                boxDetection: boxDetector.detect(on: image),
                                blockDetections: blockDetector.detect(on: image)
                            )
                            self.partialResult(await result)
                            self.fullResult(await result, image)
                        }
                    }
                    activeTasks += 1
                }
            }
        }
    }

    /// warmup the model on the neural engine.
    func warmup() async {
        let blank = CIImage(color: CIColor.black)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        dprint("FrameProcessor: Warming up block detector")
        let _ = await blockDetector.detect(on: blank)
    }

    func startCountingBlocks(for handedness: HumanHandPoseObservation.Chirality, box: BoxDetection) {
        countingBlocks = true
        blockTrackers = [:]
        counter = Counter(
            handedness: handedness,
            state: .inital,
            blockCounts: 0,
            box: box,
            results: []
        )

        // Create reordering stream
        let (stream, continuation) = AsyncStream.makeStream(
            of: (Int, FrameResult, CIImage).self,
            bufferingPolicy: .unbounded
        )
        
        resultContinuation = continuation

        // Serial consumer: state machine processing
        processingTask = Task { [weak self] in
            guard let self else { return }

            var buffer = [Int: (FrameResult, CIImage)]()
            var nextIndex: Int = 0

            for await (finishedIndex, result, image) in stream {
                buffer[finishedIndex] = (result, image)
                while let (nextResult, frame) = buffer.removeValue(forKey: nextIndex) {

                    await self.processInOrder(frame, partialResult: nextResult)

                    nextIndex += 1
                }
            }
        }
    }

    func stopCountingBlocks() async -> [FrameResult] {
        // Finish the internal counting stream
        resultContinuation?.finish()
        resultContinuation = nil

        // Wait for pipeline to drain
        await processingTask?.value

        processingTask = nil

        let resultsToReturn = counter?.results ?? []
        #if DEBUG
        print("Frame processor: returned results count \(resultsToReturn.count)")
        #endif

        // Reset state — mainTask automatically resumes pre-counting mode
        countingBlocks = false
        counter = nil
        blockTrackers = [:]

        return resultsToReturn
    }

    // MARK: - Private functions

    private func processInOrder(_ frame: CIImage, partialResult: FrameResult) async {
        guard let counter else { fatalError("Frame Processor: counter is nil") }
        let previousState = counter.state
        var updatedResult = partialResult
        
        defer {
            let result: FrameResult = self.counter!.update(with: updatedResult)

            if previousState != .crossed && result.state == .crossed {
                onCrossed()
            }

            fullResult(result, frame)
        }

        // 1. Filter to target-side blocks.
        //    handedness == .left  -> target side is x < dividerX
        //    handedness == .right -> target side is x > dividerX
        let dividerX = counter.box.dividerX(in: CameraSettings.resolution)
        let targetIdxs: [Int] = partialResult.blockDetections.indices.filter { idx in
            let c = partialResult.blockDetections[idx].boundingBox.toImageCoordinates(CameraSettings.resolution)
            switch counter.handedness {
            case .left:  return Float(c.midX) < dividerX(Float(c.midY))
            case .right: return Float(c.midX) > dividerX(Float(c.midY))
            @unknown default: return false
            }
        }

        // 2. Run live trackers against this frame.
        let requests = Array(blockTrackers.keys)
        var trackedBlocks: [UUID: NormalizedRect] = [:]
        let handler = ImageRequestHandler(frame)
        #if DEBUG
        print("Frame processor: \(requests.count) tracking requests")
        var observationCount: Int = 0
        let trackingStart = Date()
        #endif
        for await observation in handler.performAll(requests) {
            if case .trackObject(let request, let trackedBlock) = observation {
                
                #if DEBUG
                observationCount += 1
                #endif
                
                guard let trackedBlock else {
                    dprint("Frame processor: tracker returned nil observation")
                    blockTrackers.removeValue(forKey: request)
                    continue
                }
                guard trackedBlock.confidence >= FrameProcessingThresholds.blockTrackedConfidenceThreshold else {
                    dprint("Frame processor: tracker dropped — confidence \(trackedBlock.confidence) < \(FrameProcessingThresholds.blockTrackedConfidenceThreshold)")
                    blockTrackers.removeValue(forKey: request)
                    continue
                }
                
                dprint("Frame processor: tracked block confidence \(trackedBlock.confidence)")
                
                // remove tracker for stalled block (by iou)
                let previousBBox = counter.results
                    .dropLast()
                    .last?.blockDetections
                    .first(where: {
                    $0.id == blockTrackers[request]!
                })?.boundingBox
                let currentBBox = trackedBlock.boundingBox
                
                guard let previousBBox = previousBBox else { continue }
                let iou = calculateIoU(
                    rect1: previousBBox.toImageCoordinates(CameraSettings.resolution),
                    rect2: currentBBox.toImageCoordinates(CameraSettings.resolution)
                )
                dprint("Frame processor: IoU from previous frame: \(iou)")
                if iou == 1.0 {
                    continue // impossible iou, tracker start working on third frame.
                } else if iou >= FrameProcessingThresholds.stallIoUThreshold { // TODO: subtle error where comparison is done with detected block instead of tracked block
                    blockTrackers.removeValue(forKey: request)
                    continue
                }
                trackedBlocks[blockTrackers[request]!] = trackedBlock.boundingBox
            }
        }
        
        #if DEBUG
        print("Frame processor: \(observationCount) observations")
        print("Frame processor: tracker took \(Date().timeIntervalSince(trackingStart)) seconds")
        #endif
        
        let (trackedNotDetected, unmatchedIndices) = assignUUIDsToDetections(
            detectionIndices: targetIdxs,
            in: &updatedResult.blockDetections,
            trackedBlocks: trackedBlocks
        )
        
        let recentTrackedBlocks = counter.results.suffix(FrameProcessingThresholds.trackedBlockLookBack).reversed().reduce(into: [UUID:NormalizedRect]()) { result, frameResult in
            for block in frameResult.blockDetections {
                guard let id = block.id else { continue }
                if result.contains(where: { $0.key == id }) { continue }
                
                result[id] = block.boundingBox
            }
        }
        
        // cheap tracker via iou
        var (_, stillNotMatchedIndices) = assignUUIDsToDetections(
            detectionIndices: unmatchedIndices,
            in: &updatedResult.blockDetections,
            trackedBlocks: recentTrackedBlocks
        )
        
        updatedResult.blockDetections.append(contentsOf: trackedNotDetected)
        
        // 3. Create new trackers for unmatched
        let trackerBoxes = Array(trackedBlocks.values)
        stillNotMatchedIndices.sort(by: { l, r in
            // highest first
            let leftBox = partialResult.blockDetections[l].boundingBox
            let rightBox = partialResult.blockDetections[r].boundingBox
            return leftBox.origin.y + leftBox.height > rightBox.origin.y + rightBox.height
        })
        for idx in stillNotMatchedIndices {
            guard blockTrackers.count < FrameProcessingThresholds.maxNumTrackers else { break }
            
            let candidateBox = partialResult.blockDetections[idx].boundingBox
                .toImageCoordinates(CameraSettings.resolution)
            // suppress any whose box already sits near a live tracker, to avoid double-spawning on near-misses.
            let nearExistingTracker = trackerBoxes.contains { tracked in
                calculateIoU(
                    rect1: candidateBox,
                    rect2: tracked.toImageCoordinates(CameraSettings.resolution)
                ) >= FrameProcessingThresholds.trackerVicinityIoUThreshold
            }
            guard !nearExistingTracker else { continue }

            let uuid = UUID()
            blockTrackers[
                TrackObjectRequest(
                    detectedObject: DetectedObjectObservation(
                        boundingBox: partialResult.blockDetections[idx].boundingBox
                    )
                )
            ] = uuid
            updatedResult.blockDetections[idx].id = uuid
            
            #if DEBUG
            print("Frame processor: tracking block at \(candidateBox.origin)")
            #endif
        }
    }
    
    nonisolated func assignUUIDsToDetections(
        detectionIndices: [Int],
        in detections: inout [BlockObservation],
        trackedBlocks: [UUID: NormalizedRect]
    ) -> (
        trackedNotDetected: [BlockObservation],
        unmatchedIndices: [Int],
    ) {
        var trackedNotDetected: [BlockObservation] = []
        
        var claimedIndices = Set<Int>()

        // 1. OUTER LOOP: Iterate through your existing trackers
        for (trackerID, tracked) in trackedBlocks {
            
            var bestMatchIndex: Int? = nil
            var highestIoU: CGFloat = 0.0
            
            // 2. INNER LOOP: Find the detection that overlaps the most with this specific tracker
            for idx in detectionIndices{
                
                guard !claimedIndices.contains(idx) else { continue }
                
                let detected = detections[idx].boundingBox
                let iou = calculateIoU(
                    rect1: detected.toImageCoordinates(CameraSettings.resolution),
                    rect2: tracked.toImageCoordinates(CameraSettings.resolution)
                )
                
                if iou > highestIoU {
                    highestIoU = iou
                    bestMatchIndex = idx
                }
            }
            
            // 3. RESOLVE THE MATCH
            if highestIoU >= FrameProcessingThresholds.iouThreshold, let matchedIndex = bestMatchIndex {
                
                // 🎯 MATCH FOUND: The detector saw the tracked object
                detections[matchedIndex].id = trackerID
                
                // Remove the matched detection from the pool so another tracker can't steal it
                claimedIndices.insert(matchedIndex)
                
            } else {
                
                // UNMATCHED TRACKER: The detector missed it this frame!
                trackedNotDetected.append(BlockObservation(
                    boundingBox: tracked,
                    id: trackerID
                ))
                
                print("Detector missed tracker \(trackerID). Falling back to tracked rectangle.")
            }
        }

        return (trackedNotDetected, detectionIndices.filter{ !claimedIndices.contains($0) })
    }
    
    nonisolated func calculateIoU(rect1: CGRect, rect2: CGRect) -> CGFloat {
        // 1. Find the overlapping rectangle
        let intersection = rect1.intersection(rect2)
        
        // If they don't overlap at all, intersection is null
        if intersection.isNull || intersection.isEmpty { return 0.0 }
        
        // 2. Calculate the areas
        let intersectionArea = intersection.width * intersection.height
        let area1 = rect1.width * rect1.height
        let area2 = rect2.width * rect2.height
        
        // 3. IoU Formula: Intersection / (Area1 + Area2 - Intersection)
        let unionArea = area1 + area2 - intersectionArea
        
        return intersectionArea / unionArea
    }
}
