//
//  FrameProcessorConstants.swift
//  CMORE
//

import Foundation
import AVFoundation

nonisolated enum FrameProcessingThresholds {
    /// Minimum confidence to keep a detected block
    static let blockConfidenceThreshold: Float = 0.5

    /// Maximum fraction of an ROI covered by the hand ROI before we skip it
    static let roiOverlapThreshold: CGFloat = 0.8

    /// Multiplier on block length for "released" distance
    static let releasedDistanceMultiplier: Double = 1.5

    /// Multiplier on block size for ROI expansion around hand
    static let handBoxExpansionMultiplier: CGFloat = 2.0

    /// Multiplier on block size for ROI centered on a block center (offset = 2x, size = 4x)
    static let blockCenterROIMultiplier: Double = 2.0

    /// Number of recent frames to search for past block detections
    static let recentFrameLookback: Int = 6

    /// Maximum time interval between two hand results for linear projection
    static let maxProjectionInterval: CMTime = CMTime(value: 1, timescale: 2)

    /// Maximum frames buffered in the CameraManager's AsyncStream before newest-wins
    static let frameBufferSize: Int = 6
    
    /// Maximum number of image process task processed concurrently
    static let maxConcurrentTasks: Int = 6
}
