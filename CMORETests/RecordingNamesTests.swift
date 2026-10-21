//
//  RecordingNamesTests.swift
//  CMORETests
//

import Testing
@testable import CMORE

@Suite("Recording Names")
struct RecordingNamesTests {

    @Test("Custom name drives video, results and session name")
    func customName() {
        let names = RecordingNames(customName: "Trial 1")
        #expect(names.videoFileName == "Trial 1.mov")
        #expect(names.resultsFileName == "Trial 1.json")
        #expect(names.sessionName == "Trial 1")
    }

    @Test("Default name shares one timestamp and leaves session name empty")
    func defaultName() {
        let names = RecordingNames(customName: nil, timestamp: 1_700_000_000.5)
        #expect(names.videoFileName == "CMORE_Recording_1700000000.5.mov")
        #expect(names.resultsFileName == "CMORE_Recording_1700000000.5.json")
        #expect(names.sessionName.isEmpty)
    }

    @Test("Results are always JSON and match the video's base name", arguments: ["Trial 1", nil])
    func resultsMatchVideo(customName: String?) {
        let names = RecordingNames(customName: customName)
        #expect(names.resultsFileName.hasSuffix(".json"))
        #expect(names.videoFileName.dropLast(".mov".count) == names.resultsFileName.dropLast(".json".count))
    }
}
