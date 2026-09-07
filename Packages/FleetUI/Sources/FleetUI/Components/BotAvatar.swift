import SwiftUI
import FleetCore

/// One renderer for gateway-owned assets and deterministic Bot identity.
public struct BotAvatar: View {
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
        guard let raw = bot?.botModeMetadata?.color,
              raw.hasPrefix("#"), raw.count == 7,
              let hex = UInt32(raw.dropFirst(), radix: 16) else { return FleetTheme.accent }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
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
                ZStack {
                    BotFaceShape(name: shape, seed: identity).fill(tint)
                    HStack(spacing: 7) {
                        Capsule().frame(width: 3, height: 6)
                        Capsule().frame(width: 3, height: 6)
                    }.foregroundStyle(.black.opacity(0.8))
                }.padding(4)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(FleetTheme.surfaceElevated)
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

private struct BotFaceShape: Shape {
    let name: String
    let seed: String
    func path(in rect: CGRect) -> Path {
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
        case "blob", "cloud": return blob(rect)
        default:
            if BotAvatarIdentity.isBlobShape(name) { return blob(rect) }
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
