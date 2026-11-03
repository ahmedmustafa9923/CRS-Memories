//
//  MemoryAgent.swift
//
//  The assistant. It runs on Apple's on-device model (Foundation Models, iOS
//  26), so the photos and the conversation never leave the phone.
//
//  It works on the montage through tools — small functions the model can
//  call — rather than by writing text we then parse. Each tool does one
//  thing to MontageFlow, and each turn that changes anything can be undone
//  in one tap.
//

import Foundation
import Observation
import FoundationModels

// MARK: - Messages

struct AgentMessage: Identifiable {
    enum Role { case user, agent, notice }

    let id = UUID()
    let role: Role
    var text: String
    /// What the montage looked like before this reply changed it.
    var undo: FlowSnapshot?
}

/// The parts of the montage the assistant can change, so a turn can be
/// compared and rolled back.
struct FlowSnapshot: Equatable {
    var title: String
    var subtitle: String
    var credits: String
    var rollCredits: Bool
    var themeID: String
    var captions: [String: String]
    var order: [String]
    var musicURL: URL?
    var musicName: String?

    init(_ flow: MontageFlow) {
        title = flow.title
        subtitle = flow.subtitle
        credits = flow.creditsLine
        rollCredits = flow.rollCredits
        themeID = flow.theme.id
        captions = flow.clipCaptions
        order = flow.selectedIDs
        musicURL = flow.customAudioURL
        musicName = flow.customAudioName
    }

    /// Clips removed since the snapshot stay removed; clips added since stay,
    /// at the end. Undo puts words and order back — it never resurrects files.
    func restore(to flow: MontageFlow) {
        flow.title = title
        flow.subtitle = subtitle
        flow.creditsLine = credits
        flow.rollCredits = rollCredits
        if let theme = MontageTheme.all.first(where: { $0.id == themeID }) {
            flow.theme = theme
        }

        let present = Set(flow.selectedIDs)
        let known = Set(order)
        var restored = order.filter { present.contains($0) }
        restored += flow.selectedIDs.filter { !known.contains($0) }
        flow.selectedIDs = restored

        flow.clipCaptions = captions.filter { present.contains($0.key) }

        // Set directly rather than through setAudio, which would delete the
        // copy being replaced. Skipped if the old file has since gone.
        if musicURL == nil || FileManager.default.fileExists(atPath: musicURL!.path) {
            flow.customAudioURL = musicURL
            flow.customAudioName = musicName
        }
    }
}

// MARK: - Quick actions

enum AgentQuickAction: String, CaseIterable, Identifiable {
    case title, captions, music, story, credits, help

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:    "Write a title"
        case .captions: "Caption every photo"
        case .music:    "Pick a tune"
        case .story:    "Tell the story"
        case .credits:  "Write credits"
        case .help:     "How does this work?"
        }
    }

    var systemImage: String {
        switch self {
        case .title:    "textformat"
        case .captions: "captions.bubble"
        case .music:    "music.note"
        case .story:    "book"
        case .credits:  "list.bullet.rectangle"
        case .help:     "questionmark.circle"
        }
    }

    var prompt: String {
        switch self {
        case .title:
            "Look at my photos, then give the montage a short title and subtitle that fit them, and set them."
        case .captions:
            "Look at my photos and write a short caption for every clip, then set them all."
        case .music:
            "Look at my photos, then pick the built-in tune that best fits their mood and set it. Tell me why in one sentence."
        case .story:
            "Look at my photos in order and tell the story this montage shows, in one short paragraph. Don't change anything."
        case .credits:
            "Write short end credits for this montage and set them. Only use names I've told you."
        case .help:
            "What can you do for me, and how do I make a montage in this app?"
        }
    }

    var needsPhotos: Bool { self != .help }
}

// MARK: - Availability

enum AgentAvailability: Equatable {
    case ready, notEligible, turnedOff, downloading, unavailable

