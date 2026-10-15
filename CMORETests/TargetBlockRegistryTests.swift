//
//  TargetBlockRegistryTests.swift
//  CMORETests
//

import Testing
import Foundation
@testable import CMORE

@Suite("Target Block Registry")
struct TargetBlockRegistryTests {
    let id = UUID()

    /// 40x40 px block at x (moving 20 px = 0.5x its size, above `movementThreshold`).
    private func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 100, width: 40, height: 40) }

    /// Feeds one frame per entry to a fresh registry and returns `hasMovement` for each frame.
    private func run(_ frames: [[UUID: CGRect]]) -> [Bool] {
        var registry = TargetBlockRegistry()
        return frames.map { registry.hasMovement($0) }
    }

    @Test func needsTwoFramesAndMovement() {
        #expect(run([[id: box(100)], [id: box(120)]]) == [false, true])
    }

    @Test func stillBlockNotCounted() {
        #expect(run([[id: box(100)], [id: box(101)]]) == [false, false])
    }

    @Test func countedOnlyOnce() {
        #expect(run([[id: box(100)], [id: box(120)], [id: box(140)]]) == [false, true, false])
    }

    @Test("Gap of one frame is bridged; not counted on the missing frame")
    func bridgesGap() {
        #expect(run([[id: box(100)], [:], [id: box(120)]]) == [false, false, true])
    }

    @Test("Custom history length: gap longer than the window drops history")
    func customHistoryLength() {
        var registry = TargetBlockRegistry(historyLength: 2)
        let results = [[id: box(100)], [:], [:], [id: box(120)]].map { registry.hasMovement($0) }
        #expect(results == [false, false, false, false])
    }

    @Test("History is dropped after a full window unseen")
    func dropsAfterWindow() {
        let unseen = Array(repeating: [UUID: CGRect](), count: FrameProcessingThresholds.blockHistoryLength)
        // Earlier position is gone, so the last frame is a first sighting again.
        #expect(run([[id: box(100)]] + unseen + [[id: box(120)]]).last == false)
    }
}
