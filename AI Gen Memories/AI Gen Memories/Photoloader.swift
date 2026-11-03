//
//  PhotoLoader.swift
//
//  Importing, and reading what was imported.
//
//  Photos come in through the system picker — the same browser Photos itself
//  shows, with albums, years, people and search — and each one is copied into
//  this app as a JPEG. After that the app never touches the photo library
//  again: the montage is built from its own files.
//
//  That's deliberate. It means no read permission, no permission prompt, no
//  silent termination for a missing usage description, and no photo vanishing
//  mid-render because it was deleted or was only ever in iCloud.
//

import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI          // PhotosPickerItem lives in PhotosUI's SwiftUI overlay,
                        // which only comes in when SwiftUI is imported too.
import UIKit
import UniformTypeIdentifiers

// MARK: - Where imports live

enum MontageImports {

    /// Application Support, not Documents: these are the app's working
    /// copies, not files the user manages in the Files app.
    static var folder: URL {
        let base = URL.applicationSupportDirectory.appending(
            path: "Imports",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for ref: String) -> URL {
        folder.appending(path: ref)
    }

    static func delete(_ ref: String) {
        try? FileManager.default.removeItem(at: url(for: ref))
    }

    /// Anything on disk that no longer belongs to the montage. Called when
    /// starting over, so a long session doesn't leave a folder full of
    /// photos nothing refers to.
    static func removeAll(except keep: Set<String>) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keep.contains(name) {
            try? manager.removeItem(at: url(for: name))
        }
    }
}

// MARK: - Reading

enum PhotoLoader {

    /// Decoded straight from the imported file at roughly the size asked for.
    /// Slightly larger than the canvas, so a Ken Burns push doesn't reveal
    /// softness as it zooms in.
    static func image(for ref: String, target: CGSize) async -> UIImage? {
        let url = MontageImports.url(for: ref)
        let maxPixel = max(target.width, target.height) * 1.4

        return await Task.detached(priority: .userInitiated) {
            decode(url: url, maxPixel: maxPixel)
        }.value
    }

    static func thumbnail(for ref: String, pixelSize: CGFloat) async -> UIImage? {
        await image(for: ref, target: CGSize(width: pixelSize, height: pixelSize))
    }

    /// ImageIO, not UIImage(contentsOfFile:) — this decodes straight to the
    /// size wanted instead of decoding full size and then shrinking, which
    /// is the difference between a few megabytes and a few hundred.
    private nonisolated static func decode(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(maxPixel, 1))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Importing

@Observable
@MainActor
final class MontageImporter {

    static let maxSelection = 60      // a montage, not a feature film
    static let minSelection = 3       // two photos is a transition, not a video

    /// Long edge of the stored copy. The render canvas is 1080 × 1920 and
    /// asks for 1.4× that, so 2700 leaves headroom for the zoom without
    /// keeping sixty full-resolution originals on disk.
    /// nonisolated because the background import task reads it.
    private nonisolated static let storedMaxPixel = 2700

    private(set) var isImporting = false
    private(set) var done = 0
    private(set) var total = 0
    var errorMessage: String?

    /// Copies the picked photos in and returns their refs, in the order they
    /// were selected. Failures are counted rather than thrown: one unreadable
    /// photo out of thirty shouldn't lose the other twenty-nine.
    func importItems(_ items: [PhotosPickerItem], room: Int) async -> [String] {
        guard !items.isEmpty, room > 0 else { return [] }

        isImporting = true
        done = 0
        total = min(items.count, room)
        errorMessage = nil

        var refs: [String] = []
        var failures = 0

        for item in items.prefix(room) {
            // The name and destination are worked out here, on the main
            // actor, and handed to the background task. This target builds
            // with default MainActor isolation, so MontageImports is
            // main-actor isolated — reaching for it from inside a detached
            // task is the mistake, not the isolation.
            let name = "\(UUID().uuidString).jpg"
            let destination = MontageImports.url(for: name)

            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   await Self.store(data, to: destination) {
                    refs.append(name)
                    // Read now: the stored copy is re-encoded and has no EXIF.
                    let taken = await PhotoInsights.captureDate(in: data)
                    PhotoInsights.shared.record(date: taken, for: name)
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
            }
            done += 1
        }

        isImporting = false

        if failures > 0 {
            errorMessage = failures == items.count
                ? "None of those photos could be imported."
                : "\(failures) of \(items.count) photos couldn't be imported and were skipped."
        }

        return refs
    }

    private nonisolated static func store(_ data: Data, to destination: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            // The source keeps the data compressed; the thumbnail call
            // decodes once, already reduced. A 48MP photo decoded in full is
            // about 190MB, and we import up to sixty of them.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return false
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Bakes in the EXIF orientation, or every photo shot in
                // portrait comes out of the renderer on its side.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: storedMaxPixel
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else { return false }

            guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
                return false
            }

            do {
                try jpeg.write(to: destination, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }
}

