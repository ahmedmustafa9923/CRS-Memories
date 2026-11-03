//
//  MontageFlow.swift
//
//  One observable object owns the whole flow. Views read from it and send it
//  intent; they hold no state of their own.
//

import Foundation
import Observation
import SwiftUI

/// A sound attached to one clip. The URL always points inside the app's own
/// container — a URL from the file picker stops working once the sheet closes.
struct ClipSound: Hashable {
    let url: URL
    let name: String
}

@Observable
@MainActor
final class MontageFlow {

    // Selection
    var selectedIDs: [String] = []

    // Style
    var theme: MontageTheme = .documentary
    var title: String = ""
    var subtitle: String = ""
    var creditsLine: String = ""

    /// Music under the whole montage.
    var customAudioURL: URL?
    var customAudioName: String?

    /// Sound attached to individual clips, keyed by the clip's ref. Plays over
    /// that clip only, with the music ducked underneath it.
    var clipSounds: [String: ClipSound] = [:]

    /// A line of text over one clip, keyed by the clip's ref. Sits still while
    /// the photo moves underneath it — a caption that drifts with the Ken
    /// Burns push reads as a mistake.
    var clipCaptions: [String: String] = [:]

    /// Credits that scroll up the screen at the end rather than sitting there.
    var rollCredits = false

    // Output
    var renderProgress: Double = 0
    var isRendering = false
    var outputURL: URL?
    var errorMessage: String?

    private var renderTask: Task<Void, Never>?
    private let renderer = MontageRenderer()

    var canRender: Bool {
        selectedIDs.count >= MontageImporter.minSelection && !isRendering
    }

    // MARK: - Titles

    /// Trimmed, because a title of three spaces should count as no title.
    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSubtitle: String {
        subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedCredits: String {
        creditsLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No title typed means no title card. The montage opens on the first
    /// photo instead of on a date nobody asked for.
    var hasTitle: Bool { !trimmedTitle.isEmpty }
    var hasCredits: Bool { !trimmedCredits.isEmpty }

    var creditLines: [String] {
        trimmedCredits
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A still card holds for a fixed beat. A roll has to last long enough to
    /// read, so it grows with the number of lines — and is capped, because a
    /// forty-second crawl over eight photos is a joke.
    var creditsDuration: Double {
        guard hasCredits else { return MontageTimeline.creditsDuration }
        guard rollCredits else { return MontageTimeline.creditsDuration }
        return min(22, max(5, 1.2 * Double(creditLines.count) + 3))
    }

    /// Asked of the timeline rather than worked out again here, so the
    /// number on the button and the length of the file can't disagree.
    var estimatedDuration: Double {
        MontageTimeline(
            photoCount: selectedIDs.count,
            theme: theme,
            includeTitle: hasTitle,
            includeCredits: hasCredits,
            creditsDuration: creditsDuration
        ).total
    }

    // MARK: - Clips

    /// Dropping a clip deletes the imported copy and any sound on it. The
    /// photo in the user's library is untouched — this only ever removes the
    /// app's own files.
    func removeClip(_ ref: String) {
        selectedIDs.removeAll { $0 == ref }
        clearClipSound(for: ref)
        clipCaptions[ref] = nil
        MontageImports.delete(ref)
    }

    func removeClips(at offsets: IndexSet) {
        let going = offsets.map { selectedIDs[$0] }
        selectedIDs.remove(atOffsets: offsets)
        for ref in going {
            clearClipSound(for: ref)
            clipCaptions[ref] = nil
            MontageImports.delete(ref)
        }
    }

    /// A caption of nothing but spaces is no caption. Storing it as nil keeps
    /// the renderer from drawing an empty scrim over the photo.
    func setCaption(_ text: String, for ref: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clipCaptions[ref] = trimmed.isEmpty ? nil : trimmed
    }

    func caption(for ref: String) -> String {
        clipCaptions[ref] ?? ""
    }

    // MARK: - Sound

    /// Never clearAudio() first: two picks of the same file would land on the
    /// same destination, and deleting "the old one" would delete the copy
    /// that was just made.
    func setAudio(url: URL, name: String) {
        if let old = customAudioURL, old.standardizedFileURL != url.standardizedFileURL {
            try? FileManager.default.removeItem(at: old)
        }
        customAudioURL = url
        customAudioName = name
    }

    /// Deletes the copy as well as forgetting it, so picking a dozen songs
    /// over an evening doesn't quietly fill the user's storage.
    func clearAudio() {
        if let url = customAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        customAudioURL = nil
        customAudioName = nil
    }

    func setClipSound(_ sound: ClipSound, for ref: String) {
        if let old = clipSounds[ref], old.url.standardizedFileURL != sound.url.standardizedFileURL {
            try? FileManager.default.removeItem(at: old.url)
        }
        clipSounds[ref] = sound
    }

    func clearClipSound(for ref: String) {
        if let old = clipSounds.removeValue(forKey: ref) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func clearAllClipSounds() {
        for sound in clipSounds.values {
            try? FileManager.default.removeItem(at: sound.url)
        }
        clipSounds = [:]
    }

    // MARK: - Lifecycle

    func reset() {
        renderTask?.cancel()
        renderTask = nil
        selectedIDs = []
        renderProgress = 0
        isRendering = false
        outputURL = nil
        errorMessage = nil
        clearAudio()
        clearAllClipSounds()

        // Starting over throws away the imported copies as well, so a long
        // evening of montages doesn't leave hundreds of orphaned JPEGs.
        MontageImports.removeAll(except: [])
    }

    func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
    }

    func render() {
        guard !isRendering else { return }

        isRendering = true
        renderProgress = 0
        outputURL = nil
        errorMessage = nil

        // Clip sounds are keyed by ref for the editor's benefit; the renderer
        // works in positions, so the translation happens here while the order
        // is still in front of us.
        var clipAudio: [Int: URL] = [:]
        var captions: [Int: String] = [:]
        for (index, ref) in selectedIDs.enumerated() {
            if let sound = clipSounds[ref] {
                clipAudio[index] = sound.url
            }
            if let caption = clipCaptions[ref], !caption.isEmpty {
                captions[index] = caption
            }
        }

        let spec = MontageSpec(
            photoRefs: selectedIDs,
            theme: theme,
            title: hasTitle ? trimmedTitle : nil,
            subtitle: trimmedSubtitle.isEmpty ? nil : trimmedSubtitle,
            credits: hasCredits ? creditLines : [],
            rollCredits: rollCredits,
            creditsDuration: creditsDuration,
            customAudioURL: customAudioURL,
            clipAudio: clipAudio,
            captions: captions
        )

        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.renderer.render(spec: spec) { fraction in
                    self.renderProgress = fraction
                }
                try Task.checkCancellation()
                self.renderProgress = 1
                self.outputURL = url
            } catch is CancellationError {
                // Left the screen. Not an error.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isRendering = false
        }
    }
}
