#!/usr/bin/env python3
"""Front a proxy-blind client with a local socket that tunnels through Squid.

Some clients ignore HTTP_PROXY entirely and open sockets directly. In the
sealed network that leaves them with no route at all: there is no egress and
external names do not even resolve.

This listens on a loopback address standing in for one real host, and forwards
each connection through the proxy with an ordinary CONNECT. The client's bytes
are relayed untouched, so TLS stays end to end and nothing is decrypted here.
The proxy's allowlist still decides: a CONNECT it refuses fails the connection,
exactly as a direct attempt would.

Hostnames map to loopback addresses through the compose file's extra_hosts, so
the client resolves and connects normally and needs no awareness of any of this.

Usage: proxy-tunnel.py <proxy-host:port> <bind-ip=hostname> [<bind-ip=hostname>...]
"""
import socket
import sys
import threading

PORTS = (80, 443)
CONNECT_TIMEOUT = 30


def relay(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


def open_tunnel(proxy_host, proxy_port, target_host, target_port):
    upstream = socket.create_connection((proxy_host, proxy_port), CONNECT_TIMEOUT)
    request = (
        f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
        f"Host: {target_host}:{target_port}\r\n"
        "Proxy-Connection: keep-alive\r\n\r\n"
    )
    upstream.sendall(request.encode())

    response = b""
    while b"\r\n\r\n" not in response:
        chunk = upstream.recv(4096)
        if not chunk:
            raise OSError("proxy closed the connection before answering CONNECT")
        response += chunk
        if len(response) > 65536:
            raise OSError("proxy sent an oversized CONNECT response")

    status = response.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    if " 200 " not in status:
        # A refusal here is the allowlist working, so say which host was refused.
        raise OSError(f"proxy refused CONNECT to {target_host}:{target_port} ({status})")
    return upstream


def serve(bind_ip, port, target_host, proxy_host, proxy_port):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((bind_ip, port))
    listener.listen(64)
    print(f"proxy-tunnel: {bind_ip}:{port} -> {target_host}:{port} via proxy", flush=True)

    while True:
        client, _ = listener.accept()
        threading.Thread(
            target=handle, args=(client, target_host, port, proxy_host, proxy_port), daemon=True
        ).start()


def handle(client, target_host, port, proxy_host, proxy_port):
    try:
        upstream = open_tunnel(proxy_host, proxy_port, target_host, port)
    except OSError as exc:
        print(f"proxy-tunnel: {target_host}:{port} unavailable: {exc}", file=sys.stderr, flush=True)
        client.close()
        return
    threading.Thread(target=relay, args=(client, upstream), daemon=True).start()
    relay(upstream, client)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    proxy_host, _, proxy_port = sys.argv[1].partition(":")
    proxy_port = int(proxy_port or 3128)

    for mapping in sys.argv[2:]:
        bind_ip, _, target_host = mapping.partition("=")
        if not bind_ip or not target_host:
            print(f"proxy-tunnel: bad mapping {mapping!r}, want <bind-ip>=<hostname>", file=sys.stderr)
            return 2
        for port in PORTS:
            threading.Thread(
                target=serve,
                args=(bind_ip, port, target_host, proxy_host, proxy_port),
                daemon=True,
            ).start()

    threading.Event().wait()
    return 0


if __name__ == "__main__":
    sys.exit(main())
