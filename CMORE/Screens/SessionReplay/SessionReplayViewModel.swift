//
//  SessionReplayViewModel.swift
//  CMORE
//

@preconcurrency import AVFoundation
import SwiftUI

@MainActor
class SessionReplayViewModel: ObservableObject {
    // MARK: - Published

    @Published var currentFrameResult: FrameResult?
    @Published var currentBlockCount: Int = 0
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0

    // MARK: - Player

    let player: AVPlayer

    // MARK: - Private

    private var frameResults: [FrameResult] = []
    nonisolated(unsafe) private var timeObserverToken: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init(session: Session) {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let videoURL = documentsDir.appendingPathComponent(session.videoFileName)
        let resultsURL = documentsDir.appendingPathComponent(session.resultsFileName)

        self.player = AVPlayer(url: videoURL)

        if let data = try? Data(contentsOf: resultsURL),
           let results = try? JSONDecoder().decode([FrameResult].self, from: data) {
            self.frameResults = results.sorted()
        }

        Task {
            if let duration = try? await player.currentItem?.asset.load(.duration) {
                self.duration = duration.seconds
            }
        }

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                self.updateOverlay(for: time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
            }
        }
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            // If at end, restart from beginning
            if currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        updateOverlay(for: cmTime)
    }

    func skipForward(_ seconds: Double = 5.0) {
        let target = min(currentTime + seconds, duration)
        seek(to: target)
    }

    func skipBackward(_ seconds: Double = 5.0) {
        let target = max(currentTime - seconds, 0)
        seek(to: target)
    }

    // MARK: - Frame Lookup (Binary Search)

    private func updateOverlay(for time: CMTime) {
        let seconds = time.seconds
        guard !frameResults.isEmpty else { return }

        var lo = 0
        var hi = frameResults.count - 1
        var bestIndex = 0

        while lo <= hi {
            let mid = (lo + hi) / 2
            let midTime = frameResults[mid].presentationTime.seconds
            if midTime <= seconds {
                bestIndex = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        currentFrameResult = frameResults[bestIndex]
        currentBlockCount = frameResults[bestIndex].blockTransfered ?? 0
    }
}
