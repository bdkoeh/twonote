import Foundation

/// Something shared to TwoNote from another app: what the share extension seals and the app
/// later turns into a page.
struct SharedItem: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Longest title, in characters.
    static let maxTitleLength = 200
    /// Longest text, in UTF-16 code units (about 40 printed pages). Longer text is cut.
    static let maxTextLength = 100_000
    /// Longest link, in UTF-16 code units.
    static let maxURLLength = 4_000

    /// Format version.
    var v = SharedItem.currentVersion
    /// 32 lowercase hex characters drawn at random by the share extension. The page made from
    /// the item gets this id, which is how an item is never added twice.
    var id: String
    var createdAt: Date
    /// The page title; may be empty.
    var title: String
    /// The text, paragraphs separated by "\n"; may be empty.
    var text: String
    /// A web address that goes with the text; nil if there is none.
    var url: String?

    init(id: String = SharedItem.newId(), createdAt: Date = Date(), title: String, text: String, url: String?) {
        self.id = id
        self.createdAt = createdAt
        self.title = SharedItem.cleanTitle(title)
        self.text = SharedItem.cleanText(text)
        self.url = url.flatMap(SharedItem.cleanURL)
    }

    static func newId() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func isId(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Whether this is an item the app can turn into a page (what arrives is checked again,
    /// whoever wrote it).
    var isValid: Bool {
        v == SharedItem.currentVersion && SharedItem.isId(id)
            && title == SharedItem.cleanTitle(title) && text == SharedItem.cleanText(text)
            && url == url.flatMap(SharedItem.cleanURL)
            && !(title.isEmpty && text.isEmpty && url == nil)
    }

    /// One line, trimmed, at most `maxTitleLength` characters.
    static func cleanTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(maxTitleLength))
    }

    /// "\n" line ends, no NUL, no blank lines at either end, at most one blank line in a row,
    /// at most `maxTextLength` UTF-16 code units.
    static func cleanText(_ text: String) -> String {
        var text = text
        if text.utf16.count > maxTextLength {
            var units = Array(text.utf16.prefix(maxTextLength))
            if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
            text = String(decoding: units, as: UTF16.self)
        }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\0", with: "")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line -> Substring in
                var line = line
                while let last = line.last, last.isWhitespace { line.removeLast() }
                return line
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var kept: [Substring] = []
        for line in lines where !(line.isEmpty && kept.last?.isEmpty == true) {
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// A web address (http or https) of sensible length, or nil.
    static func cleanURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count <= maxURLLength, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return trimmed
    }
}

/// What a host app handed to the share sheet, reduced to plain values.
struct ShareInput: Equatable, Sendable {
    /// The title the host gave the item, if any.
    var title: String?
    /// The host's descriptive text for the item (Safari: the page title).
    var contentText: String?
    /// Plain-text attachments, in order.
    var texts: [String] = []
    /// URL attachments, in order.
    var urls: [String] = []
}

/// What the share sheet shows before saving, worked out from a `ShareInput`.
struct ShareDraft: Equatable, Sendable {
    /// The title the page gets if the user types none: the page title for a link, else the first line of the text.
    var suggestedTitle: String
    var text: String
    var url: String?

    var isEmpty: Bool { text.isEmpty && url == nil }

    init(_ input: ShareInput) {
        var url = input.urls.lazy.compactMap(SharedItem.cleanURL).first
        var text = SharedItem.cleanText(input.texts.map(SharedItem.cleanText).filter { !$0.isEmpty }.joined(separator: "\n\n"))
        var pageTitle = input.title.map(SharedItem.cleanTitle).flatMap { $0.isEmpty ? nil : $0 }

        // Some apps hand over a link as plain text.
        if url == nil, let only = SharedItem.cleanURL(text) {
            url = only
            text = ""
        }
        if let content = input.contentText.map(SharedItem.cleanText), !content.isEmpty, content != text {
            let oneLine = !content.contains("\n") && content.count <= SharedItem.maxTitleLength
            if url != nil, oneLine, SharedItem.cleanURL(content) == nil {
                // With a link, a short description is the page's title.
                pageTitle = pageTitle ?? content
            } else if text.isEmpty, url == nil || SharedItem.cleanURL(content) != url {
                text = content
            }
        }
        if url == nil, let only = SharedItem.cleanURL(text) {
            url = only
        }
        if text.trimmingCharacters(in: .whitespaces) == url { text = "" }

        self.url = url
        self.text = text
        if let pageTitle {
            suggestedTitle = pageTitle
        } else if let line = text.split(separator: "\n").first {
            suggestedTitle = Self.shortened(String(line))
        } else {
            suggestedTitle = url.flatMap { URL(string: $0)?.host } ?? ""
        }
    }

    /// A first line as a title: cut at a word boundary if it is long.
    static func shortened(_ line: String, limit: Int = 80) -> String {
        let line = SharedItem.cleanTitle(line)
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit))
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The item to save, with the title the user typed (empty: the suggested one).
    func item(title: String) -> SharedItem {
        let typed = SharedItem.cleanTitle(title)
        return SharedItem(title: typed.isEmpty ? suggestedTitle : typed, text: text, url: url)
    }
}
