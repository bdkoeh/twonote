import SwiftUI
import TwoNoteDocuments
import TwoNoteEditor

@main
struct EditorSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Two replicas of one page, as two devices would hold them, joined by a slow link.
/// (ObservableObject rather than @Observable for historical reasons: TwoNoteDocuments used to
/// have a class called `Observation` that shadowed the module the macro expands to. It is now
/// `ChangeObservation`, so `@Observable` works; the real app uses it.)
@MainActor
final class SpikeSession: ObservableObject {
    let a: InMemoryPageText
    let b: InMemoryPageText
    let link: InMemoryPageLink
    @Published var isOffline = false {
        didSet { link.isPaused = isOffline }
    }

    init() {
        a = InMemoryPageText(site: 1, seed: SampleContent.runs)
        b = InMemoryPageText(site: 2, seed: SampleContent.runs)
        a.undoCaptureInterval = 0.6
        b.undoCaptureInterval = 0.6
        link = InMemoryPageLink(a, b, delay: 0.4)
    }
}

struct ContentView: View {
    @StateObject private var session = SpikeSession()
    @State private var shown = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular {
                    HStack(spacing: 0) {
                        pane("Replica A", session.a)
                        Divider()
                        pane("Replica B", session.b)
                    }
                } else {
                    ZStack {
                        EditorView(page: session.a)
                            .opacity(shown == 0 ? 1 : 0)
                            .allowsHitTesting(shown == 0)
                        EditorView(page: session.b)
                            .opacity(shown == 1 ? 1 : 0)
                            .allowsHitTesting(shown == 1)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("Editor Spike")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sizeClass != .regular {
                    ToolbarItem(placement: .principal) {
                        Picker("Replica", selection: $shown) {
                            Text("Replica A").tag(0)
                            Text("Replica B").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.isOffline.toggle()
                    } label: {
                        Label(session.isOffline ? "Reconnect" : "Go Offline",
                              systemImage: session.isOffline ? "wifi.slash" : "wifi")
                    }
                }
            }
        }
    }

    private func pane(_ title: String, _ page: InMemoryPageText) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
            EditorView(page: page)
        }
    }
}

/// Hosts the UIKit editor: an `EditorTextView` bound to a page, with the format bar above the keyboard.
struct EditorView: UIViewRepresentable {
    let page: InMemoryPageText

    @MainActor
    final class Coordinator {
        var binding: PageTextBinding?
        var bar: FormatBar?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        let binding = PageTextBinding(textView: view, page: page)
        let bar = FormatBar(binding: binding)
        view.inputAccessoryView = bar.toolbar
        context.coordinator.binding = binding
        context.coordinator.bar = bar
        // For screenshots from the command line: `simctl launch <device> <bundle id> -spikeFocus A`.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-spikeFocus"), flag + 1 < arguments.count,
           arguments[flag + 1] == (page.site == 1 ? "A" : "B") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                view.becomeFirstResponder()
                view.selectedRange = NSRange(location: 78, length: 4)
            }
        }
        if arguments.contains("-spikeScrollToEnd") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                view.layoutIfNeeded()
                let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
                view.setContentOffset(CGPoint(x: 0, y: max(-view.adjustedContentInset.top, bottom)), animated: false)
            }
        }
        return view
    }

    func updateUIView(_ view: EditorTextView, context: Context) {}
}
