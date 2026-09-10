import SwiftUI
import FleetCore

/// Reusable Hermes Pet picker sheet (#9): a searchable, lazily-rendered
/// Petdex gallery for choosing a Pet's idle frame as the Bot's avatar
/// image. REUSABLE BY DESIGN — Create Bot can mount the same component
/// later without duplicating the networking or gallery logic.
///
/// - Two-stage load: local/generated pets first (`localOnly`), full
///   Petdex catalog hydrated + merged after.
/// - LazyVGrid ~3 columns on iPhone; thumbnails request lazily as cells
///   render, coalesced + cached by the controller (route-aware).
/// - Search matches displayName AND slug.
/// - Honest states: loading, empty, retryable transient failure, Pets
///   unavailable on the gateway.
/// - Selecting a pet stages PNG bytes into #7's appearance draft ONLY —
///   zero remote writes; the callback hands the bytes to the editor
///   (preview updates immediately; Save persists).
public struct BotPetPickerSheet: View {
    let environment: AppEnvironment
    let bot: FleetBot
    /// Called with the selected pet's idle-frame PNG bytes. The caller
    /// owns the draft mutation (stage into the avatar appearance draft).
    let onSelected: (HermesPet, Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectionInFlightSlug: String?

    public init(
        environment: AppEnvironment,
        bot: FleetBot,
        onSelected: @escaping (HermesPet, Data) -> Void
    ) {
        self.environment = environment
        self.bot = bot
        self.onSelected = onSelected
    }

    private var management: BotManagementController { environment.botManagement }

    private var phase: BotManagementController.PetGalleryPhase {
        management.petGalleryPhaseByRoute[bot.route] ?? .idle
    }

    private var pets: [HermesPet] {
        management.petGalleryByRoute[bot.route] ?? []
    }

    private var filteredPets: [HermesPet] {
        pets.filter { $0.matches(query: query) }
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle, .loadingLocal:
                    ProgressView("Loading pets…")
                        .accessibilityIdentifier("fleet.bot.pet.loading")
                case .unsupported:
                    unsupportedState
                case .failed(let message):
                    retryableFailureState(message)
                case .hydrating, .loaded:
                    galleryGrid
                }
            }
            .navigationTitle("Choose Hermes Pet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("fleet.bot.pet.cancel")
                }
            }
            .searchable(text: $query, prompt: Text("Search pets"))
            .task { await management.loadPetGallery(for: bot) }
        }
    }

    /// Pets unavailable (method-not-found): a capability fact — no retry
    /// affordance that would imply a transient problem.
    private var unsupportedState: some View {
        ContentUnavailableView {
            Label("Pets Unavailable", systemImage: "pawprint")
        } description: {
            Text("This gateway does not expose Hermes Pets. Update the gateway to choose a pet avatar.")
        }
        .accessibilityIdentifier("fleet.bot.pet.unsupported")
    }

    /// Transient failure: retryable, visually distinct from unsupported.
    private func retryableFailureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Load Pets", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await management.retryPetGallery(for: bot) }
            }
            .accessibilityIdentifier("fleet.bot.pet.retry")
        }
        .accessibilityIdentifier("fleet.bot.pet.failed")
    }

    private var galleryGrid: some View {
        ScrollView {
            if filteredPets.isEmpty && phase == .loaded {
                Text(pets.isEmpty ? "No pets are available." : "No pets match your search.")
                    .font(FleetTheme.secondaryFont)
                    .foregroundStyle(FleetTheme.textSecondary)
                    .padding(.top, 60)
                    .accessibilityIdentifier("fleet.bot.pet.empty")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(filteredPets) { pet in
                        BotPetCell(
                            pet: pet,
                            selectionInFlight: selectionInFlightSlug == pet.slug,
                            loadThumbnail: {
                                await management.petThumbnailData(for: bot, pet: pet)
                            },
                            retryThumbnail: {
                                await management.retryPetThumbnail(for: bot, pet: pet)
                            },
                            onSelect: { await select(pet) }
                        )
                        .accessibilityIdentifier("fleet.bot.pet.cell.\(pet.slug)")
                    }
                }
                .padding()
                if phase == .hydrating {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the full Petdex catalog…")
                            .font(.caption)
                            .foregroundStyle(FleetTheme.textSecondary)
                    }
                    .accessibilityIdentifier("fleet.bot.pet.hydrating")
                }
            }
        }
    }

    private func select(_ pet: HermesPet) async {
        guard selectionInFlightSlug == nil else { return }
        selectionInFlightSlug = pet.slug
        defer { selectionInFlightSlug = nil }
        // pet.thumb through the Bot's own gateway/profile route; PNG bytes
        // hand off to the editor's draft — no remote write happens here.
        guard let bytes = await management.petThumbnailData(for: bot, pet: pet) else {
            await management.retryPetThumbnail(for: bot, pet: pet)
            return
        }
        onSelected(pet, bytes)
        dismiss()
    }
}

/// One gallery cell: lazy thumbnail (nearest-neighbor scaling for pixel
/// art), installed/generated/curated badges, display name + slug.
struct BotPetCell: View {
    let pet: HermesPet
    let selectionInFlight: Bool
    let loadThumbnail: () async -> Data?
    let retryThumbnail: () async -> Void
    let onSelect: () async -> Void

    @State private var thumbnail: Data?
    @State private var failed = false

    var body: some View {
        Button {
            guard !selectionInFlight else { return }
            Task { await onSelect() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(FleetTheme.surfaceElevated)
                    if let thumbnail, let image = UIImage(data: thumbnail) {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .padding(6)
                    } else if failed {
                        Button {
                            Task { await retryBoth() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(FleetTheme.textSecondary)
                        }
                        .accessibilityIdentifier("fleet.bot.pet.thumb-retry.\(pet.slug)")
                    } else {
                        ProgressView()
                    }
                    if selectionInFlight { ProgressView() }
                }
                .frame(height: 88)
                VStack(spacing: 2) {
                    Text(pet.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    Text(pet.slug)
                        .font(.caption2)
                        .foregroundStyle(FleetTheme.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if pet.installed {
                        badge("Installed")
                    }
                    if pet.generated {
                        badge("Generated")
                    }
                    if pet.curated {
                        badge("Curated")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: pet.slug) {
            // Lazy: the request fires only when the cell materializes in
            // the grid (LazyVGrid virtualizes off-screen cells away).
            if let bytes = await loadThumbnail() {
                thumbnail = bytes
                failed = false
            } else {
                failed = true
            }
        }
    }

    private func retryBoth() async {
        await retryThumbnail()
        if let bytes = await loadThumbnail() {
            thumbnail = bytes
            failed = false
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(FleetTheme.accent.opacity(0.18)))
            .foregroundStyle(FleetTheme.accent)
    }
}
