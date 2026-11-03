import Foundation

/// Every price, limit and link the Profile screen shows, in one place. The prices and URLs are placeholders:
/// replace them before shipping. The limits only drive what the screen displays; nothing here enforces them.
enum ProfileConstants {
    // MARK: Limits shown to the user

    /// Notebooks included with the free plan.
    static let freeNotebookLimit = 8
    /// One-time AI questions a free account can try; they never reset.
    static let freeAIQuestions = 2
    /// AI questions per month on Pro.
    static let proAIQuestionsPerMonth = 100

    // MARK: Prices (placeholders)

    static let monthlyPrice = "$X.XX"
    static let yearlyPrice = "$X.XX"

    // MARK: Links (placeholders)

    static let privacyPolicyURL = URL(string: "https://example.com/privacy")!
    static let termsURL = URL(string: "https://example.com/terms")!
    static let manageSubscriptionURL = URL(string: "https://example.com/manage-subscription")!
    /// Where a shared referral code points a friend.
    static let referralLandingURL = URL(string: "https://example.com/invite")!
}
