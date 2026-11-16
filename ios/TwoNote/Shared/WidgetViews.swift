import AppIntents
import SwiftUI
import WidgetKit

// The widget's views. The notes are encrypted and the widget draws while they are locked, so
// by default it shows nothing from them: only buttons that open the app (which then asks for
// the unlock). If the user turns on "Show Recent Pages in Widget", the medium size lists the
// titles the app wrote to the App Group container for it.
//
// Compiled into the app as well as into the widget extension, so the app's tests can look at
// the views.

/// What the widget shows for a family: `recent` is nil unless the user turned titles on.
struct TwoNoteWidgetView: View {
    let recent: RecentPages?
    /// The size to draw; nil (always, inside WidgetKit) means the one the system asks for. Set
    /// only to draw the widget outside WidgetKit, for screenshots.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily

    private var family: WidgetFamily { size ?? systemFamily }

    var body: some View {
        switch family {
        case .systemMedium:
            if let recent, !recent.pages.isEmpty {
                RecentPagesWidgetView(recent: recent)
            } else {
                HStack(spacing: 8) {
                    WidgetAction(link: .newNote, title: "New Note", symbol: "square.and.pencil", layout: .tile)
                    WidgetAction(link: .search, title: "Search", symbol: "magnifyingglass", layout: .tile)
                    WidgetAction(link: .continueLast, title: "Continue", symbol: "arrow.forward.circle", layout: .tile)
                }
            }
        #if os(iOS)
        // The Lock Screen's accessories (the Mac has none).
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .widgetAccentable()
            }
            .widgetURL(DeepLink.newNote.url)
            .accessibilityLabel("New Note in TwoNote")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.title2)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("TwoNote")
                        .font(.headline)
                        .widgetAccentable()
                    Text("New Note")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .widgetURL(DeepLink.newNote.url)
        #endif
        default:
            VStack(spacing: 8) {
                WidgetAction(link: .newNote, title: "New Note", symbol: "square.and.pencil", layout: .row)
                WidgetAction(link: .search, title: "Search", symbol: "magnifyingglass", layout: .row)
            }
        }
    }
}

/// One button of the widget.
struct WidgetAction: View {
    enum Layout {
        /// Symbol and title side by side (the small widget's two rows).
        case row
        /// Symbol above the title (the medium widget's three tiles).
        case tile
        /// The symbol alone, in a circle (the header of the recent pages).
        case icon
    }

    let link: DeepLink
    let title: String
    let symbol: String
    let layout: Layout

    var body: some View {
        Button(intent: OpenTwoNoteIntent(link)) {
            switch layout {
            case .row:
                HStack(spacing: 8) {
                    glyph.font(.body.weight(.semibold))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
            case .tile:
                VStack(alignment: .leading, spacing: 0) {
                    glyph.font(.title2.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
            case .icon:
                glyph.font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .circle)
                    .accessibilityLabel(title)
            }
        }
        .buttonStyle(.plain)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .foregroundStyle(.tint)
            .widgetAccentable()
    }
}

/// The medium widget with titles on: the pages edited last, each a link to its page.
struct RecentPagesWidgetView: View {
    let recent: RecentPages

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Recent Pages")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .widgetAccentable()
                Spacer(minLength: 0)
                WidgetAction(link: .search, title: "Search", symbol: "magnifyingglass", layout: .icon)
                WidgetAction(link: .newNote, title: "New Note", symbol: "square.and.pencil", layout: .icon)
            }
            .padding(.bottom, 4)
            // Always four slots, so one page takes the same room as four.
            ForEach(0..<RecentPages.limit, id: \.self) { index in
                if index < recent.pages.count {
                    let page = recent.pages[index]
                    Divider()
                    Link(destination: page.link.url) {
                        Text(page.displayTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                } else {
                    Color.clear
                }
            }
        }
    }
}
