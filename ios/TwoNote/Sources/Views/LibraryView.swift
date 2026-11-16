import SwiftUI

/// The unlocked app: notebooks → sections → pages → page.
///
/// Narrow (the Duo's cover display, an iPhone, a slim iPad window): one navigation stack.
/// Wide (an iPad, the Duo unfolded): the same hierarchy as a sidebar, with the page beside it.
/// "Wide" is a regular size class, or failing that simply enough width.
/// Both render `LibraryModel`'s navigation state, so changing between them mid-edit keeps the
/// open page; the editor's views belong to the model and move across with their selection,
/// scroll position and keyboard.
struct LibraryView: View {
    let library: LibraryModel

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    /// Wide enough for sidebar and page side by side, even if the system calls the width compact.
    static let wideWidth: CGFloat = 560

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitLayout
            } else if width >= Self.wideWidth {
                sideBySideLayout
            } else {
                compactLayout
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: sizeClass != .regular && width < Self.wideWidth, initial: true) { _, compact in
            library.compactLayout = compact
        }
        .overlay(alignment: .bottom) {
            NoticeBanner(library: library)
        }
        .sheet(isPresented: Binding(get: { library.showingSettings }, set: { library.showingSettings = $0 })) {
            SettingsView()
        }
        .alert(
            "Unlock with \(app.biometry.name)?",
            isPresented: Binding(get: { app.biometricOffer }, set: { _ in }) // both buttons answer
        ) {
            Button("Use \(app.biometry.name)") { app.answerBiometricOffer(enable: true) }
            Button("Not Now", role: .cancel) { app.answerBiometricOffer(enable: false) }
        } message: {
            Text("TwoNote can unlock with \(app.biometry.name) on this device instead of your password. You can change this in Settings.")
        }
        .alert(
            library.alert?.title ?? "",
            isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.alert?.detail ?? "")
        }
    }

    private var compactLayout: some View {
        NavigationStack(path: Binding(
            get: { library.path + (library.selectedPage.map { [Route.page($0)] } ?? []) },
            set: { library.navigate(to: $0) })
        ) {
            NotebookListView(library: library)
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
    }

    /// Regular width (an iPad, and the unfolded Duo if the system calls it regular): the
    /// system's split view.
    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            NavigationStack {
                PageView(library: library)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// A screen the system calls compact but that is wide enough for both: a split view would
    /// collapse itself there (it follows the size class), so the two stacks are placed side by
    /// side directly.
    private var sideBySideLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: min(300, max(240, (width * 0.42).rounded())))
            Divider()
                .ignoresSafeArea()
            NavigationStack {
                PageView(library: library)
            }
        }
    }

    private var sidebar: some View {
        NavigationStack(path: Binding(get: { library.path }, set: { library.setPath($0) })) {
            NotebookListView(library: library)
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .notebook(let notebookId):
            SectionListView(library: library, notebookId: notebookId)
        case .section(let notebookId, let sectionId):
            PageListView(library: library, notebookId: notebookId, sectionId: sectionId)
        case .page:
            PageView(library: library)
        }
    }
}
