#!/usr/bin/env python3
"""Exercise real Puma workers against an empty, disposable database."""
import http.client
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def check():
    with tempfile.TemporaryDirectory(prefix="muni-http-security-") as scratch:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        env = {key: value for key, value in os.environ.items() if not key.startswith("MUNI_")}
        env.update(RACK_ENV="production", MUNI_DB_PATH=f"{scratch}/muni.sqlite3",
                   MUNI_WEB_THREADS="0:5", MUNI_LOG_LEVEL="error")
        sockets = []
        with open(f"{scratch}/server.log", "w+") as log:
            process = subprocess.Popen(
                ["bundle", "exec", "muni", "serve", "--bind=127.0.0.1", f"--port={port}"],
                cwd=Path(__file__).resolve().parent.parent, env=env, stdout=log, stderr=log,
            )
            try:
                for attempt in range(100):
                    try:
                        health(port)
                        break
                    except (OSError, http.client.HTTPException):
                        if process.poll() is not None or attempt == 99:
                            log.seek(0)
                            raise RuntimeError(f"Test server failed to start: {log.read()}") from None
                        time.sleep(0.1)
                for _ in range(10):
                    client = socket.create_connection(("127.0.0.1", port), timeout=2)
                    client.sendall(b"GET /stream/cambridge/service_requests HTTP/1.1\r\n"
                                   b"Host: localhost\r\n\r\n")
                    sockets.append(client)
                time.sleep(0.2)
                health(port)
                for client in sockets:
                    client.close()
                sockets.clear()
                health(port)
                print("HTTP security: health stays available with 10 idle stream clients and after disconnect.")
            finally:
                for client in sockets:
                    client.close()
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def health(port):
    client = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        client.request("GET", "/healthz")
        response = client.getresponse()
        assert response.status == 200, f"Health returned {response.status}"
        response.read()
    finally:
        client.close()


if __name__ == "__main__":
    check()
