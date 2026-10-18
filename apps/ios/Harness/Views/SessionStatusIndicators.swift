// Passive session status marks for the header: no glass, button or swipe surface.

import SwiftUI

struct SessionStatusIndicators: View {
    @Environment(AppModel.self) private var model
    let current: String
    let chats: [Chat]
    let maxVisible: Int

    var body: some View {
        let _ = model.connectivity.pulse
        let window = SessionStatusWindow(ids: chats.map(\.id), current: current, limit: maxVisible)
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        let shown = window.visibleIDs.compactMap { byID[$0] }
        HStack(spacing: 3) {
            ForEach(shown) { chat in
                statusMark(model.indicator(for: chat))
                    .frame(width: 10, height: 10)
                    .padding(3)
                    .overlay {
                        if chat.id == current {
                            Circle().strokeBorder(Theme.textMuted, lineWidth: 1)
                        }
                    }
            }
            if let overflow = window.overflowText {
                Text(overflow)
                    .font(Theme.sans(10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .accessibilityIdentifier("session-status-overflow")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((window.hiddenCount > 0 ? "\(window.hiddenCount) more sessions not shown. " : "") + chats.map { chat in
            let status = description(model.indicator(for: chat))
            return "\(chat.displayTitle): \(status)" + (chat.id == current ? ", current session" : "")
        }.joined(separator: "; "))
        .accessibilityValue(window.overflowText ?? "All sessions shown")
        .accessibilityIdentifier("session-status-indicators")
    }

    @ViewBuilder
    private func statusMark(_ indicator: ChatIndicator) -> some View {
        switch indicator {
        case .working:
            Circle().strokeBorder(Theme.statusWorking, lineWidth: 1.5)
        case .awaitingInput:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning)
        case .completed:
            Image(systemName: "checkmark").foregroundStyle(Theme.statusCompleted)
        case .errored:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .idle:
            Circle().fill(ink(0.25)).frame(width: 5, height: 5)
        }
    }

    private func description(_ indicator: ChatIndicator) -> String {
        switch indicator {
        case .working: "Running"
        case .awaitingInput: "Needs your input"
        case .completed: "Finished, unread reply"
        case .errored: "Run failed"
        case .idle: "Idle, no unread reply"
        }
    }
}
