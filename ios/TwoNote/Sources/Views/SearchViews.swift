import SwiftUI

/// The results of a search, shown in place of a list while something is typed in its search
/// field: matching notebooks and sections, then pages with a piece of their text.
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
                    }
                }
            }
            if !pages.isEmpty {
                Section("Pages") {
                    ForEach(pages) { hit in
                        Button { open(hit) } label: { PageRow(hit: hit) }
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .overlay {
            if search.hits.isEmpty {
                if search.searching || search.indexing {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: search.query)
                }
            }
        }
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
        }
    }

    private struct PageRow: View {
        let hit: SearchHit

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(Self.styled(hit))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Label(hit.location, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
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

extension View {
    /// The search field of a list in the library. Every list searches the whole account.
    /// - Parameter isFront: whether this list is the one the sidebar is showing; that one's
    ///   field takes the keyboard when a `twonote://search` link asks for search.
    func librarySearch(_ library: LibraryModel, isFront: Bool) -> some View {
        modifier(LibrarySearch(library: library, isFront: isFront))
    }
}

private struct LibrarySearch: ViewModifier {
    let library: LibraryModel
    let isFront: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        @Bindable var search = library.search
        content
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .searchFocused($focused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: library.wantsSearchFocus && isFront) {
                guard library.wantsSearchFocus, isFront else { return }
                // Let the list get on screen first (after unlocking, or while a page closes).
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, library.wantsSearchFocus, isFront else { return }
                library.wantsSearchFocus = false
                focused = true
            }
    }
}
