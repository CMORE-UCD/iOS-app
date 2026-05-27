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

    /// Single persistent stream consumer — never cancelled/restarted
    private var mainTask: Task<Void, Never>?

    /// Counting pipeline tasks
    private var processingTask: Task<Void, Never>?

    /// Feeds frames into the counting pipeline when countingBlocks == true
    private var resultContinuation: AsyncStream<(Int, FrameResult, CIImage)>.Continuation?

    // MARK: - Computed properties

    private var blockSize: Double {
        guard let box = counter?.box else { fatalError("No box exist!") }
        return blockLengthInPixels(scale: box.cmPerPixel)
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
        let dividerX: (Float) -> Float = box.dividerX
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
                        if detectBoxInThisFrame { lastBoxUpdateTime = timestamp }
                        
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
        counter = Counter(
            handedness: handedness,
            state: .free,
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

        return resultsToReturn
    }

    // MARK: - Private functions
    
    private func processInOrder(_ frame: CIImage, partialResult: FrameResult) async {
        guard counter != nil else { fatalError("Frame Processor: counter is nil") }
        let previousState = counter!.state

        let result: FrameResult = counter!.update(with: partialResult)

        if previousState != .crossed, result.state == .crossed {
            onCrossed()
        }

        fullResult(result, frame)
    }
}

