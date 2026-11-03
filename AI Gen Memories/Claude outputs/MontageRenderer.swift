//
//  MontageRenderer.swift
//
//  Photos in, an MP4 out.
//
//  Two deliberate choices:
//
//  1. AVAssetWriter with a pixel buffer adaptor, not
//     AVVideoCompositionCoreAnimationTool. The Core Animation route is the
//     textbook one and is also notorious for hanging mid-export. Writing
//     frames ourselves means every frame is a pure function of a timestamp —
//     which is slower to write and far easier to debug.
//
//  2. Title and credit cards are pre-rendered to images before the loop
//     starts. That makes the whole timeline a list of pictures, so the frame
//     renderer only ever does one job: composite images with a transform and
//     an alpha. No per-frame text layout.
//

import AVFoundation
import CoreImage
import UIKit

// MARK: - Spec

struct MontageSpec {
    var photoRefs: [String]          // PHAsset local identifiers
    var theme: MontageTheme
    var title: String
    var subtitle: String?
    var credits: [String]

    /// 1080 × 1920 portrait by default — the shape most of these get watched in.
    var size = CGSize(width: 1080, height: 1920)
    var fps: Int32 = 30

    /// Audio the user supplied, or nil to use the theme's bundled track.
    var customAudioURL: URL?
}

// MARK: - Theme

struct MontageTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String

    var background: CGColor
    var titleColor: UIColor
    var titleFont: UIFont
    var captionFont: UIFont

    /// Seconds each photo holds on screen, before the crossfade.
    var secondsPerPhoto: Double
    var crossfade: Double

    /// How far the Ken Burns move travels. 0 is a locked-off still; 0.18 is
    /// a noticeable but not seasick push.
    var zoom: Double

    /// Bundled track, without extension. Nil means silence.
    var trackName: String?

    static let all: [MontageTheme] = [.documentary, .warm, .energetic]

    static let documentary = MontageTheme(
        id: "documentary",
        name: "Documentary",
        blurb: "Slow, plain, observed",
        background: UIColor.black.cgColor,
        titleColor: .white,
        titleFont: .systemFont(ofSize: 96, weight: .semibold),
        captionFont: .systemFont(ofSize: 44, weight: .regular),
        secondsPerPhoto: 3.2,
        crossfade: 0.8,
        zoom: 0.10,
        trackName: nil
    )

    static let warm = MontageTheme(
        id: "warm",
        name: "Warm",
        blurb: "Unhurried, soft edges",
        background: UIColor(red: 0.08, green: 0.06, blue: 0.10, alpha: 1).cgColor,
        titleColor: UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1),
        titleFont: .systemFont(ofSize: 92, weight: .medium),
        captionFont: .systemFont(ofSize: 42, weight: .regular),
        secondsPerPhoto: 3.6,
        crossfade: 1.0,
        zoom: 0.14,
        trackName: nil
    )

    static let energetic = MontageTheme(
        id: "energetic",
        name: "Energetic",
        blurb: "Quick cuts, more movement",
        background: UIColor.black.cgColor,
        titleColor: .white,
        titleFont: .systemFont(ofSize: 104, weight: .heavy),
        captionFont: .systemFont(ofSize: 46, weight: .semibold),
        secondsPerPhoto: 1.6,
        crossfade: 0.25,
        zoom: 0.22,
        trackName: nil
    )
}

// MARK: - Timeline

/// One picture on screen for a stretch of time. Photos, the title card and
/// the credits are all the same kind of thing by the time we render.
private struct Segment {
    let image: CIImage
    let start: Double
    let duration: Double
    let zoomIn: Bool       // alternated, so the movement doesn't get monotonous
    let panUp: Bool
    let applyKenBurns: Bool
}

// MARK: - Renderer

/// Not main-actor isolated. Frame rendering runs on a background queue, and
/// everything here is either immutable or a thread-safe Core Image context —
/// only the progress callback hops back to the main actor.
final class MontageRenderer: @unchecked Sendable {

