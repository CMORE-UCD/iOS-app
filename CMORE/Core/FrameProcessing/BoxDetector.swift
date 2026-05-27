//
//  BoxDetector.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 9/1/25.
//
import CoreML
import Vision
import CoreImage

nonisolated fileprivate let INPUTSIZE = CGSize(width: 640, height: 640)

nonisolated struct BoxDetection: Codable, Sendable {
    var centerX: Float = 0
    var centerY: Float = 0
    var width: Float = 0
    var height: Float = 0
    var objectConf: Float = 0
    var keypoints: [Keypoint] = []
    
    func cmPerPixel(in size: CGSize) -> Double {
        let dividerHeight: Double = 10.0 // cm
        let keypointHeight = distance( // px
            pixelPosition(of: "Front divider top", in: size),
            pixelPosition(of: "Front top middle", in: size)
        )

        return dividerHeight / Double(keypointHeight)
    }

    func dividerX(in size: CGSize) -> (Float) -> Float {
        let frontTopDivider = pixelPosition(of: "Front divider top", in: size)
        let bottomDivider = pixelPosition(of: "Front top middle", in: size)
        let backTopDivider = pixelPosition(of: "Back divider top", in: size)

        return { y in
            let start: SIMD2<Float>
            let end: SIMD2<Float>

            if y <= frontTopDivider.y {
                // Case A: Bottom Section
                start = frontTopDivider
                end = bottomDivider
            }
            else if y >= backTopDivider.y {
                // Case B: Top Section (Parallel Projection)
                // Vector Math: Calculate direction (B - A) and add to C
                // No manual loops needed; SIMD handles the subtraction/addition.
                let direction = bottomDivider - frontTopDivider

                start = backTopDivider
                end = backTopDivider + direction
            }
            else {
                // Case C: Middle Section
                start = frontTopDivider
                end = backTopDivider
            }

            // 2. Solve for X
            // Calculate vertical progress 't' (0.0 to 1.0)
            let dy = end.y - start.y

            // Safety: Avoid division by zero
            guard abs(dy) > .leastNormalMagnitude else { return start.x }

            let t = (y - start.y) / dy

            // 3. Built-in Interpolation
            // simd_mix(a, b, t) is the hardware-optimized version of "a + (b - a) * t"
            return simd_mix(start.x, end.x, t)
        }
    }

    // Control which properties get saved
    enum CodingKeys: String, CodingKey {
        case objectConf
        case keypoints
    }

    private let keypointNames: [String] = ["Front top left", "Front bottom left", "Front top middle", "Front bottom middle", "Front top right", "Front bottom right", "Back divider top", "Front divider top", "Back top left", "Back top right"]

    subscript(name: String) -> Keypoint {
        let idx = keypointNames.firstIndex(of: name)!
        return keypoints[idx]
    }

    /// Denormalizes a named keypoint into pixel coordinates for the given image size.
    func pixelPosition(of name: String, in size: CGSize) -> SIMD2<Float> {
        let p = self[name].location
        return SIMD2<Float>(Float(p.x * size.width), Float(p.y * size.height))
    }

    /// Line through the two front-top corners. Returns the line's y in pixel space
    /// for a given x. Used to gate "is this hand inside the counting region?".
    func frontTopLineY(in size: CGSize) -> (Float) -> Float {
        let left = pixelPosition(of: "Front top left", in: size)
        let right = pixelPosition(of: "Front top right", in: size)
        return { x in
            let dx = right.x - left.x
            guard abs(dx) > .leastNormalMagnitude else { return left.y }
            let t = (x - left.x) / dx
            return simd_mix(left.y, right.y, t)
        }
    }
}

struct Keypoint: Codable {
    let confidence: Float
    var location: NormalizedPoint

    init(confidence: Float, position: NormalizedPoint) {
        self.confidence = confidence
        self.location = position
    }
}

// MARK: - BoxDetector
struct BoxDetector {
    private let request: CoreMLRequest

    init() {
        guard let model = try? KeypointDetector() else {
            fatalError("Failed to load KeypointDetector model")
        }
        guard let modelContainer = try? CoreMLModelContainer(model: model.model) else {
            fatalError("Failed to convert KeypointDetector model to MLModelContainer")
        }
        var req = CoreMLRequest(model: modelContainer)
        req.cropAndScaleAction = .scaleToFit
        self.request = req
    }

    func detect(on image: CIImage) async -> BoxDetection? {
        guard let obs = try? await request.perform(on: image) else { return nil }
        guard let shapedArray = (obs as! [CoreMLFeatureValueObservation]).first?
            .featureValue.shapedArrayValue(of: Float.self) else { return nil }
        return BoxDetector.processKeypointOutput(shapedArray, originalImageSize: image.extent.size)
    }

    /// Processes the raw model output to extract keypoints
    static func processKeypointOutput(_ shapedArray: MLShapedArray<Float>, confThresh objectConfThreshold: Float = 0.2, IOUThreshold: Float = 0.5, originalImageSize: CGSize = CameraSettings.resolution) -> BoxDetection? {
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
                let normalized = normalizedPointFromScaleToFit(
                    SIMD2<Float>(x, y),
                    originalImageSize: originalImageSize
                )
                keypoints.append(Keypoint(confidence: conf, position: normalized))
            }
            detection.keypoints = keypoints
            allDetections.append(detection)
        }

        // Apply Non-Maximum Suppression (operates on centerX/Y/W/H in raw model space)
        let filteredDetections = applyNMS(detections: allDetections, iouThreshold: IOUThreshold)

        return filteredDetections.first
    }

    /// Converts a YOLO model-space position (inside a letterboxed `modelInputSize` buffer
    /// produced by `.scaleToFit`) to a `NormalizedPoint` in the original image, using
    /// Vision's Y-up convention.
    static func normalizedPointFromScaleToFit(_ modelPos: SIMD2<Float>, modelInputSize: CGSize = INPUTSIZE, originalImageSize: CGSize) -> NormalizedPoint {

        // Vision scales the longest side to the input size and letterboxes the rest.
        let scale = min(modelInputSize.width / originalImageSize.width, modelInputSize.height / originalImageSize.height)

        let scaledWidth = originalImageSize.width * scale
        let scaledHeight = originalImageSize.height * scale
        let paddingX = (modelInputSize.width - scaledWidth) / 2.0
        let paddingY = (modelInputSize.height - scaledHeight) / 2.0

        // Strip the letterbox padding, then normalize by the un-padded region.
        // Y is flipped so 0 = bottom (Vision convention).
        let nx = (CGFloat(modelPos.x) - paddingX) / scaledWidth
        let ny = (modelInputSize.height - CGFloat(modelPos.y) - paddingY) / scaledHeight
        return NormalizedPoint(x: nx, y: ny)
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
