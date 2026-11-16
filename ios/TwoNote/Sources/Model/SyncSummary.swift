import Foundation
import TwoNoteCore

/// What the sync indicator shows: one of five calm states, derived from the engine's status.
/// Being offline is the normal state of this app away from home, so it reads as a fact, not
/// as a failure.
struct SyncSummary: Equatable {
    enum Kind: Equatable {
        case synced
        case syncing
        case offline
        case needsSignIn
        case problem
    }

    var kind: Kind
    /// Pages with edits the server has not acknowledged yet.
    var pendingPages: Int
    /// Notebooks whose lists (names, sections, page order) have changes the server has not acknowledged yet.
    var pendingNotebooks: Int
    /// Whether anything at all is waiting.
    var hasPending: Bool

    init(_ status: SyncStatus) {
        pendingPages = status.pendingPages
        pendingNotebooks = status.pendingNotebooks
        hasPending = status.pendingUpdates > 0
        switch status.state {
        case .authRequired:
            kind = .needsSignIn
        case .offline:
            kind = .offline
        case .error:
            kind = .problem
        case .syncing:
            kind = .syncing
        case .idle:
            if !status.running {
                kind = .offline // the loop is stopped: nothing is being sent
            } else if status.pendingUpdates > 0 || status.cursor < status.head || status.lastSyncedAt == nil {
                kind = .syncing
            } else {
                kind = .synced
            }
        }
    }

    /// Short text for the status line under a list.
    var title: String {
        switch kind {
        case .synced: "Synced"
        case .syncing: "Syncing…"
        case .offline: hasPending ? "Offline · Changes Waiting" : "Offline"
        case .needsSignIn: "Sign In Required"
        case .problem: "Sync Paused"
        }
    }

    /// What is waiting, in the user's terms: "2 Pages", "1 Page and Notebook Changes",
    /// "Notebook Changes". Nil when nothing is. The engine's count of raw updates (one per
    /// burst of typing) is not something to show a person.
    var waiting: String? {
        guard hasPending else { return nil }
        let pages = pendingPages == 1 ? "1 Page" : "\(pendingPages) Pages"
        if pendingPages > 0 && pendingNotebooks > 0 {
            return "\(pages) and Notebook Changes"
        }
        if pendingPages > 0 {
            return pages
        }
        return pendingNotebooks > 0 ? "Notebook Changes" : "Changes"
    }

    /// One sentence for the settings sheet.
    var explanation: String {
        switch kind {
        case .synced:
            "Everything on this device is on your server."
        case .syncing:
            "Exchanging changes with your server."
        case .offline:
            hasPending
                ? "Your server can’t be reached right now. The changes saved on this device will sync when it is back in reach."
                : "Your server can’t be reached right now. You can keep working; changes sync when it is back in reach."
        case .needsSignIn:
            "Your server no longer accepts this device’s sign-in, usually because the password was changed on another device. Sign in again to continue syncing."
        case .problem:
            "The last sync did not finish. TwoNote will keep trying."
        }
    }

    var symbol: String {
        switch kind {
        case .synced: "checkmark.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .problem: "exclamationmark.triangle"
        }
    }

    /// True for the states that want the user's attention.
    var wantsAttention: Bool {
        kind == .needsSignIn || kind == .problem
    }
}
