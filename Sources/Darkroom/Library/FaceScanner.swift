import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Finds faces with the Mac's on-device Vision and describes each one with a feature print,
/// so faces of the same person can be grouped. Vision's feature print is a general image
/// description (macOS has no public face-recognition API), so grouping is approximate.
enum FaceScanner {
    /// Faces narrower than this (pixels at the scan size) are skipped: too small to compare.
    static let minimumFacePixels: CGFloat = 36
    static let scanSize = 1600

    /// Faces in one photo (nil = the photo couldn't be read).
    static func scan(url: URL) -> [DetectedFace]? {
        // Upright and uncropped, like the stored face positions.
        guard let image = DevelopRenderer.render(url: url, settings: .default, maxPixel: scanSize) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)

        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        var faces: [DetectedFace] = []
        for observation in observations {
            let box = observation.boundingBox  // 0…1, origin bottom-left
            guard box.width * width >= minimumFacePixels else { continue }
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)

            // A square around the face with some margin, in pixels (top-left origin).
            let side = max(box.width * width, box.height * height) * 1.4
            let centre = CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
            let crop = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !crop.isEmpty, let faceImage = image.cropping(to: crop) else { continue }
            faces.append(DetectedFace(rect: rect, print: featurePrint(faceImage), thumb: thumbnail(faceImage)))
        }
        return faces
    }

    private static func featurePrint(_ image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    /// 120 px JPEG for the People window.
    private static func thumbnail(_ image: CGImage) -> Data? {
        let side = 120
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Comparing

    static func decodePrint(_ data: Data?) -> VNFeaturePrintObservation? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do {
            try a.computeDistance(&d, to: b)
        } catch {
            return nil
        }
        return d
    }
}

/// Groups unnamed faces that look alike and suggests a person for each group.
enum FaceGrouping {
    struct Group: Identifiable {
        let id: Int64            // first face's id
        var faces: [FaceRecord]
        var suggestion: Person?
    }

    /// `threshold`: largest feature-print distance still counted as the same person.
    static func groups(faces: [FaceRecord], people: [Person], threshold: Float) -> [Group] {
        let prints = Dictionary(faces.compactMap { face in FaceScanner.decodePrint(face.print).map { (face.id, $0) } },
                                uniquingKeysWith: { a, _ in a })
        let unnamed = faces.filter { $0.personID == nil }

        // Leader clustering: a face joins the first group whose leader is close enough.
        var groups: [Group] = []
        var leaders: [VNFeaturePrintObservation?] = []
        for face in unnamed {
            guard let print = prints[face.id] else {
                groups.append(Group(id: face.id, faces: [face]))
                leaders.append(nil)
                continue
            }
            var best: (index: Int, distance: Float)?
            for (i, leader) in leaders.enumerated() {
                guard let leader, let d = FaceScanner.distance(print, leader), d <= threshold else { continue }
                if best == nil || d < best!.distance { best = (i, d) }
            }
            if let best {
                groups[best.index].faces.append(face)
            } else {
                groups.append(Group(id: face.id, faces: [face]))
                leaders.append(print)
            }
        }

        // Suggestion: the named person with the closest face (up to 30 faces each).
        let named = Dictionary(grouping: faces.filter { $0.personID != nil }, by: { $0.personID! })
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        for i in groups.indices {
            guard let leader = leaders[i] else { continue }
            var best: (person: Int64, distance: Float)?
            for (personID, personFaces) in named {
                for face in personFaces.prefix(30) {
                    guard let print = prints[face.id], let d = FaceScanner.distance(leader, print), d <= threshold else { continue }
                    if best == nil || d < best!.distance { best = (personID, d) }
                }
            }
            if let best { groups[i].suggestion = peopleByID[best.person] }
        }
        return groups.sorted { $0.faces.count > $1.faces.count }
    }
}
