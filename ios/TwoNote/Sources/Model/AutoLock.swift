import Foundation

/// How long the app may stay in the background before it locks itself.
enum AutoLockDelay: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case never = -1

    static let standard = AutoLockDelay.fiveMinutes

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        case .never: "Never"
        }
    }

    /// Whether an app that has been in the background for `elapsed` has to lock.
    func shouldLock(after elapsed: Duration) -> Bool {
        switch self {
        case .never: false
        case .immediately: true
        default: elapsed >= .seconds(rawValue)
        }
    }
}
