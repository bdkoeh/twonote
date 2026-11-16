import SwiftUI

/// The results of a search, in the middle column while something is typed in the toolbar's
/// search field: matching notebooks and sections, then pages with a piece of their text. The
/// same in-memory index as on the iPhone (`SearchModel`).
struct SearchResultsView: View {
    let library: LibraryModel
    @Environment(\.dismissSearch) private var dismissSearch

    /// What makes the page texts worth re-reading while results are on screen.
    private struct Trigger: Hashable {
        var cursor: Int64
        var pending: Int
        var pages: Int
    }

    var body: some View {
        let search = library.search
        let places = search.hits.filter { if case .page = $0.target { false } else { true } }
        let pages = search.hits.filter { if case .page = $0.target { true } else { false } }
        let status = library.client.syncMonitor.status
        List {
            if !places.isEmpty {
                Section("Notebooks and Sections") {
                    ForEach(places) { hit in
                        Button { open(hit) } label: { PlaceRow(hit: hit) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if !pages.isEmpty {
                Section("Pages") {
                    ForEach(pages) { hit in
                        Button { open(hit) } label: { PageHitRow(hit: hit) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if search.hits.isEmpty {
                if search.searching || search.indexing {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: search.query)
                }
            }
        }
        .navigationTitle("Search")
        .accessibilityIdentifier("search-results")
        .task(id: Trigger(
            cursor: status.cursor, pending: status.pendingUpdates,
            pages: library.notebooks.reduce(0) { $0 + $1.pages.values.reduce(0) { $0 + $1.count } })
        ) {
            await search.refresh()
        }
    }

    private func open(_ hit: SearchHit) {
        library.open(hit)
        dismissSearch()
    }

    private struct PlaceRow: View {
        let hit: SearchHit

        var body: some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title)
                    if !hit.location.isEmpty {
                        Text(hit.location)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: hit.location.isEmpty ? "book.closed" : "folder")
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
    }

    private struct PageHitRow: View {
        let hit: SearchHit

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.headline)
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(Self.styled(hit))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label(hit.location, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search-hit")
        }

        /// The snippet with the matched words set off from the rest.
        static func styled(_ hit: SearchHit) -> AttributedString {
            var text = AttributedString(hit.snippet)
            if let match = hit.snippetMatch, let range = Range(match, in: hit.snippet),
               let lower = AttributedString.Index(range.lowerBound, within: text),
               let upper = AttributedString.Index(range.upperBound, within: text) {
                text[lower..<upper].foregroundColor = .primary
                text[lower..<upper].font = .subheadline.weight(.semibold)
            }
            return text
        }
    }
}
