//
//  Session.swift
//  CMORE
//

import Foundation
import SwiftData
import Vision

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var date: Date
    var blockCount: Int
    var videoFileName: String
    var resultsFileName: String
    var handedness: HumanHandPoseObservation.Chirality

    init(id: UUID = UUID(), date: Date, blockCount: Int, videoFileName: String, resultsFileName: String, handedness: HumanHandPoseObservation.Chirality) {
        self.id = id
        self.date = date
        self.blockCount = blockCount
        self.videoFileName = videoFileName
        self.resultsFileName = resultsFileName
        self.handedness = handedness
    }
}
