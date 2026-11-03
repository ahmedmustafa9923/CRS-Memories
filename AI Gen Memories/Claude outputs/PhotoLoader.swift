//
//  PhotoLoader.swift
//
//  Lifted from the Memories app — photo library access, unchanged in shape.
//  Limited authorization by default, full access if the user grants it, and
//  every permission state handled.
//

import Foundation
import Photos
import PhotosUI
import UIKit
import Observation

struct LibraryPhoto: Identifiable, Hashable {
    let id: String              // PHAsset.localIdentifier
    let creationDate: Date?

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.creationDate = asset.creationDate
    }
}

/// Stateless image fetching, separated from the observable service so the
/// renderer can pull frames without touching UI state.
enum PhotoLoader {

    /// Full-size-enough for the canvas, no bigger. Network access stays off:
    /// the app never fetches anything, including from the user's own iCloud.
    static func image(for id: String, target: CGSize) async -> UIImage? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact
        options.deliveryMode = .highQualityFormat   // exactly one callback

        // Request more than the canvas so a Ken Burns push doesn't reveal
        // softness as it zooms in.
        let request = CGSize(width: target.width * 1.4, height: target.height * 1.4)

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: request,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func thumbnail(for id: String, pixelSize: CGFloat) async -> UIImage? {
        await image(for: id, target: CGSize(width: pixelSize, height: pixelSize))
    }
}

@Observable
@MainActor
final class PhotoLibraryService {

    enum Access: Equatable {
        case notDetermined
        case limited
        case authorized
        case denied
        case restricted
        case missingUsageDescription
    }

    static let maxSelection = 60      // a montage, not a feature film
    static let minSelection = 3       // two photos is a transition, not a video

    private(set) var access: Access = .notDetermined
    private(set) var photos: [LibraryPhoto] = []
    private(set) var isLoading = false

    private var loadGeneration = 0

    /// Nothing touches PhotoKit here. Anything done during view construction
    /// fails invisibly; call start() once the UI is on screen.
    init() {}

    func start() {
        refreshStatus()
        if access == .limited || access == .authorized {
            load()
        }
    }

    func refreshStatus() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        // Without NSPhotoLibraryUsageDescription iOS terminates the process
        // here, with no error anyone will see. Refusing to make the call
        // turns that into a message on screen.
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            access = .missingUsageDescription
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        if access == .limited || access == .authorized {
            load()
        }
    }

    func presentLimitedPicker() {
        guard let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Off the main actor — under full access this walks the entire library,
    /// and doing that on the main thread freezes the UI including the spinner
    /// that would have explained the wait.
    func load() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true

        Task {
            let found = await Self.fetchAll()
            guard generation == self.loadGeneration else { return }
            self.photos = found
            self.isLoading = false
        }
    }

    private static func fetchAll() async -> [LibraryPhoto] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            // Newest first: people make a montage of the trip they just took.
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(with: .image, options: options)
            var found: [LibraryPhoto] = []
            found.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                found.append(LibraryPhoto(asset: asset))
            }
            return found
        }.value
    }

    private static func map(_ status: PHAuthorizationStatus) -> Access {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted:    .restricted
        case .denied:        .denied
        case .authorized:    .authorized
        case .limited:       .limited
        @unknown default:    .denied
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
