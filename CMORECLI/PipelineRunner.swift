//
//  PipelineRunner.swift
//  CMORECLI
//

import AVFoundation
import CoreImage
import Vision

actor PipelineRunner {
    private enum Phase { case scanning, counting }

    private let extractor: VideoFrameExtractor
    private var frameProcessor: FrameProcessor?
    private var phase: Phase = .scanning
    private var handedness: HumanHandPoseObservation.Chirality?
    private var continuation: AsyncStream<(CIImage, CMTime)>.Continuation?
    private var transitionTask: Task<Void, Never>?
    private var doneContinuation: CheckedContinuation<[FrameResult]?, Never>?

    init(videoURL: URL) {
        extractor = VideoFrameExtractor(url: videoURL)
    }

    // Called after init to avoid escaping-self capture during initialization.
    nonisolated func setup() {
        let fp = FrameProcessor(
            fullResult: { @Sendable [weak self] result, _ in
                Task { await self?.onFrameProcessed(result) }
            }
        )
        Task { await self.setProcessor(fp) }
    }

    private func setProcessor(_ fp: FrameProcessor) {
        frameProcessor = fp
    }

    func process() async -> [FrameResult]? {
        if let error = await extractor.validate() {
            fputs("Video validation failed: \(error)\n", stderr)
            return nil
        }
        return await withCheckedContinuation { cont in
            doneContinuation = cont
            Task { await startProcessing() }
        }
    }

    private func startProcessing() async {
        guard let frameProcessor else { return }
        do {
            try await extractor.prepare()
        } catch {
            fputs("Failed to prepare video: \(error)\n", stderr)
            doneContinuation?.resume(returning: nil)
            doneContinuation = nil
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: (CIImage, CMTime).self)
        continuation = cont
        phase = .scanning
        await frameProcessor.startProcessing(stream: stream)
        for _ in 0..<FrameProcessingThresholds.maxConcurrentTasks {
            yieldNextFrame()
        }
    }

    private func onFrameProcessed(_ result: FrameResult) {
        switch phase {
        case .scanning:
            if let box = result.boxDetection, !result.blockDetections.isEmpty {
                if handedness == nil {
                    handedness = FrameProcessor.decideHandedness(by: box, and: result.blockDetections)
                }
                guard transitionTask == nil else { return }
                transitionTask = Task { await transitionToCounting(box: box) }
            } else {
                yieldNextFrame()
            }
        case .counting:
            yieldNextFrame()
        }
    }

    private func transitionToCounting(box: BoxDetection) async {
        do {
            try await extractor.rewind()
        } catch {
            fputs("Failed to rewind video: \(error)\n", stderr)
            continuation?.finish()
            return
        }
        phase = .counting
        guard let handedness else { fatalError("Handedness not set before counting phase") }
        await frameProcessor?.startCountingBlocks(for: handedness, box: box)
        yieldNextFrame()
    }

    private func yieldNextFrame() {
        if let (image, time) = extractor.nextFrame() {
            continuation?.yield((image, time))
        } else {
            finishVideo()
        }
    }

    private func finishVideo() {
        guard continuation != nil else { return }
        continuation?.finish()
        continuation = nil
        Task {
            let results: [FrameResult]?
            if phase == .counting {
                results = await frameProcessor?.stopCountingBlocks()
            } else {
                results = nil
            }
            doneContinuation?.resume(returning: results)
            doneContinuation = nil
        }
    }
}
