// The Watch's one screen: where the next message goes, the Speak button, and
// how the last few messages went.

import SwiftUI

struct HomeView: View {
    @Environment(WatchStore.self) private var store
    @Environment(Recorder.self) private var recorder
    let dictateRequest: Int

    @State private var flow: Flow?
    @State private var typed = ""

    /// What's on top of the home screen while a message is being made.
    enum Flow: Identifiable, Equatable {
        case recording(id: String)
        case review(text: String)
        case transcribing(id: String, file: URL)
        /// The iPhone isn't reachable: the recording can wait for it.
        case away(id: String, file: URL)

        var id: String {
            switch self {
            case .recording(let id), .transcribing(let id, _), .away(let id, _): id
            case .review(let text): "review-\(text.hashValue)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // What was just sent stays in view until it lands.
                if let fresh {
                    Section { SentRow(sent: fresh) }
                }

                Section {
                    NavigationLink {
                        ChatPickerView()
                    } label: {
                        TargetRow()
                    }
                    .accessibilityIdentifier("watch-target")
                }

                Section {
                    Button(action: speak) {
                        Label("Speak", systemImage: "mic.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .listRowBackground(Capsule().fill(.tint))
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("watch-speak")

                    TextField("Type or dictate", text: $typed)
                        .onSubmit {
                            if let text = WatchLink.cleaned(typed) { flow = .review(text: text) }
                            typed = ""
                        }
                }

                if let notice {
                    Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                }

                let earlier = store.sent.filter { $0.id != fresh?.id }.prefix(5)
                if !earlier.isEmpty {
                    Section("Sent") {
                        ForEach(earlier) { SentRow(sent: $0) }
                    }
                }
            }
            .navigationTitle("Harness")
        }
        .tint(.white)
        .sheet(item: $flow) { flow in
            FlowView(flow: flow, finish: { next in self.flow = next })
                .environment(store)
                .environment(recorder)
        }
        .onChange(of: dictateRequest) { _, _ in speak() }
        .task { store.refresh() }
    }

    /// The latest message, for two minutes after it was sent.
    private var fresh: WatchLink.Sent? {
        store.sent.first.flatMap { WatchStore.nowMs() - $0.createdAt < 120_000 ? $0 : nil }
    }

    private var notice: String? {
        guard let context = store.context else { return "Open Harness on your iPhone to see your chats here." }
        return context.signedIn ? nil : "Sign in to Harness on your iPhone."
    }

    private func speak() {
        guard flow == nil else { return }
        flow = .recording(id: WatchStore.newId())
    }
}

/// "To: <chat>" with its status.
private struct TargetRow: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("To").font(.caption2).foregroundStyle(.secondary)
            Text(store.targetTitle).font(.body).lineLimit(2)
            if let status = store.targetChat?.status {
                StatusLabel(status: status)
            }
        }
    }
}

struct StatusLabel: View {
    let status: WatchLink.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .working: .green
        case .needsInput: .orange
        case .failed: .red
        case .idle: .gray
        }
    }
}

private struct SentRow: View {
    let sent: WatchLink.Sent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sent.text).font(.footnote).lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(caption).font(.caption2).lineLimit(2)
            }
            .foregroundStyle(tint)
        }
    }

    private var icon: String {
        switch sent.state {
        case .waiting: "clock"
        case .delivered: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var caption: String {
        switch sent.state {
        case .waiting: "Waiting for iPhone · \(sent.chatTitle)"
        case .delivered: "Sent · \(sent.chatTitle)"
        case .failed(let why): why
        }
    }

    private var tint: Color {
        switch sent.state {
        case .waiting: .secondary
        case .delivered: .green
        case .failed: .orange
        }
    }
}
