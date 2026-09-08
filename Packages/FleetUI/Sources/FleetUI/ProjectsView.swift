import SwiftUI
import FleetCore

/// R10-T3 — the remote Projects browser: the gateway's project → repo
/// → lane structure with preview sessions (Nous terminal-minimal skin).
/// Tapping a project drills into fully hydrated lanes
/// (`projects.project_sessions`); tapping a session row opens the
/// conversation via the existing route on the pane's own stack.
///
/// R9 memory-graph UX pattern: offline snapshot prefill, live refresh
/// (pull-to-refresh), honest empty state, thin offline banner when a
/// snapshot survives a live failure.
public struct ProjectsView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let profile: ProfileSlug
    /// R10-T3 round 2 — the tap-through `@file:`/`@folder:` ref path:
    /// the containing project is pre-highlighted and the target path
    /// surfaced in a focus banner (never a silent root landing).
    private let focusPath: String?
    @State private var model: ProjectsBrowserViewModel?
    @State private var drillPath: [ProjectDrillRoute] = []

    public init(environment: AppEnvironment, gatewayID: GatewayID, profile: ProfileSlug, focusPath: String? = nil) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.profile = profile
        self.focusPath = focusPath
    }

    public var body: some View {
        Group {
            if let model {
                browserContent(model)
            } else {
                unavailableContent
            }
        }
        .background(FleetTheme.background)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profileScope) {
            await bindModel()
        }
        .onDisappear {
            Task { model = nil }
        }
    }

    private var profileScope: String { profile.rawValue }

    private func bindModel() async {
        guard let seam = environment.makeProjectsSeam(for: gatewayID) else {
            model = nil
            return
        }
        let next = ProjectsBrowserViewModel(
            gatewayID: gatewayID,
            projects: seam,
            snapshotStore: environment.projectsSnapshotStore)
        model = next
        await next.start(profile: profileScope)
    }

    // MARK: content

    @ViewBuilder
    private func browserContent(_ model: ProjectsBrowserViewModel) -> some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage, model.tree == nil {
                errorContent(error, model: model)
            } else if model.isLoading && model.tree == nil {
                ProgressView("Mapping projects…")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let tree = model.tree, tree.projects.isEmpty {
                emptyContent
            } else {
                treeList(model)
            }
        }
    }

    /// R10-T3 round 2 — the project containing the tap-through
    /// `focusPath` (deep repo-root prefix match, FleetCore). Nil = the
    /// ref doesn't live in any listed project (relative refs, foreign
    /// paths) — then only the banner shows, no fake highlight.
    private var focusedProjectID: String? {
        guard let focusPath, let tree = model?.tree else { return nil }
        return tree.project(containingPath: focusPath)?.id
    }

    private func treeList(_ model: ProjectsBrowserViewModel) -> some View {
        // ScrollView + VStack + plain NavigationLinks — the proven
        // BotDetailView pattern (List rows + custom button styles have
        // swallowed NavigationLink taps on this OS).
        ScrollView {
            VStack(spacing: FleetTheme.spacingSm) {
                if let focusPath {
                    focusBanner(focusPath)
                }
                if let error = model.errorMessage {
                    // Offline-with-snapshot: thin banner, not a pane error.
                    offlineBanner(error, capturedAt: model.offlineCapturedAt, model: model)
                }
                ForEach(model.tree?.projects ?? []) { project in
                    // Destination-initializer link (NOT value-based): the
                    // browser is itself a pushed destination, and a
                    // navigationDestination(for:) registered inside a
                    // pushed view can silently fail to bind on this OS.
                    NavigationLink {
                        ProjectDrillView(
                            environment: environment,
                            gatewayID: gatewayID,
                            projectID: project.id,
                            profile: profileScope)
                    } label: {
                        // FOS-6: operational row (SPEC §18) — projectRow
                        // content without card chrome.
                        projectRow(
                            project,
                            isActiveProject: project.id == model.tree?.activeID,
                            isFocusedProject: project.id == focusedProjectID)
                    }
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("fleet.projects.row.\(project.id)")
                }
            }
            .padding(.horizontal, FleetTheme.spacingMd)
            .padding(.vertical, FleetTheme.spacingSm)
        }
        .refreshable {
            await model.reload(profile: profileScope)
        }
    }

    /// R10-T3 round 2 — tap-through context: the referenced path is
    /// surfaced at the top of the browser (never a silent root landing).
    /// When the containing project is known it is also highlighted; the
    /// banner names it so the highlight is self-explanatory.
    private func focusBanner(_ path: String) -> some View {
        let projectLabel = focusedProjectID.flatMap { id in
            model?.tree?.projects.first(where: { $0.id == id })?.label
        }
        return HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "scope")
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(projectLabel.map { "From transcript — in \($0)" } ?? "From transcript")
                    .font(FleetTheme.monoCaptionFont.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
                Text(path)
                    .font(FleetTheme.monoCaptionFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FleetTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        // Explicit combined label: the visually-truncated path text is
        // not reliably folded into the element's accessibility label.
        .accessibilityLabel(
            (projectLabel.map { "From transcript — in \($0). " } ?? "From transcript. ") + path)
        .accessibilityIdentifier("fleet.projects.focus.banner")
    }

    private func projectRow(
        _ project: ProjectNode,
        isActiveProject: Bool,
        isFocusedProject: Bool = false
    ) -> some View {
        HStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: project.isNoProject
                  ? "tray" : (project.isAuto ? "folder.badge.gearshape" : "folder"))
                .foregroundStyle(FleetTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(FleetTheme.textPrimary)
                    if isFocusedProject {
                        // R10-T3 round 2 — tap-through target badge: the
                        // containing project of the referenced file.
                        Text("referenced")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FleetTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(FleetTheme.accent.opacity(0.15), in: Capsule())
                    }
                    if isActiveProject {
                        Text("active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FleetTheme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(FleetTheme.accent.opacity(0.15), in: Capsule())
                    }
                }
                Text(projectSubtitle(project))
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(project.sessionCount)")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityLabel("\(project.sessionCount) sessions")
        }
        .padding(.vertical, 2)
    }

    private func projectSubtitle(_ project: ProjectNode) -> String {
        if project.isNoProject { return "Sessions outside any project" }
        var parts: [String] = []
        if !project.repos.isEmpty {
            parts.append(project.repos.map(\.label).joined(separator: ", "))
        }
        if let preview = project.previewSessions.first?.title, !preview.isEmpty {
            parts.append(preview)
        }
        return parts.isEmpty ? (project.path ?? "") : parts.joined(separator: " · ")
    }

    private func offlineBanner(_ text: String, capturedAt: Date?, model: ProjectsBrowserViewModel) -> some View {
        Section {
            HStack(spacing: FleetTheme.spacingSm) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.textSecondary)
                    if let capturedAt {
                        Text("Snapshot \(capturedAt, style: .relative) ago")
                            .font(FleetTheme.monoCaptionFont)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                }
                Spacer()
                Button("Retry") {
                    Task { await model.reload(profile: profileScope) }
                }
                .font(FleetTheme.secondaryFont.weight(.semibold))
                .accessibilityIdentifier("fleet.projects.retry")
            }
        }
        .listRowBackground(FleetTheme.surfaceElevated)
        .accessibilityIdentifier("fleet.projects.offline-banner")
    }

    private var emptyContent: some View {
        ContentUnavailableView(
            "No Projects",
            systemImage: "folder",
            description: Text("No sessions grouped into projects on this gateway yet.")
        )
        .accessibilityIdentifier("fleet.projects.empty")
    }

    private func errorContent(_ text: String, model: ProjectsBrowserViewModel) -> some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(FleetTheme.textSecondary)
            Text(text)
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await model.reload(profile: profileScope) }
            }
            .font(.body.weight(.semibold))
            .accessibilityIdentifier("fleet.projects.retry")
        }
        .padding(FleetTheme.spacingLg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableContent: some View {
        VStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.largeTitle)
                .foregroundStyle(FleetTheme.textSecondary)
            Text("Projects unavailable")
                .font(.body.weight(.semibold))
                .foregroundStyle(FleetTheme.textPrimary)
            Text("This gateway has no projects surface configured.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FleetTheme.spacingLg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("fleet.projects.unavailable")
    }
}

