// The Watch complication and Smart Stack widget (#322): one tap opens
// Harness on the Watch already recording.

import SwiftUI
import WidgetKit

struct DictateEntry: TimelineEntry {
    let date: Date
}

struct DictateProvider: TimelineProvider {
    func placeholder(in context: Context) -> DictateEntry { DictateEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (DictateEntry) -> Void) {
        completion(DictateEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DictateEntry>) -> Void) {
        // Nothing on it changes over time.
        completion(Timeline(entries: [DictateEntry(date: Date())], policy: .never))
    }
}

struct DictateView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WatchLink.dictateURL)
            .containerBackground(for: .widget) {}
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Harness").font(.headline)
                    Text("Speak to a chat").font(.caption)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("Speak to Harness", systemImage: "mic.fill")
        case .accessoryCorner:
            Image(systemName: "mic.fill")
                .font(.title3)
                .widgetLabel("Harness")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title3)
            }
        }
    }
}

@main
struct HarnessWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "harness.dictate", provider: DictateProvider()) { _ in
            DictateView()
        }
        .configurationDisplayName("Speak to Harness")
        .description("Opens Harness ready to record a message for a chat.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
