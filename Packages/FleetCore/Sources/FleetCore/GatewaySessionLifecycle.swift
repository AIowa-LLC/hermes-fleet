/// Lifecycle seam for any gateway-backed feature that owns a persistent
/// transport. The UI runtime uses this to close feature-specific sockets at
/// app-background and privacy-cache deletion boundaries without importing the
/// networking module.
public protocol GatewaySessionDisconnecting: Sendable {
    func disconnect() async
}
