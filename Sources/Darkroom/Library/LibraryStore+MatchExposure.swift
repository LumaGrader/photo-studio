import Foundation
import ImageIO

/// Photo ▸ Match Total Exposures (⌥⇧⌘M), like Lightroom's: gives every selected photo the
/// same overall brightness as the active one, from the camera's shutter speed, aperture and
/// ISO. Useful for a series shot in changing light or with auto exposure that jumped around.
/// Only Exposure changes; photos without that camera data are skipped.
enum ExposureMatch {
    /// How much light the camera let in, in stops: log2(shutter × ISO / f²).
    /// Twice the light = one stop more = needs one stop less Exposure to look the same.
    static func cameraStops(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0,
              let fNumber = exif[kCGImagePropertyExifFNumber] as? Double, fNumber > 0
        else { return nil }
        let isoList = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double]
        let iso = isoList?.first ?? 100
        guard iso > 0 else { return nil }
        return log2(time * iso / (fNumber * fNumber))
    }

    /// Exposure for a photo so it matches the reference photo's brightness.
    static func matchedExposure(reference: Double, referenceStops: Double, stops: Double) -> Double {
        let value = reference + (referenceStops - stops)
        return (min(max(value, -5), 5) * 100).rounded() / 100
    }
}

extension LibraryStore {
    /// Two or more photos selected, one of them active.
    var canMatchExposures: Bool { targetIDs.count > 1 && selectedPhotoID != nil }

    func matchTotalExposures() {
        guard let referenceID = selectedPhotoID,
              let reference = photos.first(where: { $0.id == referenceID }),
              let referenceSettings = currentSettings(of: referenceID) else { return }
        let others: [(id: Int64, url: URL)] = targetIDs.filter { $0 != referenceID }.compactMap { id in
            photos.first { $0.id == id }.map { ($0.id, $0.url) }
        }
        guard !others.isEmpty else {
            notice = ("Match Total Exposures", "Select the photos to match, then click the one whose brightness the others should get.")
            return
        }
        develop.flushSave()
        let referenceURL = reference.url
        Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .userInitiated) { () -> (Double?, [(Int64, Double?)]) in
                (ExposureMatch.cameraStops(url: referenceURL),
                 others.map { ($0.id, ExposureMatch.cameraStops(url: $0.url)) })
            }.value
            guard let self else { return }
            guard let referenceStops = read.0 else {
                self.notice = ("Match Total Exposures",
                               "\(reference.fileName) has no shutter speed, aperture or ISO in its file, so there's nothing to match to.")
                return
            }
            var matched = 0
            var skipped: [String] = []
            for (id, stops) in read.1 {
                guard var settings = self.currentSettings(of: id) else { continue }
                guard let stops else {
                    if let name = self.photos.first(where: { $0.id == id })?.fileName { skipped.append(name) }
                    continue
                }
                settings.exposure = ExposureMatch.matchedExposure(reference: referenceSettings.exposure,
                                                                  referenceStops: referenceStops, stops: stops)
                self.setSettings(settings, for: id, label: "Match Total Exposures")
                matched += 1
            }
            if !skipped.isEmpty {
                let list = skipped.prefix(5).joined(separator: ", ") + (skipped.count > 5 ? "…" : "")
                self.notice = ("Match Total Exposures",
                               "Matched \(matched) photo\(matched == 1 ? "" : "s"). Skipped \(skipped.count) without camera exposure data: \(list)")
            }
        }
    }
}
