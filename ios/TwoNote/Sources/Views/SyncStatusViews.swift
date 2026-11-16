import SwiftUI
import TwoNoteCore

/// The status line under a list: "Synced", "Offline · Changes Waiting"… Tapping it opens
/// Settings, where the details are. Offline is shown as plainly as synced; only a sign-in request or a
/// failing sync is highlighted.
struct SyncStatusLine: View {
    let library: LibraryModel

    var body: some View {
        let summary = SyncSummary(library.client.syncMonitor.status)
        Button {
            library.showingSettings = true
        } label: {
            HStack(spacing: 4) {
                if summary.wantsAttention {
                    Image(systemName: summary.symbol)
                }
                Text(summary.title)
            }
            .font(.footnote)
            .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sync-status")
        .accessibilityLabel("Sync status: \(summary.title)")
    }
}

/// The same status as one small symbol, for the editor's navigation bar.
struct SyncStatusButton: View {
    let library: LibraryModel

    var body: some View {
        let summary = SyncSummary(library.client.syncMonitor.status)
        Button {
            library.showingSettings = true
        } label: {
            Image(systemName: summary.symbol)
                .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .accessibilityIdentifier("sync-status")
        .accessibilityLabel("Sync status: \(summary.title)")
    }
}

/// Settings and Lock, behind the ellipsis.
struct MoreMenu: View {
    let library: LibraryModel
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("Settings", systemImage: "gearshape") {
                library.showingSettings = true
            }
            Button("Lock TwoNote", systemImage: "lock") {
                Task { await app.lock() }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("more-menu")
    }
}