    var message: String {
        switch self {
        case .ready:
            "Ready."
        case .notEligible:
            "This iPhone doesn't support Apple Intelligence, which the assistant runs on. It needs an iPhone 15 Pro, iPhone 16 or newer."
        case .turnedOff:
            "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri to use the assistant."
        case .downloading:
            "Apple Intelligence is still downloading to this iPhone. Keep it on Wi-Fi and charging, then try again."
        case .unavailable:
            "The assistant isn't available on this device right now."
        }
    }
}

// MARK: - Agent

/// Identifiable so the editor can present its chat with `.sheet(item:)`.
@Observable
final class MemoryAgent: Identifiable {

    private(set) var messages: [AgentMessage] = []
    private(set) var isResponding = false
    private(set) var availability: AgentAvailability = .unavailable

    private let flow: MontageFlow
    private var session: LanguageModelSession?

    init(flow: MontageFlow) {
        self.flow = flow
        refreshAvailability()
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            availability = .ready
        case .unavailable(.deviceNotEligible):
            availability = .notEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            availability = .turnedOff
        case .unavailable(.modelNotReady):
            availability = .downloading
        default:
            availability = .unavailable
        }

        if availability == .ready, session == nil {
            session = makeSession()
            session?.prewarm()
        }
    }

    /// `shownAs` lets a quick action show its short label in the chat while
    /// the model gets the fuller instruction.
    func send(_ prompt: String, shownAs: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        messages.append(AgentMessage(role: .user, text: shownAs ?? trimmed))

        refreshAvailability()
        guard availability == .ready else {
            messages.append(AgentMessage(role: .notice, text: availability.message))
            return
        }

        isResponding = true
        let before = FlowSnapshot(flow)

        Task {
            let reply = await respond(to: trimmed, retrying: true)
            let changed = FlowSnapshot(flow) != before
            messages.append(AgentMessage(role: .agent, text: reply, undo: changed ? before : nil))
            isResponding = false
        }
    }

    func undo(_ message: AgentMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              let snapshot = messages[index].undo else { return }
        snapshot.restore(to: flow)
        messages[index].undo = nil
        messages.append(AgentMessage(role: .notice, text: "Undone — the montage is back how it was."))
    }

    func newChat() {
        guard !isResponding else { return }
        messages = []
        session = availability == .ready ? makeSession() : nil
    }

    // MARK: - Talking to the model

    private func respond(to prompt: String, retrying: Bool) async -> String {
        guard let session else { return availability.message }

        do {
            return try await session.respond(to: prompt).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // The on-device model has a small memory. Start a fresh
                // conversation and ask again rather than failing outright.
                self.session = makeSession()
                if retrying {
                    messages.append(AgentMessage(
                        role: .notice,
                        text: "The conversation got long, so I started a fresh one."
                    ))
                    return await respond(to: prompt, retrying: false)
                }
                return "That's too much for me to handle in one go. Try asking about fewer photos at a time."
            case .guardrailViolation:
                return "I can't help with that one. Try asking a different way."
            case .unsupportedLanguageOrLocale:
                return "I can't chat in that language yet. Try English or another language Apple Intelligence supports."
            case .assetsUnavailable:
                refreshAvailability()
                return availability.message
            case .decodingFailure, .rateLimited, .concurrentRequests:
                // Usually passing. A fresh session and one more try clears
                // most of these without the user ever seeing them.
                if retrying {
                    self.session = makeSession()
                    try? await Task.sleep(for: .milliseconds(400))
                    return await respond(to: prompt, retrying: false)
                }
                return "The assistant is busy or got confused. Please try again in a moment.\n\n(\(Self.detail(error)))"
            default:
                return "Something went wrong.\n\n(\(Self.detail(error)))"
            }
        } catch let error as LanguageModelSession.ToolCallError {
            // A tool failed. Start clean and try once more; if it fails
            // again, say which tool so it can be fixed.
            if retrying {
                self.session = makeSession()
                return await respond(to: prompt, retrying: false)
            }
            return "Something went wrong while using \(error.tool.name).\n\n(\(Self.detail(error.underlyingError)))"
        } catch {
            return "Something went wrong.\n\n(\(Self.detail(error)))"
        }
    }

    /// The full error, not just localizedDescription — Foundation Models'
    /// descriptions are often just "error -1", which tells nobody anything.
    private static func detail(_ error: any Error) -> String {
        String(reflecting: error)
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                GetMontageTool(flow: flow),
                SetTitleTool(flow: flow),
                SetCaptionsTool(flow: flow),
                SetCreditsTool(flow: flow),
                SetThemeTool(flow: flow),
                MoveClipTool(flow: flow),
                SetMusicTool(flow: flow),
            ],
            instructions: Self.instructions
        )
    }

    private static let instructions = """
    You are the assistant inside AI Gen Memories, an iPhone app that turns the user's photos into a short video montage. You help in four ways: writing titles and captions, editing the montage when asked, telling the story the photos show, and explaining how to use the app.

    Rules:
    - Before writing anything about the photos, call get_montage with includePhotos true. Photo details are labels from on-device image analysis plus the date taken. Treat them as hints, not facts.
    - Never invent names of people, pets or places. Use a name only if the user gave it.
    - When the user asks for a change, make it with the tools, then say in one short sentence what you changed. Every change can be undone with the Undo button under your reply.
    - Titles are 2 to 5 words. Subtitles and captions are under 8 words. No hashtags or emoji unless asked.
    - Keep replies to two or three sentences. A story is one paragraph under 120 words.
    - You can set one of the built-in tunes as the music with set_music. Match the tune to the mood: Golden Hour is warm piano, Quiet Roads is calm ambient, Weekend is upbeat pop, Cinematic Rise is big strings, Lo-fi Nights is a mellow beat.
    - You cannot add or delete photos, pick songs from the user's own library or files, or export. Tell the user how to do those themselves.

    How the app works:
    - "Browse Photos", or + at the top right, picks 3 to 60 photos, in the order they are tapped.
    - Drag a clip to reorder it. Swipe left on a clip to remove it.
    - The themes along the top change the pace and look: Documentary, Warm, Energetic.
    - Title, subtitle, captions and credits can also be typed straight into the editor.
    - Music: "Choose music" in the Music section offers five free built-in tunes, songs from the user's music library, or audio files from Files. The microphone on a clip adds a sound bite over that clip only. Songs streamed from Apple Music are protected and can't be used.
    - "Export video" at the bottom makes the video. After that it can be saved to Photos or shared.
    """
}

