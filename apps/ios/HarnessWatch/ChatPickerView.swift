// Where the next message goes: the latest chat, one of the recent ones, or a
// new chat.

import SwiftUI

struct ChatPickerView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Button {
                store.target = .newChat
                dismiss()
            } label: {
                Label("New chat", systemImage: "plus")
            }
            ForEach(store.chats) { chat in
                Button {
                    // The newest chat follows whatever is called next.
                    store.target = chat.id == store.chats.first?.id ? .latest : .chat(chat.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).lineLimit(2)
                        StatusLabel(status: chat.status)
                    }
                }
            }
        }
        .navigationTitle("Send to")
    }
}
