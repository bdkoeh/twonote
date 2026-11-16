import Foundation
import Observation
import TwoNoteCore

// Searching encrypted notes
// -------------------------
// Page text is ciphertext in the local store. Search therefore works on an index that exists
// in memory only, and only while the account is unlocked: after unlocking, each page's text is
// decrypted once (off the main thread) and kept in `SearchModel`; later only pages whose stored
// content changed are read again. Locking drops all of it. Nothing derived from note text - no
// index, no cache, no recent searches - is ever written to disk.

/// One search result.
struct SearchHit: Identifiable, Equatable, Sendable {
    enum Target: Hashable, Sendable {
        case notebook(String)
        case section(notebookId: String, sectionId: String)
        case page(PageRef)
    }

    var target: Target
    var title: String
    /// Where it lives: "Notebook" for a section, "Notebook › Section" for a page.
    var location: String
    /// A piece of the page's text around the match, or its beginning; empty if there is none.
    var snippet = ""
    /// The matched part of `snippet` (UTF-16 offsets), if the match is in the text.
    var snippetMatch: NSRange?
    /// The first match in the page's text (UTF-16 offsets), to scroll to.
    var textMatch: NSRange?

    var id: Target { target }
}

/// Everything that can be found, as plain values: built on the main actor, searched off it.
struct SearchCorpus: Sendable {
    struct Entry: Sendable {
        var target: SearchHit.Target
        var title: String
        var location: String
        var foldedTitle: String
        var text = ""
        var foldedText = ""
    }

    var entries: [Entry] = []

    private static let folding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Lower-cased, without accents: what matching is done on. Stored as contiguous UTF-8 so a
    /// byte search can run over it.
    static func fold(_ text: String) -> String {
        var folded = text.folding(options: folding, locale: nil)
        folded.makeContiguousUTF8()
        return folded
    }

    /// The entries that contain every word of the query, in their title or their text. Matches
    /// in a title come first; within each group the order of the corpus is kept.
    func search(_ query: String, limit: Int = 200) -> [SearchHit] {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        guard !terms.isEmpty else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let phrase = words.joined(separator: " ")

        var inTitle: [SearchHit] = []
        var inText: [SearchHit] = []
        for entry in entries {
            if Task.isCancelled { return [] }
            var allInTitle = true
            var allSomewhere = true
            for term in terms {
                if Self.contains(entry.foldedTitle, term) { continue }
                allInTitle = false
                if !Self.contains(entry.foldedText, term) {
                    allSomewhere = false
                    break
                }
            }
            guard allSomewhere else { continue }
            var hit = SearchHit(target: entry.target, title: entry.title, location: entry.location)
            if !entry.text.isEmpty {
                let text = entry.text as NSString
                var match = text.range(of: phrase, options: Self.folding)
                for word in words where match.location == NSNotFound {
                    match = text.range(of: word, options: Self.folding)
                }
                if match.location != NSNotFound {
                    hit.textMatch = match
                    (hit.snippet, hit.snippetMatch) = Self.snippet(of: text, around: match)
                } else {
                    hit.snippet = Self.snippet(of: text, around: NSRange(location: 0, length: 0)).text
                }
            }
            if allInTitle {
                inTitle.append(hit)
            } else {
                inText.append(hit)
            }
            if inTitle.count >= limit { break }
        }
        return Array((inTitle + inText).prefix(limit))
    }

    private static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        let found = haystack.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard bytes.count >= needle.count, let base = bytes.baseAddress else { return false }
            return needle.withUnsafeBufferPointer { memmem(base, bytes.count, $0.baseAddress, needle.count) != nil }
        }
        return found ?? haystack.contains(String(decoding: needle, as: UTF8.self))
    }

    /// About two lines of text around `match`, on one line, cut at word boundaries, with "…"
    /// where text was left out.
    static func snippet(of text: NSString, around match: NSRange, before: Int = 30, length: Int = 140) -> (text: String, match: NSRange?) {
        let total = text.length
        var start = max(0, match.location - before)
        if start > 0 {
            // Start at the beginning of a word, and not in the middle of a character.
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: start, length: match.location - start))
            start = space.location == NSNotFound ? text.rangeOfComposedCharacterSequence(at: start).location : NSMaxRange(space)
        }
        var end = min(total, max(start + length, NSMaxRange(match)))
        if end < total {
            end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end - 1))
        }
        var piece = text.substring(with: NSRange(location: start, length: end - start))
        piece = piece.replacingOccurrences(of: "\u{FFFC}", with: " ")
        // One line: every run of line breaks and spaces becomes one space, counted in UTF-16
        // so the match can be placed in the result.
        var result = ""
        var matchStart: Int?
        var matchEnd: Int?
        var offset = start
        var lastWasSpace = true
        for unit in piece.unicodeScalars {
            let width = unit.utf16.count
            if offset == match.location { matchStart = result.utf16.count }
            if offset == NSMaxRange(match) { matchEnd = result.utf16.count }
            offset += width
            if CharacterSet.whitespacesAndNewlines.contains(unit) {
                if !lastWasSpace { result.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                result.unicodeScalars.append(unit)
                lastWasSpace = false
            }
        }
        if offset == NSMaxRange(match) { matchEnd = result.utf16.count }
        while result.hasSuffix(" ") { result.removeLast() }
        let prefix = start > 0 && !result.isEmpty ? "…" : ""
        let suffix = end < total - 1 && !result.isEmpty ? "…" : ""
        var range: NSRange?
        if match.length > 0, let matchStart, let matchEnd, matchEnd > matchStart, matchEnd <= result.utf16.count {
            range = NSRange(location: matchStart + prefix.utf16.count, length: matchEnd - matchStart)
        }
        return (prefix + result + suffix, range)
    }
}

