import Foundation

/// Issue #109 (D6): the resolved look of an assistant code card.
///
/// The card fill and the syntax palette are derived together from the ACTIVE
/// resolved theme, never from the system color scheme. The old renderer
/// configuration pinned the `.xcode` highlight theme, whose light/dark variant
/// followed the system appearance, so a light-ink palette on a near-black card
/// could receive the dark-ink (light-appearance) variant. Choosing the palette
/// from the card itself keeps keyword/string/comment colors legible for the
/// built-in light and dark themes, Increase Contrast, and custom palettes.
struct CodeBlockAppearance: Equatable {
    enum SyntaxPalette: Equatable {
        /// Bright tokens for a dark card (light ink).
        case darkCard
        /// Deep tokens for a light card (dark ink).
        case lightCard
        /// Contrast gate failed; the block renders in a single ink.
        case monochrome
    }

    enum Token: CaseIterable {
        case comment, keyword, string, number, type, title, attribute

        /// highlight.js class selectors carried by each token role.
        var selectors: [String] {
            switch self {
            case .comment: [".hljs-comment", ".hljs-quote", ".hljs-meta"]
            case .keyword: [".hljs-keyword", ".hljs-doctag", ".hljs-formula", ".hljs-literal"]
            case .string: [".hljs-string", ".hljs-regexp", ".hljs-meta-string", ".hljs-addition"]
            case .number: [".hljs-number"]
            case .type: [".hljs-type", ".hljs-built_in", ".hljs-class .hljs-title"]
            case .title: [
                ".hljs-title", ".hljs-symbol", ".hljs-bullet", ".hljs-link",
                ".hljs-selector-id"
            ]
            case .attribute: [
                ".hljs-attr", ".hljs-attribute", ".hljs-variable",
                ".hljs-template-variable", ".hljs-selector-class",
                ".hljs-selector-attr", ".hljs-selector-pseudo"
            ]
            }
        }
    }

    /// Opaque card fill (content surfaces stay opaque; no glass).
    let card: FleetStoredColor
    /// Ink for un-highlighted code and chrome, corrected to be readable on `card`.
    let ink: FleetStoredColor
    let palette: SyntaxPalette
    /// Final, contrast-corrected token colors. Empty for `.monochrome`.
    let tokenColors: [Token: FleetStoredColor]
    /// The minimum contrast the token colors were gated against.
    let minimumContrast: Double

    /// Quieter ink for chrome (language label, Copy), still >= 4.5:1 on the card.
    var chromeInk: FleetStoredColor {
        FleetThemeContrast.correctedForeground(
            ink.blended(toward: card, amount: 0.22),
            on: card,
            minimum: FleetThemeContrast.normalTextMinimum)
    }

    static func make(theme: FleetThemeValues) -> CodeBlockAppearance {
        let card = cardFill(theme: theme)
        let minimum = theme.isIncreasedContrast
            ? 7.0
            : FleetThemeContrast.normalTextMinimum
        let ink = FleetThemeContrast.correctedForeground(
            theme.resolvedPalette.text,
            on: card,
            minimum: FleetThemeContrast.normalTextMinimum)
        return resolve(card: card, ink: ink, minimumContrast: minimum)
    }

    /// Pure core, exposed for tests with arbitrary card/ink pairs.
    static func resolve(
        card: FleetStoredColor,
        ink: FleetStoredColor,
        minimumContrast: Double
    ) -> CodeBlockAppearance {
        let prefersLightCard = FleetThemeContrast.relativeLuminance(card) > 0.4
        let base = prefersLightCard ? lightCardColors : darkCardColors
        var resolved: [Token: FleetStoredColor] = [:]
        for token in Token.allCases {
            guard let color = base[token] else { continue }
            let corrected = FleetThemeContrast.correctedForeground(
                color, on: card, minimum: minimumContrast)
            guard FleetThemeContrast.ratio(corrected, card) >= minimumContrast else {
                // Gate failed (mid-tone card no ink can satisfy): drop syntax
                // colors entirely rather than ship an unreadable token.
                return CodeBlockAppearance(
                    card: card,
                    ink: ink,
                    palette: .monochrome,
                    tokenColors: [:],
                    minimumContrast: minimumContrast)
            }
            resolved[token] = corrected
        }
        return CodeBlockAppearance(
            card: card,
            ink: ink,
            palette: prefersLightCard ? .lightCard : .darkCard,
            tokenColors: resolved,
            minimumContrast: minimumContrast)
    }

    /// highlight.js CSS for this appearance. Only `code { color }` is emitted
    /// for the monochrome fallback.
    var css: String {
        var rules = ["code { color: \(ink.hexString) }"]
        for token in Token.allCases {
            guard let color = tokenColors[token] else { continue }
            rules.append("\(token.selectors.joined(separator: ",\n")) { color: \(color.hexString) }")
        }
        return rules.joined(separator: "\n")
    }

    /// Dogfood r6 (G3) + OCR fix: the code-card fill is derived from the ACTIVE
    /// palette, never from a raw system color (see the note on
    /// `FleetMarkdownRenderConfiguration.codeCardBackground`, which now
    /// delegates here). Light ink takes the measured near-black card; dark ink
    /// takes the elevated token. A pathological palette whose ink fails
    /// contrast against the near-black card falls back to the elevated token.
    static func cardFill(theme: FleetThemeValues) -> FleetStoredColor {
        let palette = theme.resolvedPalette
        let nearBlack = FleetStoredColor(red: 0.04, green: 0.05, blue: 0.07)
        let darkCard = palette.background.blended(toward: nearBlack, amount: 0.75)
        guard FleetThemeContrast.relativeLuminance(palette.text) > 0.5,
              FleetThemeContrast.ratio(palette.text, darkCard)
                >= FleetThemeContrast.normalTextMinimum else {
            return theme.surfaceElevatedStored
        }
        return darkCard
    }

    // MARK: Base token colors (before per-card contrast correction)

    private static let darkCardColors: [Token: FleetStoredColor] = [
        .comment: FleetStoredColor(hex: 0x8B95A1),
        .keyword: FleetStoredColor(hex: 0xFF7AB2),
        .string: FleetStoredColor(hex: 0xFF8170),
        .number: FleetStoredColor(hex: 0xD9C97C),
        .type: FleetStoredColor(hex: 0x5DD8FF),
        .title: FleetStoredColor(hex: 0x78C2B3),
        .attribute: FleetStoredColor(hex: 0xFFA14F)
    ]

    private static let lightCardColors: [Token: FleetStoredColor] = [
        .comment: FleetStoredColor(hex: 0x5D6C79),
        .keyword: FleetStoredColor(hex: 0x9B2393),
        .string: FleetStoredColor(hex: 0xC41A16),
        .number: FleetStoredColor(hex: 0x1C00CF),
        .type: FleetStoredColor(hex: 0x0B4F79),
        .title: FleetStoredColor(hex: 0x326D74),
        .attribute: FleetStoredColor(hex: 0x815F03)
    ]
}
