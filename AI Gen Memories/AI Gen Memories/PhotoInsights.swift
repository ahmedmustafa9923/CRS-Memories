//
//  PhotoInsights.swift
//
//  What the assistant knows about each imported photo: when it was taken,
//  what Vision sees in it, and how many faces. All of it is worked out on
//  this device — nothing is uploaded, which keeps the promise the photo
//  permission text makes.
//
//  The date has to be read at import time. The imported copy is re-encoded
//  from pixels, so its EXIF is gone by the time anyone asks.
//

import Foundation
import ImageIO
import Vision

struct PhotoInsight: Sendable {
    var date: Date?
    var labels: [String]
    var faces: Int
}

final class PhotoInsights {

    static let shared = PhotoInsights()

    private var dates: [String: Date] = [:]
    private var analysed: [String: PhotoInsight] = [:]

    private init() {}

    // MARK: - Bookkeeping

    func record(date: Date?, for ref: String) {
        dates[ref] = date
    }

    func forget(_ ref: String) {
        dates[ref] = nil
        analysed[ref] = nil
    }

    func removeAll() {
        dates = [:]
        analysed = [:]
    }

    // MARK: - Reading

    /// Analyses anything not seen yet, one photo at a time so sixty photos
    /// don't all decode at once, and caches the result.
    func insights(for refs: [String]) async -> [String: PhotoInsight] {
        var result: [String: PhotoInsight] = [:]
        for ref in refs {
            if let cached = analysed[ref] {
                result[ref] = cached
                continue
            }
            let url = MontageImports.url(for: ref)
            let (labels, faces) = await Self.analyse(url: url)
            let insight = PhotoInsight(date: dates[ref], labels: labels, faces: faces)
            analysed[ref] = insight
            result[ref] = insight
        }
        return result
    }

    /// Off the main actor, so the editor keeps playing while Vision works.
    /// A photo Vision can't read just comes back with no labels.
    private nonisolated static func analyse(url: URL) async -> ([String], Int) {
        await Task.detached(priority: .userInitiated) {
            var labels: [String] = []
            var faces = 0

            if let observations = try? await ClassifyImageRequest().perform(on: url) {
                labels = observations
                    .filter { $0.confidence > 0.35 }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(5)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            }

            if let found = try? await DetectFaceRectanglesRequest().perform(on: url) {
                faces = found.count
            }

            return (labels, faces)
        }.value
    }

    // MARK: - Import-time metadata

    /// The original capture date from the picked file's EXIF, if it has one.
    /// Screenshots and downloaded images often don't, and that's fine.
    nonisolated static func captureDate(in data: Data) async -> Date? {
        await Task.detached(priority: .utility) {
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return nil }

            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
            guard let raw else { return nil }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return formatter.date(from: raw)
        }.value
    }
}
