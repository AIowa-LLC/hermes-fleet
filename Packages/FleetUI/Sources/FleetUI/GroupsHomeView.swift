import SwiftUI
import FleetCore

/// ADR-0010: the Groups tab root — the fleet-wide home for hosted and
/// desktop-legacy rooms, separated from the Chats screen (ordinary
/// conversations only). Rows deep-link by `FleetScreen.room` value like
/// every other room surface; New Group lives here (moved from the Chats
/// floating menu).
struct GroupsHomeView: View {
    @Environment(\.fleetTheme) private var theme
    let environment: AppEnvironment
    @State private var query = ""
    @State private var gatewayID: GatewayID?
    @State private var showingGroupCompose = false

    // MARK: Room lists

    /// Reconciled interactive rooms only (legacy projections are searched
    /// separately in the historical archive). Pure functions of the two room
    /// lists + filters so `body` can compute each list ONCE per render pass.
    private func filteredHosted(_ hosted: [FleetRoom]) -> [FleetRoom] {
        hosted
            .filter { room in
                (gatewayID == nil || room.id.gatewayID == gatewayID)
                    && (query.isEmpty || (room.name + " " + room.members.map(\.name).joined(separator: " ")).localizedCaseInsensitiveContains(query))
            }
            .sorted { $0.canonicalIdentity < $1.canonicalIdentity }
    }

    private func filteredArchive(_ archive: [FleetRoom]) -> [FleetRoom] {
        archive
            .filter { room in
                (gatewayID == nil || room.id.gatewayID == gatewayID)
                    && (query.isEmpty || (room.name + " " + room.members.map(\.name).joined(separator: " ")).localizedCaseInsensitiveContains(query))
            }
            .sorted { $0.id.description < $1.id.description }
    }

    private var hasActiveFilter: Bool {
        !query.isEmpty || gatewayID != nil
    }

    var body: some View {
        // Room-union reads re-ingest + reconcile the whole union on EVERY
        // access (`AppEnvironment.allRooms`/`legacyRoomArchive` derive from a
        // computed `roomUnion`), and the body dereferences them from the
        // empty-state gate, the section gate, and each ForEach — so a single
        // search keystroke ran several full reconciliations. Compute both
        // lists ONCE here and read the locals below.
        let groups = filteredHosted(environment.allRooms)
        let archiveRooms = filteredArchive(environment.legacyRoomArchive)
        List {
            Section {
                Picker("Gateway", selection: $gatewayID) {
                    Text("All gateways").tag(Optional<GatewayID>.none)
                    ForEach(environment.gateways) { gateway in
                        Text(gateway.displayName).tag(Optional(gateway.id))
                    }
                }
                .accessibilityIdentifier("fleet.groups.gateway-filter")
            }
            if groups.isEmpty && archiveRooms.isEmpty {
                Section {
                    ContentUnavailableView(
                        hasActiveFilter ? "No matching groups" : "No groups yet",
                        systemImage: "person.3",
                        description: Text(
                            hasActiveFilter
                                ? "Clear the search or gateway filter to see every group in the fleet."
                                : "Groups you create or join appear here, across every connected gateway."
                        )
                    )
                    .accessibilityIdentifier("fleet.groups.empty")
                }
            } else if !groups.isEmpty {
                Section("Groups") {
                    ForEach(groups, id: \.canonicalIdentity) { room in
                        NavigationLink(value: FleetScreen.room(room.id)) {
                            VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                                RoomRowView(room: room)
                                if environment.roomSyncWarnings[room.canonicalIdentity] != nil {
                                    Label("History sync pending", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption2)
                                        .foregroundStyle(FleetTheme.statusNeedsIntervention)
                                        .padding(.leading, FleetTheme.spacingMd)
                                }
                            }
                        }
                        .accessibilityIdentifier("fleet.groups.row.\(room.canonicalIdentity)")
                    }
                }
            }
            if !archiveRooms.isEmpty {
                Section("Desktop history archive") {
                    Text("Desktop snapshots are preserved here as historical, read-only conversations.")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .listRowSeparator(.hidden)
                    ForEach(archiveRooms, id: \.id) { room in
                        NavigationLink(value: FleetScreen.room(room.id)) {
                            RoomRowView(room: room)
                        }
                        .accessibilityIdentifier("fleet.groups.archive.row.\(room.id.description)")
                    }
                }
            }
        }
        // Surface id rides the List BEFORE overlays attach (the QA-measured
        // rule: a container id applied after .overlay wraps the overlay and
        // replaces every descendant identifier).
        .accessibilityIdentifier("fleet.groups")
        .sheet(isPresented: $showingGroupCompose) {
            CreateRoomSheet(environment: environment) { room in
                environment.requestScreen(.room(room.id))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            floatingNewGroupCluster
                .padding(.trailing, FleetTheme.spacingLg)
                .padding(.bottom, FleetTheme.spacingMd)
        }
        // No bar on scroll: the nav bar keeps NO background at the scroll
        // edge (same treatment as Chats).
        .toolbarBackground(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden).background(theme.background)
        // Reserve bottom breathing room clear of the iOS 26 floating bar
        // (FleetChatsListLayout is the shared design token).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: FleetChatsListLayout.bottomBreathingRoom)
                .accessibilityHidden(true)
        }
        .navigationTitle("Groups")
        .searchable(text: $query, prompt: "Search groups and members")
        .refreshable { await environment.loadRooms() }
        .task { await environment.loadRooms() }
    }

    /// Floating Liquid Glass New Group control (Chats' FAB pattern,
    /// single-action): opens the fleet-wide CreateRoomSheet.
    private var floatingNewGroupCluster: some View {
        Button {
            showingGroupCompose = true
        } label: {
            Image(systemName: "person.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.fleetPressable)
        .background(.ultraThinMaterial)
        .accessibilityLabel("New Group")
        .accessibilityIdentifier("fleet.groups.new")
    }
}
