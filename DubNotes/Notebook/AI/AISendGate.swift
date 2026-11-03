import SwiftUI

/// Hook for the future per-user server check. Nothing implements it yet; `NoServerCheck` always allows.
protocol AIServerCheck {
    func decide(plan: Plan) async -> AISendGate.Decision
}

struct NoServerCheck: AIServerCheck {
    func decide(plan: Plan) async -> AISendGate.Decision { .allowed }
}

/// The single place that decides whether an AI Send may go ahead, and that counts a question once its reply is saved.
@MainActor
final class AISendGate {
    enum Decision: Equatable {
        case allowed
        case trialExhausted
    }

    let account: AccountService
    private let serverCheck: AIServerCheck

    init(account: AccountService, serverCheck: AIServerCheck = NoServerCheck()) {
        self.account = account
        self.serverCheck = serverCheck
    }

    func decide() async -> Decision {
        if account.plan == .free && account.aiTrialRemaining <= 0 { return .trialExhausted }
        // TODO(server-check): per-user server enforcement plugs in here through `serverCheck`.
        return await serverCheck.decide(plan: account.plan)
    }

    /// Call once a successful reply has been saved. Pro is never counted.
    func recordSuccessfulReply() {
        if account.plan == .free { account.consumeAITrialQuestion() }
    }
}

private struct AISendGateKey: EnvironmentKey {
    static let defaultValue: AISendGate? = nil
}

extension EnvironmentValues {
    /// Set by the library for the notebook screens; nil (previews) means Send is not gated.
    var aiSendGate: AISendGate? {
        get { self[AISendGateKey.self] }
        set { self[AISendGateKey.self] = newValue }
    }
}
