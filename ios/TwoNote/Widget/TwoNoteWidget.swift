import SwiftUI
import WidgetKit

// The Home Screen widget (and the two Lock Screen accessories); on the Mac, from this same
// file, the desktop and Notification Center widget (TwoNoteMac/project.yml). It runs in its
// own process and has no key: it cannot read a note. It shows buttons, and - only if the user
// turned that on in the app - the page titles the app left for it in the App Group container.

struct TwoNoteEntry: TimelineEntry {
    let date: Date
    /// Nil unless "Show Recent Pages in Widget" is on.
    let recent: RecentPages?
}

struct TwoNoteProvider: TimelineProvider {
    /// What is shown before anything is loaded, and in the widget gallery: never a title.
    func placeholder(in context: Context) -> TwoNoteEntry {
        TwoNoteEntry(date: .now, recent: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TwoNoteEntry) -> Void) {
        completion(TwoNoteEntry(date: .now, recent: context.isPreview ? nil : RecentPages.load(from: .appGroup)))
    }

    /// One entry that stays until the app says the titles changed (it reloads the timeline).
    func getTimeline(in context: Context, completion: @escaping (Timeline<TwoNoteEntry>) -> Void) {
        let entry = TwoNoteEntry(date: .now, recent: RecentPages.load(from: .appGroup))
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct TwoNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TwoNoteWidget", provider: TwoNoteProvider()) { entry in
            TwoNoteWidgetView(recent: entry.recent)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("TwoNote")
        .description("Start a note, search, or carry on where you left off.")
        #if os(macOS)
        // The desktop and Notification Center.
        .supportedFamilies([.systemSmall, .systemMedium])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        #endif
    }
}

@main
struct TwoNoteWidgets: WidgetBundle {
    var body: some Widget {
        TwoNoteWidget()
    }
}