    enum RenderError: LocalizedError {
        case noPhotos
        case cannotCreateWriter
        case noPixelBufferPool
        case writeFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPhotos:            "Pick some photos first."
            case .cannotCreateWriter:  "Couldn't start writing the video."
            case .noPixelBufferPool:   "Couldn't allocate video memory. Try fewer photos."
            case .writeFailed(let m):  "Writing the video failed: \(m)"
            case .exportFailed(let m): "Adding the soundtrack failed: \(m)"
            }
        }
    }

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Renders the montage and returns a file URL in the temporary directory.
    /// `progress` is called on the main actor with 0...1.
    func render(
        spec: MontageSpec,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {

        guard !spec.photoRefs.isEmpty else { throw RenderError.noPhotos }

        // 1. Load everything up front. Rendering must never wait on I/O
        //    inside the frame loop or the writer stalls.
        let images = await loadImages(refs: spec.photoRefs, target: spec.size)
        guard !images.isEmpty else { throw RenderError.noPhotos }

        let titleCard = makeCard(
            lines: [spec.title] + (spec.subtitle.map { [$0] } ?? []),
            spec: spec,
            isTitle: true
        )
        let creditsCard = makeCard(lines: spec.credits, spec: spec, isTitle: false)

        let segments = buildTimeline(
            photos: images,
            titleCard: titleCard,
            creditsCard: creditsCard,
            theme: spec.theme
        )

        let totalDuration = segments.last.map { $0.start + $0.duration } ?? 0

        // 2. Video first, silent.
        let videoURL = try await writeVideo(
            segments: segments,
            duration: totalDuration,
            spec: spec,
            progress: progress
        )

        // 3. Then the soundtrack, if there is one.
        guard let audioURL = resolveAudio(spec: spec) else { return videoURL }
        return try await mux(video: videoURL, audio: audioURL, duration: totalDuration)
    }

    // MARK: - Timeline

    private func buildTimeline(
        photos: [CIImage],
        titleCard: CIImage,
        creditsCard: CIImage,
        theme: MontageTheme
    ) -> [Segment] {

        var segments: [Segment] = []
        var cursor: Double = 0

        func append(_ image: CIImage, duration: Double, kenBurns: Bool, index: Int) {
            segments.append(
                Segment(
                    image: image,
                    start: cursor,
                    duration: duration,
                    // Alternate direction so a long montage doesn't feel
                    // like the same move repeated forty times.
                    zoomIn: index % 2 == 0,
                    panUp: (index / 2) % 2 == 0,
                    applyKenBurns: kenBurns
                )
            )
            cursor += duration - theme.crossfade
        }

        append(titleCard, duration: 2.6, kenBurns: false, index: 0)

        for (index, photo) in photos.enumerated() {
            append(photo,
                   duration: theme.secondsPerPhoto + theme.crossfade,
                   kenBurns: true,
                   index: index)
        }

        append(creditsCard, duration: 3.4, kenBurns: false, index: 0)

        return segments
    }

    // MARK: - Frame rendering

    /// Every frame is a pure function of `time`. That is what makes this
    /// debuggable — you can render frame 417 on its own and look at it.
    private func frame(at time: Double, segments: [Segment], spec: MontageSpec) -> CIImage {
        let canvas = CGRect(origin: .zero, size: spec.size)

        var output = CIImage(color: CIColor(cgColor: spec.theme.background))
            .cropped(to: canvas)

        for segment in segments {
            let end = segment.start + segment.duration
            guard time >= segment.start, time < end else { continue }

            let progress = (time - segment.start) / segment.duration
            let alpha = fadeAlpha(
                progress: progress,
                duration: segment.duration,
                crossfade: spec.theme.crossfade,
                isFirst: segment.start == 0
            )
            guard alpha > 0.001 else { continue }

            var image = fit(segment.image, into: canvas)

            if segment.applyKenBurns {
                image = kenBurns(
                    image,
                    canvas: canvas,
                    progress: progress,
                    zoom: spec.theme.zoom,
                    zoomIn: segment.zoomIn,
                    panUp: segment.panUp
                )
            }

            if alpha < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
            }

            output = image.composited(over: output)
        }

        return output.cropped(to: canvas)
    }

    private func fadeAlpha(progress: Double, duration: Double, crossfade: Double, isFirst: Bool) -> Double {
        guard crossfade > 0 else { return 1 }
        let fadePortion = min(0.49, crossfade / duration)

        // Fade in, unless this is the very first thing on screen — a montage
        // that starts on black and fades up reads as a mistake at 0.25s.
        if !isFirst, progress < fadePortion {
            return progress / fadePortion
        }
        if progress > 1 - fadePortion {
            return (1 - progress) / fadePortion
        }
        return 1
    }

    /// Aspect-fill into the canvas, centred.
    private func fit(_ image: CIImage, into canvas: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = max(canvas.width / extent.width, canvas.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let dx = canvas.midX - scaled.extent.midX
        let dy = canvas.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    /// The move. Scale grows or shrinks across the segment and the frame
    /// drifts, both eased so it starts and ends gently.
    private func kenBurns(
        _ image: CIImage,
        canvas: CGRect,
        progress: Double,
        zoom: Double,
        zoomIn: Bool,
        panUp: Bool
    ) -> CIImage {
        let eased = progress * progress * (3 - 2 * progress)   // smoothstep
        let amount = zoomIn ? eased : (1 - eased)

        let scale = 1 + zoom * amount
        let drift = canvas.height * zoom * 0.25 * (panUp ? amount : -amount)

        let centred = image.transformed(
            by: CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
        )
        let scaled = centred.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(
            by: CGAffineTransform(translationX: canvas.midX, y: canvas.midY + drift)
        )
    }

    // MARK: - Writing

    private func writeVideo(
        segments: [Segment],
        duration: Double,
        spec: MontageSpec,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montage-\(UUID().uuidString).mp4")

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw RenderError.cannotCreateWriter
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(spec.size.width),
            AVVideoHeightKey: Int(spec.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(spec.size.width),
                kCVPixelBufferHeightKey as String: Int(spec.size.height)
            ]
        )

        guard writer.canAdd(input) else { throw RenderError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(duration * Double(spec.fps))
        let context = self.context

        // AVAssetWriterInput and the adaptor aren't Sendable, and the
        // media-data callback is. Only this one queue ever touches them, in
        // order, so the escape hatch is safe — but it is an escape hatch, so
        // don't start using these from anywhere else.
        nonisolated(unsafe) let writerInput = input
        nonisolated(unsafe) let bufferAdaptor = adaptor

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "montage.render")
            var frameIndex = 0

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard frameIndex < totalFrames else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }

                    guard let pool = bufferAdaptor.pixelBufferPool else {
                        continuation.resume(throwing: RenderError.noPixelBufferPool)
                        return
                    }

                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let pixelBuffer = buffer else {
                        continuation.resume(throwing: RenderError.noPixelBufferPool)
                        return
                    }

                    let time = Double(frameIndex) / Double(spec.fps)
                    let image = self.frame(at: time, segments: segments, spec: spec)
                    context.render(image, to: pixelBuffer)

                    let presentation = CMTimeMake(
                        value: Int64(frameIndex),
                        timescale: spec.fps
                    )
                    if !bufferAdaptor.append(pixelBuffer, withPresentationTime: presentation) {
                        continuation.resume(
                            throwing: RenderError.writeFailed("frame \(frameIndex) rejected")
                        )
                        return
                    }

                    frameIndex += 1

                    if frameIndex % 15 == 0 {
                        let fraction = Double(frameIndex) / Double(totalFrames)
                        Task { @MainActor in progress(fraction * 0.9) }
                    }
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw RenderError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return url
    }

    // MARK: - Audio

    private func resolveAudio(spec: MontageSpec) -> URL? {
        if let custom = spec.customAudioURL { return custom }
        guard let name = spec.theme.trackName else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "m4a")
    }

    /// Video is copied through untouched; only the audio is re-encoded, so
    /// this step is quick even for a long montage.
    private func mux(video videoURL: URL, audio audioURL: URL, duration: Double) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))

        guard
            let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RenderError.exportFailed("no video track")
        }
        try compVideo.insertTimeRange(range, of: videoTrack, at: .zero)

        var audioMix: AVMutableAudioMix?

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {

            // Loop or trim the track to the montage's length. A soundtrack
            // that stops dead two thirds through is the single most amateur
            // thing a montage can do.
            let trackDuration = try await audioAsset.load(.duration)
            var filled = CMTime.zero
            while filled < range.duration, trackDuration.seconds > 0.1 {
                let remaining = range.duration - filled
                let chunk = min(remaining, trackDuration)
                try compAudio.insertTimeRange(
                    CMTimeRange(start: .zero, duration: chunk),
                    of: audioTrack,
                    at: filled
                )
                filled = filled + chunk
            }

            // Fade the last two seconds rather than cutting.
            let fade = CMTime(seconds: 2, preferredTimescale: 600)
            let parameters = AVMutableAudioMixInputParameters(track: compAudio)
            parameters.setVolumeRamp(
                fromStartVolume: 1.0,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: range.duration - fade, duration: fade)
            )
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            audioMix = mix
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("montage-\(UUID().uuidString)-final.mp4")

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RenderError.exportFailed("couldn't create export session")
        }

        export.audioMix = audioMix

        // export(to:as:) supersedes the export()/status/error dance, which is
        // deprecated from iOS 18. It throws instead of leaving you to poll.
        do {
            try await export.export(to: outputURL, as: .mp4)
        } catch {
            throw RenderError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }

    // MARK: - Cards

    /// Title and credits become images before rendering starts, so the frame
    /// loop never lays out text.
    private func makeCard(lines: [String], spec: MontageSpec, isTitle: Bool) -> CIImage {
        let renderer = UIGraphicsImageRenderer(size: spec.size)
        let font = isTitle ? spec.theme.titleFont : spec.theme.captionFont
        let color = spec.theme.titleColor

        let image = renderer.image { ctx in
            ctx.cgContext.setFillColor(spec.theme.background)
            ctx.cgContext.fill(CGRect(origin: .zero, size: spec.size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = font.pointSize * 0.25

            let text = lines.joined(separator: "\n")
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ])

            let inset = spec.size.width * 0.10
            let bounds = CGSize(width: spec.size.width - inset * 2, height: .greatestFiniteMagnitude)
            let rect = attributed.boundingRect(
                with: bounds,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            attributed.draw(with: CGRect(
                x: inset,
                y: (spec.size.height - rect.height) / 2,
                width: bounds.width,
                height: rect.height
            ), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }

        return CIImage(image: image) ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: spec.size))
    }

    // MARK: - Loading

    /// Loaded at canvas size, not full resolution. A 48-megapixel original
    /// costs memory and buys nothing at 1080 wide.
    private func loadImages(refs: [String], target: CGSize) async -> [CIImage] {
        var output: [CIImage] = []
        for ref in refs {
            if let image = await PhotoLoader.image(for: ref, target: target),
               let ci = CIImage(image: image) {
                output.append(ci)
            }
        }
        return output
    }
}
