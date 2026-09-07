#!/usr/bin/env python3
"""t_f54b722e (T2): TCP forwarder 127.0.0.1:<local> -> <remote>:9120 with Host
header rewrite, cloned from the P3-accepted p3fix_tcp_forward.py pattern.

Why: the iOS Simulator app is held from the Mac's own LAN/tailnet IPs by iOS
local-network privacy even after the ATS fix
(the providers GET hangs with no response/error; P3 documented the same wall
and the accepted simulator proof was a loopback forwarder). This tunnel lets
the SAME app code path (username/password -> ws-ticket -> WS -> conversation)
hit the REAL tailnet surface end-to-end.

Usage: python3 t2_tcp_forward.py <local_port> <remote_host> <remote_port>
"""
import socket
import sys
import threading

LOCAL_HOST = "127.0.0.1"
LOCAL_PORT = int(sys.argv[1])
REMOTE_HOST = sys.argv[2]
REMOTE_PORT = int(sys.argv[3])
REWRITE_HOST = f"{REMOTE_HOST}:{REMOTE_PORT}"


def rewrite_host_headers(head: bytes) -> bytes:
    """Rewrite Host AND Origin (the tailnet surface validates the WebSocket
    Origin header against its bound host — an app via the loopback forwarder
    sends Origin: http://127.0.0.1:PORT which the surface rejects with 403;
    rewriting Origin to http://<remote>:<port> fixes it, matching the Host
    rewrite pattern). Force Connection: close on non-upgrade requests."""
    text = head.decode("latin1")
    lines = text.split("\r\n")
    out = []
    is_upgrade = any(ln.lower().startswith("upgrade:") for ln in lines)
    for line in lines:
        lowered = line.lower()
        if lowered.startswith("host:"):
            out.append(f"Host: {REWRITE_HOST}")
        elif lowered.startswith("origin:"):
            out.append(f"Origin: http://{REWRITE_HOST}")
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
            reqline = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
            sys.stderr.write(f"  CONN {reqline}\n")
            sys.stderr.flush()
            rewritten = rewrite_host_headers(head)
            remote.sendall(rewritten + rest)
        else:
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
