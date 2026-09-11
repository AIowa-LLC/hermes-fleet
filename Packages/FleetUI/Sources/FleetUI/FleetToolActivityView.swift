import SwiftUI

/// Expandable, selectable output using only the transcript's actual tool data.
struct FleetToolActivityView: View {
    @Environment(\.fleetTheme) private var theme
    let title: String
    let detail: String?
    @State private var expanded = false
    @State private var previewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled).lineLimit(12)
                    Button("Inspect output", systemImage: "arrow.up.left.and.arrow.down.right") { previewing = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("fleet.conversation.tool.inspect")
                } else {
                    Text("No additional output reported.").font(.caption).foregroundStyle(theme.textSecondary)
                }
            } label: {
                Label(title, systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.medium)).foregroundStyle(theme.textPrimary)
                    .lineLimit(expanded ? nil : 2).frame(minHeight: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $previewing) {
            NavigationStack {
                ScrollView {
                    Text(detail ?? "").font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Tool output").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewing = false } } }
            }
            .presentationDetents([.medium, .large])
            .accessibilityIdentifier("fleet.preview.tool-output")
        }
    }
}
