// Making one message: record, get the text back from the iPhone, review it,
// then Send or Discard. A recording made while the iPhone is away can be
// sent as it is; the iPhone writes it out and sends it when they reconnect.

import SwiftUI

struct FlowView: View {
    @Environment(WatchStore.self) private var store
    @Environment(Recorder.self) private var recorder
    let flow: HomeView.Flow
    let finish: (HomeView.Flow?) -> Void

    var body: some View {
        switch flow {
        case .recording(let id): RecordingView(id: id, finish: finish)
        case .transcribing(let id, let file): TranscribingView(id: id, file: file, finish: finish)
        case .review(let text): ReviewView(text: text, finish: finish)
        case .away(let id, let file): AwayView(id: id, file: file, finish: finish)
        }
    }
}

private struct RecordingView: View {
    @Environment(WatchStore.self) private var store
    @Environment(Recorder.self) private var recorder
    let id: String
    let finish: (HomeView.Flow?) -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch recorder.state {
            case .denied:
                Text("Allow the microphone for Harness in the Watch's Settings.")
                    .font(.footnote).multilineTextAlignment(.center)
                Button("Close") { recorder.reset(); finish(nil) }
            case .failed(let why):
                Text(why).font(.footnote)
                Button("Close") { recorder.reset(); finish(nil) }
            case .idle, .recording:
                if case .recording(let started) = recorder.state {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(started))
                            .formatted(.time(pattern: .minuteSecond)))
                            .font(.title3.monospacedDigit())
                    }
                } else {
                    Text("0:00").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                LevelBar(level: recorder.level)
                Text("To \(store.targetTitle)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.title2).frame(width: 56, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .clipShape(Circle())
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("watch-stop")
            }
        }
        .task { await recorder.start(id: id) }
        .onChange(of: recorder.reachedLimit) { _, reached in if reached { stop() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard", systemImage: "xmark") {
                    recorder.cancel()
                    finish(nil)
                }
            }
        }
    }

    private func stop() {
        guard let file = recorder.stop() else {
            finish(nil)
            return
        }
        finish(store.reachable ? .transcribing(id: id, file: file) : .away(id: id, file: file))
    }
}

private struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: max(6, geo.size.width * level))
                }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct TranscribingView: View {
    @Environment(WatchStore.self) private var store
    let id: String
    let file: URL
    let finish: (HomeView.Flow?) -> Void
    @State private var slow = false

    var body: some View {
        VStack(spacing: 10) {
            if let transcript = store.transcripts[id], transcript.text == nil {
                Text(transcript.detail ?? "Couldn't write that out.").font(.footnote).multilineTextAlignment(.center)
                Button("Close") { finish(nil) }
            } else if slow {
                Text("Your iPhone is taking a while.").font(.footnote).multilineTextAlignment(.center)
                Button("Send without reviewing") {
                    store.sendRecording(file, id: WatchStore.newId(), deliver: true)
                    finish(nil)
                }
                Button("Discard", role: .destructive) { finish(nil) }
            } else {
                ProgressView()
                Text("Writing it out on your iPhone…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            store.sendRecording(file, id: id, deliver: false)
            try? await Task.sleep(for: .seconds(20))
            slow = true
        }
        .onChange(of: store.transcripts[id]) { _, transcript in
            if let text = transcript?.text {
                store.forgetTranscript(id)
                finish(.review(text: text))
            }
        }
    }
}

private struct ReviewView: View {
    @Environment(WatchStore.self) private var store
    @State var text: String
    let finish: (HomeView.Flow?) -> Void

    init(text: String, finish: @escaping (HomeView.Flow?) -> Void) {
        _text = State(initialValue: text)
        self.finish = finish
    }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("watch-transcript")
                TextField("Edit", text: $text)
                Text("To \(store.targetTitle)").font(.caption2).foregroundStyle(.secondary)
                if store.targetBusy {
                    Picker("While it's working", selection: $store.mode) {
                        Text("Queue").tag(WatchLink.Mode.queue)
                        Text("Steer now").tag(WatchLink.Mode.now)
                    }
                }
                Button {
                    if store.send(text) { finish(nil) }
                } label: {
                    Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(WatchLink.cleaned(text) == nil)
                .accessibilityIdentifier("watch-send")
                Button("Discard", role: .destructive) { finish(nil) }
            }
        }
    }
}

private struct AwayView: View {
    @Environment(WatchStore.self) private var store
    let id: String
    let file: URL
    let finish: (HomeView.Flow?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Your iPhone isn't nearby. Send the recording, and Harness on your iPhone writes it out and sends it to \(store.targetTitle) when they reconnect.")
                    .font(.footnote)
                Button("Send recording") {
                    store.sendRecording(file, id: id, deliver: true)
                    finish(nil)
                }
                .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) {
                    try? FileManager.default.removeItem(at: file)
                    finish(nil)
                }
            }
        }
    }
}
