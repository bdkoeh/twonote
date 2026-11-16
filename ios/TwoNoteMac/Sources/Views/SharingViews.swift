import SwiftUI

// The Mac's side of Share to TwoNote and the widget: the remark when shared items were added,
// and the Settings tab for both. Same model and wording as the iPhone's ExtrasViews.swift,
// laid out the Mac's way (a menu instead of a list to pick from, a tab instead of a section).

/// A remark in passing at the foot of the window ("2 Shared Items Added"); clicking it shows
/// the section the items went to. Leaves by itself.
struct NoticeBanner: View {
    let library: LibraryModel

    var body: some View {
        ZStack {
            if let notice = library.notice {
                Button {
                    open(notice)
                } label: {
                    Label(notice.text, systemImage: "square.and.arrow.down")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help("Show the section they were added to")
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("import-notice")
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled {
                        library.notice = nil
                    }
                }
            }
        }
        .animation(.snappy, value: library.notice)
    }

    private func open(_ notice: LibraryModel.Notice) {
        library.notice = nil
        guard let notebookId = notice.notebookId, let sectionId = notice.sectionId,
              library.notebook(notebookId)?.section(sectionId) != nil else { return }
        library.setPath([.notebook(notebookId), .section(notebookId: notebookId, sectionId: sectionId)])
    }
}

/// Settings > Sharing: where things shared to TwoNote go and how many are waiting, and whether
/// the widget may show page titles.
struct SharingSettings: View {
    let library: LibraryModel
    @Environment(AppModel.self) private var app

    /// The picker's value for the default (an Inbox section in the first notebook).
    private static let inbox = ""

    var body: some View {
        Form {
            Section {
                Picker(selection: destination) {
                    Text(inboxTitle).tag(Self.inbox)
                    ForEach(library.notebooks) { notebook in
                        Section(notebook.displayTitle) {
                            ForEach(notebook.sections) { section in
                                Text(section.title.isEmpty ? "Untitled Section" : section.title)
                                    .tag(Self.tag(notebook.id, section.id))
                            }
                        }
                    }
                } label: {
                    Label("Shared Items Go To", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings-share-destination")
                if app.waitingSharedItems > 0 {
                    LabeledContent {
                        Text("\(app.waitingSharedItems)")
                    } label: {
                        Label("Waiting to Be Added", systemImage: "clock")
                    }
                    .accessibilityIdentifier("settings-share-waiting")
                }
            } header: {
                Text("Share Menu")
            } footer: {
                Text("Text and links you share to TwoNote from other apps’ Share menu become pages in this section the next time TwoNote is unlocked. Until then they are kept encrypted on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { app.showsRecentPagesInWidget }, set: { app.setShowsRecentPagesInWidget($0) })) {
                    Label("Show Recent Pages in Widget", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("settings-widget-recent")
            } header: {
                Text("Widget")
            } footer: {
                Text(Self.widgetFooter)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { app.refreshWaitingSharedItems() }
    }

    static let widgetFooter = "The TwoNote widget normally shows only buttons. With this on, it also lists the titles of the pages you edited last. These titles are stored outside the encrypted vault, and anyone using this Mac can read them on the desktop and in Notification Center without unlocking TwoNote. The text of your pages is never shown."

    /// The default's name: the Inbox section that is made when the first item arrives.
    private var inboxTitle: String {
        if let first = library.notebooks.first {
            "\(ShareDestination.inboxTitle) in “\(first.displayTitle)”"
        } else {
            ShareDestination.inboxTitle
        }
    }

    /// The picker's value for a section.
    static func tag(_ notebookId: String, _ sectionId: String) -> String {
        "\(notebookId)/\(sectionId)"
    }

    private var destination: Binding<String> { Self.destination(library) }

    /// The picker's value: the chosen section's tag, or the default's.
    static func destination(_ library: LibraryModel) -> Binding<String> {
        Binding(
            get: {
                guard let chosen = library.chosenShareDestination else { return inbox }
                return tag(chosen.notebookId, chosen.sectionId)
            },
            set: { value in
                let parts = value.split(separator: "/").map(String.init)
                library.chooseShareDestination(parts.count == 2 ? (parts[0], parts[1]) : nil)
            })
    }
}
