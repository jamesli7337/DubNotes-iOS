import Foundation

/// The Free-plan notebook cap. Pages and boards both count; folders and dividers don't. Pro is unlimited.
enum NotebookCap {
    /// Whether one more notebook may be created. Only creating is limited: users already over the cap keep what
    /// they have, and nothing here ever blocks deleting or restoring.
    static func allowsCreation(plan: Plan, existing: Int, limit: Int = ProfileConstants.freeNotebookLimit) -> Bool {
        plan == .pro || existing < limit
    }
}

enum LibraryError: LocalizedError, Equatable {
    case freePlanLimit

    var errorDescription: String? {
        "Free plan is limited to \(ProfileConstants.freeNotebookLimit) notebooks."
    }
}
