import SwiftUI
import UIKit

/// Colours from the Profile design. Light values are the design's; the dark ones are matching neutrals.
private enum PF {
    static func color(_ light: UInt32, dark: UInt32) -> Color {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    static let sheet = color(0xffffff, dark: 0x1c1c1e)
    static let card = color(0xfafafa, dark: 0x252528)
    static let inner = color(0xffffff, dark: 0x2e2e32)
    static let border = color(0xe5e7eb, dark: 0x3a3a3e)
    static let innerBorder = color(0xe8eaef, dark: 0x3a3a3e)
    static let hairline = color(0xf0f1f4, dark: 0x2e2e32)
    static let ink = color(0x1f2530, dark: 0xf2f3f6)
    static let inkMuted = color(0x555b6d, dark: 0xb4b8c4)
    static let inkSoft = color(0x707b93, dark: 0x9aa2b5)
    static let inkFaint = color(0x8e9099, dark: 0x8a8d98)
    static let chip = color(0xecedf2, dark: 0x2e2e32)
    static let control = color(0xf2f3f6, dark: 0x303034)
    static let controlBorder = color(0xdcdfe5, dark: 0x45454a)
    static let violet = AITheme.violet
    static let violetText = AITheme.violetText

    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8

    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

private struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var fill = PF.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: PF.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PF.cardRadius, style: .continuous).strokeBorder(PF.border))
    }
}

private struct CardSeparator: View {
    var body: some View {
        Rectangle().fill(PF.innerBorder).frame(height: 1)
    }
}

