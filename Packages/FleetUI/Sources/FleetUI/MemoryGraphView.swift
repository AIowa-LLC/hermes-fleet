import SwiftUI
import FleetCore

/// R9-T7 — the read-only Memory Graph star map (Nous terminal-minimal,
/// Direction A): a SwiftUI Canvas constellation of learned skills (●) and
/// memories (◆) on the near-black canvas, pale-cyan accent ONLY on
/// interactive/memory ink, pan + zoom gestures, All/Skills/Memories filter,
/// and a timeline scrubber that reveals the journey oldest → newest.
/// Read-only for R9 — no edit/delete affordances.
public struct MemoryGraphView: View {
    private let environment: AppEnvironment
    private let gatewayID: GatewayID
    private let profile: ProfileSlug
    @State private var model: MemoryGraphViewModel?

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
        .background(FleetTheme.background)
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
            snapshotStore: nil) // Legacy gateway-only cache is unsafe for an explicitly scoped route.
        /* Scoped persistence is wired in FOS-2. */

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
                    .foregroundStyle(FleetTheme.textSecondary)
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
            filterChips(model)
            MemoryGraphCanvas(model: model) { nodeID in
                Task { await model.loadDetail(for: nodeID) }
            }
            .frame(maxHeight: .infinity)
            scrubber(model)
        }
        .padding(FleetTheme.spacingMd)
        .refreshable {
            await model.reload(profile: profileScope)
        }
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
                    .foregroundStyle(FleetTheme.accent)
                    .lineLimit(3)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("memorygraph.mutation-banner")
            } else if let refusal = model.mutationError {
                HStack(spacing: FleetTheme.spacingSm) {
                    Text(refusal)
                        .font(FleetTheme.secondaryFont)
                        .foregroundStyle(FleetTheme.statusDegraded)
                        .lineLimit(4)
                        .accessibilityIdentifier("memorygraph.mutation-banner.text")
                    Spacer()
                    Button("Dismiss") { model.clearMutationFeedback() }
                        .font(FleetTheme.secondaryFont.weight(.semibold))
                        .foregroundStyle(FleetTheme.accent)
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
                    .foregroundStyle(FleetTheme.textSecondary)
                    .accessibilityIdentifier("memorygraph.cap-label")
            }
            ForEach(model.graph?.summary.lines ?? [], id: \.self) { line in
                Text(line)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
            }
            if model.source == .offlineSnapshot, let captured = model.offlineCapturedAt {
                Text("offline snapshot · \(captured.formatted(date: .abbreviated, time: .shortened))")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textMuted)
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
                            model.filter == filter ? FleetTheme.background : FleetTheme.textSecondary)
                        .padding(.horizontal, FleetTheme.spacingMd)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                model.filter == filter ? FleetTheme.accent : FleetTheme.accent.opacity(0.08)))
                }
                .buttonStyle(.fleetPressable)
                .accessibilityIdentifier("memorygraph.filter.\(filter.rawValue)")
            }
            Spacer()
            Text("● skills   ◆ memories")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textMuted)
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
            .foregroundStyle(FleetTheme.textMuted)
            .accessibilityHidden(true)
            Slider(value: Binding(
                get: { model.reveal },
                set: { model.setReveal($0) }
            ), in: 0...1)
            .tint(FleetTheme.accent)
            .accessibilityLabel("Timeline reveal")
            .accessibilityIdentifier("memorygraph.scrubber")
        }
    }

    private func offlineBanner(_ text: String, capturedAt: Date?, model: MemoryGraphViewModel) -> some View {
        HStack(spacing: FleetTheme.spacingSm) {
            Image(systemName: "wifi.slash")
                .font(.caption)
                .foregroundStyle(FleetTheme.statusDegraded)
                .accessibilityHidden(true)
            Text("Offline — showing the last captured map. \(text)")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.statusDegraded)
                .lineLimit(2)
            Spacer()
            Button("Retry") {
                Task { await model.reload(profile: profileScope) }
            }
            .font(FleetTheme.secondaryFont.weight(.semibold))
            .foregroundStyle(FleetTheme.accent)
            .buttonStyle(.fleetPressable)
            .accessibilityIdentifier("memorygraph.retry")
        }
        .padding(.horizontal, FleetTheme.spacingMd)
    }

    private var emptyContent: some View {
        VStack(spacing: FleetTheme.spacingMd) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(FleetTheme.textSecondary)
                .accessibilityHidden(true)
            Text("No learning yet — keep using Hermes and it maps out here.")
                .font(FleetTheme.secondaryFont)
                .foregroundStyle(FleetTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(FleetTheme.spacingXl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memorygraph.empty")
    }

    private func errorContent(_ error: String, model: MemoryGraphViewModel) -> some View {
        VStack(spacing: FleetTheme.spacingMd) {
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
                        Task { await model.reload(profile: profileScope) }
                    }
                    .font(FleetTheme.secondaryFont.weight(.semibold))
                    .foregroundStyle(FleetTheme.accent)
                    .buttonStyle(.fleetPressable)
                    .accessibilityIdentifier("memorygraph.error.retry")
                }
            }
        }
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
                        ? FleetTheme.accent.opacity(alpha)
                        : FleetTheme.textSecondary.opacity(alpha)
                    if placed.isMemory && !reduceTransparency && contrast != .increased {
                        let halo = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
                        context.fill(Path(ellipseIn: halo), with: .radialGradient(
                            Gradient(colors: [FleetTheme.accent.opacity(0.2), .clear]),
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
    let errorText: String

    var body: some View {
        NavigationStack {
            VStack(spacing: FleetTheme.spacingMd) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(FleetTheme.statusDegraded)
                Text(errorText)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDegraded)
                    .multilineTextAlignment(.center)
            }
            .padding(FleetTheme.spacingXl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FleetTheme.background)
            .navigationTitle("Node")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Node drill-in: full SKILL.md or memory chunk (learning.detail) with
/// R10-T5 edit (learning.edit) and delete (learning.delete) affordances.
struct LearningNodeDetailSheet: View {
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
            .background(FleetTheme.background)
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
                        if model.mutationError == nil { dismiss() }
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
                        .foregroundStyle(FleetTheme.accent)
                        .accessibilityHidden(true)
                    Text(detail.kind.uppercased())
                        .font(FleetTheme.sectionHeaderFont)
                        .tracking(FleetTheme.microLabelTracking)
                        .foregroundStyle(FleetTheme.textSecondary)
                }
                Text(detail.label)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(FleetTheme.textPrimary)
                    .accessibilityIdentifier("memorygraph.detail.label")
                Text(detail.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(FleetTheme.textSecondary)
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
                .tracking(FleetTheme.microLabelTracking)
                .foregroundStyle(FleetTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let refusal = model.mutationError {
                // Verbatim gateway refusal (names the remedy) — inline in
                // the editor so the user can fix the content and retry.
                Text(refusal)
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.statusDegraded)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("memorygraph.detail.edit.refusal")
            }
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(FleetTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(FleetTheme.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FleetTheme.accent.opacity(0.4), lineWidth: 1))
                .accessibilityIdentifier("memorygraph.detail.edit.field")
        }
        .padding(FleetTheme.spacingLg)
    }
}
