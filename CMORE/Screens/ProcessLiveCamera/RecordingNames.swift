//
//  RecordingNames.swift
//  CMORE
//

import Foundation

/// File names and session name for one recording, derived from the optional user-chosen name.
/// Both the start-of-recording and save paths build names here so the extensions can't drift apart.
struct RecordingNames: Equatable {
    /// User-chosen name; nil means the session falls back to its date in the library
    let customName: String?
    let videoFileName: String
    let resultsFileName: String

    init(customName: String?, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        let baseName = customName ?? "CMORE_Recording_\(String(timestamp))"
        self.customName = customName
        self.videoFileName = "\(baseName).mov"
        self.resultsFileName = "\(baseName).json"
    }

    /// Value stored in `Session.name`; empty tells the library to show the date instead
    var sessionName: String { customName ?? "" }
}