/// Drill routes on the browser's own NavigationStack.
public enum ProjectDrillRoute: Hashable, Sendable {
    case project(String)
}

/// R10-T3 — the entered project: fully hydrated repo → lane → session
/// rows (`projects.project_sessions`). Tapping a session opens the
/// conversation via the existing `FleetScreen.conversation` route.
public struct ProjectDrillView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let projectID: String
    private let profile: String?
    @State private var detail: ProjectNode?
    @State private var loadFailed = false

    init(
        environment: AppEnvironment,
        gatewayID: GatewayID,
        projectID: String,
        profile: String?
    ) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.projectID = projectID
        self.profile = profile
    }

    public var body: some View {
        Group {
            if let project = detail {
                projectBody(project)
            } else if loadFailed {
                ContentUnavailableView(
                    "Project Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Could not load this project's sessions from the gateway.")
                )
                .accessibilityIdentifier("fleet.projects.drill.error")
            } else {
                ProgressView("Loading project…")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FleetTheme.background)
        .navigationTitle(detail?.label ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            // Prefilled from the VM's cached drill-in state when
            // available; otherwise load through the VM (which owns the
            // seam + error surface).
            guard detail == nil else { return }
            if let seam = environment.makeProjectsSeam(for: gatewayID) {
                let vm = ProjectsBrowserViewModel(
                    gatewayID: gatewayID, projects: seam, snapshotStore: nil)
                await vm.openProject(id: projectID, profile: profile)
                detail = vm.projectDetail?.project
                loadFailed = vm.projectDetail?.project == nil
            } else {
                loadFailed = true
            }
        }
    }

    @ViewBuilder
    private func projectBody(_ project: ProjectNode) -> some View {
        if project.repos.isEmpty {
            ContentUnavailableView(
                "No Repos",
                systemImage: "folder.badge.questionmark",
                description: Text("This project has no repository structure yet.")
            )
            .accessibilityIdentifier("fleet.projects.drill.empty")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                    ForEach(project.repos) { repo in
                        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                            Text(repo.label)
                                .font(FleetTheme.monoCaptionFont.weight(.semibold))
                                .foregroundStyle(FleetTheme.textSecondary)
                                .padding(.top, FleetTheme.spacingSm)
                            ForEach(repo.groups) { lane in
                                laneRows(lane)
                            }
                        }
                    }
                }
                .padding(.horizontal, FleetTheme.spacingMd)
                .padding(.vertical, FleetTheme.spacingSm)
            }
        }
    }

    /// One lane: a header row (branch identity) + its session rows
    /// directly beneath (flat hierarchy — no collapsed disclosure
    /// hiding the rows the user drilled in for).
    @ViewBuilder
    private func laneRows(_ lane: ProjectLaneNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: lane.isKanban
                  ? "square.grid.3x3"
                  : (lane.isMain ? "arrow.trunk.branch" : "arrow.triangle.branch"))
                .font(.caption)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityHidden(true)
            Text(lane.label)
                .font(FleetTheme.monoCaptionFont.weight(.semibold))
                .foregroundStyle(FleetTheme.textSecondary)
            Spacer()
            Text("\(lane.sessions.count)")
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.textSecondary)
        }
        .accessibilityIdentifier("fleet.projects.lane.\(lane.label)")
        ForEach(lane.sessions) { session in
            sessionRow(session)
        }
    }

    private func sessionRow(_ session: ProjectSessionRow) -> some View {
        // Destination-initializer link (same drill as the project rows —
        // value-based links inside this pushed subtree don't bind).
        let slug = ProfileSlug(rawValue: session.profile)
        let route = (Route(validating: gatewayID, profileSlug: slug)
                     ?? Route(gatewayID: gatewayID, profileSlug: ProfileSlug(rawValue: "default")))
        return NavigationLink {
            ConversationView(environment: environment, route: route, sessionID: session.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title.isEmpty ? session.id : session.title)
                    .font(.body)
                    .foregroundStyle(FleetTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !session.gitBranch.isEmpty {
                        Text(session.gitBranch)
                    }
                    if !session.preview.isEmpty {
                        Text("· " + session.preview)
                    }
                }
                .font(FleetTheme.monoCaptionFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.fleetPressable)
        .accessibilityIdentifier("fleet.projects.session.\(session.id)")
    }
}
