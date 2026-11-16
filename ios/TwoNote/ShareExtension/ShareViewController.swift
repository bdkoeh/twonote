import SwiftUI
import UIKit

// "TwoNote" in the system share sheet.
//
// This runs in its own process, usually while the notes are locked, and it cannot open the
// vault: it has no key that opens anything. All it can do is seal what was shared to the share
// inbox's public key and leave it in the App Group container for the app (see
// Shared/SharedContainer.swift and the app's ShareImport.swift). It cannot read an item back
// once it is sealed, it shows nothing from the notes, and it writes nothing in the clear.
// The sheet's logic (ShareModel, reading what was shared) is in Shared/ShareModel.swift,
// which the Mac's share extension uses too.

struct ShareView: View {
    @Bindable var model: ShareModel
    var onCancel: () -> Void
    var onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView()
                case .notSetUp:
                    ContentUnavailableView(
                        "Open TwoNote First",
                        systemImage: "lock",
                        description: Text("Set up TwoNote on this device and unlock it once. After that you can save text and links to it from here, even while it is locked."))
                case .nothing:
                    ContentUnavailableView(
                        "Nothing to Save",
                        systemImage: "doc.text",
                        description: Text("TwoNote can save text and links."))
                case .ready(let draft):
                    form(draft)
                }
            }
            .navigationTitle("TwoNote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("share-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save() {
                            onSaved()
                        }
                    }
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("share-save")
                }
            }
        }
    }

    private func form(_ draft: ShareDraft) -> some View {
        Form {
            Section("Title") {
                TextField("Title", text: $model.title)
                    .accessibilityIdentifier("share-title")
            }
            Section {
                if !draft.text.isEmpty {
                    Text(draft.text)
                        .lineLimit(8)
                        .accessibilityIdentifier("share-text")
                }
                if let url = draft.url {
                    Label {
                        Text(url)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "link")
                    }
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("share-link")
                }
            } header: {
                Text("New Page")
            } footer: {
                Text("Added to your notes the next time TwoNote is unlocked. Until then it is kept encrypted on this device.")
            }
            if let failure = model.failure {
                Section {
                    Text(failure)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("share-failure")
                }
            }
        }
    }
}

/// The extension's entry point (named in Info.plist): hosts the sheet and reads what was shared.
final class ShareViewController: UIViewController {
    private let model = ShareModel(container: .appGroup)

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = ShareView(
            model: model,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onSaved: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task {
            model.load(await ShareInput.read(items))
        }
    }
}