// MARK: - What the tools do

/// The tools are thin; the work happens here, on the main actor, where
/// MontageFlow lives.
enum AgentActions {

    static let photosPerPage = 20

    static func montage(flow: MontageFlow, includePhotos: Bool, startClip: Int) async -> String {
        var lines: [String] = []
        lines.append("Title: \(flow.hasTitle ? "\"\(flow.trimmedTitle)\"" : "none")")
        lines.append("Subtitle: \(flow.trimmedSubtitle.isEmpty ? "none" : "\"\(flow.trimmedSubtitle)\"")")
        let themes = MontageTheme.all.map { "\($0.id) (\($0.blurb))" }.joined(separator: ", ")
        lines.append("Theme: \(flow.theme.id). Available: \(themes)")
        lines.append(flow.hasCredits
                     ? "Credits: \(flow.creditLines.count) lines\(flow.rollCredits ? ", rolling" : ", held card")"
                     : "Credits: none")
        let tuneIDs = BuiltInTune.all.map(\.id).joined(separator: ", ")
        if let name = flow.customAudioName {
            let builtIn = BuiltInTune.matching(flow.customAudioURL) != nil
            lines.append("Music: \(name)\(builtIn ? " (built-in tune)" : " (the user's own song)"). Built-in tunes: \(tuneIDs)")
        } else {
            lines.append("Music: none. Built-in tunes: \(tuneIDs)")
        }
        lines.append("Clips: \(flow.selectedIDs.count), about \(Int(flow.estimatedDuration.rounded())) seconds")

        guard includePhotos, !flow.selectedIDs.isEmpty else {
            return lines.joined(separator: "\n")
        }

        let start = min(max(startClip, 1), flow.selectedIDs.count)
        let end = min(start + photosPerPage - 1, flow.selectedIDs.count)
        let refs = Array(flow.selectedIDs[(start - 1)..<end])
        let insights = await PhotoInsights.shared.insights(for: refs)

        lines.append("Photos \(start) to \(end):")
        for (offset, ref) in refs.enumerated() {
            var parts = ["\(start + offset)."]
            if let insight = insights[ref] {
                if let date = insight.date {
                    parts.append(date.formatted(date: .abbreviated, time: .omitted))
                }
                if !insight.labels.isEmpty {
                    parts.append(insight.labels.joined(separator: ", "))
                }
                if insight.faces > 0 {
                    parts.append(insight.faces == 1 ? "1 face" : "\(insight.faces) faces")
                }
            }
            if let caption = flow.clipCaptions[ref] {
                parts.append("caption \"\(caption)\"")
            }
            lines.append(parts.joined(separator: " · "))
        }
        if end < flow.selectedIDs.count {
            lines.append("More photos: call get_montage again with startClip \(end + 1).")
        }
        return lines.joined(separator: "\n")
    }

    static func setTitle(flow: MontageFlow, title: String, subtitle: String?) -> String {
        flow.title = title
        if let subtitle { flow.subtitle = subtitle }
        return "Title set to \"\(flow.trimmedTitle)\"."
    }

    static func setCaptions(flow: MontageFlow, items: [(clip: Int, caption: String)]) -> String {
        var set = 0
        for item in items where flow.selectedIDs.indices.contains(item.clip - 1) {
            flow.setCaption(item.caption, for: flow.selectedIDs[item.clip - 1])
            set += 1
        }
        let skipped = items.count - set
        return skipped == 0
            ? "Set \(set) captions."
            : "Set \(set) captions. Skipped \(skipped) with clip numbers outside 1 to \(flow.selectedIDs.count)."
    }

    static func setCredits(flow: MontageFlow, lines: [String], roll: Bool) -> String {
        flow.creditsLine = lines.joined(separator: "\n")
        flow.rollCredits = roll && flow.hasCredits
        return flow.hasCredits ? "Credits set, \(flow.creditLines.count) lines." : "Credits cleared."
    }

    static func setTheme(flow: MontageFlow, id: String) -> String {
        guard let theme = MontageTheme.all.first(where: { $0.id == id.lowercased() }) else {
            return "No theme called \(id). Use one of: \(MontageTheme.all.map(\.id).joined(separator: ", "))."
        }
        flow.theme = theme
        return "Theme set to \(theme.name)."
    }

    /// Sets the music directly, without deleting what it replaces, so the
    /// user's own song comes back if they tap Undo.
    static func setMusic(flow: MontageFlow, id: String) -> String {
        if id == "none" {
            flow.customAudioURL = nil
            flow.customAudioName = nil
            return "Music removed."
        }
        guard let tune = BuiltInTune.all.first(where: { $0.id == id }), let url = tune.url else {
            return "No tune called \(id). Use one of: \(BuiltInTune.all.map(\.id).joined(separator: ", ")), or none."
        }
        flow.customAudioURL = url
        flow.customAudioName = tune.name
        return "Music set to \(tune.name)."
    }

    static func moveClip(flow: MontageFlow, from: Int, to: Int) -> String {
        let count = flow.selectedIDs.count
        guard (1...max(count, 1)).contains(from), count > 0 else {
            return "There is no clip \(from). Clips are numbered 1 to \(count)."
        }
        let target = min(max(to, 1), count)
        let ref = flow.selectedIDs.remove(at: from - 1)
        flow.selectedIDs.insert(ref, at: target - 1)
        return "Moved clip \(from) to position \(target)."
    }
}

// MARK: - Tools

nonisolated struct GetMontageTool: Tool {
    let flow: MontageFlow
    let name = "get_montage"
    let description = "Reads the montage: title, theme, credits, music, and optionally what is in each photo and when it was taken."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "True to include a line describing each photo.")
        var includePhotos: Bool
        @Guide(description: "First clip number to describe, starting at 1. Up to 20 photos are returned per call.")
        var startClip: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let include = arguments.includePhotos
        let start = arguments.startClip
        return await AgentActions.montage(flow: flow, includePhotos: include, startClip: start)
    }
}

