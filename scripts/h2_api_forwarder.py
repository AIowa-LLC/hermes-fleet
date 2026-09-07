#!/usr/bin/env python3
"""H2 device-test fixture: LAN-reachable TCP forwarder for the api_server.

The real api_server binds 127.0.0.1 + 100.100.105.61 only. The phone's ATS
exempts RFC1918 LAN HTTP (NSAllowsLocalNetworking) but NOT the CGNAT tailnet
range — so the on-device doctor probe needs the REST surface reachable over
the LAN. This forwards 0.0.0.0:18642 -> 127.0.0.1:8642 (the real surface).

Usage: python3 h2_api_forwarder.py [--lifetime-secs N]
"""
import socket, threading, sys, time

LISTEN = ("0.0.0.0", 18642)
TARGET = ("100.100.105.61", 8642)


def pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try: src.close()
        except OSError: pass
        try: dst.close()
        except OSError: pass


def main() -> None:
    lifetime = 0
    if "--lifetime-secs" in sys.argv:
        lifetime = int(sys.argv[sys.argv.index("--lifetime-secs") + 1])

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN)
    srv.listen(8)
    print(f"h2 forwarder {LISTEN} -> {TARGET}", flush=True)
    if lifetime:
        threading.Timer(lifetime, lambda: (srv.close(), sys.exit(0))).start()
    while True:
        conn, _peer = srv.accept()
        up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            up.connect(TARGET)
        except OSError:
            conn.close()
            continue
        threading.Thread(target=pipe, args=(conn, up), daemon=True).start()
        threading.Thread(target=pipe, args=(up, conn), daemon=True).start()


if __name__ == "__main__":
    main()
