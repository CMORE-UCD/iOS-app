//
// TargetZone.swift
// CMORE
//
// Created by QUYEN TAN on 10/9/26.
//
import Vision

nonisolated struct TargetZone: Codable, Sendable { // check codable interface for required methods
    var topLeft: NormalizedPoint = NormalizedPoint(x: 0, y: 0)
    var topRight: NormalizedPoint = NormalizedPoint(x: 0, y: 0)
    var bottomRight: NormalizedPoint = NormalizedPoint(x: 0, y: 0)
    var bottomLeft: NormalizedPoint = NormalizedPoint(x: 0, y: 0)
    
    init(box: BoxDetection, handedness: HumanHandPoseObservation.Chirality) {
        let topLeft = box["Back top left"].location
        let topRight = box["Back top right"].location
        let bottomLeft = box["Front top left"].location
        let bottomRight = box["Front top right"].location
        let boxFrontMiddle = box["Front top middle"].location
        let split = calculateSplit(box: box, topLeft: topLeft, topRight: topRight)
        
        if handedness == .left {
            self.topLeft = topLeft
            self.bottomLeft = bottomLeft
            self.topRight = split
            self.bottomRight = boxFrontMiddle
        } else { // defaults to handedness right
            self.topLeft = split
            self.bottomLeft = boxFrontMiddle
            self.topRight = topRight
            self.bottomRight = bottomRight
        }
    }
}

private func calculateSplit(box: BoxDetection, topLeft: NormalizedPoint, topRight: NormalizedPoint) -> NormalizedPoint {
    let divider = box["Back divider top"].location
    let dx = topRight.x - topLeft.x
    let t = abs(dx) > .ulpOfOne ? (divider.x - topLeft.x) / dx : 0

    return NormalizedPoint(
        x: topLeft.x + t * (topRight.x - topLeft.x),
        y: topLeft.y + t * (topRight.y - topLeft.y)
    )   
}