nonisolated struct SetTitleTool: Tool {
    let flow: MontageFlow
    let name = "set_title"
    let description = "Sets the montage title, and the subtitle if one is given."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The title, 2 to 5 words.")
        var title: String
        @Guide(description: "An optional subtitle, under 8 words.")
        var subtitle: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let title = arguments.title
        let subtitle = arguments.subtitle
        return await AgentActions.setTitle(flow: flow, title: title, subtitle: subtitle)
    }
}

@Generable
nonisolated struct ClipCaption {
    @Guide(description: "The clip number, starting at 1.")
    var clip: Int
    @Guide(description: "The caption, under 8 words. Empty text removes the caption.")
    var caption: String
}

nonisolated struct SetCaptionsTool: Tool {
    let flow: MontageFlow
    let name = "set_captions"
    let description = "Sets the caption printed over one or more clips."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "One entry per clip to caption.")
        var captions: [ClipCaption]
    }

    func call(arguments: Arguments) async throws -> String {
        let items = arguments.captions.map { (clip: $0.clip, caption: $0.caption) }
        return await AgentActions.setCaptions(flow: flow, items: items)
    }
}

nonisolated struct SetCreditsTool: Tool {
    let flow: MontageFlow
    let name = "set_credits"
    let description = "Sets the end credits, one line per credit. An empty list removes them."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The credit lines, in order.")
        var lines: [String]
        @Guide(description: "True to roll the credits up the screen, false to hold them as a card.")
        var roll: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        let lines = arguments.lines
        let roll = arguments.roll
        return await AgentActions.setCredits(flow: flow, lines: lines, roll: roll)
    }
}

