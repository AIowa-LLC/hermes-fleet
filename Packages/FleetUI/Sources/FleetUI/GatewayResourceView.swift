import SwiftUI
import FleetCore

/// FOS-2 — the profile-scoped wrapper beneath Gateway Detail for the
/// profile-owned resource panes (Schedules / Skills / Memory / Projects).
///
/// SPEC §8 scope selection rule: entry from Bot Detail carries the Route's
/// profile; entry from Gateway Detail resolves through
/// `GatewayProfileSelectionPolicy` — a valid previous explicit choice is
/// reused, a single valid profile preselects VISIBLY, several profiles
/// require explicit selection, and nothing ever silently falls back to the
/// first profile or `default`.
struct GatewayResourceView: View {
    let environment: AppEnvironment
    let gatewayID: GatewayID
    let screen: FleetScreen
    let focusPath: String?
    let onSelection: (ProfileSlug) -> Void
    @State private var selected: ProfileSlug?
    @State private var autoResolvedKey = ""

    init(environment: AppEnvironment, gatewayID: GatewayID, screen: FleetScreen, profile: ProfileSlug?, focusPath: String? = nil, onSelection: @escaping (ProfileSlug) -> Void) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.screen = screen
        self.focusPath = focusPath
        self.onSelection = onSelection
        _selected = State(initialValue: profile)
    }

    private var candidates: [GatewayProfileSelectionPolicy.Candidate] {
        let bots: [FleetBot]
        if case .loaded = environment.rosterSnapshot?.outcome(for: gatewayID) {
            bots = environment.bots(on: gatewayID)
        } else {
            bots = environment.cachedBotsByGateway[gatewayID] ?? []
        }
        return bots
            .filter { $0.route.isRoutingSafe }
            .map { GatewayProfileSelectionPolicy.Candidate(profileSlug: $0.route.profileSlug, botName: $0.displayName) }
    }

    private var storageKey: String {
        "fleet.explicit-profile.v1.\(gatewayID.rawValue).\(Self.paneKey(screen))"
    }

    static func paneKey(_ screen: FleetScreen) -> String {
        switch screen {
        case .cron: return "cron"
        case .skills: return "skills"
        case .memoryGraph: return "memory"
        case .projects: return "projects"
        default: return "other"
        }
    }

    /// Storage-key prefix for persisted explicit profile selections.
    static let selectionKeyPrefix = "fleet.explicit-profile.v1."

    /// UI-test hygiene (HERMES_FLEET_NAV_RESET): drop every persisted
    /// explicit profile selection so the §8 chooser renders deterministically.
    static func resetStoredSelections() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(selectionKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private var storedSelection: ProfileSlug? {
        UserDefaults.standard.string(forKey: storageKey).map(ProfileSlug.init(rawValue:))
    }

    private var resolution: GatewayProfileSelectionPolicy.Resolution {
        GatewayProfileSelectionPolicy().resolve(candidates: candidates, storedSelection: storedSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let selected, candidates.contains(where: { $0.profileSlug == selected }) {
                scopeBar(selected: selected)
                Divider()
                content(selected).id(Route(gatewayID: gatewayID, profileSlug: selected))
            } else if selected != nil {
                ContentUnavailableView(
                    "Profile unavailable",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("The selected profile is no longer available. Choose another profile explicitly to continue.")
                )
            } else {
                chooser
            }
        }
        .background(autoResolver)
    }

    /// Auto-resolution (stored choice still valid, or exactly one candidate)
    /// applied without a user gesture. Re-runs whenever the candidate set
    /// changes (roster refresh). A single-candidate auto pick is NOT
    /// persisted as an explicit user choice — if a second profile appears
    /// later, selection is required again. A reused stored choice re-emits
    /// `onSelection` so the route gains its explicit scope.
    private var autoResolver: some View {
        Color.clear
            .frame(height: 0)
            .task(id: candidates.map(\.profileSlug.rawValue).joined(separator: ",")) {
                resolveAutomaticallyIfNeeded()
            }
    }

    // MARK: Scope bar (always visible once a profile is active — SPEC §8:
    // "single valid profile may preselect but VISIBLY labeled")

    private func scopeBar(selected: ProfileSlug) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.gateway(for: gatewayID)?.displayName ?? gatewayID.rawValue)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Profile: \(selected.rawValue)")
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("fleet.scope.profileName.\(gatewayID.rawValue)")
            }
            Spacer()
            if candidates.count > 1 {
                Menu {
                    ForEach(candidates) { candidate in
                        Button("\(candidate.botName) · \(candidate.profileSlug.rawValue)") {
                            choose(candidate.profileSlug)
                        }
                        .accessibilityIdentifier("fleet.scope.option.\(gatewayID.rawValue)#\(candidate.profileSlug.rawValue)")
                    }
                } label: {
                    Text("Change")
                }
                .accessibilityIdentifier("fleet.scope.change.\(gatewayID.rawValue)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fleet.scope.bar.\(gatewayID.rawValue)")
    }

    // MARK: Chooser (no valid selection yet — explicit choice required)

    private var chooser: some View {
        Group {
            switch resolution {
            case .reuseStored, .singleCandidate, .selectionRequired:
                // All candidate-present states render the explicit chooser
                // list; auto-resolution (when admissible) happens via
                // `autoResolver` and swaps in the scoped content.
                List(candidates) { candidate in
                    Button {
                        choose(candidate.profileSlug)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.botName)
                            Text("Profile: \(candidate.profileSlug.rawValue)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("fleet.scope.option.\(gatewayID.rawValue)#\(candidate.profileSlug.rawValue)")
                }
                .overlay {
                    if candidates.isEmpty {
                        profilesUnavailable
                    }
                }
                .navigationTitle("Choose profile")
            case .unavailable:
                profilesUnavailable
            }
        }
    }

    private var profilesUnavailable: some View {
        ContentUnavailableView(
            "Profiles unavailable",
            systemImage: "person.crop.circle",
            description: Text("Refresh this gateway's Bots to discover valid profiles.")
        )
    }

    private func resolveAutomaticallyIfNeeded() {
        let key = candidates.map(\.profileSlug.rawValue).joined(separator: ",")
        guard autoResolvedKey != key, selected == nil else { return }
        autoResolvedKey = key
        switch resolution {
        case .reuseStored(let profile):
            selected = profile
            onSelection(profile)
        case .singleCandidate(let profile):
            // Visible via the scope bar, but not persisted as an explicit
            // user choice (see autoResolver doc).
            selected = profile
            onSelection(profile)
        case .selectionRequired, .unavailable:
            break // explicit choice required — no fallback
        }
    }

    private func choose(_ profile: ProfileSlug) {
        selected = profile
        UserDefaults.standard.set(profile.rawValue, forKey: storageKey)
        onSelection(profile)
    }

    @ViewBuilder private func content(_ profile: ProfileSlug) -> some View {
        switch screen {
        case .cron:
            CronView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .skills:
            SkillsView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .memoryGraph:
            MemoryGraphView(environment: environment, gatewayID: gatewayID, profile: profile)
        case .projects:
            ProjectsView(environment: environment, gatewayID: gatewayID, profile: profile, focusPath: focusPath)
        default:
            EmptyView()
        }
    }
}
