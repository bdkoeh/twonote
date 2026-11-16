import AppKit
import SwiftUI

// "TwoNote" in the Mac's Share menu (Safari, Notes, Mail, TextEdit's Share button...): a small
// sheet with what will be saved, an optional title, Cancel and Save.
//
// It runs in its own process, usually while the notes are locked, and has no key that opens
// anything: it seals what was shared to the share inbox's public key and leaves it in the App
// Group container for the app, exactly as on the iPhone. The logic is the iPhone's
// (../../TwoNote/Shared/ShareModel.swift); only the sheet is the Mac's.
//
// Compiled into the app as well (TwoNoteMac/project.yml), so the app's end-to-end run can
// draw the sheet for its screenshots.

/// The sheet.
struct MacShareView: View {
    @Bindable var model: ShareModel
    var onCancel: () -> Void
    var onSaved: () -> Void

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .notSetUp:
                message("Open TwoNote First", symbol: "lock",
                        "Set up TwoNote on this Mac and unlock it once. After that you can save text and links to it from the Share menu, even while it is locked.")
            case .nothing:
                message("Nothing to Save", symbol: "doc.text", "TwoNote can save text and links.")
            case .ready(let draft):
                form(draft)
            }
            HStack {
                Spacer()
                if model.canSave {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("share-cancel")
                    Button("Save") {
                        if model.save() {
                            onSaved()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("share-save")
                } else {
                    Button("OK", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("share-cancel")
                }
            }
            .controlSize(.large)
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func message(_ title: String, symbol: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func form(_ draft: ShareDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to TwoNote")
                .font(.headline)
            TextField("Title", text: $model.title, prompt: Text(draft.suggestedTitle.isEmpty ? "Title" : draft.suggestedTitle))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("share-title")
            VStack(alignment: .leading, spacing: 8) {
                if !draft.text.isEmpty {
                    Text(draft.text)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            Text("Added to your notes as a new page the next time TwoNote is unlocked. Until then it is kept encrypted on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("share-failure")
            }
        }
    }
}

/// The extension's entry point (named in Info.plist): hosts the sheet and reads what was shared.
final class ShareViewController: NSViewController {
    private let model = ShareModel(container: .appGroup)
    private var host: NSHostingView<MacShareView>?

    override func loadView() {
        let sheet = MacShareView(
            model: model,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onSaved: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = NSHostingView(rootView: sheet)
        host.sizingOptions = [.preferredContentSize]
        self.host = host
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task {
            model.load(await ShareInput.read(items))
            preferredContentSize = host?.fittingSize ?? preferredContentSize
            #if DEBUG
            autoSaveForEndToEndRun()
            #endif
        }
    }

    #if DEBUG
    /// The app's end-to-end run cannot click into this sheet (it is another process, and
    /// driving another process's windows needs an accessibility permission the run does not
    /// have), so it asks for "Save" through a marker file in the App Group. Debug builds only;
    /// the marker says nothing about what is shared.
    private func autoSaveForEndToEndRun() {
        guard let container = SharedContainer.appGroup else { return }
        let marker = container.root.appendingPathComponent("e2e-share-autosave")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        if let title = try? String(contentsOf: marker.appendingPathExtension("title"), encoding: .utf8) {
            model.title = title
            try? FileManager.default.removeItem(at: marker.appendingPathExtension("title"))
        }
        if model.save() {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
    #endif
}
