import Foundation
import CoreGraphics
import Vision

/// AI Cull: looks at each photo with the Mac's own Vision models, on-device.
/// - Aesthetics score and "utility" (screenshots, documents) — macOS 15 or later
/// - Faces and closed eyes (face landmarks)
/// - Sharpness (detail in the sharpest part of the frame)
/// - A feature print, to find runs of similar shots (bursts)
enum CullingAnalyzer {
    struct Result {
        var analysis: PhotoAnalysis
        var print: VNFeaturePrintObservation?
    }

    static func analyze(_ image: CGImage, previous: VNFeaturePrintObservation?) -> Result {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceLandmarksRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([faces, print])

        var aesthetic: Double?
        var utility = false
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            if (try? handler.perform([request])) != nil, let result = request.results?.first {
                aesthetic = Double(result.overallScore)
                utility = result.isUtility
            }
        }

        // Faces big enough to judge (at least 4% of the photo's width).
        let faceObservations = (faces.results ?? []).filter { $0.boundingBox.width >= 0.04 }
        let eyesClosed = faceObservations.filter(eyesLookClosed).count

        let featurePrint = print.results?.first
        var distance: Double?
        if let featurePrint, let previous {
            var value: Float = 0
            if (try? featurePrint.computeDistance(&value, to: previous)) != nil {
                distance = Double(value)
            }
        }

