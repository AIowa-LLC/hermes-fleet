import XCTest
@testable import FleetCore

/// Slash-command parity — FleetCore domain coverage: catalog model, router
/// dispositions, dispatch decoding contracts, and fail-closed behavior.
final class HermesCommandDomainTests: XCTestCase {

    // MARK: Router

    func testNativeSurfacesWinOverDispositions() {
        // /model is upstream `hidden` but Fleet has a native picker surface.
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "model", desktopDisposition: "hidden"),
            .picker(.model))
        // /steer has no disposition upstream; Fleet's action wins.
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "steer", desktopDisposition: nil),
            .action(.steer))
    }

    func testTerminalDispositionIsUnavailable() {
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "redraw", desktopDisposition: "terminal"),
            .unavailable(.terminal))
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "approve", desktopDisposition: "messaging"),
            .unavailable(.messaging))
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "reasoning", desktopDisposition: "advanced"),
            .unavailable(.advanced))
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "skills", desktopDisposition: "settings"),
            .unavailable(.settings))
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "voice", desktopDisposition: "composer-voice"),
            .unavailable(.composerVoice))
    }

    func testUnknownCommandDefaultsToBackendExec() {
        // A future Hermes command / new plugin surfaces as executable.
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "brand-new-command", desktopDisposition: nil),
            .exec)
        // A hidden command Hermes owns still executes when typed.
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "codex-runtime", desktopDisposition: "hidden"),
            .exec)
    }

    func testAliasesAreNeverSuggestedButAlwaysExecutable() {
        let canon = ["/reset": "/new", "/fork": "/branch"]
        let reset = SlashCommandSuggestion(text: "/reset", kind: .command)
        let new = SlashCommandSuggestion(text: "/new", kind: .command)
        XCTAssertFalse(FleetCommandRouter.isSuggestible(reset, canon: canon))
        XCTAssertTrue(FleetCommandRouter.isSuggestible(new, canon: canon))
        XCTAssertTrue(FleetCommandRouter.isExecutable(canonicalName: "reset", desktopDisposition: nil))
    }

    func testUnavailableCommandsAreNotSuggestedAndNotExecutable() {
        let redraw = SlashCommandSuggestion(
            text: "/redraw", kind: .command, desktopDisposition: "terminal")
        XCTAssertFalse(FleetCommandRouter.isSuggestible(redraw, canon: [:]))
        XCTAssertFalse(FleetCommandRouter.isExecutable(canonicalName: "redraw", desktopDisposition: "terminal"))
    }

    /// Token convention: completion rows carry `/name`, while the router's
    /// native table and execution path use the bare canonical name. Both
    /// spellings of the same command must classify identically, or a palette
    /// row silently loses its Fleet surface and falls back to its upstream
    /// `desktop` disposition.
    func testSlashPrefixedAndBareTokensClassifyIdentically() {
        for name in ["model", "steer", "status", "resume"] {
            XCTAssertEqual(
                FleetCommandRouter.surface(for: "/\(name)", desktopDisposition: nil),
                FleetCommandRouter.surface(for: name, desktopDisposition: nil),
                "/\(name) must classify as its bare canonical name")
            XCTAssertEqual(
                FleetCommandRouter.surface(for: "/\(name)", desktopDisposition: "hidden"),
                FleetCommandRouter.surface(for: name, desktopDisposition: "hidden"))
        }
        // A native command keeps its Fleet surface even when the SLASH form
        // is the one carrying the upstream disposition (the palette row).
        let model = SlashCommandSuggestion(
            text: "/model", kind: .command, desktopDisposition: "hidden")
        XCTAssertTrue(
            FleetCommandRouter.isSuggestible(model, canon: ["/model": "/model"]),
            "/model is Fleet-native — its picker surface decides, not `hidden`")
    }

    /// `hidden` upstream means executable when typed but omitted from normal
    /// discovery. A hidden command with NO Fleet surface must therefore stay
    /// out of the palette and `/help`, while still executing.
    func testHiddenCommandWithoutFleetSurfaceExecutesButIsNotSuggested() {
        let hidden = SlashCommandSuggestion(
            text: "/codex-runtime", kind: .command, desktopDisposition: "hidden")
        XCTAssertFalse(
            FleetCommandRouter.isSuggestible(hidden, canon: [:]),
            "hidden + no Fleet surface must not be offered in discovery")
        XCTAssertTrue(
            FleetCommandRouter.isExecutable(canonicalName: "codex-runtime", desktopDisposition: "hidden"),
            "hidden still executes when typed")
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "codex-runtime", desktopDisposition: "hidden"),
            .exec)
        // Rows WITH a disposition that just ride backend exec (skills, quick
        // commands, no disposition at all) stay suggestible.
        XCTAssertTrue(FleetCommandRouter.isSuggestible(
            SlashCommandSuggestion(text: "/my-quick-command", kind: .extensionCommand),
            canon: [:]))
    }

    // MARK: Catalog model

    func testCanonicalFormResolvesAliases() {
        let catalog = HermesCommandCatalog(
            commands: [],
            canon: ["/reset": "/new", "/fork": "/branch"],
            commandMeta: [:],
            skills: [:])
        XCTAssertEqual(catalog.canonicalForm(of: "/reset"), "/new")
        XCTAssertEqual(catalog.canonicalForm(of: "/NEW"), "/new")
        XCTAssertEqual(catalog.canonicalForm(of: "/branch"), "/branch")
        // Unknown token canonicalizes to itself (lowercased).
        XCTAssertEqual(catalog.canonicalForm(of: "/Unknown"), "/unknown")
    }

    // MARK: Dispatch contract (fail-closed semantics live in FleetNetworking
    // decode tests; here we pin the error surface).

    func testUnknownDispatchTypeErrorIsFailClosed() {
        let error = SlashCommandError.unknownDispatchType("holodeck")
        XCTAssertEqual(
            error.errorDescription,
            "This Hermes command returned a response this version of Fleet does not understand (type holodeck).")
    }

    func testUnavailableReasonCopy() {
        XCTAssertEqual(
            FleetCommandUnavailableReason.terminal.message,
            "is available from the Hermes terminal, not Fleet.")
    }

    func testSuggestionArgumentModesRoundTrip() {
        XCTAssertEqual(SlashCommandSuggestion.ArgumentMode(rawValue: "options"), .options)
        XCTAssertEqual(SlashCommandSuggestion.ArgumentMode(rawValue: "text"), .text)
        XCTAssertEqual(SlashCommandSuggestion.ArgumentMode(rawValue: "mixed"), .mixed)
        XCTAssertNil(SlashCommandSuggestion.ArgumentMode(rawValue: "voice"))
    }

    func testUnsupportedProviderThrowsTypedCapabilityErrors() async throws {
        let unsupported = UnsupportedSlashCommandProviding()
        do {
            _ = try await unsupported.catalog(sessionID: nil)
            XCTFail("catalog must throw")
        } catch let error as SlashCommandError {
            XCTAssertEqual(error, .unsupportedCapability(method: "commands.catalog"))
        }
        do {
            _ = try await unsupported.execute(sessionID: "s", command: "/x")
            XCTFail("execute must throw")
        } catch let error as SlashCommandError {
            XCTAssertEqual(error, .unsupportedCapability(method: "slash.exec"))
        }
        do {
            _ = try await unsupported.stopProcesses(sessionID: "s")
            XCTFail("stopProcesses must throw")
        } catch let error as SlashCommandError {
            XCTAssertEqual(error, .unsupportedCapability(method: "process.stop"))
        }
    }
}
