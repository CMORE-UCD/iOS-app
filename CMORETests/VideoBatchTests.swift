//
//  BlockCountBatchTests.swift
//  CMORETests
//
//  Runs block counting on every video in TestResources and prints results.
//  No assertions — just make sure it doesn't crash.
//  Sessions are kept after the run for review.
//

import Testing
import AVFoundation
@testable import CMORE

private class BatchBundleAnchor {}

@Suite("Video Batch", .timeLimit(.minutes(60)))
struct VideoBatchTests {

    private func allVideoURLs() -> [URL] {
        let bundle = Bundle(for: BatchBundleAnchor.self)
        guard let resourceURL = bundle.resourceURL else { return [] }

        let testResourcesURL = resourceURL.appendingPathComponent("TestResources")
        let extensions: Set<String> = ["MOV", "mov", "mp4", "MP4", "m4v", "M4V"]

        guard let enumerator = FileManager.default.enumerator(
            at: testResourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("Process all videos and print block counts")
    func processAllVideos() async throws {
        // Clear any existing sessions before the run
        let existingSessions = try await SessionStore.shared.loadAll()
        for session in existingSessions {
            try await SessionStore.shared.delete(session)
        }
        print("Cleared \(existingSessions.count) existing session(s)")

        let urls = allVideoURLs()
        print("\n=== Batch Block Count: \(urls.count) video(s) ===\n")

        for url in urls {
            let name = url.lastPathComponent
            print("▶ \(name)")

            let extractor = VideoFrameExtractor(url: url)
            guard await extractor.validate() == nil else {
                print("  skipped (validation failed)\n")
                continue
            }

            let vm = await VideoProcessingViewModel()
            await vm.loadVideo(url: url)
            await vm.startProcessing()

            while await !vm.isDone {
                try await Task.sleep(for: .milliseconds(100))
            }

            let sessions = try await SessionStore.shared.loadAll()
            if let session = sessions.first {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let videoPath = docs.appendingPathComponent(session.videoFileName).path
                let resultsPath = docs.appendingPathComponent(session.resultsFileName).path
                print("  → \(session.blockCount) block(s)")
                print("  video:   \(videoPath)")
                print("  results: \(resultsPath)\n")
            } else {
                print("  → no session saved\n")
            }
            // Sessions intentionally kept for post-run review
        }

        print("=== Done ===\n")
    }
}
