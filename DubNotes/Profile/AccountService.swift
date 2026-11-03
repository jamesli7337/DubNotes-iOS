import Foundation

struct AccountUser: Equatable {
    var name: String
    var email: String
}

enum Plan: Equatable {
    case free, pro

    var title: String { self == .pro ? "Pro" : "Free" }
}

enum Billing: String, CaseIterable {
    case monthly, yearly

    var label: String { rawValue.capitalized }
}

enum AccountError: LocalizedError, Equatable {
    case signInRequired
    case emptyCode
    case ownCode
    case alreadyRedeemed
    case unknownCode
    case unavailable

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in first."
        case .emptyCode: return "Enter a code first."
        case .ownCode: return "That is your own referral code."
        case .alreadyRedeemed: return "You have already used a friend’s code."
        case .unknownCode: return "That code wasn’t recognised."
        case .unavailable: return "This isn’t available yet."
        }
    }
}

/// What the Profile screen needs from the account system. The reads are plain values; the actions are async because
/// the real service will talk to Sign in with Apple, StoreKit and a server. Only `MockAccountService` exists today.
@MainActor
protocol AccountService: AnyObject {
    var user: AccountUser? { get }
    var plan: Plan { get }
    var notebookCount: Int { get }
    /// Free AI questions left from the one-time trial.
    var aiTrialRemaining: Int { get }
    /// Empty while signed out.
    var referralCode: String { get }
    var referralCount: Int { get }

    func signIn() async throws
    func signOut() async
    func deleteAccount() async throws
    func upgrade(to billing: Billing) async throws
    /// True if a purchase was found and restored.
    func restorePurchases() async throws -> Bool
    func redeemReferral(code: String) async throws
    func redeemPromo(code: String) async throws
}

/// In-memory stand-in: nothing is stored, nothing leaves the device. `notebookCount` is read live from the library.
@MainActor
final class MockAccountService: AccountService {
    private(set) var user: AccountUser?
    private(set) var plan: Plan
    private(set) var aiTrialRemaining: Int
    private(set) var referralCode: String
    private(set) var referralCount: Int
    private var redeemedFriendCode = false
    private let notebookCountProvider: () -> Int

    var notebookCount: Int { notebookCountProvider() }

    init(user: AccountUser? = nil, plan: Plan = .free, aiTrialRemaining: Int = ProfileConstants.freeAIQuestions,
         referralCode: String = "", referralCount: Int = 0, notebookCount: @escaping () -> Int) {
        self.user = user
        self.plan = plan
        self.aiTrialRemaining = aiTrialRemaining
        self.referralCode = referralCode
        self.referralCount = referralCount
        self.notebookCountProvider = notebookCount
    }

    func signIn() async throws {
        user = AccountUser(name: "Sample User", email: "sample@example.com")
        referralCode = "DUB-SAMPLE"
    }

    func signOut() async {
        user = nil
        plan = .free
        referralCode = ""
        referralCount = 0
    }

    func deleteAccount() async throws {
        await signOut()
        aiTrialRemaining = ProfileConstants.freeAIQuestions
        redeemedFriendCode = false
    }

    func upgrade(to billing: Billing) async throws {
        guard user != nil else { throw AccountError.signInRequired }
        plan = .pro
    }

    func restorePurchases() async throws -> Bool { false }

    func redeemReferral(code: String) async throws {
        guard user != nil else { throw AccountError.signInRequired }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw AccountError.emptyCode }
        guard trimmed != referralCode else { throw AccountError.ownCode }
        guard !redeemedFriendCode else { throw AccountError.alreadyRedeemed }
        guard trimmed.hasPrefix("DUB-") else { throw AccountError.unknownCode }
        redeemedFriendCode = true
    }

    func redeemPromo(code: String) async throws {
        throw AccountError.unavailable
    }
}
