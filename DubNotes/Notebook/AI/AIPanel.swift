import SwiftUI
import UIKit

enum AITheme {
    /// #6d28d9
    static let violet = Color(red: 0x6d / 255, green: 0x28 / 255, blue: 0xd9 / 255)
    static let uiViolet = UIColor(red: 0x6d / 255, green: 0x28 / 255, blue: 0xd9 / 255, alpha: 1)
    /// The violet for text and outlines that sit on dark backgrounds, where #6d28d9 is too dim to read.
    static let uiVioletOnDark = UIColor(red: 0xc4 / 255, green: 0xb5 / 255, blue: 0xfd / 255, alpha: 1)
    static let uiVioletText = UIColor { $0.userInterfaceStyle == .dark ? AITheme.uiVioletOnDark : AITheme.uiViolet }
    static let violetText = Color(AITheme.uiVioletText)
}

/// The slide-out chat panel that opens over the left edge of the notebook when AI mode turns on.
struct AIPanel: View {
    static let width: CGFloat = 326

    let store: AIChatStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            SwiftUI.Divider()
            picker
            SwiftUI.Divider()
            turns
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(.separator)).frame(width: 0.5).ignoresSafeArea()
        }
        .shadow(color: .black.opacity(0.2), radius: 10, x: 2)
    }

    private var header: some View {
        HStack {
            Text("DubNotes AI").font(.headline).foregroundStyle(AITheme.violetText)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close AI panel")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
    }

    private var picker: some View {
        Menu {
            Button { store.startNewChat() } label: {
                if store.activeChatId == nil { Label("New chat", systemImage: "checkmark") } else { Text("New chat") }
            }
            ForEach(store.chatsNewestFirst) { chat in
                Button { store.activeChatId = chat.id } label: {
                    if chat.id == store.activeChatId { Label(chat.title, systemImage: "checkmark") } else { Text(chat.title) }
                }
            }
            if store.activeChat != nil {
                SwiftUI.Divider()
                Button(role: .destructive) { store.deleteActiveChat() } label: { Label("Delete chat", systemImage: "trash") }
            }
        } label: {
            HStack {
                Text(store.activeChat?.title ?? "New chat").lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .accessibilityLabel("Chats")
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var turns: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(store.activeChat?.turns ?? []) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(turn.text)
                            .foregroundStyle(turn.isError ? Color.red : Color.primary)
                            .padding(12)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(turn.model).font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                if store.isThinkingInActiveChat {
                    Text("DubNotes AI is thinking...").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }
            .padding(12)
        }
        .defaultScrollAnchor(.bottom)
    }
}
