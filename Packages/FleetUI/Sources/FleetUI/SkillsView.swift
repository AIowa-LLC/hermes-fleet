import SwiftUI
import FleetCore

/// R9-T6 — the per-gateway Skills pane (Gold Fleet design).
///
/// Rows grouped by category with per-skill enable/disable toggles. The
/// toggle is PROFILE CONFIG, not a skills-manage action (0.21.0's
/// `skills.manage` has no toggle — methods_tools.py:1897-1959); it rides
/// `profiles.configure disabled_skills` with replace semantics, verified
/// by a fresh describe. Install-from-hub is deferred (YAGNI).
public struct SkillsView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    @State private var model: ManagementPanesViewModel?
    @State private var query = ""

    public init(environment: AppEnvironment, gatewayID: GatewayID) {
        self.environment = environment
        self.gatewayID = gatewayID
    }

    public var body: some View {
        Group {
            if let model {
                skillsContent(model)
            } else {
                unavailableContent
            }
        }
        .background(FleetTheme.background)
        .navigationTitle("Skills")
        .searchable(text: $query, prompt: "Find a capability")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profileScope) {
            await bindModel()
        }
        .onDisappear {
            Task { model = nil }
        }
    }

    private var profileScope: String {
        let profiles = environment.rosterSnapshot?.roster.bots(on: gatewayID) ?? []
        return profiles.map { $0.route.profileSlug.rawValue }.first ?? "default"
    }

    private func bindModel() async {
        guard let seam = environment.makeManagementSeam(for: gatewayID) else {
            model = nil
            return
        }
        let next = ManagementPanesViewModel(gatewayID: gatewayID, management: seam)
        model = next
        await next.start(profile: profileScope)
    }

    // MARK: content

    @ViewBuilder
    private func skillsContent(_ model: ManagementPanesViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                if model.isLoading && model.skillsRows.isEmpty {
                    ProgressView("Loading skills…")
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(FleetTheme.spacingXl)
                } else if let error = model.errorMessage, model.skillsRows.isEmpty {
                    errorContent(error, model: model)
                } else if model.skillsRows.isEmpty {
                    emptyContent
                } else {
                    if let error = model.errorMessage {
                        // A toggle failure must not blank the loaded list.
                        errorCard(error)
                    }
                    ForEach(groupedRows, id: \.category) { group in
                        VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                            Text(group.category.uppercased())
                                .font(FleetTheme.sectionHeaderFont)
                                .tracking(FleetTheme.microLabelTracking)
                                .foregroundStyle(FleetTheme.textSecondary)
                                .padding(.top, FleetTheme.spacingSm)
                            ForEach(group.rows) { skill in
                                skillRow(skill, model: model)
                            }
                        }
                    }
                }
            }
            .padding(FleetTheme.spacingLg)
        }
        .refreshable {
            await model.refresh(profile: profileScope)
        }
    }

    private func skillRow(_ skill: ProfileSkill, model: ManagementPanesViewModel) -> some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(FleetTheme.textMuted)
                    .accessibilityHidden(true)
                Text(skill.name)
                    .font(.system(.body, design: .monospaced).weight(.regular))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Row identity rides the name text (a container-level
                    // identifier would override the toggle's id).
                    .accessibilityIdentifier("skills.row.\(skill.name)")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skill.isEnabled },
                    set: { next in
                        Task { await model.setSkill(skill.name, enabled: next, profile: profileScope) }
                    }
                ))
                .labelsHidden()
                .tint(FleetTheme.statusOnline)
                .disabled(model.pendingSkills.contains(skill.name.lowercased()))
                // Rebuild the switch when the resolved state changes — the
                // closure binding captures the row struct, so without a
                // fresh identity the UISwitch's on-state can go stale
                // after the async toggle settles.
                .id("skills.toggle.\(skill.name).\(skill.isEnabled)")
                .accessibilityLabel("Enable \(skill.name)")
                .accessibilityIdentifier("skills.row.toggle.\(skill.name)")
            }
        }
        // NOTE: NO container identifier or .combine — a container's
        // identifier propagates and replaces the toggle's id. Row identity
        // rides the skill-name text.
    }

    private var groupedRows: [(category: String, rows: [ProfileSkill])] {
        // Rows arrive category-ordered from the catalog; regroup from the
        // VM rows is unnecessary — but the roster-scoped VM keeps the flat
        // rows, so group by the catalog's category pass via the VM order.
        // Simplest stable grouping: keep insertion order.
        (model?.categoryGroups ?? []).compactMap { group in
            let rows = group.rows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || group.category.localizedCaseInsensitiveContains(query) }
            return rows.isEmpty ? nil : (category: group.category, rows: rows)
        }
    }

    private func errorCard(_ text: String) -> some View {
        FleetCard {
            Label {
                Text(text)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDegraded)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(FleetTheme.statusDegraded)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills.error-card")
    }

    private var emptyContent: some View {
        FleetCard {
            HStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityHidden(true)
                Text("No skills reported for this profile.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills.empty")
    }

    private func errorContent(_ error: String, model: ManagementPanesViewModel) -> some View {
        FleetCard {
            VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                Label {
                    Text(error)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(FleetTheme.statusDegraded)
                }
                Button("Retry") {
                    Task { await model.refresh(profile: profileScope) }
                }
                .font(FleetTheme.secondaryFont.weight(.semibold))
                .foregroundStyle(FleetTheme.accent)
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("skills.retry")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skills.error")
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("Skills Unavailable", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("This gateway has no management session wired. Reconnect and try again.")
        }
        .accessibilityIdentifier("skills.unavailable")
    }
}
