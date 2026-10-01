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
            TargetZoneView(geometry, boxDetection)
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

struct TargetZoneView: View {
    let geo: GeometryProxy
    let box: BoxDetection

    init(_ geo: GeometryProxy, _ box: BoxDetection) {
        self.geo = geo
        self.box = box
    }

    var body: some View {
        let targetPolygon = targetZonePolygon()

        return Group {
            if !targetPolygon.isEmpty {
                Path { path in
                    path.move(to: targetPolygon[0])
                    for point in targetPolygon.dropFirst() {
                        path.addLine(to: point)
                    }
                    path.closeSubpath()
                }
                .stroke(Color.yellow, lineWidth: 3)
            }
        }
    }

    private func targetZonePolygon() -> [CGPoint] {
        let orderedKeys = ["topLeft", "bottomLeft", "bottomRight", "topRight"]
        var polygon: [CGPoint] = []

        for key in orderedKeys {
            guard let point = box.targetZone[key] else { return [] }
            polygon.append(
                CGPoint(
                    x: CGFloat(point.x) / CameraSettings.resolution.width * geo.size.width,
                    y: (1 - CGFloat(point.y) / CameraSettings.resolution.height) * geo.size.height
                )
            )
        }

        return polygon
    }
}
