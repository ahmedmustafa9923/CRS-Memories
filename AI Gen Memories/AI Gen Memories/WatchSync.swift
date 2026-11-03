//
//  WatchSync.swift  (iPhone side)
//
//  Keeps the Apple Watch app up to date:
//
//  • Status — the editor's title, clip count and export progress, sent as
//    application context, which always holds just the latest state.
//  • Finished montages — a small, watch-sized copy of each exported video,
//    sent as a file transfer, which survives the watch being out of range.
//  • Export requests — the watch's Export button arrives here as a message.
//
//  Everything goes phone → watch over Apple's own WatchConnectivity link;
//  nothing touches a server.
//

import Foundation
import AVFoundation
import UIKit
import WatchConnectivity

// MARK: - The session delegate

/// WatchConnectivity calls its delegate on a background queue, so this
/// class is deliberately not main-actor isolated. It only forwards: state
/// lives in WatchSync, on the main actor.
nonisolated final class WatchSessionBridge: NSObject, WCSessionDelegate, @unchecked Sendable {

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in WatchSync.shared.sessionBecameActive() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Re-activate after switching to a different paired watch.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let action = message["action"] as? String
        let reply = UncheckedReply(replyHandler)
        Task { @MainActor in
            let answer = WatchSync.shared.handle(action: action)
            reply.send(answer)
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // The outbox copy has done its job either way.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

/// The reply handler isn't Sendable; it's called exactly once, from the main
/// actor, which WatchConnectivity allows.
private struct UncheckedReply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ answer: [String: Any]) { handler(answer) }
}

// MARK: - State and sending

@MainActor
final class WatchSync {

    static let shared = WatchSync()

    /// Set by the root view: starts an export the same way the Export
    /// button does. Returns nil on success, or why it couldn't.
    var onExportRequest: (() -> String?)?

    private let bridge = WatchSessionBridge()
    private var lastStatus: [String: Any] = [:]
    private var lastSentProgress: Double = -1

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private init() {}

    /// Call once at launch. Does nothing on iPad, which has no watch.
    func start() {
        guard let session else { return }
        session.delegate = bridge
        session.activate()
    }

    fileprivate func sessionBecameActive() {
        if !lastStatus.isEmpty { push(lastStatus) }
    }

    // MARK: Status

    func sendStatus(_ flow: MontageFlow) {
        // Progress changes every frame while rendering; the watch only needs
        // to see it move in steps.
        if flow.isRendering, abs(flow.renderProgress - lastSentProgress) < 0.05, lastSentProgress >= 0 {
            return
        }
        lastSentProgress = flow.isRendering ? flow.renderProgress : -1

        let status: [String: Any] = [
            "title": flow.trimmedTitle,
            "clips": flow.selectedIDs.count,
            "seconds": Int(flow.estimatedDuration.rounded()),
            "music": flow.customAudioName ?? "",
            "theme": flow.theme.name,
            "rendering": flow.isRendering,
            "progress": flow.renderProgress,
            "canExport": flow.canRender,
            "minClips": MontageImporter.minSelection,
            "updated": Date().timeIntervalSince1970,
        ]
        lastStatus = status
        push(status)
    }

    private func push(_ status: [String: Any]) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(status)
    }

    // MARK: Export requests

    fileprivate func handle(action: String?) -> [String: Any] {
        // The watch asks for this when it opens, so it doesn't sit on
        // "open the iPhone app" waiting for the next change.
        if action == "status" {
            return lastStatus.isEmpty ? ["ok": false] : lastStatus.merging(["ok": true]) { a, _ in a }
        }
        guard action == "export" else { return ["ok": false, "reason": "Unknown request."] }
        guard UIApplication.shared.applicationState == .active else {
            return ["ok": false, "reason": "Open CRS Memories on your iPhone, then tap Export again."]
        }
        if let problem = onExportRequest?() {
            return ["ok": false, "reason": problem]
        }
        return ["ok": true]
    }

    // MARK: Finished montages

    /// Makes a watch-sized copy and a poster frame, then queues the transfer.
    /// Runs after the iPhone already has its full-quality video, so a slow
    /// or failed watch copy never holds anything up.
    func sendMontage(at url: URL, title: String, seconds: Int) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }

        Task {
            guard let small = await Self.watchCopy(of: url) else { return }
            let poster = await Self.poster(for: url)

            var metadata: [String: Any] = [
                "id": UUID().uuidString,
                "title": title.isEmpty ? "Untitled montage" : title,
                "seconds": seconds,
                "date": Date().timeIntervalSince1970,
            ]
            if let poster { metadata["poster"] = poster }
            session.transferFile(small, metadata: metadata)
        }
    }

    private static var outbox: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "WatchOutbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Medium quality is roughly 360p — sharp on a watch face, and a few
    /// megabytes rather than a few hundred.
    private nonisolated static func watchCopy(of url: URL) async -> URL? {
        let destination = await outbox.appending(path: "\(UUID().uuidString).mp4")
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            return nil
        }
        do {
            try await export.export(to: destination, as: .mp4)
            return destination
        } catch {
            return nil
        }
    }

    /// A small JPEG from a second in, for the watch's list.
    private nonisolated static func poster(for url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 426)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }
}
