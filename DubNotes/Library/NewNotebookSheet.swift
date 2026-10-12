import SwiftUI

/// "New": type, name, and the starting paper (template, line spacing, colour) — the web's
/// newNotebookDialog, with nothing more. Line spacing is dimmed for a blank template.
struct NewNotebookSheet: View {
    let onCreate: (_ name: String, _ paper: Paper, _ kind: Notebook.Kind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = Notebook.Kind.pages
    @State private var name = ""
    @State private var paper = Paper.default
    @FocusState private var nameFocused: Bool

    private var nameLabel: String { kind == .board ? "Board name" : "Notebook name" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Type", selection: $kind) {
                        Text("Notebook").tag(Notebook.Kind.pages)
                        Text("Board").tag(Notebook.Kind.board)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section(nameLabel) {
                    TextField(nameLabel, text: $name)
                        .focused($nameFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(create)
                }
                Section("Template") {
                    Picker("Template", selection: $paper.template) {
                        Text("Blank").tag(Paper.Template.blank)
                        Text("Ruled").tag(Paper.Template.ruled)
                        Text("Grid").tag(Paper.Template.grid)
                        Text("Dot").tag(Paper.Template.dot)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Line spacing") {
                    Picker("Line spacing", selection: $paper.spacing) {
                        Text("Narrow").tag(Paper.Spacing.narrow)
                        Text("Medium").tag(Paper.Spacing.medium)
                        Text("Wide").tag(Paper.Spacing.wide)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(paper.template == .blank)
                }
                Section("Paper color") {
                    Picker("Paper color", selection: $paper.color) {
                        Text("White").tag(Paper.Color.white)
                        Text("Cream").tag(Paper.Color.cream)
                        Text("Dark").tag(Paper.Color.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create) }
            }
        }
        .interactiveDismissDisabled()
        .onAppear { nameFocused = true }
    }

    private func create() {
        onCreate(name, paper, kind)
        dismiss()
    }
}
