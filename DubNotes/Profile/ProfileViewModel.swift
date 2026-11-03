import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @ObservationIgnored private let service: AccountService

    // Mirrors of the service, refreshed after every action (the service itself is not observable).
    private(set) var user: AccountUser?
    private(set) var plan = Plan.free
    private(set) var notebookCount = 0
    private(set) var aiTrialRemaining = 0
    private(set) var referralCode = ""
    private(set) var referralCount = 0

    var billing = Billing.yearly
    var friendCode = ""
    var promoCode = ""
    var confirmingDelete = false
    var notice: Notice?
    private(set) var busy = false

    init(service: AccountService) {
        self.service = service
        refresh()
    }

    func refresh() {
        user = service.user
        plan = service.plan
        notebookCount = service.notebookCount
        aiTrialRemaining = service.aiTrialRemaining
        referralCode = service.referralCode
        referralCount = service.referralCount
    }

    var isSignedIn: Bool { user != nil }

    var price: String {
        billing == .monthly ? ProfileConstants.monthlyPrice : ProfileConstants.yearlyPrice
    }

    var priceUnit: String { billing == .monthly ? "month" : "year" }

    var notebooksUsage: String {
        plan == .pro ? "\(notebookCount) notebooks" : "\(notebookCount) of \(ProfileConstants.freeNotebookLimit) notebooks used"
    }

    var aiTrialUsage: String {
        "\(aiTrialRemaining) of \(ProfileConstants.freeAIQuestions) free AI questions left"
    }

    var referralShareMessage: String {
        "Try DubNotes with my code \(referralCode) for 20% off. \(ProfileConstants.referralLandingURL.absoluteString)"
    }

    // MARK: Actions

    func signIn() async { await run { try await self.service.signIn() } }

    func signOut() async {
        await service.signOut()
        refresh()
    }

    func deleteAccount() async {
        await run { try await self.service.deleteAccount() }
    }

    func upgrade() async {
        await run { try await self.service.upgrade(to: self.billing) }
    }

    func restorePurchases() async {
        await run {
            let found = try await self.service.restorePurchases()
            self.notice = Notice(title: found ? "Purchases restored" : "Nothing to restore",
                                 message: found ? "Your Pro plan is back." : "No earlier purchases were found for this Apple ID.")
        }
    }

    func redeemFriendCode() async {
        let code = friendCode
        await run {
            try await self.service.redeemReferral(code: code)
            self.friendCode = ""
            self.notice = Notice(title: "Code applied", message: "20% off one billing cycle, for you and your friend.")
        }
    }

    func redeemPromoCode() async {
        let code = promoCode
        await run {
            try await self.service.redeemPromo(code: code)
            self.promoCode = ""
        }
    }

    /// Runs a service call, shows its error, and refreshes the mirrored state either way.
    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            notice = Notice(title: "Couldn’t finish", message: error.localizedDescription)
        }
        refresh()
    }
}
