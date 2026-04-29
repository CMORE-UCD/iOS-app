//
//  VideoStreamViewModel.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 8/19/25.
//

import Vision
import AVFoundation
import AudioToolbox

@MainActor
class StreamViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Whether the camera is currently recording video
    @Published var isRecording = false

    /// Whether to show the save confirmation dialog
    @Published var showSaveConfirmation = false

    /// Show the visualization overlay in real-time
    @Published var overlay: FrameResult?

    /// Use to help identify which hand we are looking at
    @Published var handedness: HumanHandPoseObservation.Chirality = .right
    
    /// Ask user for a box when not seen one.
    @Published var askForBox = false

    /// The main camera capture session — forwarded from CameraManager
    var captureSession: AVCaptureSession? { cameraManager.captureSession }

    // MARK: - Private Properties

    private let cameraManager = CameraManager()

    /// The URL of the current video being processed (temporary)
    private var currentVideoURL: URL?

    /// Suffix for both saved video and result
    private var fileNameSuffix: String?

    /// Timestamp for the start
    private var recordingStartTime: CMTime?

    /// The algorithm and ml results for the video
    private var result: [FrameResult]?

    /// Processes each frame through it
    private var frameProcessor: FrameProcessor!

    // MARK: - Initialization

    init() {
        cameraManager.setup()

        self.frameProcessor = FrameProcessor(
            onCross: { AudioServicesPlaySystemSound(1054) },
            partialResult: { @Sendable [weak self] result in
                Task { @MainActor in
                    guard let self else { return }

                    if self.isRecording && self.recordingStartTime == nil {
                        self.recordingStartTime = result.presentationTime
                    }

                    self.overlay = result
                }
            }
        )

        cameraManager.onRecordingFinished = { @Sendable [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
            
                if let error = error {
                    print("Stream View Model: Recording error: \(error.localizedDescription)")
                    self.currentVideoURL = nil
                } else {
                    print("Stream View Model: Recording completed! Save or discard?")
                    self.showSaveConfirmation = true
                }
            }
        }
        
        cameraManager.onFrameDrop = { @Sendable [weak self] sampleBuffer in
            let timestamp = sampleBuffer.presentationTimeStamp
            
            Task { @MainActor in
                guard let self else { return }
                
                if self.isRecording && self.recordingStartTime == nil {
                    self.recordingStartTime = timestamp
                }
            }
        }
    }

    deinit {
        cameraManager.stop()
    }

    // MARK: - Public Methods

    /// Toggles video recording on/off (main functionality)
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func toggleHandedness() {
        guard !isRecording else {
            print("Stream View Model: Handedness change not allowed after recording started!")
            return
        }

        if handedness == .left {
            handedness = .right
        } else {
            handedness = .left
        }
    }

    /// Saves the recording as a session (video stays in Documents, results written to JSON)
    func saveSession() {
        guard let videoURL = currentVideoURL,
              let fileNameSuffix = fileNameSuffix,
              let result = result,
              !result.isEmpty,
              let recordingStartTime = recordingStartTime else {
            print("Stream View Model: missing data for session save")
            return
        }

        // Save results JSON
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resultsFileName = "CMORE_Results_\(fileNameSuffix).json"
        let resultsURL = documentsDir.appendingPathComponent(resultsFileName)

        do {
            let data = try JSONEncoder().encode(result.map {
                var tmp = $0
                tmp.presentationTime = tmp.presentationTime - recordingStartTime
                return tmp
            })
            try data.write(to: resultsURL)
        } catch {
            print("Stream View Model: Error saving results: \(error)")
        }

        // Compute block count from results
        let blockCount = result.compactMap(\.blockTransfered).max() ?? 0

        // Create and persist the session
        let session = Session(
            id: UUID(),
            date: Date(),
            blockCount: blockCount,
            videoFileName: videoURL.lastPathComponent,
            resultsFileName: resultsFileName
        )
        
        Task {
            do {
                try await SessionStore.shared.add(session)
            } catch {
                dprint("StreamViewModel: failed to save the recorded session!")
            }
            
            // Clean up state
            self.currentVideoURL = nil
            self.result = nil
            self.fileNameSuffix = nil
            self.recordingStartTime = nil
            self.showSaveConfirmation = false
        }
    }

    /// Discards the pending recording (video file + in-memory results)
    func discardSession() {
        if let videoURL = currentVideoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }

        currentVideoURL = nil
        result = nil
        fileNameSuffix = nil
        recordingStartTime = nil

        showSaveConfirmation = false
    }

    /// Starts the camera feed and begins frame processing
    func startCamera() async {
        await cameraManager.start()

        if let stream = cameraManager.frameStream {
            await frameProcessor.startProcessing(stream: stream)
        }
    }

    // MARK: - Private Methods

    /// Starts video recording to a file
    private func startRecording() {
        guard !isRecording else {
            #if DEBUG
            print("Stream viewModel: Already recording!")
            #endif
            return
        }
        guard overlay?.boxDetection != nil else {
            Task { @MainActor in
                self.askForBox = true
            }
            return
        }

        isRecording = true

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let suffix = Date().timeIntervalSince1970

        let videoFileName = "CMORE_Recording_\(suffix).mov"
        fileNameSuffix = String(suffix)
        let outputURL = documentsPath.appendingPathComponent(videoFileName)

        currentVideoURL = outputURL

        cameraManager.startRecording(to: outputURL)

        Task {
            await frameProcessor.startCountingBlocks(for: handedness, box: (overlay?.boxDetection)!)
        }
    }

    /// Stops video recording
    private func stopRecording() {
        guard isRecording else { return }

        isRecording = false

        Task {
            result = await frameProcessor.stopCountingBlocks()
        }

        cameraManager.stopRecording()
    }
}
