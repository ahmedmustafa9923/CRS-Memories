//
//  PhoneLink.swift  (Apple Watch side)
//
//  The watch's half of the link to CRS Memories on the iPhone. It receives
//  the editor's status and finished montages, and sends the Export button's
//  request back.
//

import Foundation
import Observation
import WatchConnectivity

// MARK: - What arrives from the phone

nonisolated struct PhoneStatus: Equatable, Sendable {
    var title: String
    var clips: Int
    var seconds: Int
    var music: String
    var theme: String
    var rendering: Bool
    var progress: Double
    var canExport: Bool
    var minClips: Int
    var updated: Date

    init?(_ context: [String: Any]) {
        guard let clips = context["clips"] as? Int else { return nil }
        self.clips = clips
        title = context["title"] as? String ?? ""
        seconds = context["seconds"] as? Int ?? 0
        music = context["music"] as? String ?? ""
        theme = context["theme"] as? String ?? ""
        rendering = context["rendering"] as? Bool ?? false
        progress = context["progress"] as? Double ?? 0
        canExport = context["canExport"] as? Bool ?? false
        minClips = context["minClips"] as? Int ?? 3
        updated = Date(timeIntervalSince1970: context["updated"] as? Double ?? Date().timeIntervalSince1970)
    }
}

nonisolated struct WatchMontage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let seconds: Int
    let date: Date
    let fileName: String
    let poster: Data?

    var url: URL { WatchStore.folder.appending(path: fileName) }
}

// MARK: - Storage

nonisolated enum WatchStore {
    /// The watch has little space, so only the latest few are kept.
    static let keep = 10

    static var folder: URL {
        let folder = URL.documentsDirectory.appending(path: "Montages", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var index: URL { folder.appending(path: "index.json") }

    static func load() -> [WatchMontage] {
        guard let data = try? Data(contentsOf: index),
              let list = try? JSONDecoder().decode([WatchMontage].self, from: data) else { return [] }
        return list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static func save(_ list: [WatchMontage]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: index, options: .atomic)
        }
    }
}

// MARK: - Link

@MainActor
@Observable
final class PhoneLink {

    static let shared = PhoneLink()

    private(set) var status: PhoneStatus?
    private(set) var montages: [WatchMontage] = []
    private(set) var reachable = false
    private(set) var isSendingExport = false
    var exportMessage: String?

    private let bridge = PhoneSessionBridge()

    private init() {}

    func start() {
        montages = WatchStore.load()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = bridge
        WCSession.default.activate()
    }

    func requestExport() {
        exportMessage = nil
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            exportMessage = "Can't reach your iPhone. Open CRS Memories on it and try again."
            return
        }
        isSendingExport = true
        session.sendMessage(["action": "export"], replyHandler: { @Sendable reply in
            let ok = reply["ok"] as? Bool ?? false
            let reason = reply["reason"] as? String
            Task { @MainActor in
                PhoneLink.shared.isSendingExport = false
                PhoneLink.shared.exportMessage = ok ? "Exporting on your iPhone…" : (reason ?? "Your iPhone couldn't start the export.")
            }
        }, errorHandler: { @Sendable error in
            let text = error.localizedDescription
            Task { @MainActor in
                PhoneLink.shared.isSendingExport = false
                PhoneLink.shared.exportMessage = "Couldn't reach your iPhone. \(text)"
            }
        })
    }

    func delete(_ montage: WatchMontage) {
        try? FileManager.default.removeItem(at: montage.url)
        montages.removeAll { $0.id == montage.id }
        WatchStore.save(montages)
    }

    // MARK: From the bridge

    fileprivate func update(status: PhoneStatus) {
        // A finished export clears any "Exporting…" note left from the button.
        if let old = self.status, old.rendering, !status.rendering {
            exportMessage = nil
        }
        self.status = status
    }

    fileprivate func update(reachable: Bool) {
        self.reachable = reachable
        if reachable { refreshStatus() }
    }

    /// Asks the phone for its current state rather than waiting for the
    /// next change to arrive by itself.
    func refreshStatus() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["action": "status"], replyHandler: { @Sendable reply in
            guard let status = PhoneStatus(reply) else { return }
            Task { @MainActor in PhoneLink.shared.update(status: status) }
        }, errorHandler: { @Sendable _ in })
    }

    fileprivate func add(_ montage: WatchMontage) {
        montages.insert(montage, at: 0)
        while montages.count > WatchStore.keep {
            let old = montages.removeLast()
            try? FileManager.default.removeItem(at: old.url)
        }
        WatchStore.save(montages)
    }
}

// MARK: - Session delegate

/// Called on a background queue, so not main-actor isolated. Anything that
/// can't wait — moving a received file before the system deletes it — is
/// done right here; state changes hop to the main actor.
nonisolated final class PhoneSessionBridge: NSObject, WCSessionDelegate, @unchecked Sendable {

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let status = PhoneStatus(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            if let status { PhoneLink.shared.update(status: status) }
            PhoneLink.shared.update(reachable: reachable)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in PhoneLink.shared.update(reachable: reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let status = PhoneStatus(context) else { return }
        Task { @MainActor in PhoneLink.shared.update(status: status) }
    }

    /// The received file is deleted as soon as this returns, so it's moved
    /// synchronously.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let meta = file.metadata ?? [:]
        let id = meta["id"] as? String ?? UUID().uuidString
        let name = "\(id).mp4"
        let destination = WatchStore.folder.appending(path: name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
        } catch {
            return
        }
        let montage = WatchMontage(
            id: id,
            title: meta["title"] as? String ?? "Montage",
            seconds: meta["seconds"] as? Int ?? 0,
            date: Date(timeIntervalSince1970: meta["date"] as? Double ?? Date().timeIntervalSince1970),
            fileName: name,
            poster: meta["poster"] as? Data
        )
        Task { @MainActor in PhoneLink.shared.add(montage) }
    }
}
