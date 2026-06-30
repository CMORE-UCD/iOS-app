//
//  CMORECLICommand.swift
//  CMORECLI
//

import ArgumentParser
import Foundation
import CoreMedia

@main
struct Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "CMORECLI",
        abstract: "Process a video and save block-count results as JSON."
    )

    @Argument(help: "Path to the input video file.")
    var videoPath: String

    @Argument(help: "Output path for the JSON results. Defaults to CMORE_Results_<video_name>.json in the current directory.")
    var outputPath: String?

    mutating func run() async throws {
        let videoURL = URL(fileURLWithPath: videoPath)

        guard FileManager.default.fileExists(atPath: videoPath) else {
            throw ValidationError("No file found at \(videoPath)")
        }

        let outputURL: URL = outputPath.map { URL(fileURLWithPath: $0) } ?? {
            let stem = videoURL.deletingPathExtension().lastPathComponent
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("CMORE_Results_\(stem).json")
        }()

        let pipeline = VideoPipeline(videoURL: videoURL)

        guard let results = await pipeline.run(), !results.isEmpty else {
            throw ValidationError("Processing failed or produced no results.")
        }

        let blockCount = results.last?.blockTransfered ?? 0
        let firstTime = results.first?.presentationTime ?? .zero
        let normalized = results.map { frame in
            var tmp = frame
            tmp.presentationTime = tmp.presentationTime - firstTime
            return tmp
        }

        let data = try JSONEncoder().encode(normalized)
        try data.write(to: outputURL)
        print("Block count: \(blockCount)")
        print("Saved to: \(outputURL.path)")
    }
}
