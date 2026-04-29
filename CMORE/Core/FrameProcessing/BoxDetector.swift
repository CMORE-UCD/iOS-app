//
//  BoxDetector.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 9/1/25.
//
import CoreML
import Vision

nonisolated fileprivate let INPUTSIZE = CGSize(width: 640, height: 640)

// MARK: - BoxDetector
/// Claude generated
struct BoxDetector {
    static func createBoxDetectionRequest() -> CoreMLRequest {
        let model = try? KeypointDetector()
        
        guard let boxDetector = model else {
            fatalError("Failed to load KeypointDetector model")
        }
        
        guard let boxDetectorContainer = try? CoreMLModelContainer(model: boxDetector.model) else {
            fatalError("Failed to convert KeypointDetector model to MLModelContainer")
        }
        
        var request = CoreMLRequest(model: boxDetectorContainer)
        request.cropAndScaleAction = .scaleToFit
        
        return request
    }
    
    
    /// Processes the raw model output to extract keypoints
    static func processKeypointOutput(_ shapedArray: MLShapedArray<Float>, confThresh objectConfThreshold: Float = 0.2, IOUThreshold: Float = 0.5) -> BoxDetection? {
        // Following YOLO pose format:
        // Output shape: (1 × 35 × 5376) -> transpose to (1 × 5376 × 35)
        // Format: [x_center, y_center, width, height, class_conf, kpt1_x, kpt1_y, kpt1_conf, ...]
        
        let numAnchors = shapedArray.shape[2] // 5376
        let numChannels = shapedArray.shape[1] // 35
        let numKeypoints = (numChannels - 5) / 3
        
        var allDetections: [BoxDetection] = []
        
        // Process each anchor
        for anchorIdx in 0..<numAnchors {
            var detection = BoxDetection()
            
            // Extract bounding box info (first 5 channels)
            detection.centerX = shapedArray[scalarAt: [0, 0, anchorIdx]]
            detection.centerY = shapedArray[scalarAt: [0, 1, anchorIdx]]
            detection.width = shapedArray[scalarAt: [0, 2, anchorIdx]]
            detection.height = shapedArray[scalarAt: [0, 3, anchorIdx]]
            detection.objectConf = shapedArray[scalarAt: [0, 4, anchorIdx]]
            
            // Skip low confidence detections
            if detection.objectConf < objectConfThreshold {
                continue
            }
            
            // Extract keypoints (channels 5-34)
            var keypoints: [Keypoint] = []
            for kptIdx in 0..<numKeypoints {
                let baseChannelIdx = 5 + kptIdx * 3
                
                let x = shapedArray[scalarAt: [0, baseChannelIdx, anchorIdx]]
                let y = shapedArray[scalarAt: [0, baseChannelIdx + 1, anchorIdx]]
                let conf = shapedArray[scalarAt: [0, baseChannelIdx + 2, anchorIdx]]
                keypoints.append(
                    Keypoint(confidence: conf, position: SIMD2<Float>(x, y))
                )
            }
            detection.keypoints = keypoints
            allDetections.append(detection)
        }
        
        // Apply Non-Maximum Suppression
        let filteredDetections = applyNMS(detections: allDetections, iouThreshold: IOUThreshold)
        
        // Return keypoints from the best detection
        if var bestDetection = filteredDetections.first {
            
            
            // Normalize the results before returning it
            for idx in bestDetection.keypoints.indices {
                restoreCoordinatesFromScaleToFit(&bestDetection.keypoints[idx])
            }
            return bestDetection
        }
        
        return nil
    }
    
