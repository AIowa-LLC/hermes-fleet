import SwiftUI
import FleetCore

/// One renderer for gateway-owned assets and deterministic Bot identity.
public struct BotAvatar: View {
    @Environment(\.fleetTheme) private var theme
    private let displayName: String
    private let bot: FleetBot?
    private let management: BotManagementController?

    public init(displayName: String) {
        self.displayName = displayName
        self.bot = nil
        self.management = nil
    }

    public init(bot: FleetBot?, management: BotManagementController) {
        self.bot = bot
        self.management = management
        self.displayName = bot.map { BotRosterPresentation.displayTitle(for: $0) } ?? ""
    }

    private var identity: String { bot?.route.profileSlug.rawValue ?? displayName }
    private var shape: String {
        bot?.botModeMetadata?.shape ?? BotAvatarIdentity.defaultShape(forName: identity)
    }
    private var tint: Color {
        BotAvatarAppearanceTint.color(hex: bot?.botModeMetadata?.color, fallback: theme.highlight)
    }

    public var body: some View {
        Group {
            if let bot, bot.hasAvatar,
               let data = management?.avatarDataByRoute[bot.route],
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if identity.isEmpty {
                Text(FleetDashboardFormatting.avatarInitials(from: displayName))
            } else {
                BotAvatarFace(shape: shape, seed: identity, tint: tint)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .accessibilityHidden(true)
        .task(id: "\(bot?.route.id ?? "")/\(bot?.hasAvatar ?? false)/\(String(bot?.uiMetaRevisions?[BotModeContract.botsMetaKey] ?? 0))") {
            if let bot { await management?.loadAvatar(for: bot) }
        }
    }
    static let side: CGFloat = 44
    static let fontSize: CGFloat = 13
    static let cornerRadius: CGFloat = 15
}

/// Shared tint resolution for the persisted roster renderer AND the editor
/// draft preview — one shape/color vocabulary (#7: the draft renderer and
/// the roster renderer must not diverge).
enum BotAvatarAppearanceTint {
    /// Resolve a #RRGGBB metadata color to a SwiftUI tint (accent fallback).
    static func color(hex raw: String?, fallback: Color) -> Color {
        guard let raw, raw.hasPrefix("#"), raw.count == 7,
              let hex = UInt32(raw.dropFirst(), radix: 16) else { return fallback }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

/// A deterministic bot face: shape geometry + eyes, shared by the roster
/// avatar and the appearance draft preview.
public struct BotAvatarFace: View {
    @Environment(\.fleetTheme) private var theme
    let shape: String
    let seed: String
    let tint: Color

    public var body: some View {
        ZStack {
            BotAvatarShapePath(name: shape, seed: seed).fill(tint)
            HStack(spacing: 7) {
                Capsule().frame(width: 3, height: 6)
                Capsule().frame(width: 3, height: 6)
            }.foregroundStyle(.black.opacity(0.8))
        }.padding(4)
    }
}

/// The #7 draft preview: renders the appearance the user WILL get after
/// Save — staged image bytes when active, else the staged shape/color.
/// Never reads stale roster metadata.
public struct BotAvatarAppearancePreview: View {
    @Environment(\.fleetTheme) private var theme
    let draft: BotAvatarAppearanceDraft
    let identityName: String

    private var shape: String {
        draft.shape ?? BotAvatarIdentity.defaultShape(forName: identityName)
    }

    /// VoiceOver / UI-test description of the staged appearance.
    private var description: String {
        if draft.effectiveImageBytes != nil { return "photo avatar" }
        if draft.shape == nil { return "deterministic default shape" }
        return "\(shape) shape"
    }

    public var body: some View {
        Group {
            if let data = draft.effectiveImageBytes, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if identityName.isEmpty {
                Text(FleetDashboardFormatting.avatarInitials(from: identityName))
            } else {
                BotAvatarFace(
                    shape: shape,
                    seed: identityName,
                    tint: BotAvatarAppearanceTint.color(hex: draft.color, fallback: theme.highlight))
            }
        }
        .frame(width: 96, height: 96)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Avatar preview: \(description)")
        .accessibilityIdentifier("fleet.bot.avatar.preview")
    }
}

/// Deterministic shape geometry. Every advertised picker shape renders
/// honestly and distinctly (#7 finding 4): `cloud` is its own composite
/// silhouette (NOT the generic blob), `squircle` is the soft-rounded
/// superellipse-ish rect, and unknown persisted values degrade safely to
/// the squircle fallback without rewriting user data.
public struct BotAvatarShapePath: Shape {
    let name: String
    let seed: String

    public func path(in rect: CGRect) -> Path {
        switch name {
        case "circle": return Path(ellipseIn: rect)
        case "pill": return Path(roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.15), cornerRadius: rect.height / 2)
        case "triangle", "hexagon":
            let sides = name == "triangle" ? 3 : 6
            return polygon(rect, sides: sides)
        case "drop":
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX * 1.3, y: rect.midY), control2: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.maxY), control2: CGPoint(x: rect.minX - rect.width * 0.3, y: rect.midY))
            return p
        case "squircle":
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.3)
        case "cloud": return cloud(rect)
        case "blob": return blob(rect)
        default:
            if BotAvatarIdentity.isBlobShape(name) { return blob(rect) }
            // Unknown/upstream free-form shape: predictable safe fallback,
            // never a crash and never a destructive rewrite of the value.
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.3)
        }
    }

    private func polygon(_ rect: CGRect, sides: Int) -> Path {
        Path { p in
            for i in 0..<sides {
                let a = Double(i) * 2 * Double.pi / Double(sides) - Double.pi / 2
                let point = CGPoint(x: rect.midX + cos(a) * rect.width / 2, y: rect.midY + sin(a) * rect.height / 2)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        }
    }

    /// Cloud: three overlapping puffs over a rounded base — visibly
    /// distinct from the wobbly seeded blob silhouette.
    private func cloud(_ rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.02,
            y: rect.midY - rect.height * 0.02,
            width: rect.width * 0.42, height: rect.height * 0.46))
        p.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.24,
            y: rect.minY + rect.height * 0.04,
            width: rect.width * 0.5, height: rect.height * 0.52))
        p.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.52,
            y: rect.midY - rect.height * 0.08,
            width: rect.width * 0.44, height: rect.height * 0.5))
        p.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.08,
            y: rect.minY + rect.height * 0.38,
            width: rect.width * 0.84, height: rect.height * 0.56))
        return p
    }

    private func blob(_ rect: CGRect) -> Path {
        // Stable silhouette from the upstream seed; static so Reduce Motion is inherent.
        let identity: String
        if case .blob(let parsed, let kind) = BotAvatarIdentity.parseBlobShape(name, fallbackSeed: seed) {
            identity = parsed + (kind ?? "")
        } else { identity = seed }
        let phase = Double(identity.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) } % 100) / 100 * .pi
        return Path { p in
            for i in 0..<120 {
                let a = Double(i) * 2 * .pi / 120
                let radius = 0.43 + 0.055 * sin(a * 5 + phase)
                let point = CGPoint(x: rect.midX + cos(a) * radius * rect.width, y: rect.midY + sin(a) * radius * rect.height)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        }
    }
}
