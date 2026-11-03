//
//  SaveOptions.swift
//
//  Where a finished video goes. Three places, and the user picks which one
//  happens by itself next time:
//
//  • Photos — the camera roll. Add-only permission, so the app still never
//    reads the library.
//  • Files — any folder the user chooses: On My iPhone, iCloud Drive, or a
//    cloud provider they've added to Files (Google Drive, Dropbox, OneDrive).
//  • Share — the share sheet, for AirDrop, Messages or another app.
//

import SwiftUI
import UIKit

enum SaveDestination: String, CaseIterable, Identifiable {
    case ask, photos, files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask:    "Ask me each time"
        case .photos: "Save to Photos"
        case .files:  "Choose a folder in Files"
        }
    }
}

enum ExportNaming {
    /// The renderer's file has a throwaway name. What lands in Photos, a
    /// folder or a share sheet should be called something a person would
    /// recognise: the montage's title and today's date.
    static func namedCopy(of url: URL, title: String) -> URL {
        let cleaned = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined(separator: "-")
        let base = cleaned.isEmpty ? "CRS Memories" : cleaned
        let date = Date().formatted(.iso8601.year().month().day())
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(base) \(date).\(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)")

        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return url
        }
    }
}

/// The system "Save to Files" picker. It shows every location Files knows
/// about, remembers the last folder used, and copies the video there.
struct FolderExporter: UIViewControllerRepresentable {
    let url: URL
    var onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
