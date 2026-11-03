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

    @State private var saveState: SaveState = .idle

    enum SaveState { case idle, saving, saved, failed(String) }

    var body: some View {
        VStack(spacing: 16) {
            if let url = flow.outputURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        save(url)
                    } label: {
                        Label(saveLabel, systemImage: saveIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isSaveDisabled)
                }

                if case .failed(let message) = saveState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            } else {
                ContentUnavailableView("No montage yet", systemImage: "film")
            }

            Spacer()
            Button("Start over", action: onStartOver)
        }
        .padding()
        .navigationTitle("Your montage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var saveLabel: String {
        switch saveState {
        case .idle:    "Save to Photos"
        case .saving:  "Saving…"
        case .saved:   "Saved"
        case .failed:  "Try again"
        }
    }

    private var saveIcon: String {
        if case .saved = saveState { return "checkmark" }
        return "square.and.arrow.down"
    }

    private var isSaveDisabled: Bool {
        switch saveState {
        case .saving, .saved: true
        default: false
        }
    }

    /// Writing back needs NSPhotoLibraryAddUsageDescription — a separate
    /// permission from reading, and the only photo permission this app asks
    /// for. Missing it terminates the process.
    private func save(_ url: URL) {
        saveState = .saving
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }
}
