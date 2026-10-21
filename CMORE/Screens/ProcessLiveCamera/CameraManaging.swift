//
//  CameraManaging.swift
//  CMORE
//
//  The camera surface StreamViewModel depends on, so tests can swap in a fake camera.
//

import CoreImage
import AVFoundation

protocol CameraManaging: AnyObject, Sendable {
    /// The camera capture session for the preview; nil when there is no real camera
    var captureSession: AVCaptureSession? { get }

    /// The async stream of camera frames, created when the camera starts
    var frameStream: AsyncStream<(CIImage, CMTime)>? { get }

    /// Called when movie file recording finishes
    var onRecordingFinished: (@Sendable (URL, Error?) -> Void)? { get set }

    /// Called with the timestamp of the first frame actually written to the video file
    var onRecordingStarted: (@Sendable (CMTime) -> Void)? { get set }

    func setup()
    func start() async
    func stop()
    func startRecording(to url: URL)
    func stopRecording()
}
