import SwiftUI
import FleetCore

/// R9-T7 — the read-only Memory Graph star map (Nous terminal-minimal,
/// Direction A): a SwiftUI Canvas constellation of learned skills (●) and
/// memories (◆) on the near-black canvas, pale-cyan accent ONLY on
/// interactive/memory ink, pan + zoom gestures, All/Skills/Memories filter,
/// and a timeline scrubber that reveals the journey oldest → newest.
/// Read-only for R9 — no edit/delete affordances.
public struct MemoryGraphView: View {
    @Environment(\.fleetTheme) private var theme
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let profile: ProfileSlug
    @State private var model: MemoryGraphViewModel?
    /// FOS-8 (SPEC §16): the accessible LIST alternative to the graph —
    /// equivalent filters and node actions, no pan/pinch/tap-gesture
    /// dependence. Persists for the screen lifetime; defaults to graph.
    @State private var presentation: MemoryPresentation = .graph

    public enum MemoryPresentation: String, CaseIterable, Identifiable {
        case graph
        case list
        public var id: String { rawValue }
        public var title: String { self == .graph ? "Graph" : "List" }
    }

    public init(environment: AppEnvironment, gatewayID: GatewayID, profile: ProfileSlug) {
        self.environment = environment
        self.gatewayID = gatewayID
        self.profile = profile
    }

    public var body: some View {
        Group {
            if let model {
                graphContent(model)
            } else {
                unavailableContent
            }
        }
        .background(theme.background)
        .navigationTitle("Memory Graph")
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
        guard let seam = environment.makeLearningSeam(for: gatewayID) else {
            model = nil
            return
        }
        let next = MemoryGraphViewModel(
            gatewayID: gatewayID,
            learning: seam,
            snapshotStore: environment.learningSnapshotStore)
        model = next
        await next.start(profile: profileScope)
    }

    // MARK: content

