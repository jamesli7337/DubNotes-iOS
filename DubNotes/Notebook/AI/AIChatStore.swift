import Foundation
import Observation

/// One reply in an AI chat. `model` is the label shown under it.
struct AITurn: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var model: String
    var isError: Bool
}

struct AIChat: Identifiable, Equatable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var turns: [AITurn]
}

/// AI mode's chats for one open notebook. Memory only: nothing is saved, and it goes when the notebook closes.
/// Step 1 has no network: `sendStub()` waits a moment and adds a canned reply.
@Observable
final class AIChatStore {
    static let placeholderPrompt = "Look at my page and explain the steps so far."
    static let placeholderReply = "This is a placeholder reply. AI replies are not connected yet."
    static let stubModel = "stub"
    static let titleLength = 40
    private static let thinkingNanoseconds: UInt64 = 1_000_000_000

    private(set) var chats: [AIChat] = []
    var activeChatId: String?
    /// The chat a reply is being waited for in, if any.
    private(set) var thinkingChatId: String?

    /// Newest first, for the picker.
    var chatsNewestFirst: [AIChat] { chats.sorted { $0.createdAt > $1.createdAt } }
    var activeChat: AIChat? { activeChatId.flatMap { id in chats.first { $0.id == id } } }
    var isThinkingInActiveChat: Bool { thinkingChatId != nil && thinkingChatId == activeChatId }

    /// The first `titleLength` characters of `text`, whitespace collapsed, with an ellipsis when cut.
    static func title(from text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > titleLength ? String(flat.prefix(titleLength)) + "…" : flat
    }

    /// "New chat": nothing is active, so the next send starts one.
    func startNewChat() {
        activeChatId = nil
    }

    func deleteActiveChat() {
        guard let id = activeChatId else { return }
        chats.removeAll { $0.id == id }
        activeChatId = nil
    }

    /// Fake send: creates a chat if none is active, then after about a second adds a placeholder reply.
    func sendStub() {
        guard thinkingChatId == nil else { return }
        let id: String
        if let active = activeChat {
            id = active.id
        } else {
            let now = Date()
            id = UUID().uuidString
            chats.append(AIChat(id: id, title: "", createdAt: now, updatedAt: now, turns: []))
            activeChatId = id
        }
        if let i = chats.firstIndex(where: { $0.id == id }), chats[i].title.isEmpty {
            chats[i].title = Self.title(from: Self.placeholderPrompt) // set once
        }
        thinkingChatId = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.thinkingNanoseconds)
            self?.finishStub(chatId: id)
        }
    }

    private func finishStub(chatId: String) {
        thinkingChatId = nil
        guard let i = chats.firstIndex(where: { $0.id == chatId }) else { return } // deleted while waiting
        chats[i].turns.append(AITurn(text: Self.placeholderReply, model: Self.stubModel, isError: false))
        chats[i].updatedAt = Date()
    }
}
