//
//  VideoFrameExtractor.swift
//  CMORE
//

import AVFoundation
import CoreImage

/// Reads frames from a saved video file one at a time (pull-based).
/// Call `prepare()` to set up the reader, then `nextFrame()` repeatedly.
/// Call `rewind()` to start over from the beginning.
class VideoFrameExtractor {
    let videoURL: URL

    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?

    init(url: URL) {
        self.videoURL = url
    }

    /// Validates that the video meets minimum requirements (≥30fps, ≥1280x720).
    /// Returns nil if valid, or an error message string if invalid.
    func validate() async -> String? {
        #if DEBUG
        print("Video Frame Extractor: validating if video is usable...")
        #endif
        
        let asset = AVURLAsset(url: videoURL)

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return "No video track found"
        }

        let size = try? await track.load(.naturalSize)
        let fps = try? await track.load(.nominalFrameRate)

        guard let size, let fps else {
            return "Could not read video properties"
        }

        let width = max(size.width, size.height)
        let height = min(size.width, size.height)

        if width <= 1280 || height <= 720 {
            return "Video resolution must be at least 1280x720 (got \(Int(width))x\(Int(height)))"
        }

        if fps < 29 {
            return "Video must be at least 29fps (got \(Int(fps))fps)"
        }

        return nil
    }

    /// Sets up the AVAssetReader from the start of the video.
    /// Must be called before `nextFrame()`.
    func prepare() async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExtractorError.noVideoTrack
        }

        let newReader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)

        guard newReader.canAdd(output) else {
            throw ExtractorError.cannotAddOutput
        }
        newReader.add(output)

        guard newReader.startReading() else {
            throw ExtractorError.readFailed(newReader.error)
        }

        self.reader = newReader
        self.trackOutput = output
    }

    /// Returns the next frame, or nil when the video ends.
    func nextFrame() -> (CIImage, CMTime)? {
        guard let reader, reader.status == .reading else { return nil }
        guard let sampleBuffer = trackOutput?.copyNextSampleBuffer() else { return nil }

        let timestamp = sampleBuffer.presentationTimeStamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nextFrame() // skip frames without pixel buffers
        }

        return (CIImage(cvPixelBuffer: pixelBuffer), timestamp)
    }

    /// Rewinds to the start by creating a fresh AVAssetReader.
    func rewind() async throws {
        reader?.cancelReading()
        reader = nil
        trackOutput = nil
        try await prepare()
    }

    enum ExtractorError: Error {
        case noVideoTrack
        case cannotAddOutput
        case readFailed(Error?)
    }
}
