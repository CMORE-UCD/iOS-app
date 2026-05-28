//
//  FrameProcessorConstants.swift
//  CMORE
//

import Foundation
import AVFoundation

nonisolated enum FrameProcessingThresholds {
    /// Minimum confidence to keep a detected block
    static let blockDetectionConfidenceThreshold: Float = 0.4
    
    /// Minimum confidence to keep a block from tracker
    static let blockTrackedConfidenceThreshold: Float = 0.5

    /// Minimum iou to match
    static let iouThreshold: CGFloat = 0.5

    /// IoU above which an unmatched detection is considered "near" an existing tracker
    /// and therefore suppressed from spawning a duplicate tracker.
    static let trackerVicinityIoUThreshold: CGFloat = 0.2

    /// Maximum frames buffered in the CameraManager's AsyncStream before newest-wins
    static let frameBufferSize: Int = 6
    
    /// Maximum number of image process task processed concurrently
    static let maxConcurrentTasks: Int = 6

    /// Time interval for updating box 
    static let boxUpdateInterval: CMTime = CMTime(value: 1, timescale: 1) // 1 second
}
