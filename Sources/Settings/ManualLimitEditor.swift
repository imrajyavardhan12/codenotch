import SwiftUI

/// Add/edit sheet for one declared limit. Owned by `SettingsView`, which
/// presents it and writes the result back to `Preferences`.
///
/// Validation lives on `ManualLimit.validate` (tested), so this is layout and
/// wiring only: going over budget stays allowed (that is the event worth
/// seeing), while the meaningless — no name, no allowance, negative use —
/// disables Save with the reason beside it rather than failing after the fact.
struct ManualLimitEditor: View {
    /// Nil when adding. Editing preserves the window anchor, so renaming does
    /// not restart the cycle — unless the period itself changed, which the old
    /// anchor cannot describe.
    let initial: ManualLimit?
    let onSave: (ManualLimit) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var limit: Int
    @State private var used: Int
    @State private var period: ManualLimit.Period

    init(initial: ManualLimit?, onSave: @escaping (ManualLimit) -> Void,
         onCancel: @escaping () -> Void) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial?.name ?? "")
        _limit = State(initialValue: initial?.limit ?? 100)
        _used = State(initialValue: initial?.used ?? 0)
        _period = State(initialValue: initial?.period ?? .week)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Copilot quota"))
            TextField("Limit", value: $limit, format: .number)
                .help("The allowance per period, in whatever the tool counts.")
            TextField("Used so far", value: $used, format: .number)
                .help("Spent in the current window. Past the limit on purpose: going over is the event worth seeing.")
            Picker("Resets every", selection: $period) {
                ForEach(ManualLimit.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if let problem = ManualLimit.validate(name: name, limit: limit, used: used) {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Add limit" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ManualLimit.validate(name: name, limit: limit, used: used) != nil)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 340)
    }

    private func save() {
        let anchor: Date
        if let initial, initial.period == period {
            anchor = initial.windowStartedAt
        } else {
            // New, or the period changed: the old anchor cannot describe this
            // cycle, so the window starts now.
            anchor = Date()
        }
        onSave(ManualLimit(id: initial?.id ?? UUID().uuidString,
                           name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           limit: limit, used: used, period: period,
                           windowStartedAt: anchor))
    }
}
