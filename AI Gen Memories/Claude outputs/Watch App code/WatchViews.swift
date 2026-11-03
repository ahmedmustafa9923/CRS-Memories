//
//  WatchViews.swift  (Apple Watch side)
//
//  Two pages, swiped vertically with the Digital Crown:
//  • Now — what's in the editor on the iPhone, with an Export button.
//  • Montages — the videos you've exported, to replay on your wrist.
//

import SwiftUI
import AVKit
import AVFoundation

struct WatchRootView: View {
    @State private var link = PhoneLink.shared

    var body: some View {
        NavigationStack {
            TabView {
                NowPage(link: link)
                MontagesPage(link: link)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: WatchMontage.self) { montage in
                MontagePlayer(montage: montage)
            }
        }
    }
}

// MARK: - Now

struct NowPage: View {
    @Bindable var link: PhoneLink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let status = link.status {
                    Text(status.title.isEmpty ? "Untitled montage" : status.title)
                        .font(.headline)
                        .lineLimit(2)

                    Text("\(status.clips) clips · \(status.seconds)s")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !status.music.isEmpty {
                        Label(status.music, systemImage: "music.note")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if status.rendering {
                        ProgressView(value: status.progress) {
                            Text("Exporting \(Int(status.progress * 100))%")
                                .font(.caption)
                        }
                        .tint(.pink)
                        .padding(.top, 4)
                    } else {
                        Button {
                            link.requestExport()
                        } label: {
                            Label(link.isSendingExport ? "Sending…" : "Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.pink)
                        .disabled(!status.canExport || link.isSendingExport)
                        .padding(.top, 4)

                        if !status.canExport {
                            Text("Add at least \(status.minClips) photos on your iPhone to export.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(.pink)
                    Text("Open CRS Memories on your iPhone to start a montage.")
                        .font(.footnote)
                }

                if let message = link.exportMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !link.reachable && link.status != nil {
                    Label("iPhone not reachable", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("CRS Memories")
        .onAppear { link.refreshStatus() }
    }
}

// MARK: - Montages

struct MontagesPage: View {
    @Bindable var link: PhoneLink

    var body: some View {
        Group {
            if link.montages.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundStyle(.pink)
                    Text("Montages you export on your iPhone appear here.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    ForEach(link.montages) { montage in
                        NavigationLink(value: montage) {
                            MontageRow(montage: montage)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { link.delete(link.montages[index]) }
                    }
                }
            }
        }
        .navigationTitle("Montages")
    }
}

struct MontageRow: View {
    let montage: WatchMontage

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let data = montage.poster, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.pink.opacity(0.3)
                }
            }
            .frame(width: 30, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(montage.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                Text(montage.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MontagePlayer: View {
    let montage: WatchMontage
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(montage.title)
            .onAppear {
                if player == nil { player = AVPlayer(url: montage.url) }
                player?.play()
            }
            .onDisappear { player?.pause() }
    }
}
