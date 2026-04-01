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

struct BlockObservation: BoundingBoxProviding {
    let confidence: Float
    var boundingBox: NormalizedRect
}

nonisolated fileprivate let INPUTSIZE = CGSize(width: 640, height: 640)

struct BlockDetector {
    
    static func createBlockDetectionRequest() -> CoreMLRequest {
        guard let model = try? epoch10() else {
            fatalError("Fail to load Block Detection Model")
        }
        
        guard let modelContainer = try? CoreMLModelContainer(model: model.model) else {
            fatalError("Faile to create CoreMLModelContainer for block detector")
        }
        
        return CoreMLRequest(model: modelContainer)
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

#Playground {
    let model = try? epoch10()
    
    let modelContainer = try? CoreMLModelContainer(model: model!.model)
    
    let url = Bundle.main.url(forResource: "IMG_2956", withExtension: "png")!
    let request = CoreMLRequest(model: modelContainer!)
    
    let results = try await request.perform(on: url)
    
    print(type(of: results))
//  print Array<visionObservation>
    print(results.count)
    // 2
    print(type(of: results.first!))
    // CoreMLFeatureValueObservation
    let observation = results as? [CoreMLFeatureValueObservation]
    // print nil
    
    let array: MLShapedArray<Float> = (observation?.first?.featureValue.shapedArrayValue(of: Float.self))!
    
    let shape = array.shape
    
    let betterShaped = array.squeezingShape()
    print(betterShaped.shape)
    
}
