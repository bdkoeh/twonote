import SwiftUI
import YrsKit

/// Settings: where things shared to TwoNote from other apps go, and how many are waiting.
struct SharedItemsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            if let library = app.library {
                NavigationLink {
                    ShareDestinationView(library: library)
                } label: {
                    LabeledContent {
                        Text(library.shareDestinationSummary)
                    } label: {
                        Label("Shared Items Go To", systemImage: "square.and.arrow.down")
                    }
                }
                .accessibilityIdentifier("settings-share-destination")
                .onAppear { app.refreshWaitingSharedItems() }
            }
            if app.waitingSharedItems > 0 {
                LabeledContent("Waiting to Be Added", value: "\(app.waitingSharedItems)")
                    .accessibilityIdentifier("settings-share-waiting")
            }
        } header: {
            Text("Share Sheet")
        } footer: {
            Text("Text and links you share to TwoNote from other apps become pages in this section the next time TwoNote is unlocked. Until then they are kept encrypted on this device.")
        }
    }
}

/// Settings: whether the widget may show page titles.
struct WidgetSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { app.showsRecentPagesInWidget }, set: { app.setShowsRecentPagesInWidget($0) })) {
                Label("Show Recent Pages in Widget", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("settings-widget-recent")
        } header: {
            Text("Widget")
        } footer: {
            Text("The TwoNote widget normally shows only buttons. With this on, it also lists the titles of the pages you edited last. These titles are stored outside the encrypted vault, and anyone holding this device can read them on the Home Screen without unlocking TwoNote. The text of your pages is never shown.")
        }
    }
}

/// The section shared items go to: the Inbox that is made when needed, or any section.
struct ShareDestinationView: View {
    let library: LibraryModel

    var body: some View {
        let chosen = library.chosenShareDestination
        List {
            Section {
                Button {
                    library.chooseShareDestination(nil)
                } label: {
                    row(ShareDestination.inboxTitle, symbol: "tray", checked: chosen == nil)
                }
                .accessibilityIdentifier("share-destination-inbox")
            } footer: {
                if let first = library.notebooks.first {
                    Text("A section called \(ShareDestination.inboxTitle) in “\(first.displayTitle)”. It is created when the first item arrives.")
                } else {
                    Text("A section called \(ShareDestination.inboxTitle) in your first notebook. Shared items wait until there is a notebook on this device.")
                }
            }
            ForEach(library.notebooks) { notebook in
                Section(notebook.displayTitle) {
                    ForEach(notebook.sections) { section in
                        Button {
                            library.chooseShareDestination((notebook.id, section.id))
                        } label: {
                            row(section.title.isEmpty ? "Untitled Section" : section.title, symbol: "folder",
                                checked: chosen?.notebookId == notebook.id && chosen?.sectionId == section.id)
                        }
                    }
                    if notebook.sections.isEmpty {
                        Text("No Sections")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Shared Items Go To")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, symbol: String, checked: Bool) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
            Spacer()
            if checked {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(.rect)
    }
}

/// A remark in passing at the bottom of the screen ("2 Shared Items Added"); tapping it goes
/// to where the items are. Leaves by itself.
struct NoticeBanner: View {
    let library: LibraryModel

    var body: some View {
        ZStack {
            if let notice = library.notice {
                Button {
                    open(notice)
                } label: {
                    Label(notice.text, systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("import-notice")
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(5))
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
        if library.compactLayout {
            library.select(nil)
        }
    }
}
