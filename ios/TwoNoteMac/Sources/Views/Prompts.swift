import SwiftUI

/// A request to type a name (new notebook, rename…): on the Mac a small sheet with one field,
/// the way Notes asks for a folder name.
struct NameRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var initial = ""
    var confirm = "Save"
    var action: (String) -> Void
}

/// A request to confirm deleting something.
struct DeleteRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirm = "Delete"
    var action: () -> Void
}

private struct NameSheet: View {
    let request: NameRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var name: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title)
                .font(.headline)
            if let message = request.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(confirm)
                .accessibilityIdentifier("name-field")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirm, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
                    .accessibilityIdentifier("name-confirm")
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            text = request.initial
            focused = true
        }
    }

    private func confirm() {
        guard !name.isEmpty else { return }
        let name = name
        dismiss()
        request.action(name)
    }
}

private struct NamePrompt: ViewModifier {
    @Binding var request: NameRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { request in
            NameSheet(request: request)
        }
    }
}

private struct DeletePrompt: ViewModifier {
    @Binding var request: DeleteRequest?

    func body(content: Content) -> some View {
        content
            .alert(
                request?.title ?? "",
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                presenting: request
            ) { request in
                Button(request.confirm, role: .destructive) {
                    request.action()
                }
                .accessibilityIdentifier("delete-confirm")
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .dialogSeverity(.critical)
    }
}

extension View {
    func namePrompt(_ request: Binding<NameRequest?>) -> some View {
        modifier(NamePrompt(request: request))
    }

    func deletePrompt(_ request: Binding<DeleteRequest?>) -> some View {
        modifier(DeletePrompt(request: request))
    }

    /// The standard alert for a `UserMessage`.
    func messageAlert(_ message: Binding<UserMessage?>) -> some View {
        alert(
            message.wrappedValue?.title ?? "",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue?.detail ?? "")
        }
    }
}

/// The wording of the library's prompts, the same as on the iPhone.
@MainActor
enum LibraryPrompts {
    static func newNotebook(_ library: LibraryModel) -> NameRequest {
        NameRequest(title: "New Notebook", message: "Enter a name for this notebook.", confirm: "Create") { name in
            Task { await library.createNotebook(title: name) }
        }
    }

    static func renameNotebook(_ library: LibraryModel, _ notebook: LibraryModel.Notebook) -> NameRequest {
        NameRequest(title: "Rename Notebook", initial: notebook.title) { name in
            library.renameNotebook(notebook.id, title: name)
        }
    }

    static func newSection(_ library: LibraryModel, notebookId: String) -> NameRequest {
        NameRequest(title: "New Section", message: "Enter a name for this section.", confirm: "Create") { name in
            library.addSection(notebookId: notebookId, title: name)
        }
    }

    static func renameSection(_ library: LibraryModel, notebookId: String, _ section: SectionTitle) -> NameRequest {
        NameRequest(title: "Rename Section", initial: section.title) { name in
            library.renameSection(notebookId: notebookId, sectionId: section.id, title: name)
        }
    }

    static func renamePage(_ library: LibraryModel, _ ref: PageRef, title: String) -> NameRequest {
        NameRequest(title: "Rename Page", initial: title) { name in
            library.renamePage(ref, title: name)
        }
    }

    static func deleteSection(_ library: LibraryModel, notebookId: String, _ section: SectionTitle) -> DeleteRequest {
        let count = library.notebook(notebookId)?.pages(in: section.id).count ?? 0
        let pages = count == 0 ? "The section" : count == 1 ? "The section and its page" : "The section and its \(count) pages"
        return DeleteRequest(
            title: "Delete “\(section.displayTitle)”?",
            message: "\(pages) will be deleted on all your devices.",
            confirm: "Delete Section"
        ) {
            library.deleteSection(notebookId: notebookId, sectionId: section.id)
        }
    }

    static func deletePage(_ library: LibraryModel, _ ref: PageRef, title: String) -> DeleteRequest {
        DeleteRequest(
            title: "Delete “\(title)”?",
            message: "The page will be deleted on all your devices.",
            confirm: "Delete Page"
        ) {
            library.deletePage(ref)
        }
    }

    /// Says why first if the notebook cannot be deleted now, else asks.
    static func deleteNotebook(_ library: LibraryModel, _ notebook: LibraryModel.Notebook, ask: @escaping (DeleteRequest) -> Void) {
        Task {
            if let obstacle = await library.deleteNotebookObstacle(notebook.id) {
                library.alert = obstacle
                return
            }
            ask(DeleteRequest(
                title: "Delete “\(notebook.displayTitle)”?",
                message: "The notebook and everything in it will be deleted from your server and all your devices. This can’t be undone.",
                confirm: "Delete Notebook"
            ) {
                Task { await library.deleteNotebook(notebook.id) }
            })
        }
    }
}

/// A section's id and title, for the prompts.
struct SectionTitle {
    var id: String
    var title: String
    var displayTitle: String { title.isEmpty ? "Untitled Section" : title }
}

/// "Untitled Page" for a page without a title.
func pageTitle(_ title: String) -> String {
    title.isEmpty ? "Untitled Page" : title
}
