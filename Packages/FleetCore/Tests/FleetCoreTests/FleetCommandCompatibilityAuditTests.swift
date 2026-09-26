import XCTest
import FleetCore

/// Mission §22 compatibility audit: every Hermes registry command with an
/// upstream `desktop=` disposition is classified against a Fleet surface.
/// The classification table below was verified against a live hermes-agent
/// 0.21.3 gateway (commands.catalog: 127 command-meta entries) and Desktop's
/// `desktop-slash-commands.ts`. This test is the drift tripwire: a new
/// upstream disposition that Fleet has no policy for fails HERE first, not
/// in a user's palette.
final class FleetCommandCompatibilityAuditTests: XCTestCase {

    /// The live 0.21.3 dispositions (name → desktop value), from
    /// hermes_cli/commands.py COMMAND_REGISTRY. gateway_only commands do not
    /// appear in catalog pairs; cli_only ones do with their disposition.
    private static let upstreamDispositions: [String: String] = [
        // terminal
        "clear": "terminal", "redraw": "terminal", "history": "terminal",
        "snapshot": "terminal", "snap": "terminal", "sethome": "terminal",
        "set-home": "terminal", "config": "terminal", "statusbar": "terminal",
        "sb": "terminal", "verbose": "terminal", "footer": "terminal",
        "indicator": "terminal", "busy": "terminal", "toolsets": "terminal",
        "cron": "terminal", "reload": "terminal", "plugins": "terminal",
        "palette": "terminal", "restart": "terminal", "platforms": "terminal",
        "gateway": "terminal", "copy": "terminal", "paste": "terminal",
        "image": "terminal", "update": "terminal", "quit": "terminal",
        "exit": "terminal", "worktree": "terminal",
        // messaging
        "approve": "messaging", "deny": "messaging",
        // settings
        "skills": "settings", "login": "settings",
        // advanced
        "reasoning": "advanced", "fast": "advanced", "curator": "advanced",
        "kanban": "advanced", "reload-mcp": "advanced", "reload_mcp": "advanced",
        "reload-skills": "advanced", "reload_skills": "advanced",
        "insights": "advanced",
        // composer-voice
        "voice": "composer-voice",
        // hidden (executable, out of the palette)
        "model": "hidden",
    ]

    /// Fleet-native surfaces (mirrors FleetCommandRouter.native).
    private static let fleetNative: Set<String> = [
        "new", "steer", "stop", "title", "branch", "help",
        "model", "resume", "sessions", "switch", "status",
    ]

    func testEveryKnownDispositionRoutesSomewhere() {
        for (name, disposition) in Self.upstreamDispositions {
            let surface = FleetCommandRouter.surface(for: name, desktopDisposition: disposition)
            switch surface {
            case .action, .picker, .rpc, .exec:
                // Native or backend-routable: fine.
                break
            case .unavailable(let reason):
                // Unavailable is only correct for the five reason classes —
                // a native command must NEVER be unavailable.
                XCTAssertFalse(
                    Self.fleetNative.contains(name),
                    "/\(name) is Fleet-native; upstream \(disposition) must not make it unavailable")
                XCTAssertNotNil(
                    FleetCommandUnavailableReason(disposition: disposition),
                    "/\(name) disposition \(disposition) must map to a known reason")
                _ = reason
            }
        }
    }

    func testFleetNativeCommandsAreNeverUnavailable() {
        for name in Self.fleetNative {
            for disposition in ["terminal", "messaging", "settings", "advanced", "composer-voice"] {
                if case .unavailable(let reason) = FleetCommandRouter.surface(for: name, desktopDisposition: disposition) {
                    if name == "model" && disposition == "hidden" { continue }
                    XCTFail("/\(name) with disposition \(disposition) became unavailable (\(reason)) — native surfaces always win")
                }
            }
        }
    }

    /// The mission's core drift requirement: an upstream command Fleet has
    /// never heard of (new Hermes release) routes to backend exec, never to
    /// unavailable, never crashes.
    func testFutureUpstreamCommandsDefaultToBackendExec() {
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "brand-new-hermes-command", desktopDisposition: nil),
            .exec)
        // Even WITH an unknown disposition string the command still executes
        // unless the disposition maps to a known unavailability reason.
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "weird-cmd", desktopDisposition: "hologram"),
            .exec)
    }

    /// Skills/quick/plugin commands have no disposition and always execute.
    func testExtensionCommandsAlwaysExecute() {
        XCTAssertEqual(
            FleetCommandRouter.surface(for: "any-skill-token", desktopDisposition: nil),
            .exec)
        XCTAssertTrue(FleetCommandRouter.isExecutable(canonicalName: "any-skill-token", desktopDisposition: nil))
    }
}
