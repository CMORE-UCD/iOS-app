//
//  Counter.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 5/12/26.
//

import Vision

struct Counter {
    let handedness: HumanHandPoseObservation.Chirality

    var state: BlockCountingState
    var blockCounts: Int
    var box: BoxDetection
    var results: [FrameResult]
    
    mutating func update(with detection: FrameResult) -> FrameResult {
        let result: FrameResult
        defer {
            results.append(result)
        }
        
        
        if detection.boxDetection != nil {
            box = detection.boxDetection!
        }
        let hands = detection.hands?.filter { $0.chirality == handedness } ?? []
        state = state.transition(by: hands, box, detection.blockDetections)
        
        result = FrameResult(
            presentationTime: detection.presentationTime,
            state: state,
            blockTransfered: blockCounts,
            hands: detection.hands,
            blockDetections: detection.blockDetections
        )
        return result
    }
}