/// Search across the notebooks, sections and pages of the unlocked account.
@MainActor
@Observable
final class SearchModel {
    /// What is typed in the search field.
    var query = "" {
        didSet {
            if query != oldValue { queryChanged() }
        }
    }
    /// The results for `query`.
    private(set) var hits: [SearchHit] = []
    /// True while results for the current query are still being worked out.
    private(set) var searching = false
    /// True while page text is being read for the first time after unlocking.
    private(set) var indexing = false
    /// Goes up whenever page texts were read or dropped (the Mac's page list shows a line of each).
    private(set) var textsRevision = 0

    private struct PageText {
        var version: DocumentVersion?
        var text: String
        var folded: String
    }

    @ObservationIgnored private weak var library: LibraryModel?
    @ObservationIgnored private var texts: [String: PageText] = [:]
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    /// How long typing has to pause before a search runs.
    @ObservationIgnored var debounce: Duration = .milliseconds(150)

    init(library: LibraryModel) {
        self.library = library
    }

    /// Whether results should be shown instead of the lists.
    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Number of pages whose text is in memory (for tests and measurements).
    var indexedPages: Int { texts.count }

    /// The text of a page as last read for search, or nil if it has not been read (yet). Exists
    /// in memory only, like everything here.
    func pageText(_ pageId: String) -> String? {
        texts[pageId]?.text
    }

    /// Reads the text of every page that is new or has changed since it was last read. Cheap
    /// when nothing changed: one query for the documents' version stamps.
    func refresh() async {
        guard let library, !closed else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            indexing = false
        }
        var changed = false
        repeat {
            refreshAgain = false
            guard let versions = try? await library.client.documentVersions(), !closed else { return }
            var live = Set<String>()
            for notebook in library.notebooks {
                for page in notebook.sections.flatMap({ notebook.pages(in: $0.id) }) {
                    live.insert(page.id)
                    let version = versions[page.id]
                    if let have = texts[page.id], have.version == version { continue }
                    if texts.isEmpty { indexing = true }
                    let text = ((try? await library.client.pageText(notebookId: notebook.id, pageId: page.id)) ?? nil) ?? ""
                    if closed { return }
                    texts[page.id] = PageText(version: version, text: text, folded: SearchCorpus.fold(text))
                    changed = true
                    await Task.yield() // let touches and scrolling in between
                }
            }
            for id in texts.keys where !live.contains(id) {
                texts[id] = nil
                changed = true
            }
        } while refreshAgain && !closed
        if changed {
            textsRevision += 1
        }
        if changed && isActive {
            run(after: .zero)
        }
    }

    private func queryChanged() {
        guard isActive else {
            searchTask?.cancel()
            hits = []
            searching = false
            return
        }
        run(after: debounce)
    }

    private func run(after delay: Duration) {
        searchTask?.cancel()
        let text = query
        searching = true
        searchTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let corpus = self?.corpus() else { return }
            let found = await Task.detached(priority: .userInitiated) { corpus.search(text) }.value
            guard !Task.isCancelled, let self else { return }
            self.hits = found
            self.searching = false
        }
    }

    /// Runs the current query now and waits for its results (tests).
    func settle() async {
        await searchTask?.value
    }

    /// The titles as they are right now, with the page texts read so far.
    func corpus() -> SearchCorpus {
        var corpus = SearchCorpus()
        guard let library else { return corpus }
        var sections: [SearchCorpus.Entry] = []
        var pages: [SearchCorpus.Entry] = []
        for notebook in library.notebooks {
            corpus.entries.append(.init(
                target: .notebook(notebook.id), title: notebook.displayTitle, location: "",
                foldedTitle: SearchCorpus.fold(notebook.displayTitle)))
            for section in notebook.sections {
                let sectionTitle = section.title.isEmpty ? "Untitled Section" : section.title
                sections.append(.init(
                    target: .section(notebookId: notebook.id, sectionId: section.id), title: sectionTitle,
                    location: notebook.displayTitle, foldedTitle: SearchCorpus.fold(sectionTitle)))
                for page in notebook.pages(in: section.id) {
                    let stored = texts[page.id]
                    let title = page.title.isEmpty ? "Untitled Page" : page.title
                    pages.append(.init(
                        target: .page(PageRef(notebookId: notebook.id, pageId: page.id)), title: title,
                        location: notebook.displayTitle + " › " + sectionTitle,
                        foldedTitle: SearchCorpus.fold(page.title), text: stored?.text ?? "", foldedText: stored?.folded ?? ""))
                }
            }
        }
        corpus.entries += sections + pages
        return corpus
    }

    /// Forgets every page text. Called when the account locks.
    func clear() {
        closed = true
        searchTask?.cancel()
        searchTask = nil
        texts = [:]
        hits = []
        query = ""
        searching = false
    }
}
