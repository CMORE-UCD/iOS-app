//
// TargetZone.swift
// CMORE
//
// Created by QUYEN TAN on 10/9/26.
//
import Vision

nonisolated struct TargetZone: Codable, Sendable {
    var targetpoints: [Targetpoint] = []
    
    enum CodingKeys: String, CodingKey {
        case targetpoints
    }

    private let targetpointNames: [String] = ["topLeft", "topRight", "bottomRight", "bottomLeft"]

    subscript(name: String) -> Targetpoint {
        get {
            let idx = targetpointNames.firstIndex(of: name)!
            return targetpoints[idx]
        }
        set {
            let idx = targetpointNames.firstIndex(of: name)!
            targetpoints[idx] = newValue
        }
    }

    mutating func updateTargetZone(box: BoxDetection, handedness: HumanHandPoseObservation.Chirality) {
        if targetpoints.isEmpty {
            let emptyPoint = NormalizedPoint(x: 0, y: 0)
            targetpoints = (0..<4).map { _ in Targetpoint(position: emptyPoint) }
        }

        let topLeft = box["Back top left"].location
        let topRight = box["Back top right"].location
        let bottomLeft = box["Front top left"].location
        let bottomRight = box["Front top right"].location
        let boxFrontMiddle = box["Front top middle"].location
        let split = calculateSplit(box: box, topLeft: topLeft, topRight: topRight)
        
        if handedness == .left {
            self["topLeft"].location = topLeft
            self["bottomLeft"].location = bottomLeft
            self["topRight"].location = split
            self["bottomRight"].location = boxFrontMiddle
        } else { // defaults to handedness right
            self["topLeft"].location = topLeft
            self["bottomLeft"].location = boxFrontMiddle
            self["topRight"].location = split
            self["bottomRight"].location = bottomRight
        }
    }
}

struct Targetpoint: Codable {
    var location: NormalizedPoint

    init(position: NormalizedPoint) {
        self.location = position
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
