//
//  OverlayView.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 10/2/25.
//
import SwiftUI
import Vision

struct OverlayView: View {
    
    let geometry: GeometryProxy
    let overlay: FrameResult
    let handedness: HumanHandPoseObservation.Chirality?
    
    init(_ overlay: FrameResult, _ geometry: GeometryProxy, _ handedness: HumanHandPoseObservation.Chirality? = nil){
        self.geometry = geometry
        self.overlay = overlay
        self.handedness = handedness
    }
    
    var body: some View {
        if let faces = overlay.faces {
            ForEach(faces.indices, id: \.self) { i in
                BoundingBoxView(geometry, faces[i])
            }
        }
        
        if let boxDetection = overlay.boxDetection {
            BoxView(geometry, boxDetection)
        }
        
        if let hands = overlay.hands {
            ForEach(hands.indices, id: \.self) { i in
                let hand = hands[i]
                let color: Color = (hand.chirality != nil && handedness != hand.chirality) ? .blue : .green
                HandView(geometry, hand, color: color)
            }
        }
        
        if !overlay.blockDetections.isEmpty {
            ForEach(overlay.blockDetections.indices, id: \.self) { i in
                BoundingBoxView(geometry, overlay.blockDetections[i], color: blockColor(for: overlay.blockDetections[i].id))
            }
        }
    }

    private func blockColor(for id: UUID?) -> Color {
        guard let id else { return .red }
        let hue = Double(abs(id.hashValue) % 100) / 100.0
        return Color(hue: hue, saturation: 0.9, brightness: 1.0)
    }
}

struct HandView: View {
    let geo: GeometryProxy
    let hand: HumanHandPoseObservation
    let normalizedPoints: [NormalizedPoint]
    let handColor: Color
    
    init(_ geo: GeometryProxy, _ hand: HumanHandPoseObservation, color: Color = .green) {
        self.geo = geo
        self.hand = hand
        self.handColor = color
        var landMarks: [NormalizedPoint] = []
        
        for joint in hand.allJoints().values {
            landMarks.append(joint.location)
        }
        
        normalizedPoints = landMarks
    }
    
    var body: some View {
        KeypointsView(geo, normalizedPoints, color: handColor)
    }
}

struct BoxView: View {
    let geo: GeometryProxy
    let box: BoxDetection
    
    let normalizedKeypoints: [NormalizedPoint]
    
    init(_ geo: GeometryProxy, _ box: BoxDetection) {
        self.geo = geo
        self.box = box
        self.normalizedKeypoints = box.keypoints.map { $0.location }
    }
    
    var body: some View {
        KeypointsView(geo, normalizedKeypoints)
    }
}
