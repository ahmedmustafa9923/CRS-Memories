//
//  MontageScreens.swift
//
//  Edit → Export → Watch. Three screens, and the first one is the editor.
//
//  There is no separate "pick photos" screen and no grid of imported
//  thumbnails. Browsing happens in the system photo picker — the Photos app's
//  own browser — and what comes back lands straight in the editor's clip
//  list. Anything in between is a screen that makes you tap to get past it.
//

import SwiftUI
import AVKit
import AVFoundation
import Photos

// MARK: - Root

enum MontageRoute: Hashable {
    case rendering
    case player
}

struct MontageRootView: View {
    @State private var flow = MontageFlow()
    @State private var path: [MontageRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            StoryboardView(flow: flow) {
                flow.render()
                path.append(.rendering)
            }
            .navigationDestination(for: MontageRoute.self) { route in
                switch route {
                case .rendering:
                    RenderingView(flow: flow) {
                        // Replace, so Back from the player returns to the
                        // editor rather than a finished progress bar.
                        path.removeLast()
                        path.append(.player)
                    } onCancel: {
                        flow.cancelRender()
                        path.removeLast()
                    }
                case .player:
                    PlayerView(flow: flow) {
                        flow.reset()
                        path.removeAll()
                    }
                }
            }
        }
        .onAppear(perform: connectWatch)
        .onChange(of: watchKey) { WatchSync.shared.sendStatus(flow) }
        .onChange(of: flow.outputURL) { _, url in
            guard let url else { return }
            WatchSync.shared.sendMontage(
                at: url,
                title: flow.trimmedTitle,
                seconds: Int(flow.estimatedDuration.rounded())
            )
        }
    }

    /// Everything the watch shows, in one value, so one onChange covers it.
    /// Progress is bucketed to 5% steps — the watch doesn't need every frame.
    private var watchKey: String {
        [
            "\(flow.selectedIDs.count)", flow.title, flow.theme.id,
            flow.customAudioName ?? "", "\(flow.isRendering)",
            "\(Int(flow.renderProgress * 20))",
        ].joined(separator: "|")
    }

    /// The watch's Export button runs the same steps as the iPhone's.
    private func connectWatch() {
        WatchSync.shared.start()
        WatchSync.shared.onExportRequest = {
            if flow.isRendering { return "Already exporting on your iPhone." }
            guard flow.canRender else {
                return "Add at least \(MontageImporter.minSelection) photos on your iPhone first."
            }
            guard path.isEmpty else { return "Go back to the editor on your iPhone first." }
            flow.render()
            path.append(.rendering)
            return nil
        }
        WatchSync.shared.sendStatus(flow)
    }
}

// MARK: - Rendering

struct RenderingView: View {
    @Bindable var flow: MontageFlow
    var onFinished: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if let error = flow.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't finish", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Try again") { flow.render() }
                        .buttonStyle(.borderedProminent)
                    Button("Back", action: onCancel)
                }
            } else {
                ProgressView(value: flow.renderProgress) {
                    Text("Making your montage")
                        .font(.headline)
                } currentValueLabel: {
                    Text("\(Int(flow.renderProgress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)

                Text("Every frame is drawn on this device. Longer montages take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
            }
        }
        .padding()
        .navigationTitle("Rendering")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .onChange(of: flow.outputURL) { _, url in
            if url != nil { onFinished() }
        }
    }
}

// MARK: - Player

struct PlayerView: View {
    @Bindable var flow: MontageFlow
    var onStartOver: () -> Void

    @AppStorage("saveDestination") private var destination: SaveDestination = .ask

    @State private var player: AVPlayer?
    @State private var shareURL: URL?
    @State private var photosState: SaveState = .idle
    @State private var filesState: SaveState = .idle
    @State private var showingFolderPicker = false
    @State private var didAutoSave = false
    @State private var confirmingStartOver = false

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let url = flow.outputURL {
                    VideoPlayer(player: player)
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    saveButtons(for: shareURL ?? url)
                    status
                    preference
                } else {
                    ContentUnavailableView("No montage yet", systemImage: "film")
                }

                Button("Start a new montage") { confirmingStartOver = true }
                    .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Your montage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prepare)
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showingFolderPicker) {
            if let file = shareURL ?? flow.outputURL {
                FolderExporter(url: file) { saved in
                    showingFolderPicker = false
                    filesState = saved ? .saved : .idle
                }
                .ignoresSafeArea()
            }
        }
        .confirmationDialog(
            "Start a new montage?",
            isPresented: $confirmingStartOver,
            titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive, action: onStartOver)
        } message: {
            Text("This clears the photos, title and music from the editor. Videos you've already saved aren't touched.")
        }
    }

    // MARK: Save

    private func saveButtons(for file: URL) -> some View {
        HStack(spacing: 10) {
            destinationButton(
                title: photosTitle,
                icon: photosState == .saved ? "checkmark.circle.fill" : "photo.on.rectangle",
                prominent: destination == .photos
            ) {
                saveToPhotos(file)
            }
            .disabled(photosState == .saving || photosState == .saved)

            destinationButton(
                title: filesState == .saved ? "Saved" : "Files",
                icon: filesState == .saved ? "checkmark.circle.fill" : "folder",
                prominent: destination == .files
            ) {
                showingFolderPicker = true
            }

            ShareLink(item: file) {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up").font(.title2)
                    Text("Share").font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.bordered)
        }
    }

    private func destinationButton(
        title: String,
        icon: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(BorderedProminentButtonStyle()) : AnyPrimitiveButtonStyle(BorderedButtonStyle()))
    }

    private var photosTitle: String {
        switch photosState {
        case .idle:    "Photos"
        case .saving:  "Saving…"
        case .saved:   "Saved"
        case .failed:  "Try again"
        }
    }

    @ViewBuilder
    private var status: some View {
        if case .failed(let message) = photosState {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if photosState == .saved || filesState == .saved {
            Text(savedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Files lets you pick On My iPhone, iCloud Drive, or Google Drive and Dropbox if you've added them to Files. Share sends it anywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var savedSummary: String {
        switch (photosState == .saved, filesState == .saved) {
        case (true, true):  "Saved to Photos and to your folder."
        case (true, false): "Saved to your Photos library."
        default:            "Saved to the folder you picked."
        }
    }

    private var preference: some View {
        HStack {
            Text("When a video is ready")
                .font(.subheadline)
            Spacer()
            Picker("When a video is ready", selection: $destination) {
                ForEach(SaveDestination.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Actions

    /// Runs once per finished video: give it a proper name, then save it
    /// wherever the user said to last time.
    private func prepare() {
        guard let url = flow.outputURL else { return }
        if player == nil { player = AVPlayer(url: url) }
        if shareURL == nil {
            shareURL = ExportNaming.namedCopy(of: url, title: flow.trimmedTitle)
        }

        guard !didAutoSave else { return }
        didAutoSave = true
        switch destination {
        case .photos: saveToPhotos(shareURL ?? url)
        case .files:  showingFolderPicker = true
        case .ask:    break
        }
    }

    /// Writing back needs NSPhotoLibraryAddUsageDescription — a separate
    /// permission from reading, and the only photo permission this app asks
    /// for. Missing it terminates the process.
    private func saveToPhotos(_ url: URL) {
        photosState = .saving
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                photosState = .saved
            } catch {
                photosState = .failed("Couldn't save to Photos. Allow it in Settings → Privacy & Security → Photos → CRS Memories. (\(error.localizedDescription))")
            }
        }
    }
}

/// Lets one button switch between bordered and prominent without two
/// copies of its label.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
