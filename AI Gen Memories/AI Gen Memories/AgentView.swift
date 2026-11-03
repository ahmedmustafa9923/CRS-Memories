//
//  AgentView.swift
//
//  The assistant's chat. It opens as a half-height sheet so the montage
//  preview stays visible above it — ask for a title and watch it appear.
//

import SwiftUI

// MARK: - Menu

/// The sparkles button in the editor's toolbar. Quick actions run straight
/// away; "Chat with assistant" just opens the conversation.
struct AgentMenu: View {
    let hasPhotos: Bool
    var onSelect: (AgentQuickAction?) -> Void

    var body: some View {
        Menu {
            Section("AI assistant") {
                ForEach(AgentQuickAction.allCases) { action in
                    Button {
                        onSelect(action)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                    }
                    .disabled(action.needsPhotos && !hasPhotos)
                }
            }
            Divider()
            Button {
                onSelect(nil)
            } label: {
                Label("Chat with assistant", systemImage: "bubble.left.and.text.bubble.right")
            }
        } label: {
            Label("AI assistant", systemImage: "sparkles")
        }
    }
}

// MARK: - Chat

struct AgentView: View {
    @Bindable var agent: MemoryAgent
    let hasPhotos: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if agent.availability == .ready {
                    conversation
                    quickActions
                    inputBar
                } else {
                    unavailable
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        agent.newChat()
                    }
                    .disabled(agent.messages.isEmpty || agent.isResponding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if agent.messages.isEmpty {
                        welcome
                    }
                    ForEach(agent.messages) { message in
                        MessageBubble(message: message) {
                            agent.undo(message)
                        }
                        .id(message.id)
                    }
                    if agent.isResponding {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .id("thinking")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.messages.count) {
                if let last = agent.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: agent.isResponding) { _, responding in
                if responding {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Ask me to name your montage, caption your photos, tell their story, or change the style.")
                .multilineTextAlignment(.center)
            Text("Runs on this iPhone. Your photos and this chat never leave it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .padding(.horizontal)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AgentQuickAction.allCases) { action in
                    Button {
                        agent.send(action.prompt, shownAs: action.label)
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(agent.isResponding || (action.needsPhotos && !hasPhotos))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask or tell me what to change…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isResponding)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        agent.send(text)
    }

    // MARK: Unavailable

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Assistant unavailable", systemImage: "sparkles")
        } description: {
            Text(agent.availability.message)
        } actions: {
            Button("Check again") { agent.refreshAvailability() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - One message

struct MessageBubble: View {
    let message: AgentMessage
    var onUndo: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }

        case .agent:
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text)
                        .textSelection(.enabled)
                    if message.undo != nil {
                        Button("Undo changes", systemImage: "arrow.uturn.backward", action: onUndo)
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 40)
            }

        case .notice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}
