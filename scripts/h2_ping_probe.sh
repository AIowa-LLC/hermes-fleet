#!/usr/bin/env bash
# h2_ping_probe.sh — H2: probe the REAL LAN gateway's gateway.ping behavior
# through the loopback forwarder (the exact path the app uses). Sends
# gateway.ping (id heartbeat-1 / heartbeat-2) over a raw URLSessionWebSocketTask
# and prints the response frames + connection lifetime, so we know whether the
# gateway echoes the request id (the transport's RTT correlation depends on it)
# and whether the socket stays alive with no other inbound traffic.
# Runs via `bash scripts/h2_ping_probe.sh`. No secrets printed.
set -uo pipefail
cd "$(dirname "$0")/.."

LAN_HOST="${HERMES_FLEET_LAN_HOST:?Set HERMES_FLEET_LAN_HOST to YOUR gateway LAN host}"
LAN_PORT="${HERMES_FLEET_LAN_PORT:-9120}"
PORT=19121
FWD_PID=""
if ! nc -z -w 2 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "starting forwarder $PORT -> $LAN_HOST:$LAN_PORT"
  python3 scripts/t2_tcp_forward.py "$PORT" "$LAN_HOST" "$LAN_PORT" > /tmp/h2_ping_fwd.log 2>&1 &
  FWD_PID=$!
  sleep 1
fi
trap '[ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null || true' EXIT
nc -z -w 2 127.0.0.1 "$PORT" 2>/dev/null || { echo "forwarder failed to come up"; exit 1; }
echo "forwarder 127.0.0.1:$PORT UP"
[ -f /tmp/hermes_lan_surface/.cred ] || { echo "MISSING /tmp/hermes_lan_surface/.cred"; exit 1; }

cat > /tmp/h2_ping_probe.swift <<'SWIFT'
import Foundation

let base = URL(string: "http://127.0.0.1:19121")!
let sema = DispatchSemaphore(value: 0)

func readCreds() -> (String, String) {
    let text = (try? String(contentsOfFile: "/tmp/hermes_lan_surface/.cred", encoding: .utf8)) ?? ""
    var u = "", p = ""
    for line in text.split(separator: "\n") {
        if line.hasPrefix("username=") { u = String(line.dropFirst(9)) }
        if line.hasPrefix("password=") { p = String(line.dropFirst(9)) }
    }
    return (u, p)
}

func login() async throws -> String {
    var req = URLRequest(url: base.appendingPathComponent("auth/password-login"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let creds = readCreds()
    req.httpBody = try JSONEncoder().encode(["provider": "basic", "username": creds.0, "password": creds.1])
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { return "" }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as! [String: String], for: base)
    return cookies.first(where: { $0.name == "hermes_session_at" })?.value ?? ""
}

func mintTicket(cookie: String) async throws -> String {
    var req = URLRequest(url: base.appendingPathComponent("api/auth/ws-ticket"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("hermes_session_at=\(cookie)", forHTTPHeaderField: "Cookie")
    let (data, resp) = try await URLSession.shared.data(for: req)
    print("  ticket HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return obj?["ticket"] as? String ?? ""
}

func wsProbe(ticket: String) async throws {
    var comps = URLComponents(url: base.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)!
    comps.scheme = "ws"
    comps.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: comps.url!)
    task.resume()
    let start = Date()
    var frames: [String] = []
    var ready = false

    // Re-register a receive after each frame (loop).
    func armReceive() {
        task.receive { result in
            switch result {
            case .failure(let e):
                print("RECV FAIL after \(Int(Date().timeIntervalSince(start)))s: \(e)")
                print("FRAMES: \(frames.joined(separator: " | "))")
                sema.signal()
            case .success(let msg):
                if case .string(let s) = msg {
                    frames.append(s)
                    if s.contains("\"gateway.ready\"") && !ready {
                        ready = true
                        print("GOT gateway.ready")
                        let frame = "{\"jsonrpc\":\"2.0\",\"id\":\"heartbeat-1\",\"method\":\"gateway.ping\",\"params\":{}}"
                        task.send(.string(frame)) { err in
                            print(err == nil ? "SENT gateway.ping heartbeat-1" : "SEND1 ERR: \(err!)")
                        }
                        // Second ping at +6s to observe continued liveness.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                            let f2 = "{\"jsonrpc\":\"2.0\",\"id\":\"heartbeat-2\",\"method\":\"gateway.ping\",\"params\":{}}"
                            task.send(.string(f2)) { err in
                                print(err == nil ? "SENT gateway.ping heartbeat-2" : "SEND2 ERR: \(err!)")
                            }
                        }
                    } else if s.contains("heartbeat-1") {
                        print("PONG heartbeat-1: \(String(s.prefix(160)))")
                    } else if s.contains("heartbeat-2") {
                        print("PONG heartbeat-2: \(String(s.prefix(160)))")
                    } else {
                        print("FRAME \(frames.count): \(String(s.prefix(120)))")
                    }
                }
                if Date().timeIntervalSince(start) < 45 {
                    armReceive()
                } else {
                    task.cancel(with: .goingAway, reason: nil)
                    print("PROBE END after 45s. frames=\(frames.count)")
                    sema.signal()
                }
            }
        }
    }
    armReceive()
}

Task {
    do {
        let cookie = try await login()
        print("[login] cookie \(cookie.isEmpty ? "MISSING" : "ok")")
        let ticket = try await mintTicket(cookie: cookie)
        print("[ticket] \(ticket.isEmpty ? "MISSING" : "ok")")
        if ticket.isEmpty { sema.signal(); return }
        try await wsProbe(ticket: ticket)
    } catch {
        print("FATAL: \(error)")
        sema.signal()
    }
}
sema.wait()
SWIFT
swift /tmp/h2_ping_probe.swift 2>&1 | grep -vE "^warning:|^note:|Compiling|Build complete|^$" | head -40
