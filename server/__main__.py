"""Run with python3 -m server from the repository root."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from pathlib import Path
import signal
import threading
from urllib.parse import parse_qs, urlsplit

from .cache import SnapshotCache
from .context import ContextBuilder, ContextQuery
from .espn_provider import ESPNProvider
from .scheduler import RefreshService


class BoundedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.slots = threading.BoundedSemaphore(16)

    def process_request(self, request, client_address):
        request.settimeout(15)
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def handler_for(builder: ContextBuilder):
    class Handler(BaseHTTPRequestHandler):
        server_version = "NFLPulseContext/0.2"

        def do_GET(self):
            if len(self.path) > 2048:
                self.respond(414, {"error": "Request URL exceeds size limit"})
                return
            parsed = urlsplit(self.path)
            if parsed.path == "/health":
                self.respond(200, builder.health())
            elif parsed.path == "/v1/context":
                try:
                    arguments = parse_qs(parsed.query, keep_blank_values=True, max_num_fields=16)
                    query = ContextQuery.parse(arguments)
                    context = builder.build(query)
                    self.respond(200, context)
                except ValueError as error:
                    self.respond(400, {"error": str(error)})
                except Exception:
                    logging.exception("Context could not be assembled")
                    self.respond(500, {"error": "Context unavailable"})
            else:
                self.respond(404, {"error": "Not found"})

        def do_POST(self):
            self.respond(405, {"error": "Read-only service; use GET"})

        do_PUT = do_POST
        do_DELETE = do_POST
        do_PATCH = do_POST

        def respond(self, status: int, body: dict):
            data = json.dumps(body, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, format, *args):
            # Don't retain player names or client query parameters in ordinary logs.
            logging.info("HTTP request from %s", self.client_address[0])

    return Handler


def main():
    parser = argparse.ArgumentParser(description="NFLPulse automatic public-data context backend")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--cache", type=Path, default=None, help="Exact cache-file path")
    parser.add_argument("--cache-dir", type=Path, default=Path("server/data"))
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    service = RefreshService(ESPNProvider(), SnapshotCache(arguments.cache or arguments.cache_dir / "context-cache.json"))
    builder = ContextBuilder(service)
    httpd = BoundedHTTPServer((arguments.host, arguments.port), handler_for(builder))
    service.start()

    def shutdown(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    logging.info("Context backend listening on %s:%d", arguments.host, arguments.port)
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.server_close()
        service.close()


if __name__ == "__main__":
    main()
