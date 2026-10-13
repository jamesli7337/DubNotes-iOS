import SwiftUI

/// "Page N paper": template, line spacing, paper colour, and whether the change applies to this page or every
/// page. Nothing is written until Confirm, as on the web.
struct PaperSheet: View {
    let session: NotebookSession
    let page: Page

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Paper
    @State private var allPages = true

    init(session: NotebookSession, page: Page) {
        self.session = session
        self.page = page
        _draft = State(initialValue: page.paper)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Page \(page.index + 1) paper")
                .font(.title3.weight(.semibold))
            field("Template") {
                Picker("Template", selection: $draft.template) {
                    Text("Blank").tag(Paper.Template.blank)
                    Text("Ruled").tag(Paper.Template.ruled)
                    Text("Grid").tag(Paper.Template.grid)
                    Text("Dot").tag(Paper.Template.dot)
                }
            }
            field("Line spacing") {
                Picker("Line spacing", selection: $draft.spacing) {
                    Text("Narrow").tag(Paper.Spacing.narrow)
                    Text("Medium").tag(Paper.Spacing.medium)
                    Text("Wide").tag(Paper.Spacing.wide)
                }
                .disabled(draft.template == .blank) // spacing only means something once there is ruling to space
            }
            field("Paper color") {
                Picker("Paper color", selection: $draft.color) {
                    Text("White").tag(Paper.Color.white)
                    Text("Cream").tag(Paper.Color.cream)
                    Text("Dark").tag(Paper.Color.dark)
                }
            }
            field("Apply to") {
                Picker("Apply to", selection: $allPages) {
                    Text("This page").tag(false)
                    Text("All pages").tag(true)
                }
            }
            Button {
                session.setPaper(page.id, paper: draft, allPages: allPages)
                dismiss()
            } label: {
                Text("Confirm").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(22)
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.visible)
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
            content().pickerStyle(.segmented).labelsHidden()
        }
    }
}
