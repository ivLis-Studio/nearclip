import AppIntents
import NearclipKit

/// "Send Verification Code", for a Shortcuts automation on Message (PROTOCOL.md §6.7). It finds the 4–8 digit code in the
/// message and sends just the code to the other devices, which ask before copying it. iOS lets no app read other apps'
/// notifications, so this is how a code from a text message reaches the computer; KakaoTalk has no automation trigger.
struct SendCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Verification Code"
    static let description = IntentDescription("Finds the verification code in a message and sends just the code to your other devices. They ask before copying it.")
    static let openAppWhenRun = false

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult {
        if let code = OneTimeCode.find(in: message) {
            await AppEnvironment.shared.forwardCode(code)
        }
        return .result()
    }
}