        let analysis = PhotoAnalysis(
            aesthetic: aesthetic,
            utility: utility,
            sharpness: sharpness(of: image, faces: faceObservations.map(\.boundingBox)),
            faces: faceObservations.count,
            eyesClosed: eyesClosed,
            distanceToPrevious: distance)
        return Result(analysis: analysis, print: featurePrint)
    }

    /// Both eyes flat: height / width of each eye outline below ~0.18.
    private static func eyesLookClosed(_ face: VNFaceObservation) -> Bool {
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else { return false }
        func openness(_ region: VNFaceLandmarkRegion2D) -> Double {
            let points = region.normalizedPoints
            guard points.count >= 4,
                  let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
                  maxX - minX > 0 else { return 1 }
            return Double((maxY - minY) / (maxX - minX))
        }
        return openness(left) < 0.18 && openness(right) < 0.18
    }

    /// Variance of the Laplacian on a 512 px grey copy, per tile; the 90th percentile tile
    /// (or the best face tile) decides, so a sharp subject on a soft background still counts.
    /// Mapped to 0…1 on a log scale.
    static func sharpness(of image: CGImage, faces: [CGRect]) -> Double {
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let w = max(16, Int(Double(image.width) * scale)), h = max(16, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.5 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let tiles = 8
        var sums = [Double](repeating: 0, count: tiles * tiles)
        var squares = [Double](repeating: 0, count: tiles * tiles)
        var counts = [Double](repeating: 0, count: tiles * tiles)
        for y in 1..<(h - 1) {
            let row = y * w
            let ty = min(tiles - 1, y * tiles / h)
            for x in 1..<(w - 1) {
                let i = row + x
                let lap = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - w]) - Double(pixels[i + w])
                let t = ty * tiles + min(tiles - 1, x * tiles / w)
                sums[t] += lap
                squares[t] += lap * lap
                counts[t] += 1
            }
        }
        let variances = (0..<(tiles * tiles)).map { t -> Double in
            guard counts[t] > 0 else { return 0 }
            let mean = sums[t] / counts[t]
            return squares[t] / counts[t] - mean * mean
        }
        var value = variances.sorted()[Int(Double(variances.count - 1) * 0.9)]
        // Faces: use the sharpest tile under a face. Vision boxes are 0…1 with the origin at
        // the bottom; the bitmap's first row (tile row 0) is the top of the photo.
        var faceBest: Double?
        for face in faces {
            let box = CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height)
            for t in 0..<(tiles * tiles) {
                let tx = Double(t % tiles) / Double(tiles), ty = Double(t / tiles) / Double(tiles)
                let tile = CGRect(x: tx, y: ty, width: 1 / Double(tiles), height: 1 / Double(tiles))
                if tile.intersects(box) { faceBest = max(faceBest ?? 0, variances[t]) }
            }
        }
        if let faceBest { value = faceBest }
        let logValue = log10(max(value, 1))
        let t = min(max((logValue - 1.3) / (2.8 - 1.3), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// What AI Cull should do with the analysis.
struct CullOptions {
    var rejectBlurry = true
    var rejectEyesClosed = true
    var rejectUtility = true
    var pickBestOfSimilar = true
    var rejectOthersOfSimilar = false
    /// 0…1: higher = only very similar shots are grouped.
    var similarityStrictness = 0.5
    var setStars = false
    /// Leave photos you already flagged / rated alone.
    var keepMyChoices = true
}

enum CullPlanner {
    /// Runs of similar shots, in folder order. Two neighbours are "similar" when their
    /// distance is well below the folder's typical neighbour distance (works whatever the
    /// feature print's scale is).
    static func groups(_ photos: [Photo], analysis: [Int64: PhotoAnalysis], strictness: Double) -> [[Photo]] {
        let distances = photos.compactMap { analysis[$0.id]?.distanceToPrevious }.sorted()
        guard !distances.isEmpty else { return photos.map { [$0] } }
        let median = distances[distances.count / 2]
        let threshold = median * (0.85 - 0.6 * min(max(strictness, 0), 1))
        var result: [[Photo]] = []
        for photo in photos {
            if let d = analysis[photo.id]?.distanceToPrevious, d < threshold, !result.isEmpty {
                result[result.count - 1].append(photo)
            } else {
                result.append([photo])
            }
        }
        return result
    }

    struct Plan {
        var flags: [Int64: Flag] = [:]
        var ratings: [Int64: Int] = [:]
        var summary: [String] = []
    }

    static func plan(_ photos: [Photo], analysis: [Int64: PhotoAnalysis], options o: CullOptions) -> Plan {
        var plan = Plan()
        var rejected = Set<Int64>()
        var counts = (blurry: 0, eyes: 0, utility: 0, picks: 0, others: 0, stars: 0)

        func canFlag(_ p: Photo) -> Bool { !o.keepMyChoices || p.flag == .unflagged }

        for photo in photos {
            guard let a = analysis[photo.id], canFlag(photo) else { continue }
            if o.rejectUtility && a.utility {
                rejected.insert(photo.id); counts.utility += 1
            } else if o.rejectBlurry && a.isBlurry {
                rejected.insert(photo.id); counts.blurry += 1
            } else if o.rejectEyesClosed && a.eyesClosed > 0 && a.eyesClosed == a.faces {
                rejected.insert(photo.id); counts.eyes += 1
            }
        }
        for id in rejected { plan.flags[id] = .reject }

        if o.pickBestOfSimilar || o.rejectOthersOfSimilar {
            for group in groups(photos, analysis: analysis, strictness: o.similarityStrictness) {
                let candidates = group.filter { !rejected.contains($0.id) && analysis[$0.id] != nil }
                guard let best = candidates.max(by: { analysis[$0.id]!.score < analysis[$1.id]!.score }) else { continue }
                if o.pickBestOfSimilar, canFlag(best) {
                    plan.flags[best.id] = .pick
                    counts.picks += 1
                }
                if o.rejectOthersOfSimilar, group.count > 1 {
                    for other in candidates where other.id != best.id && canFlag(other) {
                        plan.flags[other.id] = .reject
                        counts.others += 1
                    }
                }
            }
        }
        if o.setStars {
            for photo in photos {
                guard let a = analysis[photo.id], !o.keepMyChoices || photo.rating == 0 else { continue }
                plan.ratings[photo.id] = a.stars
                counts.stars += 1
            }
        }
        if counts.picks > 0 { plan.summary.append("\(counts.picks) picked (best of each group of similar shots)") }
        if counts.blurry > 0 { plan.summary.append("\(counts.blurry) rejected as blurry") }
        if counts.eyes > 0 { plan.summary.append("\(counts.eyes) rejected for closed eyes") }
        if counts.utility > 0 { plan.summary.append("\(counts.utility) rejected as screenshots/documents") }
        if counts.others > 0 { plan.summary.append("\(counts.others) rejected as weaker similar shots") }
        if counts.stars > 0 { plan.summary.append("\(counts.stars) rated with stars") }
        return plan
    }
}