nonisolated struct SetThemeTool: Tool {
    let flow: MontageFlow
    let name = "set_theme"
    let description = "Changes the montage theme, which sets its pace and look."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The theme id.", .anyOf(["documentary", "warm", "energetic"]))
        var theme: String
    }

    func call(arguments: Arguments) async throws -> String {
        let id = arguments.theme
        return await AgentActions.setTheme(flow: flow, id: id)
    }
}

nonisolated struct MoveClipTool: Tool {
    let flow: MontageFlow
    let name = "move_clip"
    let description = "Moves one clip to a new position in the montage."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The clip number to move, starting at 1.")
        var from: Int
        @Guide(description: "The position to move it to, starting at 1.")
        var to: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let from = arguments.from
        let to = arguments.to
        return await AgentActions.moveClip(flow: flow, from: from, to: to)
    }
}

nonisolated struct SetMusicTool: Tool {
    let flow: MontageFlow
    let name = "set_music"
    let description = "Sets one of the app's built-in tunes as the montage music, or removes the music."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The tune id, or none to remove the music.",
               .anyOf(["golden-hour", "quiet-roads", "weekend", "cinematic-rise", "lofi-nights", "none"]))
        var tune: String
    }

    func call(arguments: Arguments) async throws -> String {
        let id = arguments.tune
        return await AgentActions.setMusic(flow: flow, id: id)
    }
}
