//
//  FinishReview.swift
//
//  What "Complete" opens: one last look at the montage before it's
//  rendered. Anything missing is flagged with a way to fix it, but nothing
//  blocks the export — an untitled, silent montage is still a montage.
//

import SwiftUI
import UIKit

/// Closes the keyboard from anywhere, whichever field has it.
@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct FinishReview: View {
    @Bindable var flow: MontageFlow
    var onExport: () -> Void
    var onChooseMusic: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var captionCount: Int {
        flow.selectedIDs.filter { !(flow.clipCaptions[$0] ?? "").isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(done: true,
                        icon: "photo.stack",
                        title: "\(flow.selectedIDs.count) clips",
                        detail: "About \(Int(flow.estimatedDuration.rounded())) seconds · \(flow.theme.name) theme")

                    row(done: flow.hasTitle,
                        icon: "textformat",
                        title: flow.hasTitle ? flow.trimmedTitle : "No title",
                        detail: flow.hasTitle
                            ? (flow.trimmedSubtitle.isEmpty ? "Opens on a title card" : flow.trimmedSubtitle)
                            : "The video opens straight on the first photo")

                    row(done: flow.customAudioName != nil,
                        icon: "music.note",
                        title: flow.customAudioName ?? "No music",
                        detail: flow.customAudioName == nil ? "The video will be silent" : "Loops to fit, fades out at the end") {
                        Button(flow.customAudioName == nil ? "Add" : "Change") {
                            dismiss()
                            onChooseMusic()
                        }
                        .buttonStyle(.borderless)
                    }

                    row(done: captionCount > 0,
                        icon: "captions.bubble",
                        title: captionCount == 0 ? "No captions" : "\(captionCount) of \(flow.selectedIDs.count) clips captioned",
                        detail: captionCount == 0 ? "Optional" : "Printed over those clips")

                    row(done: flow.hasCredits,
                        icon: "list.bullet.rectangle",
                        title: flow.hasCredits ? "\(flow.creditLines.count) credit lines" : "No credits",
                        detail: flow.hasCredits ? (flow.rollCredits ? "Rolling up the screen" : "Held as a card") : "Optional — ends on the last photo")
                } header: {
                    Text("Your montage")
                } footer: {
                    Text("Anything not ticked is optional. Tap Keep editing to change it, or ask the ✨ assistant to fill it in.")
                }
            }
            .navigationTitle("Ready to export?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep editing") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onExport()
                } label: {
                    Label("Export video", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!flow.canRender)
                .padding()
                .background(.bar)
            }
        }
    }

    private func row(done: Bool, icon: String, title: String, detail: String) -> some View {
        row(done: done, icon: icon, title: title, detail: detail) { EmptyView() }
    }

    private func row<Trailing: View>(
        done: Bool,
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: icon)
                    .labelStyle(.titleOnly)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            trailing()
        }
    }
}
