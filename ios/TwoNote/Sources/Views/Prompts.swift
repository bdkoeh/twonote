import SwiftUI

/// A request to type a name: the standard alert with one text field (new notebook, rename…).
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

private struct NamePrompt: ViewModifier {
    @Binding var request: NameRequest?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(
                request?.title ?? "",
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                presenting: request
            ) { request in
                TextField("Name", text: $text)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("name-field")
                Button("Cancel", role: .cancel) {}
                Button(request.confirm) {
                    let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        request.action(name)
                    }
                }
            } message: { request in
                if let message = request.message {
                    Text(message)
                }
            }
            .onChange(of: request?.id) {
                text = request?.initial ?? ""
            }
    }
}

private struct DeletePrompt: ViewModifier {
    @Binding var request: DeleteRequest?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                request?.title ?? "",
                isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                titleVisibility: .visible,
                presenting: request
            ) { request in
                Button(request.confirm, role: .destructive) {
                    request.action()
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
    }
}

extension View {
    func namePrompt(_ request: Binding<NameRequest?>) -> some View {
        modifier(NamePrompt(request: request))
    }

    func deletePrompt(_ request: Binding<DeleteRequest?>) -> some View {
        modifier(DeletePrompt(request: request))
    }
}
