import Foundation
import notify
import Observation
import UniformTypeIdentifiers

// The share sheet's logic, the same on the iPhone (ShareExtension/ShareViewController.swift)
// and the Mac (TwoNoteMac/ShareExtension/ShareViewController.swift); each platform draws its
// own sheet around it.
//
// This runs in the share extension's own process, usually while the notes are locked, and it
// cannot open the vault: it has no key that opens anything. All it can do is seal what was
// shared to the share inbox's public key and leave it in the App Group container for the app
// (see SharedContainer.swift and the app's ShareImport.swift). It cannot read an item back
// once it is sealed, it shows nothing from the notes, and it writes nothing in the clear.

/// The share sheet's state.
@MainActor
@Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        /// The app has not been set up and unlocked on this device yet.
        case notSetUp
        /// Nothing TwoNote can keep was shared.
        case nothing
        case ready(ShareDraft)
    }

    private(set) var state = State.loading
    /// The title field. Starts as the suggested title; empty means "use the suggested one".
    var title = ""
    /// Why saving did not work, in the user's terms.
    private(set) var failure: String?

    @ObservationIgnored private let inbox: ShareInbox?

    init(container: SharedContainer?) {
        inbox = container.map(ShareInbox.init(container:))
    }

    var canSave: Bool {
        if case .ready = state { true } else { false }
    }

    func load(_ input: ShareInput) {
        guard let inbox, inbox.publicKey != nil else {
            state = .notSetUp
            return
        }
        let draft = ShareDraft(input)
        guard !draft.isEmpty else {
            state = .nothing
            return
        }
        title = draft.suggestedTitle
        state = .ready(draft)
    }

    /// Seals the item and leaves it for the app. True when that worked.
    func save() -> Bool {
        guard case .ready(let draft) = state, let inbox else { return false }
        do {
            try inbox.add(draft.item(title: title))
            notify_post(SharedContainer.inboxChangedNotification)
            return true
        } catch ShareInbox.Failure.notSetUp {
            state = .notSetUp
        } catch ShareInbox.Failure.full {
            failure = "Too many items are waiting for TwoNote. Open TwoNote and unlock it, then share this again."
        } catch {
            failure = "This could not be saved. Check that this device has free storage and try again."
        }
        return false
    }
}

extension ShareInput {
    /// Reduces what the host app handed over to text and web addresses. Files and images are
    /// not read (the activation rule in Info.plist keeps TwoNote out of the sheet for them).
    /// On the main actor, with the extension's view controller that has the items.
    @MainActor
    static func read(_ items: [NSExtensionItem]) async -> ShareInput {
        var input = ShareInput()
        for item in items {
            if input.title == nil, let title = item.attributedTitle?.string, !title.isEmpty {
                input.title = title
            }
            if input.contentText == nil, let text = item.attributedContentText?.string, !text.isEmpty {
                input.contentText = text
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await load(URL.self, from: provider), !url.isFileURL {
                        input.urls.append(url.absoluteString)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await load(String.self, from: provider) {
                        input.texts.append(text)
                    }
                }
            }
        }
        return input
    }

    @MainActor
    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        guard provider.canLoadObject(ofClass: type) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }
}
