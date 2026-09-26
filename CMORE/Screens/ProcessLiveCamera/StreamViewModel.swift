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
    
    /// Whether to show the start confirmation process
    @Published var showStartConfirmation = false

    /// Signals that the camera screen can dismiss after the pending recording is handled.
    @Published var shouldDismissCamera = false

    /// Controls whether the camera screen hides the navigation back button.
    @Published var hideNavigationBackButton = false

    /// Show the visualization overlay in real-time
    @Published var overlay: FrameResult?

    /// Use to help identify which hand we are looking at
    @Published var handedness: HumanHandPoseObservation.Chirality = .right

    /// Ask user for a box when not seen one.
    @Published var askForBox = false

    /// Countdown value (3, 2, 1) before recording starts; nil when not counting down
    @Published var countdown: Int? = nil

    /// Seconds remaining in the current recording (counts down from maxRecordingSeconds)
    @Published var recordingTimeRemaining: Int = 60

    /// The main camera capture session — forwarded from CameraManager
    @Published var captureSession: AVCaptureSession?

    /// Light up the UI when the box Detection is aligned with lines on the screen
    @Published var isAligned: Bool = false

    // MARK: - Private Properties

    private let cameraManager = CameraManager()

    /// The URL of the current video being processed (temporary)
    private var currentVideoURL: URL?

    /// Suffix for both saved video and result
    private var fileNameModified: Bool = false
    
    private var videoFileName: String = ""
    
    private var resultsFileName: String = ""

    /// Timestamp for the start
    private var recordingStartTime: CMTime?

    /// The algorithm and ml results for the video
    private var result: [FrameResult]?

    /// Processes each frame through it
    private var frameProcessor: FrameProcessor!

    private let maxRecordingSeconds = 60
    private var countdownTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        cameraManager.setup()

        self.frameProcessor = FrameProcessor(
            onCross: { if !UserDefaults.standard.bool(forKey: "soundMuted") { AudioServicesPlaySystemSound(1054) } },
            partialResult: { @Sendable [weak self] result in
                Task { @MainActor in
                    let box = result.boxDetection != nil ? result.boxDetection : self?.overlay?.boxDetection
                    self?.overlay = result
                    self?.overlay?.boxDetection = box
                    
                    if let isRecording = self?.isRecording, isRecording {
                        return // early return
                    }
                    self?.isAligned = self?.isBoxAligned(result.boxDetection) ?? false
                }
            }
        )

        cameraManager.onRecordingStarted = { @Sendable [weak self] firstFrameTime in
            Task { @MainActor in
                guard let self, self.recordingStartTime == nil else { return }
                self.recordingStartTime = firstFrameTime
            }
        }

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
        
    }

    deinit {
        cameraManager.stop()
    }

    // MARK: - Public Methods

    /// Toggles video recording on/off (main functionality)
    func toggleRecording() {
        if countdown != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            hideNavigationBackButton = false
        } else if isRecording {
            stopRecording()
        } else {
            if (self.startConditionsMet()) {
                hideNavigationBackButton = true
                self.showStartConfirmation = true
            }
        }
    }

    func toggleHandedness() {
        guard !isRecording && countdown == nil else {
            print("Stream View Model: Handedness change not allowed after recording started!")
            return
        }

        if handedness == .left {
            handedness = .right
        } else {
            handedness = .left
        }

        let selectedHandedness = handedness
        Task {
            await frameProcessor.updateHandedness(selectedHandedness)
        }
    }

    /// Saves the recording as a session (video stays in Documents, results written to JSON)
    func saveSession(nameRequest: String? = nil) {
        guard let videoURL = currentVideoURL,
              let result = result,
              !result.isEmpty,
              let recordingStartTime = recordingStartTime else {
            print("Stream View Model: missing data for session save")
            return
        }

        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        if let nameRequest {
            videoFileName = "\(nameRequest).mov"
            resultsFileName = "\(nameRequest).json"
            fileNameModified = true
        }

        let finalVideoURL = documentsDir.appendingPathComponent(videoFileName)

        if finalVideoURL != videoURL {
            do {
                try FileManager.default.moveItem(at: videoURL, to: finalVideoURL)
                currentVideoURL = finalVideoURL
            } catch {
                print("Stream View Model: Error renaming recording: \(error)")
            }
        }

        // Save results JSON

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

        // if not custom, should be empty
        let sessionName = (fileNameModified) ? nameRequest : ""

        Task {
            do {
                try await SessionStore.shared.add(
                    name: sessionName!,
                    blockCount: blockCount,
                    videoFileName: finalVideoURL.lastPathComponent,
                    resultsFileName: resultsFileName,
                    handedness: handedness
                )
            } catch {
                dprint("StreamViewModel: failed to save the recorded session!")
            }
            
            // Clean up state
            self.currentVideoURL = nil
            self.result = nil
            self.recordingStartTime = nil
            self.showSaveConfirmation = false
            self.shouldDismissCamera = true
            self.fileNameModified = false
        }
    }
    
    func checkExist(fileName: String) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let videoFileName = "\(fileName).mov"
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let finalVideoURL = documentsDir.appendingPathComponent(videoFileName)
        if FileManager.default.fileExists(atPath: finalVideoURL.path) {return nil}

        let invalidCharacters = CharacterSet(charactersIn: "/:")
        return trimmed
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
    }

    /// Discards the pending recording (video file + in-memory results)
    func discardSession() {
        if let videoURL = currentVideoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }

        currentVideoURL = nil
        result = nil
        recordingStartTime = nil
        fileNameModified = false

        showSaveConfirmation = false
        shouldDismissCamera = true
    }

    /// Starts the camera feed and begins frame processing
    func startCamera() async {
        await cameraManager.start()
        captureSession = cameraManager.captureSession

        if let stream = cameraManager.frameStream {
            await frameProcessor.startProcessing(stream: stream)
        }
    }
    
    /// Runs the 3-second countdown then starts video recording
    func startRecording(nameRequest: String? = nil) {
        self.showStartConfirmation = false
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            Task { await self.frameProcessor.warmup() }
            for tick in [3, 2, 1] {
                guard !Task.isCancelled else { return }
                self.countdown = tick
                self.playUnmutableSound("countdown_\(tick).mp3")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else {
                self.countdown = nil
                return
            }
            self.countdown = nil
            self.actuallyStartRecording(nameRequest)
        }
    }

    // MARK: - Private Methods
    private func startConditionsMet() -> Bool {
        guard !isRecording && countdown == nil else { return false }
        guard overlay?.boxDetection != nil else {
            askForBox = true
            return false
        }
        
        return true
    }
    
    private var soundEffect: AVAudioPlayer?

    private func playUnmutableSound(_ soundFileName: String) {
        let baseName = (soundFileName as NSString).deletingPathExtension
        let ext = (soundFileName as NSString).pathExtension

        guard let url = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "SoundAssets")
            ?? Bundle.main.url(forResource: baseName, withExtension: ext)
        else {
            dprint("StreamViewModel: missing sound file \(soundFileName)")
            return
        }

        do {
            soundEffect = try AVAudioPlayer(contentsOf: url)
            soundEffect?.prepareToPlay()
            soundEffect?.play() 
            //test
        } catch {
            dprint("StreamViewModel: failed to load sound file \(soundFileName): \(error)")
        }
    }

    private func actuallyStartRecording(_ nameRequest: String? = nil) {
        self.playUnmutableSound("beep.mp3") // "begin recording" chime
        isRecording = true
        recordingTimeRemaining = maxRecordingSeconds

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        if (nameRequest != nil) {
            videoFileName = "\(nameRequest!).mov"
            resultsFileName = "\(nameRequest!).csv"
            fileNameModified = true
        } else {
            let suffix = String(Date().timeIntervalSince1970)
            videoFileName = "CMORE_Recording_\(suffix).mov"
            resultsFileName = "CMORE_Recording_\(suffix).json"
        }
        
        let outputURL = documentsPath.appendingPathComponent(videoFileName)
        currentVideoURL = outputURL

        cameraManager.startRecording(to: outputURL)

        Task {
            await frameProcessor.startCountingBlocks(for: handedness, box: (overlay?.boxDetection)!)
        }

        recordingTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = self.maxRecordingSeconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1
                self.recordingTimeRemaining = remaining
            }
            if !Task.isCancelled {
                self.playUnmutableSound("beep.mp3")
                self.stopRecording()
            }
        }
    }

    /// Stops video recording
    private func stopRecording() {
        guard isRecording else { return }

        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        isRecording = false

        Task {
            result = await frameProcessor.stopCountingBlocks()
        }

        cameraManager.stopRecording()
        cameraManager.stop()
    }

    private func isBoxAligned(_ box: BoxDetection?) -> Bool {
        guard let box else { return false }

        // BoxShapeConstants use screen-space y (0 = top).
        // The guide is drawn with .scaleEffect(scaleFactor), which scales around
        // the view center (0.5, 0.5), so apply the same transform here.
        // NormalizedPoint stores Vision-space y (0 = bottom), so flip with (1 - y).
        let scale = Double(LiveUIConstants.scaleFactor)
        func scaled(_ v: CGFloat) -> Double { 0.5 + (Double(v) - 0.5) * scale }

        let checks: [(String, Double, Double)] = [
            ("Back top left",      scaled(LiveUIConstants.backLeftX),         1 - scaled(LiveUIConstants.backRimY)),
            ("Back top right",     scaled(LiveUIConstants.backRightX),        1 - scaled(LiveUIConstants.backRimY)),
            ("Front top left",     scaled(LiveUIConstants.frontTopLeftX),     1 - scaled(LiveUIConstants.frontRimY)),
            ("Front top right",    scaled(LiveUIConstants.frontTopRightX),    1 - scaled(LiveUIConstants.frontRimY)),
            ("Front bottom left",  scaled(LiveUIConstants.frontBottomLeftX),  1 - scaled(LiveUIConstants.bottomY)),
            ("Front bottom right", scaled(LiveUIConstants.frontBottomRightX), 1 - scaled(LiveUIConstants.bottomY)),
        ]

        return checks.allSatisfy { name, gx, gy in
            let loc = box[name].location
            let dx = Double(loc.x) - gx
            let dy = Double(loc.y) - gy
            return (dx * dx + dy * dy).squareRoot() < LiveUIConstants.offTolerant
        }
    }
}
