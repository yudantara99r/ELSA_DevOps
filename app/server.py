"""Quote API with health checks and a Prometheus counter."""

import json
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CPU_MS = 100
QUOTES = (
    "Ship the smallest change that proves the system.",
    "A drain that still serves traffic is a successful drill.",
    "Measure a baseline before you choose a threshold.",
    "Keep one replica on capacity you do not expect to lose.",
    "Fail the pipeline on the finding, while the commit is still cheap.",
    "A read-only filesystem catches the write you did not intend.",
    "A soft spread still reschedules when a node disappears.",
    "Labels describe the pool. Taints decide who may enter.",
)

_lock = threading.Lock()
_requests = {}


def burn_cpu(ms):
    """Use CPU until the deadline. Sleep would not show up under load."""
    deadline = time.perf_counter() + (ms / 1000.0)
    value = 0
    while time.perf_counter() < deadline:
        value = (value * 31 + 1) & 0xFFFFFFFF
    return value


def record(path, code):
    with _lock:
        key = (path, str(code))
        _requests[key] = _requests.get(key, 0) + 1


def metrics_text():
    with _lock:
        items = sorted(_requests.items())
    lines = [
        "# HELP quote_requests_total HTTP responses served by the quote API.",
        "# TYPE quote_requests_total counter",
    ]
    if not items:
        lines.append('quote_requests_total{path="/api/quote",code="200"} 0')
    for (path, code), count in items:
        lines.append(
            'quote_requests_total{path="%s",code="%s"} %d' % (path, code, count)
        )
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self._reply(path, 200, "text/plain; charset=utf-8", b"ok\n")
        elif path == "/readyz":
            self._reply(path, 200, "text/plain; charset=utf-8", b"ready\n")
        elif path == "/metrics":
            record(path, 200)
            body = metrics_text().encode()
            self._write(200, "text/plain; version=0.0.4; charset=utf-8", body)
        elif path == "/api/quote":
            burn_cpu(CPU_MS)
            body = (json.dumps({"quote": random.choice(QUOTES)}) + "\n").encode()
            self._reply(path, 200, "application/json", body)
        else:
            self._reply(path, 404, "text/plain; charset=utf-8", b"not found\n")

    def _reply(self, path, code, content_type, body):
        record(path, code)
        self._write(code, content_type, body)

    def _write(self, code, content_type, body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def serve():
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    serve()
