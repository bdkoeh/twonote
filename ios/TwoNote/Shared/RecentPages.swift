import Foundation

/// The titles the widget may show: the most recently edited pages. Exists as a file in the App
/// Group container only while the user has "Show Recent Pages in Widget" switched on; it is
/// the one thing from the notes that is ever stored outside the encrypted store. Titles and
/// ids only, never text.
struct RecentPages: Codable, Equatable, Sendable {
    /// How many pages the file holds at most (the medium widget shows up to four).
    static let limit = 4

    struct Page: Codable, Equatable, Sendable, Identifiable {
        var notebookId: String
        var pageId: String
        var title: String

        var id: String { pageId }
        var displayTitle: String { title.isEmpty ? "Untitled Page" : title }
        var link: DeepLink { .page(notebookId: notebookId, pageId: pageId) }
    }

    var pages: [Page]

    /// What is in the container, or nil when the setting is off (no file) or the file is unreadable.
    static func load(from container: SharedContainer?) -> RecentPages? {
        guard let container, let data = try? Data(contentsOf: container.recentPagesURL),
              let recent = try? JSONDecoder().decode(RecentPages.self, from: data) else { return nil }
        return RecentPages(pages: Array(recent.pages.prefix(limit)))
    }
}
