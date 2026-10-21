//
//  StreamViewModelTests.swift
//  CMORETests
//

import Testing
import Foundation
import CoreImage
import AVFoundation
import Vision
@testable import CMORE

/// Stands in for the real camera: writes an empty movie file and emits blank frames on demand.
final class FakeCamera: CameraManaging, @unchecked Sendable {
    var captureSession: AVCaptureSession? { nil }
    private(set) var frameStream: AsyncStream<(CIImage, CMTime)>?
    var onRecordingFinished: (@Sendable (URL, Error?) -> Void)?
    var onRecordingStarted: (@Sendable (CMTime) -> Void)?

    private var frameContinuation: AsyncStream<(CIImage, CMTime)>.Continuation?
    private var recordingURL: URL?
    private var frameTime = CMTime.zero
    private let blankFrame = CIImage(color: .black)
        .cropped(to: CGRect(origin: .zero, size: CameraSettings.resolution))

    func setup() {}

    func start() async {
        let (stream, continuation) = AsyncStream.makeStream(of: (CIImage, CMTime).self)
        frameStream = stream
        frameContinuation = continuation
    }

    func stop() {
        frameContinuation?.finish()
        frameContinuation = nil
        frameStream = nil
    }

    func startRecording(to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        recordingURL = url
        onRecordingStarted?(frameTime)
    }

    func stopRecording() {
        guard let url = recordingURL else { return }
        recordingURL = nil
        onRecordingFinished?(url, nil)
    }

    func emitFrame() {
        frameTime = frameTime + CMTime(value: 1, timescale: 30)
        frameContinuation?.yield((blankFrame, frameTime))
    }
}

@MainActor
@Suite("Stream View Model", .serialized)
struct StreamViewModelTests {

    private struct TimedOut: Error { let what: String }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func kp(_ x: CGFloat, _ y: CGFloat) -> Keypoint {
        Keypoint(confidence: 1, location: NormalizedPoint(x: x, y: y))
    }

    private var box: BoxDetection {
        BoxDetection(
            centerX: 0, centerY: 0, width: 0, height: 0, objectConf: 1,
            frontTopLeft: kp(0.20, 0.30), frontBottomLeft: kp(0.20, 0.10),
            frontTopMiddle: kp(0.50, 0.28), frontBottomMiddle: kp(0.50, 0.08),
            frontTopRight: kp(0.80, 0.32), frontBottomRight: kp(0.80, 0.12),
            backDividerTop: kp(0.51, 0.61), frontDividerTop: kp(0.50, 0.40),
            backTopLeft: kp(0.30, 0.62), backTopRight: kp(0.72, 0.60)
        )
    }

    /// Runs countdown → record a few frames → stop, leaving the view model at the save prompt
    private func record(with viewModel: StreamViewModel, camera: FakeCamera, nameRequest: String?) async throws {
        await viewModel.startCamera()
        viewModel.overlay = FrameResult(presentationTime: .zero, boxDetection: box)

        viewModel.startRecording(nameRequest: nameRequest)
        try await waitUntil("recording starts") { viewModel.isRecording }

        for _ in 0..<10 {
            camera.emitFrame()
            try await Task.sleep(for: .milliseconds(50))
        }

        viewModel.toggleRecording()
        try await waitUntil("save prompt with results") {
            viewModel.showSaveConfirmation && !(viewModel.result ?? []).isEmpty
        }
    }

    /// Saves, waits for the session to land in the store, then removes it and its files
    private func saveAndFetch(_ viewModel: StreamViewModel, nameRequest: String? = nil) async throws -> (name: String, videoFileName: String, resultsFileName: String) {
        let existing = Set(try await SessionStore.shared.loadAll().map(\.id))
        viewModel.saveSession(nameRequest: nameRequest)
        try await waitUntil("session saved") { viewModel.shouldDismissCamera }

        let session = try #require(try await SessionStore.shared.loadAll().first { !existing.contains($0.id) })
        let saved = (session.name, session.videoFileName, session.resultsFileName)
        try await SessionStore.shared.delete(session.id)
        return saved
    }

    @Test("Name chosen before recording survives a plain Save")
    func nameFromStartIsKeptOnPlainSave() async throws {
        let camera = FakeCamera()
        let viewModel = StreamViewModel(cameraManager: camera)
        let name = "Test_\(UUID().uuidString)"

        try await record(with: viewModel, camera: camera, nameRequest: name)
        let saved = try await saveAndFetch(viewModel)

        #expect(saved.name == name)
        #expect(saved.videoFileName == "\(name).mov")
        #expect(saved.resultsFileName == "\(name).json")
    }

    @Test("Unnamed recording saves with an empty session name and JSON results")
    func unnamedRecordingSavesWithEmptyName() async throws {
        let camera = FakeCamera()
        let viewModel = StreamViewModel(cameraManager: camera)

        try await record(with: viewModel, camera: camera, nameRequest: nil)
        let saved = try await saveAndFetch(viewModel)

        #expect(saved.name.isEmpty)
        #expect(saved.resultsFileName.hasSuffix(".json"))
    }

    @Test("Name check rejects names whose cleaned-up video or results file already exists",
          arguments: ["mov", "json"])
    func checkExistUsesCleanedNameAndBothFiles(existingExtension: String) throws {
        let viewModel = StreamViewModel(cameraManager: FakeCamera())
        let base = "Test_\(UUID().uuidString)"
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let existing = documentsDir.appendingPathComponent("\(base)-a.\(existingExtension)")
        FileManager.default.createFile(atPath: existing.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: existing) }

        // " name/a " cleans up to "name-a", which is taken
        #expect(viewModel.checkExist(fileName: " \(base)/a ") == nil)
        #expect(viewModel.checkExist(fileName: " \(base)/b ") == "\(base)-b")
    }
}
