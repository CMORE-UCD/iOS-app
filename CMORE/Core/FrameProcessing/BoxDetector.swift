//
//  BoxDetector.swift
//  CMORE
//
//  Created by ZIQIANG ZHU on 9/1/25.
//
import CoreML
import Vision
import CoreImage
import simd

nonisolated fileprivate let INPUTSIZE = CGSize(width: 640, height: 640)

nonisolated struct BoxDetection: Codable, Sendable {
    let centerX: Float
    let centerY: Float
    let width: Float
    let height: Float
    let objectConf: Float

    // Keypoints, in the order the model outputs them
    let frontTopLeft: Keypoint
    let frontBottomLeft: Keypoint
    let frontTopMiddle: Keypoint
    let frontBottomMiddle: Keypoint
    let frontTopRight: Keypoint
    let frontBottomRight: Keypoint
    let backDividerTop: Keypoint
    let frontDividerTop: Keypoint
    let backTopLeft: Keypoint
    let backTopRight: Keypoint

    /// All keypoints, in the order the model outputs them.
    var keypoints: [Keypoint] {
        [frontTopLeft, frontBottomLeft, frontTopMiddle, frontBottomMiddle, frontTopRight,
         frontBottomRight, backDividerTop, frontDividerTop, backTopLeft, backTopRight]
    }

    func cmPerPixel(in size: CGSize) -> Double {
        let dividerHeight: Double = 10.0 // cm
        let top = point(frontDividerTop, in: size)
        let bottom = point(frontTopMiddle, in: size)
        let keypointHeight = hypot(top.x - bottom.x, top.y - bottom.y) // px

        return dividerHeight / Double(keypointHeight)
    }

    /// Divider's x for a given y. Pass `size` for pixel space; omit it for normalized space.
    func dividerX(in size: CGSize? = nil) -> (Float) -> Float {
        let frontTopDivider = point(frontDividerTop, in: size)
        let bottomDivider = point(frontTopMiddle, in: size)
        let backTopDivider = point(backDividerTop, in: size)

        return { yFloat in
            let y = CGFloat(yFloat)
            let start: CGPoint
            let end: CGPoint

            if y <= frontTopDivider.y {
                // Case A: Bottom Section
                start = frontTopDivider
                end = bottomDivider
            }
            else if y >= backTopDivider.y {
                // Case B: Top Section (Parallel Projection)
                // Calculate direction (B - A) and add to C
                start = backTopDivider
                end = CGPoint(
                    x: backTopDivider.x + (bottomDivider.x - frontTopDivider.x),
                    y: backTopDivider.y + (bottomDivider.y - frontTopDivider.y)
                )
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
            guard abs(dy) > .leastNormalMagnitude else { return Float(start.x) }

            let t = (y - start.y) / dy

            // 3. Interpolate
            return Float(start.x + (end.x - start.x) * t)
        }
    }

    /// Front-top edge's y for a given x. Used to gate "is this hand inside the counting region?".
    /// Pass `size` for pixel space; omit it for normalized space.
    func frontTopLineY(in size: CGSize? = nil) -> (Float) -> Float {
        Self.line(from: point(frontTopLeft, in: size), to: point(frontTopRight, in: size))
    }

    /// Back-top edge's y for a given x. Pass `size` for pixel space; omit it for normalized space.
    func backTopLineY(in size: CGSize? = nil) -> (Float) -> Float {
        Self.line(from: point(backTopLeft, in: size), to: point(backTopRight, in: size))
    }

    /// The keypoint's location in pixels if `size` is given, otherwise as stored (normalized).
    private func point(_ keypoint: Keypoint, in size: CGSize?) -> CGPoint {
        guard let size else { return keypoint.location.cgPoint }
        return keypoint.location.toImageCoordinates(size)
    }

    /// y on the line through `left` and `right` for a given x. Works in any coordinate space.
    private static func line(from left: CGPoint, to right: CGPoint) -> (Float) -> Float {
        { xFloat in
            let x = CGFloat(xFloat)
            let dx = right.x - left.x
            guard abs(dx) > .leastNormalMagnitude else { return Float(left.y) }
            let t = (x - left.x) / dx
            return Float(left.y + (right.y - left.y) * t)
        }
    }

    func targetZone(handedness: HumanHandPoseObservation.Chirality) -> TargetZone {
        let x = backDividerTop.location.x
        let backTopMiddle = Keypoint(
            confidence: backDividerTop.confidence,
            location: NormalizedPoint(x: x, y: CGFloat(backTopLineY()(Float(x))))
        )

        if handedness == .left {
            return TargetZone(
                topLeft: backTopLeft,
                topRight: backTopMiddle,
                bottomRight: frontTopMiddle,
                bottomLeft: frontTopLeft
            )
            
        } else { // defaults to handedness right
            return TargetZone(
                topLeft: backTopMiddle,
                topRight: backTopRight,
                bottomRight: frontTopRight,
                bottomLeft: frontTopMiddle
            )
        }
    }
}

struct Keypoint: Codable {
    let confidence: Float
    let location: NormalizedPoint
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
        return BoxDetector.processKeypointOutput(
            shapedArray,
            originalImageSize: image.extent.size
        )
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
            // Skip low confidence detections (channel 4)
            let objectConf = shapedArray[scalarAt: [0, 4, anchorIdx]]
            if objectConf < objectConfThreshold {
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
                keypoints.append(Keypoint(confidence: conf, location: normalized))
            }
            guard keypoints.count == 10 else { continue }

            // Bounding box info (channels 0-3), keypoints in the order the model outputs them
            allDetections.append(BoxDetection(
                centerX: shapedArray[scalarAt: [0, 0, anchorIdx]],
                centerY: shapedArray[scalarAt: [0, 1, anchorIdx]],
                width: shapedArray[scalarAt: [0, 2, anchorIdx]],
                height: shapedArray[scalarAt: [0, 3, anchorIdx]],
                objectConf: objectConf,
                frontTopLeft: keypoints[0],
                frontBottomLeft: keypoints[1],
                frontTopMiddle: keypoints[2],
                frontBottomMiddle: keypoints[3],
                frontTopRight: keypoints[4],
                frontBottomRight: keypoints[5],
                backDividerTop: keypoints[6],
                frontDividerTop: keypoints[7],
                backTopLeft: keypoints[8],
                backTopRight: keypoints[9]
            ))
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
