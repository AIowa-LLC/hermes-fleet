#!/usr/bin/env python3
"""t_f54b722e: raw WebSocket upgrade through the tailnet forwarder, mimicking
URLSessionWebSocketTask's handshake exactly (Host: 127.0.0.1:19120 + Origin:
http://127.0.0.1:19120 + the standard upgrade headers). Uses a FRESH ticket.
Proves whether the forwarder's Host+Origin rewrite makes the tailnet surface
accept the app's exact WS handshake."""
import json
import socket
import subprocess
import sys
import time

CRED = "/tmp/hermes_lan_surface/.cred"
BASE = ("127.0.0.1", 19120)


def creds():
    d = {}
    for line in open(CRED):
        line = line.strip()
        if line.startswith("username="):
            d["username"] = line[len("username="):]
        elif line.startswith("password="):
            d["password"] = line[len("password="):]
    return d


def http_request(host, port, method, path, headers=None, body=None, cookie=None):
    s = socket.create_connection((host, port), timeout=8)
    req = f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
    for k, v in (headers or {}).items():
        req += f"{k}: {v}\r\n"
    if cookie:
        req += f"Cookie: {cookie}\r\n"
    req += f"Content-Length: {len(body or '')}\r\n" if body else ""
    req += "Connection: close\r\n\r\n"
    s.sendall(req.encode())
    if body:
        s.sendall(body.encode())
    data = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    s.close()
    head, _, rest = data.partition(b"\r\n\r\n")
    status = head.split(b" ")[1].decode()
    cookies = {}
    for line in head.decode("latin1").split("\r\n"):
        if line.lower().startswith("set-cookie:"):
            parts = line.split(":", 1)[1].strip().split(";")
            name, _, value = parts[0].partition("=")
            cookies[name.strip()] = value.strip()
    return int(status), cookies, rest


def ws_handshake(host, port, path, ticket, origin, cookie=None):
    s = socket.create_connection((host, port), timeout=8)
    key = "dGhlIHNhbXBsZSBub25jZQ=="  # RFC6455 example key
    req = (
        f"GET {path}?ticket={ticket} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"Origin: {origin}\r\n"
        "\r\n"
    )
    s.sendall(req.encode())
    s.settimeout(8)
    data = b""
    try:
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    head = data.split(b"\r\n\r\n")[0].decode("latin1", "replace")
    return s, head, data


def main():
    c = creds()
    body = json.dumps({"provider": "basic", "username": c["username"], "password": c["password"]})
    status, cookies, _ = http_request(*BASE, "POST", "/auth/password-login",
                                      {"Content-Type": "application/json"}, body)
    cookie_str = "; ".join(f"{k}={v}" for k, v in cookies.items())
    print(f"[login] HTTP {status}")
    status, _, ticket_json = http_request(*BASE, "POST", "/api/auth/ws-ticket",
                                          {"Accept": "application/json"}, cookie=cookie_str)
    ticket = json.loads(ticket_json)["ticket"]
    print(f"[ticket] HTTP {status}")

    # Exact URLSession-style handshake via the forwarder.
    s, head, _ = ws_handshake(BASE[0], BASE[1], "/api/ws", ticket, "http://127.0.0.1:19120")
    print("[ws via forwarder] handshake response head:")
    print("  " + head.replace("\r\n", "\r\n  "))
    if "101" in head.split("\r\n")[0]:
        # Read one WS frame (server -> client text). Minimal unmask (server frames are unmasked).
        s.settimeout(8)
        try:
            frame = s.recv(2048)
            print(f"[ws] first frame bytes: {frame[:80]}")
            # Find gateway.ready JSON
            txt = frame.decode("utf-8", "replace")
            print(f"[ws] decoded: {txt[:160]}")
        except socket.timeout:
            print("[ws] timed out waiting for ready frame")
    s.close()


if __name__ == "__main__":
    main()