private struct FilledButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color = .white
    var border: Color?
    var radius: CGFloat = PF.buttonRadius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PF.body(12, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if let border { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border) }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct ProfileView: View {
    @State private var model: ProfileViewModel
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(model: ProfileViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountCard
                    SwiftUI.Divider().overlay(PF.hairline)
                    planCard
                    usageCard
                    if model.isSignedIn {
                        referralCard
                    } else {
                        freeAINote
                    }
                    promoCard
                    if model.isSignedIn { deleteCard }
                    linksRow
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
            }
        }
        .background(PF.sheet)
        .foregroundStyle(PF.ink)
        .tint(PF.violet)
        .onAppear { model.refresh() }
        .alert(item: $model.notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Delete your account?", isPresented: $model.confirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.plan == .pro
                 ? "This permanently deletes your DubNotes account and can’t be undone. It does not cancel your subscription — use Manage subscription first."
                 : "This permanently deletes your DubNotes account and can’t be undone.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Text("PROFILE & ACCOUNT")
                .font(PF.body(12, .semibold))
                .tracking(0.8)
                .foregroundStyle(PF.inkFaint)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PF.inkSoft)
                    .frame(width: 32, height: 32)
                    .background(PF.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(PF.hairline).frame(height: 1) }
    }

    // MARK: Account

    @ViewBuilder
    private var accountCard: some View {
        if let user = model.user {
            Card {
                HStack(spacing: 14) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name).font(PF.heading(16))
                        Text(user.email).font(PF.body(12)).foregroundStyle(PF.inkSoft)
                    }
                    Spacer(minLength: 12)
                    Button("Sign out") { Task { await model.signOut() } }
                        .buttonStyle(FilledButtonStyle(fill: PF.control, foreground: PF.ink, border: PF.controlBorder))
                }
            }
        } else {
            Card {
                VStack(spacing: 12) {
                    avatar
                    VStack(spacing: 4) {
                        Text("Sign in to use AI").font(PF.heading(16))
                        Text("Connect with your Apple ID to synchronize notebooks, unlock formula derivations, and access free AI questions.")
                            .font(PF.body(12))
                            .foregroundStyle(PF.inkSoft)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 384)
                    }
                    Button { Task { await model.signIn() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "applelogo")
                            Text("Sign in with Apple")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledButtonStyle(fill: .black))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var avatar: some View {
        Image(systemName: "touchid")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(PF.violetText)
            .frame(width: 48, height: 48)
            .background(PF.inner, in: Circle())
            .overlay(Circle().strokeBorder(PF.innerBorder))
    }

    // MARK: Plan

    private var planCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.plan.title) plan").font(PF.heading(14))
                        VStack(alignment: .leading, spacing: 4) {
                            if model.plan == .pro {
                                bullet("Unlimited notebooks", color: PF.inkFaint)
                                bullet("\(ProfileConstants.proAIQuestionsPerMonth) AI questions / mo", color: PF.violet)
                            } else {
                                bullet("\(ProfileConstants.freeNotebookLimit) notebooks included", color: PF.inkFaint)
                                bullet("\(ProfileConstants.freeAIQuestions) free AI questions to try", color: PF.violet)
                            }
                        }
                    }
                    Spacer(minLength: 12)
                    if model.plan == .pro {
                        Button("Manage subscription") { openURL(ProfileConstants.manageSubscriptionURL) }
                            .buttonStyle(FilledButtonStyle(fill: PF.control, foreground: PF.ink, border: PF.controlBorder))
                    } else {
                        Button("Upgrade to Pro") { Task { await model.upgrade() } }
                            .buttonStyle(FilledButtonStyle(fill: PF.violet))
                            .disabled(model.busy)
                    }
                }

                if model.plan == .free {
                    comparison.padding(.top, 20)
                    pricing.padding(.top, 16)
                }

                HStack {
                    Button("Restore purchases") { Task { await model.restorePurchases() } }
                    Spacer()
                }
                .font(PF.body(11))
                .foregroundStyle(PF.inkSoft)
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(PF.body(12)).foregroundStyle(PF.inkMuted)
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardSeparator()
            Text("FREE VS PRO")
                .font(PF.body(11, .semibold)).tracking(0.8).foregroundStyle(PF.inkFaint)
                .padding(.top, 6)
            HStack(spacing: 12) {
                comparisonCell(title: "Free", titleColor: PF.inkSoft,
                               line: "\(ProfileConstants.freeNotebookLimit) notebooks", lineWeight: .medium,
                               sub: "\(ProfileConstants.freeAIQuestions) one-time AI questions", subColor: PF.inkSoft,
                               highlighted: false)
                comparisonCell(title: "Pro", titleColor: PF.violetText,
                               line: "Unlimited notebooks", lineWeight: .semibold,
                               sub: "\(ProfileConstants.proAIQuestionsPerMonth) AI questions / mo", subColor: PF.violetText,
                               highlighted: true)
            }
        }
    }

    private func comparisonCell(title: String, titleColor: Color, line: String, lineWeight: Font.Weight,
                                sub: String, subColor: Color, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PF.body(12, highlighted ? .semibold : .medium)).foregroundStyle(titleColor)
            Text(line).font(PF.body(12, lineWeight))
            Text(sub).font(PF.body(11, highlighted ? .medium : .regular)).foregroundStyle(subColor)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PF.inner, in: RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous)
                .strokeBorder(highlighted ? PF.violet.opacity(0.3) : PF.innerBorder)
        }
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous)
                    .strokeBorder(PF.violet.opacity(0.2), lineWidth: 1).padding(-1)
            }
        }
    }

    private var pricing: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardSeparator()
            HStack {
                HStack(spacing: 2) {
                    ForEach(Billing.allCases, id: \.self) { b in
                        Button { model.billing = b } label: {
                            HStack(spacing: 6) {
                                Text(b.label)
                                if b == .yearly {
                                    Text("Best value")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(PF.violet, in: Capsule())
                                }
                            }
                            .font(PF.body(12, model.billing == b ? .semibold : .medium))
                            .foregroundStyle(model.billing == b ? PF.ink : PF.inkSoft)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background {
                                if model.billing == b {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(PF.inner)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(PF.chip, in: RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous))
                Spacer()
                Text(model.price).font(PF.body(12, .semibold))
                    + Text(" / \(model.priceUnit)").font(PF.body(11)).foregroundColor(PF.inkFaint)
            }
        }
    }

    // MARK: Usage

    private var usageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Usage").font(PF.heading(14))
                usageRow(icon: "book.closed", text: model.notebooksUsage)
                if model.plan == .free {
                    usageRow(icon: "sparkles", text: model.aiTrialUsage, tint: PF.violetText)
                    Text("The free AI questions are a one-time trial and don’t reset.")
                        .font(PF.body(11)).foregroundStyle(PF.inkFaint)
                }
            }
        }
    }

    private func usageRow(icon: String, text: String, tint: Color = PF.inkSoft) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            Text(text).font(PF.body(12)).foregroundStyle(PF.inkMuted)
        }
    }

    // MARK: Notes and codes

    private var freeAINote: some View {
        Card(padding: 16, fill: PF.inner) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(PF.violetText)
                    .frame(width: 28, height: 28)
                    .background(PF.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try \(ProfileConstants.freeAIQuestions) AI Questions for Free").font(PF.body(12, .semibold))
                    Text("Sign in to trigger derivation steps, graph analysis, and handwritten equation checking without entering payment details.")
                        .font(PF.body(12)).foregroundStyle(PF.inkMuted)
                }
            }
        }
    }

    private var promoCard: some View {
        codeCard(title: "Have a gift or promo code?", placeholder: "Enter promo code",
                 text: $model.promoCode) { await model.redeemPromoCode() }
    }

    private func codeCard(title: String, placeholder: String, text: Binding<String>,
                          redeem: @escaping () async -> Void) -> some View {
        Card(padding: 16, fill: PF.inner) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(PF.body(12, .medium)).foregroundStyle(PF.inkMuted)
                codeField(placeholder: placeholder, text: text, redeem: redeem)
            }
        }
    }

    private func codeField(placeholder: String, text: Binding<String>, redeem: @escaping () async -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(PF.body(12))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(PF.inner, in: RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous).strokeBorder(PF.controlBorder))
            Button("Redeem") { Task { await redeem() } }
                .buttonStyle(FilledButtonStyle(fill: PF.control, foreground: PF.ink, border: PF.controlBorder))
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
        }
    }

    // MARK: Referrals

    private var referralCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Referrals").font(PF.heading(14))
                Text("20% off one billing cycle for you and your friend, stacks per referral.")
                    .font(PF.body(12)).foregroundStyle(PF.inkMuted)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your code").font(PF.body(12, .medium)).foregroundStyle(PF.inkMuted)
                    HStack(spacing: 8) {
                        Text(model.referralCode)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PF.inner, in: RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: PF.buttonRadius, style: .continuous).strokeBorder(PF.controlBorder))
                            .textSelection(.enabled)
                        Button { copyCode() } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(FilledButtonStyle(fill: PF.control, foreground: PF.ink, border: PF.controlBorder))
                        ShareLink(item: model.referralShareMessage) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(FilledButtonStyle(fill: PF.violet))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Have a friend’s code?").font(PF.body(12, .medium)).foregroundStyle(PF.inkMuted)
                    codeField(placeholder: "Enter friend’s code", text: $model.friendCode) {
                        await model.redeemFriendCode()
                    }
                }

                CardSeparator()
                HStack {
                    Text("Successful referrals").font(PF.body(12)).foregroundStyle(PF.inkMuted)
                    Spacer()
                    Text("\(model.referralCount)").font(PF.body(12, .semibold))
                }
            }
        }
    }

    @MainActor
    private func copyCode() {
        UIPasteboard.general.string = model.referralCode
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: Delete and links

    private var deleteCard: some View {
        Card {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete account").font(PF.heading(14))
                    Text("Permanently removes your account. This can’t be undone.")
                        .font(PF.body(12)).foregroundStyle(PF.inkSoft)
                }
                Spacer(minLength: 12)
                Button("Delete account") { model.confirmingDelete = true }
                    .buttonStyle(FilledButtonStyle(fill: Color.red.opacity(0.1), foreground: .red,
                                                   border: Color.red.opacity(0.3)))
            }
        }
    }

    private var linksRow: some View {
        HStack(spacing: 16) {
            Link("Privacy policy", destination: ProfileConstants.privacyPolicyURL)
            Link("Terms", destination: ProfileConstants.termsURL)
        }
        .font(PF.body(11))
        .foregroundStyle(PF.inkSoft)
        .frame(maxWidth: .infinity)
    }
}
