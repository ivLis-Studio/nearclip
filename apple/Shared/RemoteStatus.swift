import NearclipKit
import SwiftUI

/// How the remote-connection status reads in Settings (DESIGN.md §4.7).
struct RemoteStatus {
    enum Tone { case neutral, on, attention, error }
    enum Action { case none, signIn, retry }

    var title: String
    var detail: String?
    var hint: String?
    var tone: Tone
    var action: Action
    var busy: Bool
    var canSignOut: Bool

    @MainActor
    init(_ model: AppModel) {
        let st = model.tailnet
        canSignOut = false
        detail = nil
        hint = nil
        busy = false
        // Pausing stops the remote connection with everything else; it starts again when syncing resumes.
        if model.settings.paused {
            title = String(localized: "Paused")
            detail = String(localized: "It turns back on when you resume syncing.")
            tone = .neutral
            action = .none
            return
        }
        switch st.state {
        case "running" where st.isRunning:
            title = st.account.map { String(localized: "On · \($0)") } ?? String(localized: "On")
            detail = st.ip.map { String(localized: "This device: \($0)") }
            hint = String(localized: "Sign in with the same account on your other devices.")
            tone = .on
            action = .none
            canSignOut = true
        case "needsLogin":
            title = model.tailnetSigningIn ? String(localized: "Waiting for sign-in…") : String(localized: "Sign in to Tailscale to finish turning this on.")
            tone = .attention
            action = .signIn
            busy = model.tailnetSigningIn
        case "needsApproval":
            title = String(localized: "Approve this device in the Tailscale admin console.")
            tone = .attention
            action = .none
            canSignOut = true
        case "error":
            title = String(localized: "Couldn't start remote connection. \(st.error ?? "")")
            tone = .error
            action = .retry
        default:
            title = String(localized: "Starting…")
            tone = .neutral
            action = .none
            busy = true
        }
    }

    var color: Color {
        switch tone {
        case .on: return Brand.online
        case .attention: return Brand.warning
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}
