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

// MARK: - error types
nonisolated fileprivate enum FrameProcessorError: Error {
    case handBoxProjectionFailed
}

// MARK: - constants safe to parallel
fileprivate let handsRequest = DetectHumanHandPoseRequest()
fileprivate let facesRequest = DetectFaceRectanglesRequest()
fileprivate let blockDetector = BlockDetector()
fileprivate let boxRequest = BoxDetector.createBoxDetectionRequest()


/// Detected and filter out the wrong hand by handedness, nil handedness are kepts
fileprivate func detectnFilterHands(in image: CIImage, _ handedness: HumanHandPoseObservation.Chirality) async -> [HumanHandPoseObservation]? {
    guard let allHands = try? await handsRequest.perform(on: image) else {
        return nil
    }
    let hands = allHands.filter { hand in
        return hand.chirality == nil || hand.chirality == handedness
    }
    guard !hands.isEmpty else {
        return nil
    }
    return hands
}

// MARK: - Frame Processor
actor FrameProcessor {

    // MARK: - Callbacks

    let onCrossed: @Sendable () -> Void
    let partialResult: @Sendable (FrameResult) -> Void
    let fullResult: @Sendable (FrameResult, CIImage) -> Void

    // MARK: - Stateful properties

    public private(set) var countingBlocks = false
    public private(set) var blockCounts = 0
    
    private var results: [FrameResult] = []

    /// Single persistent stream consumer — never cancelled/restarted
    private var mainTask: Task<Void, Never>?

    /// Counting pipeline tasks
    private var processingTask: Task<Void, Never>?

    /// Feeds frames into the counting pipeline when countingBlocks == true
    private var resultContinuation: AsyncStream<(Int, FrameResult, CIImage)>.Continuation?

    /// Used for reordering the results
    private var currentIndex: Int = 0

    /// Stateful information
    private var boxLastUpdated: CMTime = .zero
    private var currentBox: BoxDetection?
    private var currentState: BlockCountingState = .free
    private var handedness: HumanHandPoseObservation.Chirality = .right

    // MARK: - Computed properties

    private var blockSize: Double {
        guard let box = currentBox else { fatalError("No box exist!") }
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

    /// Start consuming the camera frame stream. A single for-await loop runs for the
    /// stream's entire lifetime, dispatching frames based on the current mode.
    func startProcessing(stream: AsyncStream<(CIImage, CMTime)>) {
        mainTask = Task { [weak self] in
            
            let maxConcurrentTasks = FrameProcessingThresholds.maxConcurrentTasks
            await withTaskGroup(of: Void.self) { group in
                var activeTasks = 0
                
                for await (image, timestamp) in stream {
                    guard let self, !Task.isCancelled else { break }
                    
                    if activeTasks >= maxConcurrentTasks {
                        await group.next()
                        activeTasks -= 1
                    }

                    if await self.countingBlocks {
                        let index = await self.currentIndex
                        await self.incrementIdx()
                        
                        group.addTask {
                            var partialResults = FrameResult(presentationTime: timestamp, state: .free, boxDetection: await self.currentBox)
                            let currentHandedness = await self.handedness

                            partialResults.hands = try? await handsRequest.perform(on: image)
                            partialResults.blockDetections = await blockDetector.detect(on: image)
                            self.partialResult(partialResults)
                            await self.resultContinuation?.yield((index, partialResults, image))
                        }
                    } else {
                        // Pre-counting: box detection for overlay
                        group.addTask {
                            var boxDetected: BoxDetection?
                            if let boxRequestResult = try? await boxRequest.perform(on: image) as? [CoreMLFeatureValueObservation],
                               let outputArray = boxRequestResult.first?.featureValue.shapedArrayValue(of: Float.self) {
                                boxDetected = BoxDetector.processKeypointOutput(outputArray)
                            }

                            let result = FrameResult(
                                presentationTime: timestamp,
                                boxDetection: boxDetected
                            )
                            self.partialResult(result)
                            self.fullResult(result, image)
                        }
                    }
                    activeTasks += 1
                }
            }
        }
    }
    
    func incrementIdx() {
        currentIndex += 1
    }

    func startCountingBlocks(for handedness: HumanHandPoseObservation.Chirality, box: BoxDetection) {
        self.handedness = handedness
        self.countingBlocks = true
        self.currentBox = box
        self.currentIndex = 0

        // Create reordering stream
        let (stream, continuation) = AsyncStream.makeStream(
            of: (Int, FrameResult, CIImage).self,
            bufferingPolicy: .unbounded
        )
        
        self.resultContinuation = continuation

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

        let resultsToReturn = results
        #if DEBUG
        print("Frame processor: returned results count \(resultsToReturn.count)")
        #endif

        // Reset state — mainTask automatically resumes pre-counting mode
        countingBlocks = false
        results.removeAll()
        currentBox = nil
        currentState = .free
        blockCounts = 0

        return resultsToReturn
    }

    // MARK: - Private functions
    
    private func updateState(_ newState: BlockCountingState) {
        if newState == .crossed && self.currentState != .crossed {
            onCrossed()
        } else if (currentState == .crossed && newState == .released) ||
                    (currentState == .crossedBack && newState == .released) {
            blockCounts += 1
        }
        currentState = newState
    }

    private func updateBox(from box: BoxDetection, at time: CMTime) {
        if boxLastUpdated < time {
            currentBox = box
        }
    }

    private func appendResult(_ result: FrameResult) {
        results.append(result)
    }
    
    private func processInOrder(_ frame: CIImage, partialResult: FrameResult) async {
        var nextResult = partialResult   // blockDetections already set by parallel task
        let hands = nextResult.hands ?? []
        let currentBox = nextResult.boxDetection!

        // Pass [] — ignoring block-driven state transitions for now
        let nextState = currentState.transition(by: hands, currentBox, [])

        updateState(nextState)
        nextResult.blockTransfered = blockCounts
        nextResult.state = nextState
        fullResult(nextResult, frame)
        results.append(nextResult)
    }
    
    // MARK: - Pure functions

    /// Returns true if the block is above the wrist and on the right side of left hand (vice versa)
    nonisolated func isInvalidBlock(_ block: BlockObservation, basedOn hand: HumanHandPoseObservation?, _ handedness: HumanHandPoseObservation.Chirality) -> Bool {
        // TODO:
        return true
    }
}

