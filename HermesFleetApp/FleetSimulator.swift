import Foundation
import FleetCore
import FleetNetworking
import FleetSecurity
import FleetPersistence
import FleetUI

#if DEBUG

/// Scripted fleet simulator — DEBUG builds ONLY.
///
/// U1 acceptance requires the navigation skeleton to be walkable in the
/// simulator: Gateways → Bots → Sessions → Conversation. Without a live Hermes
/// gateway wired with credentials, the real transport would classify every
/// gateway offline and the shell would show empty states end-to-end. This
/// simulator drives the SAME observable `AppEnvironment` runtime and the SAME
/// FleetCore seams with scripted services that return deterministic,
/// in-memory fleet data — so the whole cockpit flow is navigable on a booted
/// simulator. Release builds use the real production graph
/// (`FleetServiceGraph.makeProductionEnvironment`).
extension FleetServiceGraph {

    static func makeSimulatorEnvironment() -> AppEnvironment {
        // Scripted registry: in-memory credential store (no Keychain writes).
        let credentials = InMemoryCredentialStore()
        let registry: any GatewayRegistryManaging = GatewayRegistryService(
            credentials: credentials,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            }
        )
        // Scripted union roster: FleetRosterService over scripted per-gateway
        // sessions (real M8 aggregation, scripted transport + roster RPCs).
        let roster: any FleetRosterProviding = FleetRosterService(
            registry: registry,
            credentials: credentials,
            sessionFactory: { gateway, _ in
                ScriptedRosterSession(gatewayID: gateway.id)
            }
        )
        // In-memory cache (scripted; no file-backed store in the simulator).
        let cache: any CacheStoring = (try! SwiftDataCacheStore.makeInMemory())

        return AppEnvironment(
            registry: registry,
            roster: roster,
            cache: cache,
            connectionFactory: { gateway, _ in
                ScriptedGatewayConnection(gatewayID: gateway.id)
            },
            seedRegistrations: ScriptedFleet.registrations
        )
    }
}

/// Deterministic in-memory fleet for the simulator: two gateways, each with a
/// couple of bots (profiles) and sessions, so every navigation destination
/// has content.
enum ScriptedFleet {
    static let registrations: [GatewayRegistration] = [
        GatewayRegistration(
            id: GatewayID(rawValue: "<dev-workstation>"),
            displayName: "MacBook M5",
            endpoint: URL(string: "http://127.0.0.1:8642")!
        ),
        GatewayRegistration(
            id: GatewayID(rawValue: "gaming-4090"),
            displayName: "Gaming 4090",
            endpoint: URL(string: "http://127.0.0.1:9900")!
        ),
    ]

    static func profiles(on gatewayID: GatewayID) -> [ProfileDescriptor] {
        switch gatewayID.rawValue {
        case "<dev-workstation>":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 12, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
                ProfileDescriptor(
                    name: "researcher", path: "~/.hermes/profiles/researcher",
                    isDefault: false, model: "hermes", provider: "openrouter",
                    displayName: "Researcher", skillCount: 8, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "researcher")
                ),
            ]
        case "gaming-4090":
            return [
                ProfileDescriptor(
                    name: "default", path: "~/.hermes/profiles/default",
                    isDefault: true, model: "hermes", provider: "nous",
                    displayName: "Default", skillCount: 10, hasAvatar: true,
                    lastSession: ScriptedFleet.session(on: "default")
                ),
            ]
        default:
            return []
        }
    }

    static func sessions(on route: Route) -> [SessionSummary] {
        switch route.gatewayID.rawValue {
        case "<dev-workstation>":
            return [
                ScriptedFleet.session(on: "default"),
                SessionSummary(
                    id: "<dev-workstation>.default.s2", title: "Replay plan review",
                    preview: "Discussing the reconnect/replay design.", startedAt: 1_755_000_000,
                    messageCount: 24, source: "ios"
                ),
            ]
        default:
            return [ScriptedFleet.session(on: route.profileSlug.rawValue)]
        }
    }

    private static func session(on slug: String) -> SessionSummary {
        SessionSummary(
            id: "<dev-workstation>.\(slug).s1", title: "Fleet setup",
            preview: "Initial conversation about the Hermes fleet.",
            startedAt: 1_754_000_000, messageCount: 6, source: "ios"
        )
    }
}

/// Scripted single-gateway connection: connects instantly, adopts a ready
/// payload, never touches the network. Used for the Gateways screen lifecycle
/// and the registry probe.
private struct ScriptedGatewayConnection: GatewayConnectivityProviding {
    let gatewayID: GatewayID

    var status: GatewayStatus {
        // Scripted connections report online immediately; the observable
        // lifecycle state is what the UI actually renders.
        .online
    }

    func adoptedReady() async -> GatewayReadyAdoption? {
        GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {
        // No-op: scripted connect succeeds instantly.
    }

    func disconnect() async {
        // No-op: scripted disconnect is safe from every state (spec §31).
    }

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }
}

/// Scripted per-gateway roster session: real M8 session shape, scripted
/// `profiles.list` / `session.list` responses.
private struct ScriptedRosterSession: GatewayRosterSession {
    let gatewayID: GatewayID

    var status: GatewayStatus { .online }

    func adoptedReady() async -> GatewayReadyAdoption? {
        GatewayReadyAdoption(replayEpoch: "scripted-1", heartbeatEnabled: true, changeEventsEnabled: true)
    }

    func connect() async throws {}

    func disconnect() async {}

    func currentGateway() async -> FleetGateway {
        FleetGateway(id: gatewayID, displayName: gatewayID.rawValue, endpoint: nil)
    }

    func fetchProfiles() async throws -> [ProfileDescriptor] {
        ScriptedFleet.profiles(on: gatewayID)
    }

    func fetchSessions(for route: Route, limit: Int) async throws -> [SessionSummary] {
        ScriptedFleet.sessions(on: route)
    }
}

#endif