    static func restoreCoordinatesFromScaleToFit(_ keypoint: inout Keypoint, modelInputSize : CGSize = INPUTSIZE, OriginalImageSize: CGSize = CameraSettings.resolution) {
        
        // Vision scale longest side to input size
        let scale = min(modelInputSize.width / OriginalImageSize.width, modelInputSize.height/OriginalImageSize.height)
        
        // Calculate the padding
        let scaledWidth = OriginalImageSize.width * scale
        let scaledHeight = OriginalImageSize.height * scale
        let paddingX = (modelInputSize.width - scaledWidth) / 2.0
        let paddingY = (modelInputSize.height - scaledHeight) / 2.0
        
        // Restore the coordinates
        keypoint.position.x = (keypoint.position.x - Float(paddingX)) / Float(scale)
        keypoint.position.y = ((Float(modelInputSize.height) - keypoint.position.y - Float(paddingY))) / Float(scale) // invert y for vision
    }
    
    // MARK: - Private
    
    /// Applies Non-Maximum Suppression to filter overlapping detections
    private static func applyNMS(detections: [BoxDetection], iouThreshold: Float) -> [BoxDetection] {
        let sortedDetections = detections.sorted { $0.objectConf > $1.objectConf }
        var filtered: [BoxDetection] = []
        
        for detection in sortedDetections {
            var shouldKeep = true
            
            for existingDetection in filtered {
                if calculateIoU(detection1: detection, detection2: existingDetection) > iouThreshold {
                    shouldKeep = false
                    break
                }
            }
            
            if shouldKeep {
                filtered.append(detection)
            }
        }
        
        return filtered
    }
    
    /// Calculates Intersection over Union (IoU) between two detections
    private static func calculateIoU(detection1: BoxDetection, detection2: BoxDetection) -> Float {
        // Convert center coordinates to corner coordinates
        let x1_min = detection1.centerX - detection1.width / 2
        let y1_min = detection1.centerY - detection1.height / 2
        let x1_max = detection1.centerX + detection1.width / 2
        let y1_max = detection1.centerY + detection1.height / 2
        
        let x2_min = detection2.centerX - detection2.width / 2
        let y2_min = detection2.centerY - detection2.height / 2
        let x2_max = detection2.centerX + detection2.width / 2
        let y2_max = detection2.centerY + detection2.height / 2
        
        // Calculate intersection
        let intersectionXMin = max(x1_min, x2_min)
        let intersectionYMin = max(y1_min, y2_min)
        let intersectionXMax = min(x1_max, x2_max)
        let intersectionYMax = min(y1_max, y2_max)
        
        let intersectionArea = max(0, intersectionXMax - intersectionXMin) * max(0, intersectionYMax - intersectionYMin)
        
        // Calculate union
        let area1 = detection1.width * detection1.height
        let area2 = detection2.width * detection2.height
        let unionArea = area1 + area2 - intersectionArea
        
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }
}

// MARK: - Supporting Structures

nonisolated struct BoxDetection: Codable, Sendable {
    var centerX: Float = 0
    var centerY: Float = 0
    var width: Float = 0
    var height: Float = 0
    var objectConf: Float = 0
    var keypoints: [Keypoint] = []
    
    var cmPerPixel: Double {
        let dividerHeight: Double = 10.0 // cm
        let keypointHeight = // px
        distance(self["Front divider top"].position, self["Front top middle"].position)
        
        return dividerHeight / Double(keypointHeight)
    }
    
    // Control which properties get saved
    enum CodingKeys: String, CodingKey {
        case centerX
        case centerY
        case width
        case height
        case objectConf
        case keypoints
    }
    
    private let keypointNames: [String] = ["Front top left", "Front bottom left", "Front top middle", "Front bottom middle", "Front top right", "Front bottom right", "Back divider top", "Front divider top", "Back top left", "Back top right"]
    
    subscript(name: String) -> Keypoint {
        let idx = keypointNames.firstIndex(of: name)!
        return keypoints[idx]
    }
    
    func normalizedKeypoint(for name: String) -> NormalizedPoint{
        return NormalizedPoint(
            x: CGFloat(self[name].position.x) / CameraSettings.resolution.width,
            y: CGFloat(self[name].position.y) / CameraSettings.resolution.height
        )
    }
}

struct Keypoint: Codable {
    let confidence: Float
    var position: SIMD2<Float>
}