    @ViewBuilder
    private func graphContent(_ model: MemoryGraphViewModel) -> some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage, model.graph == nil {
                errorContent(error, model: model)
            } else if model.isLoading && model.graph == nil {
                ProgressView("Mapping learning…")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph = model.graph, graph.summary.totalCount == 0,
                      graph.buckets.isEmpty {
                emptyContent
            } else {
                starMap(model)
            }
        }
        .sheet(item: detailBinding(model)) { box in
            if let detail = box.detail {
                LearningNodeDetailSheet(
                    detail: detail,
                    model: model,
                    profile: profileScope)
            } else if let errorText = box.errorText {
                LearningNodeDetailErrorSheet(errorText: errorText)
            }
        }
    }

    private func detailBinding(_ model: MemoryGraphViewModel) -> Binding<LearningDetailBox?> {
        Binding(
            get: {
                if let detail = model.detail {
                    return LearningDetailBox(detail: detail)
                }
                if let errorText = model.detailError {
                    return LearningDetailBox(errorText: errorText)
                }
                return nil
            },
            set: { _ in model.dismissDetail() }
        )
    }

    private func starMap(_ model: MemoryGraphViewModel) -> some View {
        VStack(spacing: FleetTheme.spacingSm) {
            if let error = model.errorMessage {
                // Offline-with-snapshot: the failure is surfaced as a thin
                // banner, not a pane error.
                offlineBanner(error, capturedAt: model.offlineCapturedAt, model: model)
            }
            mutationBanner(model)
            summaryHeader(model)
            // FOS-8: Graph ⇄ List — the accessible list alternative carries
            // the SAME filters and node actions (SPEC §16).
            presentationPicker
            filterChips(model)
            if presentation == .list {
                nodeList(model)
            } else {
                MemoryGraphCanvas(model: model) { nodeID in
                    Task { await model.loadDetail(for: nodeID) }
                }
                .frame(maxHeight: .infinity)
            }
            scrubber(model)
        }
        .padding(FleetTheme.spacingMd)
        .refreshable {
            await model.reload(profile: profileScope)
        }
    }

    /// Chronological groups for the list alternative: the layout's spiral
    /// walk is chronological; consecutive nodes sharing a bucket date label
    /// group together. The label comes from each node's `meta` date segment
    /// (fixture and live payloads both carry "kind · date · xN"); nodes
    /// whose meta lacks a date fall into the previous group.
    private func nodeGroups(_ layout: MemoryStarLayout) -> [(label: String, nodes: [MemoryStarLayout.PlacedNode])] {
        var out: [(String, [MemoryStarLayout.PlacedNode])] = []
        for placed in layout.orderedNodes {
            let segs = placed.node.meta.components(separatedBy: " · ")
            let label = segs.count >= 2 ? segs[1] : (out.last?.0 ?? "Learning")
            if let last = out.last, last.0 == label {
                out[out.count - 1].1.append(placed)
            } else {
                out.append((label, [placed]))
            }
        }
        return out.map { (label: $0.0, nodes: $0.1) }
    }

    /// Graph ⇄ List presentation switch. Scoped identifier (NOT a bare
    /// "List" match — see FOS-5 lesson on segmented-control queries).
    private var presentationPicker: some View {
        Picker("Presentation", selection: $presentation) {
            ForEach(MemoryPresentation.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("memorygraph.presentation")
    }

    /// The accessible LIST alternative (FOS-8, SPEC §16): the same
    /// filtered/reveal-windowed node set as the canvas (single source of
    /// truth: MemoryStarLayout.orderedNodes), grouped by chronological
    /// bucket, each row opening the SAME detail sheet (equivalent edit and
    /// delete node actions without gesture dependence).
    private func nodeList(_ model: MemoryGraphViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FleetTheme.spacingSm) {
                if let layout = model.layout {
                    ForEach(nodeGroups(layout), id: \.label) { group in
                        VStack(alignment: .leading, spacing: FleetTheme.spacingXs) {
                            Text(group.label)
                                .font(FleetTheme.sectionHeaderFont)
                                .foregroundStyle(theme.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.nodes) { placed in
                                Button {
                                    Task { await model.loadDetail(for: placed.id) }
                                } label: {
                                    HStack(spacing: FleetTheme.spacingSm) {
                                        Image(systemName: placed.isMemory ? "diamond" : "circle")
                                            .font(.caption)
                                            .foregroundStyle(placed.isMemory ? theme.highlight : theme.textSecondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(placed.node.label)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            Text(placed.node.meta)
                                                .font(FleetTheme.monoCaptionFont)
                                                .foregroundStyle(theme.textSecondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(theme.textSecondary)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.vertical, FleetTheme.spacingSm)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.fleetPressable)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("memorygraph.list.row.\(placed.id)")
                            }
                        }
                    }
                    if layout.orderedNodes.isEmpty {
                        Text("No nodes in this filter.")
                            .font(FleetTheme.secondaryFont)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.vertical, FleetTheme.spacingLg)
                    }
                }
            }
            .padding(.horizontal, FleetTheme.spacingSm)
        }
        .accessibilityIdentifier("memorygraph.list")
    }

    /// R10-T5 — outcome of the last edit/delete: the gateway's message
    /// (success "updated …" or a verbatim refusal naming the remedy).
    private func mutationBanner(_ model: MemoryGraphViewModel) -> some View {
        Group {
            if model.mutationInFlight {
                ProgressView()
                    .controlSize(.small)
            } else if let message = model.mutationMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.highlight)
                    .lineLimit(3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("memorygraph.mutation-banner")
            } else if let refusal = model.mutationError {
                HStack(spacing: FleetTheme.spacingSm) {
                    Text(refusal)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDestructive)
                        .lineLimit(4)
                        .accessibilityIdentifier("memorygraph.mutation-banner.text")
                    Spacer()
                    Button("Dismiss") { model.clearMutationFeedback() }
                        .font(FleetTheme.secondaryFont.weight(.semibold))
                        .foregroundStyle(theme.highlight)
                        .buttonStyle(.fleetPressable)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("memorygraph.mutation-banner")
    }

    private func summaryHeader(_ model: MemoryGraphViewModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let layout = model.layout, let cap = layout.capLabel {
                Text(cap)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityIdentifier("memorygraph.cap-label")
            }
            ForEach(model.graph?.summary.lines ?? [], id: \.self) { line in
                Text(line)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textSecondary)
            }
            if model.source == .offlineSnapshot, let captured = model.offlineCapturedAt {
                Text("offline snapshot · \(captured.formatted(date: .abbreviated, time: .shortened))")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(theme.textMuted)
                    .accessibilityIdentifier("memorygraph.offline-stamp")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memorygraph.summary")
    }

    private func filterChips(_ model: MemoryGraphViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            ForEach(MemoryGraphFilter.allCases) { filter in
                Button {
                    model.filter = filter
                } label: {
                    Text(filter.title)
                        .font(FleetTheme.secondaryFont.weight(.semibold))
                        .foregroundStyle(
                            model.filter == filter ? theme.background : theme.textSecondary)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                model.filter == filter ? theme.highlight : theme.highlight.opacity(0.08)))
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("memorygraph.filter.\(filter.rawValue)")
            }
            Spacer()
            Text("● skills   ◆ memories")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textMuted)
                .accessibilityHidden(true)
        }
    }

    private func scrubber(_ model: MemoryGraphViewModel) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(model.graph?.summary.start ?? "oldest")
                Spacer()
                Text(model.graph?.summary.end ?? "now")
            }
            .font(FleetTheme.secondaryFont)
            .foregroundStyle(theme.textMuted)
            .accessibilityHidden(true)
            Slider(value: Binding(
                get: { model.reveal },
                set: { model.setReveal($0) }
            ), in: 0...1)
            .tint(theme.highlight)
            .accessibilityLabel("Timeline reveal")
            .accessibilityIdentifier("memorygraph.scrubber")
        }
    }

    private func offlineBanner(_ text: String, capturedAt: Date?, model: MemoryGraphViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "wifi.slash")
                .font(.caption)
                .foregroundStyle(FleetTheme.statusDestructive)
                .accessibilityHidden(true)
            Text("Offline — showing the last captured map. \(text)")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.statusDestructive)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                Task { await model.reload(profile: profileScope) }
            }
            .font(FleetTheme.secondaryFont.weight(.semibold))
            .foregroundStyle(theme.highlight)
            .buttonStyle(.fleetPressable)
            .accessibilityIdentifier("memorygraph.retry")
        }
        .padding(.horizontal, FleetTheme.spacingMd)
    }

    private var emptyContent: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Text("No learning yet — keep using Hermes and it maps out here.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FleetTheme.spacingXl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memorygraph.empty")
    }

    private func errorContent(_ error: String, model: MemoryGraphViewModel) -> some View {
        // FOS-6: contextual error notice with bounded Retry (SPEC §18).
        FleetNoticeBar(
            error,
            systemImage: "exclamationmark.triangle.fill",
            tone: .error,
            id: "memorygraph.error",
            actionTitle: "Retry",
            actionID: "memorygraph.error.retry",
            action: { Task { await model.reload(profile: profileScope) } }
        )
        .padding(FleetTheme.spacingLg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableContent: some View {
        ContentUnavailableView {
            Label("Memory Graph Unavailable", systemImage: "sparkles")
        } description: {
            Text("This gateway has no learning session wired. Reconnect and try again.")
        }
        .accessibilityIdentifier("memorygraph.unavailable")
    }
}

// MARK: - Canvas

/// The pan/zoom constellation canvas. Nodes render as ● (skill, muted
/// gray-blue) / ◆ (memory, pale-cyan accent — memories are the drillable
/// ink, matching the desktop palette roles); brightness rides the
/// age-gradient ink. Taps hit-test in unit space (size-independent).
struct MemoryGraphCanvas: View {
    @Environment(\.fleetTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let model: MemoryGraphViewModel
    let onTapNode: (String) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var pinchScale: CGFloat = 1.0
    @State private var lastPinch: CGFloat = 1.0
    @State private var canvasSize: CGSize = .zero

    /// Node render radius (points) at scale 1.
    private let nodeRadius: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard let layout = model.layout else { return }
                let side = min(size.width, size.height) * pinchScale
                let originX = (size.width - side) / 2 + dragOffset.width
                let originY = (size.height - side) / 2 + dragOffset.height

                for placed in layout.orderedNodes {
                    let point = CGPoint(
                        x: originX + placed.x * side,
                        y: originY + placed.y * side)
                    let alpha = contrast == .increased ? 1.0 : 0.55 + 0.45 * placed.ink
                    let color = placed.isMemory
                        ? theme.highlight.opacity(alpha)
                        : theme.textSecondary.opacity(alpha)
                    if placed.isMemory && !reduceTransparency && contrast != .increased {
                        let halo = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
                        context.fill(Path(ellipseIn: halo), with: .radialGradient(
                            Gradient(colors: [theme.highlight.opacity(0.2), .clear]),
                            center: point, startRadius: 2, endRadius: 12))
                    }
                    if placed.isMemory {
                        // ◆ diamond (memory — drillable ink).
                        var path = Path()
                        path.move(to: CGPoint(x: point.x, y: point.y - nodeRadius))
                        path.addLine(to: CGPoint(x: point.x + nodeRadius, y: point.y))
                        path.addLine(to: CGPoint(x: point.x, y: point.y + nodeRadius))
                        path.addLine(to: CGPoint(x: point.x - nodeRadius, y: point.y))
                        path.closeSubpath()
                        context.fill(path, with: .color(color))
                    } else {
                        // ● circle (skill).
                        let rect = CGRect(
                            x: point.x - nodeRadius, y: point.y - nodeRadius,
                            width: nodeRadius * 2, height: nodeRadius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture.simultaneously(with: magnificationGesture))
            .onTapGesture { location in
                guard let layout = model.layout, canvasSize != .zero else { return }
                let side = min(canvasSize.width, canvasSize.height) * pinchScale
                let originX = (canvasSize.width - side) / 2 + dragOffset.width
                let originY = (canvasSize.height - side) / 2 + dragOffset.height
                // Nearest node within a generous touch radius (points).
                let hitRadius: CGFloat = 28
                var best: (id: String, distance: CGFloat)?
                for placed in layout.orderedNodes {
                    let point = CGPoint(
                        x: originX + placed.x * side,
                        y: originY + placed.y * side)
                    let dx = point.x - location.x
                    let dy = point.y - location.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance <= hitRadius && (best == nil || distance < best!.distance) {
                        best = (placed.id, distance)
                    }
                }
                if let best {
                    onTapNode(best.id)
                }
            }
            .task {
                // Set outside the render pass (mutating @State inside
                // Canvas's closure is "state modification during view
                // update").
                canvasSize = proxy.size
            }
            .onChange(of: proxy.size) { _, newSize in
                canvasSize = newSize
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Learning constellation, \(model.layout?.orderedNodes.count ?? 0) nodes. Drag to pan, pinch to zoom, tap a diamond for memory content.")
        .accessibilityIdentifier("memorygraph.canvas")
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { _ in
                // Keep the pan (free exploration); a double-tap resets below.
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Anchored incremental scaling: multiply the scale delta
                // since the last callback, clamped 1…4.
                let delta = value / lastPinch
                lastPinch = value
                pinchScale = min(max(pinchScale * delta, 1.0), 4.0)
            }
            .onEnded { _ in
                lastPinch = 1.0
            }
    }
}

/// Sheet identity wrapper (LearningNodeDetail is not Identifiable).
struct LearningDetailBox: Identifiable {
    let detail: LearningNodeDetail?
    let errorText: String?

    var id: String {
        detail?.id ?? "error-\(errorText ?? "")"
    }

    init(detail: LearningNodeDetail) {
        self.detail = detail
        self.errorText = nil
    }

    init(errorText: String) {
        self.detail = nil
        self.errorText = errorText
    }
}

/// Read-only node drill-in error (detail fetch failed).
struct LearningNodeDetailErrorSheet: View {
    @Environment(\.fleetTheme) private var theme
    let errorText: String

    var body: some View {
        NavigationStack {
            VStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(FleetTheme.statusDestructive)
                Text(errorText)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .multilineTextAlignment(.center)
            }
            .padding(FleetTheme.spacingXl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
            .navigationTitle("Node")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Node drill-in: full SKILL.md or memory chunk (learning.detail) with
/// R10-T5 edit (learning.edit) and delete (learning.delete) affordances.
struct LearningNodeDetailSheet: View {
    @Environment(\.fleetTheme) private var theme
    let detail: LearningNodeDetail
    // @Observable model — plain reference; body tracks reads automatically.
    let model: MemoryGraphViewModel
    let profile: String?

    @State private var isEditing = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    editorContent
                } else {
                    readContent
                }
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Node" : "Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Cancel") {
                            isEditing = false
                            draft = ""
                        }
                        .accessibilityIdentifier("memorygraph.detail.edit.cancel")
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") {
                            let content = draft
                            Task {
                                await model.performEdit(
                                    nodeID: detail.id, content: content, profile: profile)
                                if model.mutationError == nil {
                                    UIAccessibility.post(
                                        notification: .announcement,
                                        argument: "Saved \(detail.label).")
                                    isEditing = false
                                    draft = ""
                                    dismiss()
                                }
                                // Refusal: stay in the editor — the inline
                                // error carries the gateway's remedy.
                            }
                        }
                        .font(.body.weight(.semibold))
                        .disabled(model.mutationInFlight)
                        .accessibilityIdentifier("memorygraph.detail.edit.save")
                    } else {
                        menu
                    }
                }
            }
            .alert("Delete this node?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.performDelete(nodeID: detail.id, profile: profile)
                        if model.mutationError == nil {
                            // FOS-8 (SPEC §16 Focus): concise result
                            // announcement after finishing an item.
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "Deleted \(detail.label).")
                            dismiss()
                        }
                    }
                }
                .accessibilityIdentifier("memorygraph.detail.delete.confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                if detail.kind == "skill" {
                    Text("The skill is archived (restorable with `hermes curator restore`).")
                } else {
                    Text("The memory chunk is removed from its file.")
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button {
                draft = detail.content
                isEditing = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("memorygraph.detail.edit")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("memorygraph.detail.delete")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("memorygraph.detail.menu")
    }

    private var readContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FleetTheme.spacingMd) {
                HStack(spacing: FleetTheme.spacingSm) {
                    Image(systemName: detail.kind == "memory" ? "diamond" : "circle")
                        .font(.caption)
                        .foregroundStyle(theme.highlight)
                        .accessibilityHidden(true)
                    Text(detail.kind)
                        .font(FleetTheme.sectionHeaderFont)
                        .foregroundStyle(theme.textSecondary)
                }
                Text(detail.label)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityIdentifier("memorygraph.detail.label")
                Text(detail.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("memorygraph.detail.content")
            }
            .padding(FleetTheme.spacingLg)
        }
    }

    private var editorContent: some View {
        VStack(spacing: FleetTheme.spacingSm) {
            Text("Content")
                .font(FleetTheme.sectionHeaderFont)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let refusal = model.mutationError {
                // Verbatim gateway refusal (names the remedy) — inline in
                // the editor so the user can fix the content and retry.
                // FOS-8 (SPEC §16 Focus): on failed Save the first error
                // summary TAKES FOCUS; the draft is preserved untouched.
                Text(refusal)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDestructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("memorygraph.detail.edit.refusal")
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear {
                        UIAccessibility.post(
                            notification: .layoutChanged,
                            argument: "Save failed. \(refusal)")
                    }
            }
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.highlight.opacity(0.4), lineWidth: 1))
                .accessibilityIdentifier("memorygraph.detail.edit.field")
        }
        .padding(FleetTheme.spacingLg)
    }
}
