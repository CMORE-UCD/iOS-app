//
//  AttemptStateTests.swift
//  CMORETests
//

import Testing
import Foundation
@testable import CMORE

@Suite("Attempt State")
struct AttemptStateTests {
    let blockA = UUID()
    let blockB = UUID()

    /// 40x40 px block at x (moving 20 px = 0.5x its size, above `movementThreshold`).
    private func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 100, width: 40, height: 40) }

    /// One frame: the hand position plus the blocks seen in the target zone.
    private typealias Frame = (hand: HandPosition, blocks: [UUID: CGRect])

    /// Feeds frames to a fresh state and registry; returns per-frame counted flags and the crossing count.
    private func run(_ frames: [Frame]) -> (counted: [Bool], crosses: Int) {
        var crosses = 0
        var state = AttemptState(onCross: { crosses += 1 })
        var registry = TargetBlockRegistry()
        let counted = frames.map { frame in
            registry.record(frame.blocks)
            return state.countsBlock(handAt: frame.hand, registry: &registry)
        }
        return (counted, crosses)
    }

    @Test("A block moving in the target zone counts once and locks the attempt")
    func countsAndLocks() {
        var state = AttemptState()
        var registry = TargetBlockRegistry()
        registry.record([blockA: box(100)])
        #expect(!state.countsBlock(handAt: .crossed, registry: &registry))
        registry.record([blockA: box(120)])
        #expect(state.countsBlock(handAt: .crossed, registry: &registry))
        #expect(state.phase == .awaitingHandReturn)
    }

    @Test("A second block moving in the same attempt is not counted")
    func lockedWithinAttempt() {
        let result = run([
            (.crossed, [blockA: box(100)]),
            (.crossed, [blockA: box(120)]),                       // A counts
            (.crossed, [blockA: box(120), blockB: box(300)]),
            (.crossed, [blockA: box(120), blockB: box(320)]),     // B moves, still locked
        ])
        #expect(result.counted == [false, true, false, false])
    }

    @Test("Hand going back and crossing over again unlocks on the crossing frame")
    func unlocksOnCrossBack() {
        let result = run([
            (.crossed, [blockA: box(100)]),
            (.crossed, [blockA: box(120)]),       // A counts
            (.notCrossed, [:]),
            (.crossed, [blockB: box(300)]),
            (.crossed, [blockB: box(320)]),       // new attempt, B counts
        ])
        #expect(result.counted == [false, true, false, false, true])
    }

    @Test("A block that moved while locked can still count on the next attempt")
    func movementWhileLockedIsNotUsedUp() {
        let result = run([
            (.crossed, [blockA: box(100)]),
            (.crossed, [blockA: box(120)]),                       // A counts
            (.crossed, [blockA: box(120), blockB: box(300)]),
            (.crossed, [blockA: box(120), blockB: box(320)]),     // B moves while locked
            (.notCrossed, [blockB: box(320)]),
            (.crossed, [blockB: box(320)]),                       // unlocked: B's movement is still in history
        ])
        #expect(result.counted == [false, true, false, false, false, true])
    }

    @Test("onCross fires on each move onto the crossed side, including the first")
    func onCrossFiresOnEachCrossing() {
        let result = run([
            (.inital, [:]),
            (.crossed, [:]),
            (.crossed, [:]),
            (.notCrossed, [:]),
            (.crossed, [:]),
        ])
        #expect(result.crosses == 2)
    }
}
