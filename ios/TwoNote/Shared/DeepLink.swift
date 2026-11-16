import Foundation

/// What a `twonote://` link asks the app to do. The widget's buttons are such links.
///
///     twonote://new                           a new page in the section used last
///     twonote://search                        the search field
///     twonote://continue                      the page that was open last
///     twonote://page/<notebookId>/<pageId>    that page
///
/// A link carries ids at most, never a title or text. The app acts on it only once it is
/// unlocked; while locked it is remembered until the unlock that follows.
enum DeepLink: Equatable, Sendable {
    static let scheme = "twonote"

    case newNote
    case search
    case continueLast
    case page(notebookId: String, pageId: String)

    /// Nil for anything that is not exactly one of the links above.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.user == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch (host, parts.count) {
        case ("new", 0): self = .newNote
        case ("search", 0): self = .search
        case ("continue", 0): self = .continueLast
        case ("page", 2) where Self.isId(parts[0]) && Self.isId(parts[1]):
            self = .page(notebookId: parts[0], pageId: parts[1])
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .newNote: URL(string: "twonote://new")!
        case .search: URL(string: "twonote://search")!
        case .continueLast: URL(string: "twonote://continue")!
        case .page(let notebookId, let pageId): URL(string: "twonote://page/\(notebookId)/\(pageId)")!
        }
    }

    private static func isId(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Hands a link that did not arrive as a URL (a widget button runs an intent in the app's
/// process) to whoever handles links in the app. A link that arrives before the handler is
/// set is kept for it.
@MainActor
final class DeepLinkRelay {
    static let shared = DeepLinkRelay()

    private var waiting: DeepLink?

    var handler: ((DeepLink) -> Void)? {
        didSet {
            if let handler, let link = waiting {
                waiting = nil
                handler(link)
            }
        }
    }

    func deliver(_ link: DeepLink) {
        if let handler {
            handler(link)
        } else {
            waiting = link
        }
    }
}
