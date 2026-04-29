//
//  CameraManager.swift
//  CMORE
//
//  Manages all AVFoundation camera concerns: session setup, device configuration,
//  recording, delegate callbacks, and video saving to Photos.
//

import CoreImage
import AVFoundation

nonisolated final class CameraManager: NSObject, @unchecked Sendable, AVCaptureFileOutputRecordingDelegate {
    // MARK: - Public Properties

    /// The camera capture session, exposed for use by CameraPreviewView
    private(set) var captureSession: AVCaptureSession?

    /// Whether the movie output is currently recording
    var isRecording: Bool { movieOutput?.isRecording ?? false }

    /// The async stream of camera frames, created when the camera starts
    private(set) var frameStream: AsyncStream<(CIImage, CMTime)>?

    // MARK: - Callbacks

    /// Called when movie file recording finishes
    var onRecordingFinished: (@Sendable (URL, Error?) -> Void)!
    
    /// Called when AVFoundation dropped a frame
    var onFrameDrop: (@Sendable (CMSampleBuffer) -> Void)!


    // MARK: - Private Properties
    
    private var frameNum: UInt = 0
    private var lastTimestamp: CMTime?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private let videoOutputQueue = DispatchQueue(label: "videoOutputQueue", qos: .userInitiated)
    private var frameContinuation: AsyncStream<(CIImage, CMTime)>.Continuation?

    // MARK: - Setup

    func setup() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Failed to get camera device")
            return
        }

        let format = getFormat(for: camera)

        do {
            try camera.lockForConfiguration()

            camera.activeFormat = format
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(CameraSettings.frameRate))

            camera.unlockForConfiguration()

            #if DEBUG
            print("Selected video format: \(camera.activeFormat)")
            print("Min frame duration: \(camera.activeVideoMinFrameDuration)")
            print("Max frame duration: \(camera.activeVideoMaxFrameDuration)")
            let shutterSpeed = camera.exposureDuration.seconds
            print("Shutter Speed: 1/\(Int(1 / shutterSpeed)) seconds")
            let actualFrameRate = 1.0 / camera.activeVideoMinFrameDuration.seconds
            print("Frame Rate: \(actualFrameRate) fps")
            #endif

            captureSession = AVCaptureSession()
            captureSession?.sessionPreset = .inputPriority

            let cameraInput = try AVCaptureDeviceInput(device: camera)

            if captureSession?.canAddInput(cameraInput) == true {
                captureSession?.addInput(cameraInput)
            }

            videoOutput = AVCaptureVideoDataOutput()
            videoOutput?.alwaysDiscardsLateVideoFrames = true
            videoOutput?.setSampleBufferDelegate(self, queue: videoOutputQueue)

            if captureSession?.canAddOutput(videoOutput!) == true {
                captureSession?.addOutput(videoOutput!)
            }

            movieOutput = AVCaptureMovieFileOutput()

            if captureSession?.canAddOutput(movieOutput!) == true {
                captureSession?.addOutput(movieOutput!)
            }

        } catch {
            #if DEBUG
            print("Camera manager: Error setting up camera: \(error)")
            #endif
        }
    }

    func start() async {
        #if DEBUG
        print("Camera manager: start")
        #endif
        guard captureSession?.isRunning != true else { return }
        guard let captureSession = captureSession else {
            print("Camera manager: capture session not available")
            return
        }

        let (stream, continuation) = AsyncStream.makeStream(
            of: (CIImage, CMTime).self,
            bufferingPolicy: .bufferingNewest(FrameProcessingThresholds.frameBufferSize)
        )
        self.frameStream = stream
        self.frameContinuation = continuation

        captureSession.startRunning()
    }

    func stop() {
        #if DEBUG
        print("Camera manager: stop")
        #endif
        frameContinuation?.finish()
        frameContinuation = nil
        frameStream = nil
        captureSession?.stopRunning()
    }

    // MARK: - Recording

    func startRecording(to url: URL) {
        guard let movieOutput = movieOutput else {
            print("Camera manager: Movie output not available")
            return
        }

        if let connection = movieOutput.connection(with: .video) {
            connection.videoRotationAngle = 0.0
        }

        movieOutput.startRecording(to: url, recordingDelegate: self)
        print("Camera manager: Recording started")
    }

    func stopRecording() {
        guard let movieOutput = movieOutput, movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate
    
    /// Called when recording starts successfully
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        print("Camera manager: Started recording to: \(fileURL)")
    }

    /// Called when recording finishes
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        self.onRecordingFinished?(outputFileURL, error)
    }

    // MARK: - Private Helpers

    private func calculateISO(old shutterOld: CMTime, new shutterNew: CMTime, current ISO: Float) -> Float {
        let factor = shutterOld.seconds / shutterNew.seconds
        return ISO * Float(factor)
    }

    private func getFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format {
        let allFormats = device.formats

        let hasCorrectResolution: (AVCaptureDevice.Format) -> Bool = { format in
            format.formatDescription.dimensions.width == Int(CameraSettings.resolution.width) &&
            format.formatDescription.dimensions.height == Int(CameraSettings.resolution.height)
        }

        let supportsFrameRate: (AVCaptureDevice.Format) -> Bool = { format in
            format.videoSupportedFrameRateRanges.contains { (range: AVFrameRateRange) in
                range.minFrameRate <= CameraSettings.frameRate && CameraSettings.frameRate <= range.maxFrameRate
            }
        }

        guard let targetFormat = (allFormats.first { format in
            hasCorrectResolution(format) &&
            supportsFrameRate(format)
        }) else {
            fatalError("Camera manager: No supported format")
        }

        return targetFormat
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentTime = sampleBuffer.presentationTimeStamp

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Camera manager: Fail to get pixel buffer!")
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let yieldResult = frameContinuation?.yield((ciImage, currentTime))
        frameNum += 1
        
        #if DEBUG
        print(String(repeating: "-", count: 50))
        print("Camera manager: Frame number: \(frameNum)")
        
        switch yieldResult {
        case .dropped(_):
            print("Camera Stream: Dropped oldest frame in the queue, currently full with \(FrameProcessingThresholds.frameBufferSize + 1) frames")
        case .enqueued(let remaining):
            print("Camera Stream: Currently \(remaining) slots remaining in the buffer queue")
            
            if let last = lastTimestamp {
                let delta = (currentTime - last).seconds
                let actualFps = 1.0 / delta
                print("Actual FPS: \(actualFps)")
            }
            lastTimestamp = currentTime
        case .terminated:
            print("Camera Stream: Stream terminated")
            frameNum = 0
        case .none:
            fallthrough
        @unknown default:
            break
        }
        #endif // DEBUG
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentTime = sampleBuffer.presentationTimeStamp
        #if DEBUG
        print("Camera manager: AVFoundation dropped \(frameNum)th frame at \(currentTime.seconds)s")
        #endif
        frameNum += 1
        
        self.onFrameDrop(sampleBuffer)
    }
}
