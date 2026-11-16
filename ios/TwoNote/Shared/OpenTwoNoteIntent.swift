import AppIntents
import Foundation

/// What a button in the widget runs: opens TwoNote and passes it a `twonote://` link. (A small
/// widget is one tap target as far as links go; buttons are the way to have two.) The system
/// brings the app to the front and runs `perform` in the app's process.
struct OpenTwoNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open TwoNote"
    static let description = IntentDescription("Opens TwoNote to start a note, search, or carry on with a page.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @Parameter(title: "Link")
    var link: String

    init() {
        link = DeepLink.continueLast.url.absoluteString
    }

    init(_ link: DeepLink) {
        self.link = link.url.absoluteString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: link), let link = DeepLink(url: url) {
            DeepLinkRelay.shared.deliver(link)
        }
        return .result()
    }
}
