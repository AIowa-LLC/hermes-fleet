import Foundation

/// H2 surface doctor vocabulary shared across module boundaries.
///
/// When an endpoint ANSWERS HTTP but the auth route is missing
/// (`POST /api/auth/ws-ticket` → 404), the roster service probes
/// `GET {base}/health`. If that answers 200 with a hermes-agent JSON body,
/// the endpoint is a Hermes server running the REST surface (api_server) —
/// the wrong port for the chat gateway. The probe result travels to the UI
/// as this non-secret marker inside the classified failure detail string
/// (same pattern as the F1 "HTTP 404" and P0-9 "no_cookie" markers), because
/// FleetUI must not import FleetNetworking (M0 guard) — FleetCore owns the
/// shared vocabulary.
public enum GatewaySurfaceDoctorDetail {

    /// Marker appended to the failure detail when `/health` identified the
    /// endpoint as a Hermes server (api_server/REST, not the chat gateway).
    /// The UI's failure copy keys off this exact token.
    public static let hermesServerMarker = "/health: hermes-agent"
}
