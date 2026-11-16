import Foundation
import TwoNoteCore

/// Text for an alert: what went wrong, in the user's terms. Never contains secrets or note content.
struct UserMessage: Equatable, Error {
    var title: String
    var detail: String

    /// Why setting up this device failed.
    static func enrolFailure(_ error: any Error, server: URL, networkAvailable: Bool) -> UserMessage {
        switch error {
        case ClientError.malformedSecretKey:
            return UserMessage(
                title: "Check the Secret Key",
                detail: "A Secret Key looks like T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX. You can find it in your Emergency Kit or in TwoNote on another device.")
        case ClientError.wrongCredentials:
            return UserMessage(
                title: "Incorrect Sign-In Details",
                detail: "The username, password or Secret Key is not right. Check all three and try again.")
        case is ServerUnreachableError:
            if !networkAvailable {
                return UserMessage(
                    title: "You’re Offline",
                    detail: "This device has no network connection. Connect to the network your server is on, then try again.")
            }
            return UserMessage(
                title: "Can’t Reach the Server",
                detail: "Nothing answered at \(server.absoluteString). Check the address and port, and that this device is on the same network as the server (or that Tailscale is connected).")
        case let error as ApiError where error.code == ErrorCodes.rateLimited:
            return UserMessage(title: "Too Many Attempts", detail: "The server is asking to wait a moment. Try again in a minute.")
        case is ApiError, is ProtocolViolationError:
            return UserMessage(
                title: "Not a TwoNote Server",
                detail: "Something answered at \(server.absoluteString), but not the way a TwoNote server does. Check the address and port.")
        case let error as KeychainError:
            return UserMessage(
                title: "Couldn’t Save the Keys",
                detail: "The Keychain refused to store this device’s keys (error \(error.status)).")
        default:
            return generic(error)
        }
    }

    /// Why signing in again failed.
    static func signInFailure(_ error: any Error) -> UserMessage {
        switch error {
        case ClientError.wrongCredentials:
            UserMessage(title: "Incorrect Password", detail: "That is not the account’s current password.")
        case is ServerUnreachableError:
            UserMessage(title: "Can’t Reach the Server", detail: "Signing in needs a connection to your server. Try again when it is in reach.")
        default:
            generic(error)
        }
    }

    /// Why deleting a notebook failed.
    static func deleteNotebookFailure(_ error: any Error) -> UserMessage {
        switch error {
        case is ServerUnreachableError:
            UserMessage(
                title: "Can’t Delete Right Now",
                detail: "Deleting a notebook removes it from your server, so it needs a connection. Try again when the server is in reach.")
        case let error as ApiError where error.status == 401:
            UserMessage(title: "Sign In Required", detail: "Sign in again, then delete the notebook.")
        default:
            generic(error)
        }
    }

    /// Why something in Settings that needs the server (devices, password change) failed.
    static func serverActionFailure(_ error: any Error, action: String) -> UserMessage {
        switch error {
        case is ServerUnreachableError:
            UserMessage(
                title: "Can’t Reach the Server",
                detail: "\(action) needs a connection to your server. Try again when it is in reach.")
        case let error as ApiError where error.status == 401:
            UserMessage(
                title: "Sign In Required",
                detail: "Your server no longer accepts this device’s sign-in. Sign in again under Sync, then try again.")
        case let error as ApiError where error.code == ErrorCodes.rateLimited:
            UserMessage(title: "Too Many Attempts", detail: "The server is asking to wait a moment. Try again in a minute.")
        default:
            generic(error)
        }
    }

    /// Why biometric unlock could not be turned on.
    static func biometricsFailure(_ error: any Error, _ biometry: BiometryKind) -> UserMessage {
        switch error {
        case ClientError.wrongCredentials:
            UserMessage(title: "Incorrect Password", detail: "That is not your password. \(biometry.name) was not turned on.")
        case BiometricFailure.unavailable:
            UserMessage(
                title: "\(biometry.name) Isn’t Available",
                detail: "Set up Touch ID or Face ID in the Settings app, and allow TwoNote to use it, then try again.")
        case let error as KeychainFailure:
            UserMessage(
                title: "Couldn’t Turn On \(biometry.name)",
                detail: "The Keychain refused to store the key (error \(error.status)). Your password still unlocks TwoNote.")
        default:
            generic(error)
        }
    }

    /// Shown instead of the delete confirmation when a notebook cannot be deleted right now.
    static let deleteNotebookOffline = UserMessage(
        title: "Can’t Delete While Offline",
        detail: "Deleting a notebook removes it from your server and from all your devices at once, so it has to wait until your server is in reach. Nothing was deleted.")

    static func generic(_ error: any Error) -> UserMessage {
        // Only the kind of error: descriptions from lower layers are not vetted for content.
        UserMessage(title: "Something Went Wrong", detail: "TwoNote could not finish that (\(type(of: error))).")
    }
}
