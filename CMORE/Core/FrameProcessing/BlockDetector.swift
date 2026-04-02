//
//  BlockDetector.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 9/15/25.
//

import CoreML
import Vision
import CoreImage
import Accelerate
import Playgrounds

struct BlockObservation: BoundingBoxProviding, Codable {
    let confidence: Float
    var boundingBox: NormalizedRect
}

nonisolated fileprivate let INPUTSIZE = CGSize(width: 640, height: 640)

struct BlockDetector {

    private let request: CoreMLRequest

    init() {
        guard let model = try? epoch10() else {
            fatalError("Fail to load Block Detection Model")
        }
        guard let modelContainer = try? CoreMLModelContainer(model: model.model) else {
            fatalError("Failed to create CoreMLModelContainer for block detector")
        }
        self.request = CoreMLRequest(model: modelContainer)
    }

    func detect(on image: CIImage) async -> [BlockObservation] {
        guard let obs = try? await request.perform(on: image) else { return [] }
        return BlockDetector.processOutput(obs)
    }

    /// Parses raw CoreML output into block observations that pass the confidence threshold.
    ///
    /// The model outputs a 300x6 matrix where each row is `[x1, y1, x2, y2, conf, class_id]`
    /// with coordinates in pixel space (640x640).
    static func processOutput(
        _ output: [any VisionObservation],
        confThresh: Float = 0.5
    ) -> [BlockObservation] {
        
        let observations = output as! [CoreMLFeatureValueObservation]
        let raw = observations.first!.featureValue.shapedArrayValue(of: Float.self)!
        let detections = raw.squeezingShape().transposed() // 6 x 300
        
        // Extract each field as a flat [Float] for vectorized access
        let x1   = detections[0].scalars
        let y1   = detections[1].scalars
        let x2   = detections[2].scalars
        let y2   = detections[3].scalars
        let conf = detections[4].scalars
        
        // Zero out sub-threshold confidences (vectorized via Accelerate)
        let passed = vDSP.threshold(conf, to: confThresh, with: .zeroFill)
        
        // Build observations only for detections that survived thresholding
        return passed.indices.compactMap { i in
            guard passed[i] > 0 else { return nil }
            
            let pixelRect = CGRect(
                x: CGFloat(x1[i]),
                y: CGFloat(y1[i]),
                width: CGFloat(x2[i] - x1[i]),
                height: CGFloat(y2[i] - y1[i])
            )
            
            return BlockObservation(
                confidence: conf[i],
                boundingBox: NormalizedRect(imageRect: pixelRect, in: INPUTSIZE)
            )
        }
    }
}

// block length 2.5cm or 1in
nonisolated func blockLengthInPixels(scale: Double) -> Double {
    return 2.5 / scale
}
