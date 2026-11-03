//
//  StoryboardView.swift
//
//  The whole editor, and the app's home screen.
//
//  Browse, import, name it, reorder, restyle, put sound on the montage or on
//  a single clip, watch it play, export — all here. Browsing is the system
//  photo picker, so it's the Photos app's own browser with albums, years,
//  people and search; what comes back appears in the clip list.
//
//  The preview is SwiftUI animating the real timeline rather than a rendered
//  file, so it's instant and free. It shares MontageTimeline with the
//  renderer, which is what keeps what you watch and what you export in
//  agreement.
//

import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

struct StoryboardView: View {
    @Bindable var flow: MontageFlow
    var onExport: () -> Void

    @State private var importer = MontageImporter()
    @State private var picked: [PhotosPickerItem] = []

    @State private var isPlaying = true
    @State private var editMode: EditMode = .inactive
    @State private var showingAudioPicker = false
    @State private var audioError: String?

    /// Which clip the file picker is about to put a sound on. Nil means the
    /// pick is the montage's music instead.
    @State private var soundTarget: String?

    var body: some View {
        Group {
            if importer.isImporting {
                importing
            } else if flow.selectedIDs.isEmpty {
                empty
            } else {
                editor
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !flow.selectedIDs.isEmpty && !importer.isImporting {
                exportBar
            }
        }
        .navigationTitle("Montage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !flow.selectedIDs.isEmpty && !importer.isImporting {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                if room > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        picker { Label("Import more", systemImage: "plus") }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .fileImporter(
            isPresented: $showingAudioPicker,
            allowedContentTypes: [.audio]
        ) { result in
            adoptAudio(result)
        }
        // The picker hands its selection back here. Clearing it afterwards
        // matters: left populated, the same photos import again the next
        // time anything about the selection changes.
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let refs = await importer.importItems(items, room: room)
                flow.selectedIDs.append(contentsOf: refs)
                picked = []
            }
        }
    }

    private var room: Int {
        max(0, MontageImporter.maxSelection - flow.selectedIDs.count)
    }

    // MARK: - Importing

    /// `.ordered` is what makes the picker number your selections as you tap
    /// them, so the order you choose is the order the montage plays in.
    ///
    /// No `photoLibrary:` argument on purpose — that variant runs in-process
    /// and needs read authorization. Without it the picker runs in its own
    /// process, hands back only what you chose, and never asks for
    /// permission at all.
    private func picker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(
            selection: $picked,
            maxSelectionCount: max(room, 1),
            selectionBehavior: .ordered,
            matching: .images,
            label: label
        )
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Make a montage", systemImage: "photo.badge.plus")
        } description: {
            Text("Browse your library the same way you do in Photos. What you pick is copied in here — nothing is uploaded, and the app never reads the rest of your library.")
        } actions: {
            picker {
                Text("Browse Photos").frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var importing: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(importer.done),
                total: Double(max(importer.total, 1))
            )
            .progressViewStyle(.linear)
            .frame(maxWidth: 280)

            Text("Importing \(importer.done) of \(importer.total)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            MontagePreviewView(flow: flow, isPlaying: $isPlaying)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxHeight: 300)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)

            themeStrip
                .padding(.vertical, 10)

            list
        }
    }

    /// Tapping a theme restyles the montage under the playhead. That
    /// immediacy is most of what makes an editor feel like an editor.
    private var themeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MontageTheme.all) { theme in
                    Button {
                        flow.theme = theme
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name).font(.subheadline.weight(.medium))
                            Text(theme.blurb).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minWidth: 130, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(flow.theme == theme ? AnyShapeStyle(.tint.opacity(0.18))
                                                          : AnyShapeStyle(.quaternary.opacity(0.4)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.tint, lineWidth: flow.theme == theme ? 2 : 0)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var list: some View {
        List {
            titleSection
            clipSection
            musicSection
            creditsSection
        }
        .listStyle(.insetGrouped)
    }

    /// First, because it's the first thing a viewer sees and the first thing
    /// you'd think of. Left blank, the montage simply opens on photo one —
    /// no card, and certainly not today's date.
    private var titleSection: some View {
        Section {
            TextField("Name this montage", text: $flow.title)
                .font(.headline)
            TextField("Subtitle (optional)", text: $flow.subtitle)
        } header: {
            Text("Title")
        } footer: {
            Text(flow.hasTitle
                 ? "Opens on a title card."
                 : "No title yet — the montage will open straight on your first photo.")
        }
    }

    /// Credits are their own section now that they can run to several lines
    /// and roll. One line per credit; the roll paces itself to how many.
    private var creditsSection: some View {
        Section {
            TextField(
                "Credits (optional)",
                text: $flow.creditsLine,
                prompt: Text("Shot by…\nMusic by…"),
                axis: .vertical
            )
            .lineLimit(1...6)

            if flow.hasCredits {
                Toggle("Roll them up the screen", isOn: $flow.rollCredits)
            }
        } header: {
            Text("Credits")
        } footer: {
            Text(creditsFooter)
        }
    }

    private var creditsFooter: String {
        guard flow.hasCredits else {
            return "Leave blank to end on the last photo."
        }
        if flow.rollCredits {
            let seconds = Int(flow.creditsDuration.rounded())
            return "\(flow.creditLines.count) lines, rolling for about \(seconds) seconds."
        }
        return "Held as a card at the end."
    }

    /// A List, not a grid — reorder and delete come for free and behave
    /// correctly, which matters more here than looking like a filmstrip.
    private var clipSection: some View {
        Section {
            ForEach(Array(flow.selectedIDs.enumerated()), id: \.element) { index, ref in
                ClipRow(
                    ref: ref,
                    number: index + 1,
                    seconds: flow.theme.secondsPerPhoto,
                    sound: flow.clipSounds[ref],
                    caption: Binding(
                        get: { flow.caption(for: ref) },
                        set: { flow.setCaption($0, for: ref) }
                    )
                ) {
                    soundTarget = ref
                    audioError = nil
                    showingAudioPicker = true
                } onRemoveSound: {
                    flow.clearClipSound(for: ref)
                }
            }
            .onMove { source, destination in
                flow.selectedIDs.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                flow.removeClips(at: offsets)
            }
        } header: {
            Text("\(flow.selectedIDs.count) clips · drag to reorder")
        } footer: {
            Text("Type a caption to print it over that clip. Tap the microphone for a sound bite — it plays over that clip only, with the music ducked underneath.")
        }
    }

    private var musicSection: some View {
        Section {
            if let name = flow.customAudioName {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1)
                        Text("Loops to fit, fades out under the credits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { flow.clearAudio() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                Button {
                    soundTarget = nil
                    audioError = nil
                    showingAudioPicker = true
                } label: {
                    Label("Add music from Files", systemImage: "music.note.list")
                }
            }

            if let audioError {
                Text(audioError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Music")
        } footer: {
            Text("Any audio file you own — m4a, mp3, wav. Tracks bought or streamed from Apple Music are protected and can't be written into a video.")
        }
    }

    private var exportBar: some View {
        VStack(spacing: 6) {
            Text("About \(Int(flow.estimatedDuration.rounded())) seconds")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(action: onExport) {
                Text("Export video").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!flow.canRender)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Sound

    /// The picker hands back a URL outside the sandbox that stops working
    /// shortly afterwards, so the file is copied in before it's remembered.
    /// Skipping this is why "my music disappeared" bugs happen.
    private func adoptAudio(_ result: Result<URL, Error>) {
        let target = soundTarget
        soundTarget = nil

        switch result {
        case .failure(let error):
            audioError = error.localizedDescription

        case .success(let source):
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            do {
                let folder = URL.documentsDirectory.appending(
                    path: "Soundtrack",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )

                // UUID prefix so the montage's music and a dozen clip sounds
                // can share a filename without overwriting each other.
                let destination = folder.appending(
                    path: "\(UUID().uuidString)-\(source.lastPathComponent)"
                )
                try FileManager.default.copyItem(at: source, to: destination)

                let name = source.deletingPathExtension().lastPathComponent
                if let target {
                    flow.setClipSound(ClipSound(url: destination, name: name), for: target)
                } else {
                    flow.setAudio(url: destination, name: name)
                }
                audioError = nil
            } catch {
                audioError = "Couldn't read that file: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - One clip

struct ClipRow: View {
    let ref: String
    let number: Int
    let seconds: Double
    let sound: ClipSound?
    @Binding var caption: String
    var onAddSound: () -> Void
    var onRemoveSound: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ClipThumbnail(ref: ref)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Clip \(number)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("\(seconds, specifier: "%.1f")s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    if let sound {
                        Label(sound.name, systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                    }
                }

                // The caption is the row's main event, so it gets the field
                // rather than a disclosure or a sheet to dig it out of.
                TextField("Caption (optional)", text: $caption, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...3)
            }

            // .borderless, or the whole row becomes one big button and the
            // list's own tap handling stops working.
            Button(action: sound == nil ? onAddSound : onRemoveSound) {
                Image(systemName: sound == nil ? "mic.badge.plus" : "speaker.slash.circle.fill")
                    .font(.title3)
                    .foregroundStyle(sound == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Live preview

struct MontagePreviewView: View {
    @Bindable var flow: MontageFlow
    @Binding var isPlaying: Bool

    /// Loaded once and kept, so scrubbing and theme changes don't re-fetch.
    @State private var images: [String: UIImage] = [:]
    @State private var startedAt = Date()
    @State private var audio = PreviewAudio()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !isPlaying)) { context in
                let timeline = MontageTimeline(
                    photoCount: flow.selectedIDs.count,
                    theme: flow.theme,
                    includeTitle: flow.hasTitle,
                    includeCredits: flow.hasCredits,
                    creditsDuration: flow.creditsDuration
                )
                let elapsed = context.date.timeIntervalSince(startedAt)
                let time = timeline.total > 0
                    ? elapsed.truncatingRemainder(dividingBy: timeline.total)
                    : 0
                let showing = timeline.active(at: time)

                // Driving the clip sound from here is a side effect in a view
                // body, which is usually wrong — but PreviewAudio holds no
                // SwiftUI state, so nothing is invalidated by the call.
                let _ = audio.clip(
                    index: leadIndex(showing),
                    url: leadSound(showing),
                    playing: isPlaying
                )

                ZStack {
                    Color(flow.theme.background)

                    ForEach(showing, id: \.slot.index) { entry in
                        slotView(entry: entry, size: geo.size)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isPlaying.toggle() }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.caption)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
                .padding(8)
        }
        .task(id: flow.selectedIDs) { await loadMissing() }
        .onAppear { audio.update(url: flow.customAudioURL, playing: isPlaying) }
        .onChange(of: isPlaying) { _, playing in
            audio.update(url: flow.customAudioURL, playing: playing)
        }
        .onChange(of: flow.customAudioURL) { _, url in
            audio.update(url: url, playing: isPlaying)
        }
        // Leaving the screen has to silence it, or the montage keeps playing
        // over whatever the user does next.
        .onDisappear { audio.stop() }
    }

    private typealias Showing = (slot: MontageTimeline.Slot, progress: Double, alpha: Double)

    /// During a crossfade two slots are on screen; the sound follows whichever
    /// is more visible, so it changes over at the midpoint of the dissolve.
    private func lead(_ showing: [Showing]) -> Showing? {
        showing.max { $0.alpha < $1.alpha }
    }

    private func leadIndex(_ showing: [Showing]) -> Int? {
        lead(showing)?.slot.index
    }

    private func leadSound(_ showing: [Showing]) -> URL? {
        guard let index = leadIndex(showing),
              index >= 0, index < flow.selectedIDs.count
        else { return nil }
        return flow.clipSounds[flow.selectedIDs[index]]?.url
    }

    @ViewBuilder
    private func slotView(entry: Showing, size: CGSize) -> some View {
        let motion = MontageTimeline.motion(
            progress: entry.progress,
            zoom: flow.theme.zoom,
            zoomIn: entry.slot.zoomIn,
            panUp: entry.slot.panUp
        )

        Group {
            if entry.slot.index == -1 {
                card(lines: [flow.trimmedTitle, flow.trimmedSubtitle].filter { !$0.isEmpty },
                     font: .title2.weight(.semibold))
            } else if entry.slot.index >= flow.selectedIDs.count {
                credits(progress: entry.progress, size: size)
            } else if let image = images[flow.selectedIDs[entry.slot.index]] {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(entry.slot.moves ? motion.scale : 1)
                        .offset(y: entry.slot.moves ? size.height * motion.drift : 0)
                        .clipped()

                    // Held still over the moving photo, exactly as the
                    // renderer composites it.
                    if let text = flow.clipCaptions[flow.selectedIDs[entry.slot.index]],
                       !text.isEmpty {
                        caption(text, size: size)
                    }
                }
            } else {
                Color.black
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(entry.alpha)
    }

    /// Held as a card, or travelling up the screen. Both come from the same
    /// creditRoll the renderer uses, so the preview's pacing is the export's.
    @ViewBuilder
    private func credits(progress: Double, size: CGSize) -> some View {
        let lines = flow.creditLines.filter { !$0.isEmpty }

        if flow.rollCredits {
            ZStack {
                Color(flow.theme.background)
                VStack(spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(Color(flow.theme.titleColor))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .offset(y: size.height * MontageTimeline.creditRoll(progress: progress))
            }
            .clipped()
        } else {
            card(lines: lines, font: .footnote)
        }
    }

    private func caption(_ text: String, size: CGSize) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, size.width * 0.035)
                .padding(.vertical, size.width * 0.03)
                .background(
                    RoundedRectangle(cornerRadius: size.width * 0.028)
                        .fill(.black.opacity(0.42))
                )
                .padding(.horizontal, size.width * 0.08)
                .padding(.bottom, size.height * 0.20)
        }
    }

    private func card(lines: [String], font: Font) -> some View {
        ZStack {
            Color(flow.theme.background)
            Text(lines.joined(separator: "\n"))
                .font(font)
                .foregroundStyle(Color(flow.theme.titleColor))
                .multilineTextAlignment(.center)
                .padding(24)
        }
    }

    /// Only fetches photos it doesn't already hold — reordering and theme
    /// changes shouldn't cost a round trip to disk.
    private func loadMissing() async {
        for ref in flow.selectedIDs where images[ref] == nil {
            if let image = await PhotoLoader.thumbnail(for: ref, pixelSize: 900) {
                images[ref] = image
            }
        }
    }
}

/// The preview's sound: music looping underneath, and each clip's own sound
/// triggered as its clip comes up. Not frame-accurate with the picture on
/// purpose — it behaves as the exported file does, which is what's being
/// judged here.
@MainActor
final class PreviewAudio {
    private var music: AVAudioPlayer?
    private var musicURL: URL?

    private var clipPlayer: AVAudioPlayer?
    private var clipIndex: Int?
    private var clipStarted = false

    func update(url: URL?, playing: Bool) {
        if url != musicURL {
            music?.stop()
            music = nil
            musicURL = url

            if let url {
                // No security-scoped access needed: the file was copied into
                // the app's own container when it was picked.
                music = try? AVAudioPlayer(contentsOf: url)
                music?.numberOfLoops = -1
                music?.prepareToPlay()
            }
        }

        guard let music else { return }

        if playing {
            if !music.isPlaying {
                activateSession()
                music.play()
            }
        } else if music.isPlaying {
            music.pause()
        }
    }

    /// `index` is the slot currently most visible. A change is what starts a
    /// clip's sound — so it fires once per clip, not once per frame.
    func clip(index: Int?, url: URL?, playing: Bool) {
        if index != clipIndex {
            clipIndex = index
            clipStarted = false
            clipPlayer?.stop()
            clipPlayer = nil

            if let url {
                clipPlayer = try? AVAudioPlayer(contentsOf: url)
                clipPlayer?.prepareToPlay()
            }
        }

        // Music sits back while a clip has something to say, matching what
        // the export does.
        music?.volume = clipPlayer == nil ? 1.0 : 0.3

        guard let clipPlayer else { return }

        if playing {
            if !clipStarted {
                activateSession()
                clipPlayer.play()
                clipStarted = true
            } else if !clipPlayer.isPlaying, clipPlayer.currentTime > 0 {
                // Paused part way through rather than finished.
                clipPlayer.play()
            }
        } else if clipPlayer.isPlaying {
            clipPlayer.pause()
        }
    }

    func stop() {
        music?.stop()
        music = nil
        musicURL = nil

        clipPlayer?.stop()
        clipPlayer = nil
        clipIndex = nil
        clipStarted = false

        // notifyOthersOnDeactivation, not OthersOf — this is what lets music
        // the user had playing before resume when the preview stops.
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

struct ClipThumbnail: View {
    let ref: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: ref) {
            image = await PhotoLoader.thumbnail(for: ref, pixelSize: 160)
        }
    }
}
