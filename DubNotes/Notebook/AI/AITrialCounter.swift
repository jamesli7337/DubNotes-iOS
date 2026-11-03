import Foundation
import Security

/// Where the number of used trial questions lives.
protocol AITrialStorage: AnyObject {
    func loadUsed() -> Int
    func saveUsed(_ count: Int)
}

final class InMemoryAITrialStorage: AITrialStorage {
    private var used: Int
    init(used: Int = 0) { self.used = used }
    func loadUsed() -> Int { used }
    func saveUsed(_ count: Int) { used = count }
}

/// Keychain, not UserDefaults: the value normally survives deleting and reinstalling the app.
final class KeychainAITrialStorage: AITrialStorage {
    private let service: String
    private let account = "ai-trial-used"

    init(service: String = "com.jamesli.dubnotes.ai-trial") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func loadUsed() -> Int {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8), let n = Int(text) else { return 0 }
        return max(0, n)
    }

    func saveUsed(_ count: Int) {
        let data = Data(String(count).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// The one-time Free AI trial: `limit` questions in total, never reset. It stores questions used, so a changed
/// limit can't hand any back.
final class AITrialCounter {
    let limit: Int
    private let storage: AITrialStorage

    init(storage: AITrialStorage, limit: Int = ProfileConstants.freeAIQuestions) {
        self.storage = storage
        self.limit = limit
    }

    /// The app's counter, backed by the Keychain.
    static let shared = AITrialCounter(storage: KeychainAITrialStorage())

    var remaining: Int { max(0, limit - storage.loadUsed()) }

    func consume() {
        guard remaining > 0 else { return }
        storage.saveUsed(storage.loadUsed() + 1)
    }
}
