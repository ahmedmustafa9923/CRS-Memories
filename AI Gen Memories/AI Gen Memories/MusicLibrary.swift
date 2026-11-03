//
//  MusicLibrary.swift
//
//  Where a montage's music comes from: five built-in tunes that ship with
//  the app, a song from the user's own music library, or an audio file from
//  Files.
//
//  The built-in tunes are original and generated for this app, so they're
//  free to use in anything the user makes and posts. A library song is
//  exported to a copy in the app's container — the same as a Files pick —
//  because the renderer needs a plain file it can read.
//

import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Built-in tunes

struct BuiltInTune: Identifiable, Hashable {
    let id: String
    let name: String
    let mood: String
    let file: String

    /// Resources in a synchronised folder are usually copied to the bundle's
    /// top level; the subdirectory lookup covers the case where they aren't.
    var url: URL? {
        Bundle.main.url(forResource: file, withExtension: "m4a")
            ?? Bundle.main.url(forResource: file, withExtension: "m4a", subdirectory: "Tunes")
    }

    static let all: [BuiltInTune] = [
        BuiltInTune(id: "golden-hour", name: "Golden Hour", mood: "Warm piano · gentle", file: "Tune-GoldenHour"),
        BuiltInTune(id: "quiet-roads", name: "Quiet Roads", mood: "Ambient · calm", file: "Tune-QuietRoads"),
        BuiltInTune(id: "weekend", name: "Weekend", mood: "Upbeat pop · bright", file: "Tune-Weekend"),
        BuiltInTune(id: "cinematic-rise", name: "Cinematic Rise", mood: "Strings · big moments", file: "Tune-CinematicRise"),
        BuiltInTune(id: "lofi-nights", name: "Lo-fi Nights", mood: "Mellow beat · cozy", file: "Tune-LofiNights"),
    ]

    /// Which tune a music URL is, if it's one of ours.
    static func matching(_ url: URL?) -> BuiltInTune? {
        guard let url else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return all.first { $0.file == name }
    }
}

// MARK: - The app's own copies

enum Soundtrack {

    static var folder: URL {
        let folder = URL.documentsDirectory.appending(path: "Soundtrack", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// True for a copy the app made, which it may delete. False for a
    /// built-in tune, which lives in the read-only app bundle.
    static func isOwnedCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(URL.documentsDirectory.standardizedFileURL.path)
    }

    static func removeAll() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            try? manager.removeItem(at: folder.appending(path: name))
        }
    }

    enum LibraryError: LocalizedError {
        case protected, exportFailed

        var errorDescription: String? {
            switch self {
            case .protected:
                "That song can't be used. Songs streamed from Apple Music, or not downloaded to this iPhone, are protected. Pick a song you bought or imported, a built-in tune, or a file from Files."
            case .exportFailed:
                "Couldn't copy that song. Try another one, or pick a file from Files."
            }
        }
    }

    /// Copies a music-library song into the app. Protected and cloud-only
    /// songs have no asset URL — that's the only reliable test, so it's the
    /// one used.
    static func importLibrarySong(_ item: MPMediaItem) async throws -> (URL, String) {
        guard let source = item.assetURL else { throw LibraryError.protected }

        let title = item.title ?? "Song"
        let safe = title.replacingOccurrences(of: "/", with: "-")
        let destination = folder.appending(path: "\(UUID().uuidString)-\(safe).m4a")

        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw LibraryError.exportFailed
        }
        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            throw LibraryError.exportFailed
        }
        return (destination, title)
    }
}

// MARK: - Music library picker

struct MusicLibraryPicker: UIViewControllerRepresentable {
    var onPick: (MPMediaItem?) -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        // Cloud items can't be exported, so don't offer them.
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = "Pick a song you own"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItem?) -> Void
        init(onPick: @escaping (MPMediaItem?) -> Void) { self.onPick = onPick }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            onPick(collection.items.first)
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            onPick(nil)
        }
    }
}

// MARK: - Tune preview

@Observable
final class TunePreview {
    private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(_ tune: BuiltInTune) {
        if playingID == tune.id {
            stop()
            return
        }
        stop()
        guard let url = tune.url else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.play()
        playingID = player == nil ? nil : tune.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

// MARK: - Chooser

/// The sheet behind "Choose music": built-in tunes first, because they
/// always work, then the user's own library and Files.
struct MusicChooser: View {
    @Bindable var flow: MontageFlow
    var onFile: (Result<URL, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview = TunePreview()
    @State private var showingLibrary = false
    @State private var showingFiles = false
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(BuiltInTune.all) { tune in
                        tuneRow(tune)
                    }
                } header: {
                    Text("Built-in tunes")
                } footer: {
                    Text("Made for this app and free to use in anything you post. Each one loops to fit your montage.")
                }

                Section {
                    Button {
                        Task { await openLibrary() }
                    } label: {
                        Label("From your music library", systemImage: "music.note.list")
                    }
                    .disabled(importing)

                    Button {
                        preview.stop()
                        showingFiles = true
                    } label: {
                        Label("From Files", systemImage: "folder")
                    }
                    .disabled(importing)

                    if importing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Copying song…").foregroundStyle(.secondary)
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Your music")
                } footer: {
                    Text("Songs you bought or imported work. Songs streamed from Apple Music are protected and can't be written into a video.")
                }
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingLibrary) {
                MusicLibraryPicker { item in
                    showingLibrary = false
                    guard let item else { return }
                    Task { await adopt(item) }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.audio]) { result in
                onFile(result)
                if case .success = result { dismiss() }
            }
            .onDisappear { preview.stop() }
        }
    }

    private func tuneRow(_ tune: BuiltInTune) -> some View {
        let chosen = BuiltInTune.matching(flow.customAudioURL) == tune
        return HStack(spacing: 12) {
            Button {
                preview.toggle(tune)
            } label: {
                Image(systemName: preview.playingID == tune.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(preview.playingID == tune.id ? "Stop preview" : "Preview \(tune.name)")

            Button {
                use(tune)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tune.name).foregroundStyle(.primary)
                        Text(tune.mood).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if chosen {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func use(_ tune: BuiltInTune) {
        guard let url = tune.url else {
            error = "That tune is missing from the app."
            return
        }
        preview.stop()
        flow.setAudio(url: url, name: tune.name)
        dismiss()
    }

    private func openLibrary() async {
        preview.stop()
        error = nil
        let status = await MPMediaLibrary.requestAuthorization()
        guard status == .authorized else {
            error = "Allow access to your music library in Settings → Privacy & Security → Media & Apple Music to pick a song from it."
            return
        }
        showingLibrary = true
    }

    private func adopt(_ item: MPMediaItem) async {
        importing = true
        defer { importing = false }
        do {
            let (url, title) = try await Soundtrack.importLibrarySong(item)
            flow.setAudio(url: url, name: title)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
