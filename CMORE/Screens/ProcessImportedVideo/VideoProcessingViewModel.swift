//
//  VideoProcessingViewModel.swift
//  CMORE
//

import Vision
import AVFoundation
import UIKit

@MainActor
class VideoProcessingViewModel: ObservableObject {
    @Published var overlay: FrameResult?
    @Published var currentFrame: UIImage?
    @Published var isProcessing = false
    @Published var isDone = false
    @Published private(set) var handedness: HumanHandPoseObservation.Chirality?

    private var pipeline: VideoPipeline?
    private var videoURL: URL?
    private let ciContext = CIContext()

    func loadVideo(url: URL) {
        videoURL = url
        pipeline = VideoPipeline(videoURL: url, onFrame: { [weak self] result, image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlay = result
                self.currentFrame = self.renderFrame(image)
            }
        })
    }

    func startProcessing() async {
        isProcessing = true
        let results = await pipeline?.run() ?? []
        handedness = await pipeline?.handedness
        isProcessing = false
        isDone = true
        guard !results.isEmpty else { return }
        saveSession(results: results)
    }

    private func renderFrame(_ ciImage: CIImage) -> UIImage? {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func saveSession(results: [FrameResult]) {
        guard let videoURL, let handedness else { return }

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let suffix = Date().timeIntervalSince1970
        let resultsFileName = "CMORE_Results_\(suffix).json"
        let resultsURL = documentsDir.appendingPathComponent(resultsFileName)
        dprint("Saved \(results.count) results to \(resultsURL.path)")

        let videoFileName = "CMORE_Import_\(suffix).mov"
        let videoDestURL = documentsDir.appendingPathComponent(videoFileName)

        do {
            try FileManager.default.copyItem(at: videoURL, to: videoDestURL)
        } catch {
            dprint("Video Processing View Model: Error copying video: \(error)")
        }

        do {
            let firstTime = results.first?.presentationTime ?? .zero
            let data = try JSONEncoder().encode(results.map {
                var tmp = $0
                tmp.presentationTime = tmp.presentationTime - firstTime
                return tmp
            })
            try data.write(to: resultsURL)
        } catch {
            dprint("Video Processing View Model: Error saving results: \(error)")
        }

        let blockCount = results.last?.blockTransfered ?? 0

        Task {
            do {
                try await SessionStore.shared.add(
                    blockCount: blockCount,
                    videoFileName: videoFileName,
                    resultsFileName: resultsFileName,
                    handedness: handedness
                )
            } catch {
                dprint("Video Processing View Model: fail to save the session")
            }
        }
    }
}
