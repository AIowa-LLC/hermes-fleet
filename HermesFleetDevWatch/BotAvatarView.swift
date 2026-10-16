import SwiftUI
import FleetWatchKit

/// A bot's face on the Watch: its uploaded image when the thumbnail is here,
/// otherwise the same shape + identity color the iPhone roster draws, otherwise
/// initials. Dimmed (always-on) shows a neutral placeholder, like names.
struct BotAvatarView: View {
    let store: WatchStore
    let bot: WatchBot?
    var size: CGFloat = 28
    var showsActivity = true
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            face
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            if showsActivity, !dimmed, let kind = bot?.activityKind, kind != .unknown {
                ActivityDot(kind: kind, size: max(7, size * 0.3))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
        .accessibilityHidden(true)
        .task(id: bot?.avatar?.imageDigest) {
            if let bot { await store.loadAvatar(for: bot) }
        }
    }

    @ViewBuilder
    private var face: some View {
        if dimmed {
            Color.gray.opacity(0.35)
        } else if let data = store.avatarData(for: bot), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let avatar = bot?.avatar {
            BotFace(avatar: avatar, size: size)
        } else {
            Text(bot?.initials ?? "?")
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
        }
    }
}

/// Shape + eyes, the Watch twin of the iPhone's `BotAvatarFace`.
struct BotFace: View {
    let avatar: WatchBotAvatar
    let size: CGFloat

    var body: some View {
        let rgb = avatar.rgb ?? (0.04, 0.52, 1.0)
        ZStack {
            BotShape(name: avatar.renderShape, seed: avatar.seed)
                .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
            HStack(spacing: size * 0.16) {
                Capsule().frame(width: size * 0.07, height: size * 0.14)
                Capsule().frame(width: size * 0.07, height: size * 0.14)
            }
            .foregroundStyle(.black.opacity(0.8))
        }
        .padding(size * 0.09)
    }
}

/// What the bot is doing, as a small colored dot. Static (no animation), so
/// Reduce Motion needs no special case.
struct ActivityDot: View {
    let kind: WatchBotActivityKind
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(.black, lineWidth: max(1, size * 0.18)))
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch kind {
        case .busy: return .green
        case .waiting: return .yellow
        case .needsAttention: return .orange
        case .idle: return .gray
        case .offline: return .gray.opacity(0.4)
        case .unknown: return .clear
        }
    }
}

/// Geometry matching the iPhone's `BotAvatarShapePath` for every shape the
/// snapshot can name.
struct BotShape: Shape {
    let name: String
    let seed: String

    func path(in rect: CGRect) -> Path {
        switch name {
        case "circle": return Path(ellipseIn: rect)
        case "pill": return Path(roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.15), cornerRadius: rect.height / 2)
        case "triangle": return polygon(rect, sides: 3)
        case "hexagon": return polygon(rect, sides: 6)
        case "drop":
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX * 1.3, y: rect.midY), control2: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addCurve(to: CGPoint(x: rect.midX, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.maxY), control2: CGPoint(x: rect.minX - rect.width * 0.3, y: rect.midY))
            return p
        case "cloud": return cloud(rect)
        case "blob": return blob(rect)
        default: return Path(roundedRect: rect, cornerRadius: rect.width * 0.3)
        }
    }

    private func polygon(_ rect: CGRect, sides: Int) -> Path {
        Path { p in
            for i in 0..<sides {
                let a = Double(i) * 2 * .pi / Double(sides) - .pi / 2
                let point = CGPoint(x: rect.midX + cos(a) * rect.width / 2, y: rect.midY + sin(a) * rect.height / 2)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
        }
    }

    private func cloud(_ rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.02, y: rect.midY - rect.height * 0.02, width: rect.width * 0.42, height: rect.height * 0.46))
        p.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.04, width: rect.width * 0.5, height: rect.height * 0.52))
        p.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.52, y: rect.midY - rect.height * 0.08, width: rect.width * 0.44, height: rect.height * 0.5))
        p.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.38, width: rect.width * 0.84, height: rect.height * 0.56))
        return p
    }

    private func blob(_ rect: CGRect) -> Path {
        let phase = Double(seed.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) } % 100) / 100 * .pi
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
