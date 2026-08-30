#!/usr/bin/env python3
"""t_eb5455f2: TCP forwarder 127.0.0.1:<local> -> <lan-ip>:9120 that rewrites
the HTTP/WebSocket Host header to the gateway's bound hostname on every request
(the gateway rejects Host != bound hostname, seen as HTTP 400).

The simulator app can reach the Mac's loopback (127.0.0.1) but is held from the
Mac's own LAN IP (<lan-ip>) by iOS local-network privacy. This tunnel lets
the SAME app code path (username/password -> ws-ticket -> WS) hit the REAL LAN
gateway (PID 96705, untouched) end-to-end.

Key subtlety: URLSession reuses keep-alive connections, so a second request on
the same socket would bypass the rewrite. We therefore force `Connection: close`
on non-upgrade requests, so every request gets a fresh connection whose Host is
rewritten. WebSocket upgrades pass through with their original headers + Host
rewrite and stay raw after the upgrade.
"""
import socket
import sys
import threading

LOCAL_HOST = "127.0.0.1"
LOCAL_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9120
REMOTE_HOST = "<lan-ip>"
REMOTE_PORT = 9120
REWRITE_HOST = "<lan-ip>:9120"


def rewrite_host_headers(head: bytes) -> bytes:
    """Rewrite Host and force Connection: close (unless upgrading to WS)."""
    text = head.decode("latin1")
    lines = text.split("\r\n")
    out = []
    is_upgrade = any(ln.lower().startswith("upgrade:") for ln in lines)
    for line in lines:
        lowered = line.lower()
        if lowered.startswith("host:"):
            out.append(f"Host: {REWRITE_HOST}")
        elif lowered.startswith("connection:") and not is_upgrade:
            out.append("Connection: close")
        else:
            out.append(line)
    if not is_upgrade and not any(ln.lower().startswith("connection:") for ln in lines):
        out.append("Connection: close")
    return ("\r\n".join(out) + "\r\n\r\n").encode("latin1")


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    try:
        remote = socket.create_connection((REMOTE_HOST, REMOTE_PORT), timeout=10)
    except OSError as e:
        sys.stderr.write(f"connect to gateway failed: {e}\n")
        client.close()
        return

    # Read the client's request headers, rewrite Host, forward, then splice the
    # remaining stream both ways.
    client.settimeout(5)
    buf = b""
    try:
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(65536)
            if not chunk:
                break
            buf += chunk
        if b"\r\n\r\n" in buf:
            head, rest = buf.split(b"\r\n\r\n", 1)
            rewritten = rewrite_host_headers(head)
            remote.sendall(rewritten + rest)
        else:
            # Connection ended before a full header block: relay raw.
            remote.sendall(buf)
    except OSError:
        remote.close()
        client.close()
        return
    finally:
        client.settimeout(None)

    t1 = threading.Thread(target=pipe, args=(client, remote), daemon=True)
    t2 = threading.Thread(target=pipe, args=(remote, client), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client.close()
    remote.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LOCAL_HOST, LOCAL_PORT))
    srv.listen(50)
    sys.stderr.write(f"rewriting forwarder {LOCAL_HOST}:{LOCAL_PORT} -> {REMOTE_HOST}:{REMOTE_PORT} (Host->{REWRITE_HOST})\n")
    sys.stderr.flush()
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
