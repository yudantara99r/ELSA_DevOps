"""Checks the quote API without a cluster."""

import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import server


class QuoteApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        thread = threading.Thread(target=cls.httpd.serve_forever, daemon=True)
        thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def setUp(self):
        with server._lock:
            server._requests.clear()

    def get(self, path):
        url = "http://127.0.0.1:%d%s" % (self.port, path)
        started = time.perf_counter()
        with urllib.request.urlopen(url) as response:
            body = response.read()
            elapsed = time.perf_counter() - started
            return response.status, body, response.headers.get("Content-Type"), elapsed

    def test_health_and_ready(self):
        status, body, _, _ = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"ok\n")
        status, body, _, _ = self.get("/readyz")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"ready\n")

    def test_quote_burns_cpu_and_returns_json(self):
        status, body, content_type, elapsed = self.get("/api/quote")
        self.assertEqual(status, 200)
        self.assertIn("application/json", content_type)
        self.assertIn(json.loads(body)["quote"], server.QUOTES)
        self.assertGreaterEqual(elapsed, 0.09)
        self.assertLess(elapsed, 1.0)

    def test_metrics_counter(self):
        self.get("/api/quote")
        status, body, content_type, _ = self.get("/metrics")
        text = body.decode()
        self.assertEqual(status, 200)
        self.assertIn("version=0.0.4", content_type)
        self.assertIn("# TYPE quote_requests_total counter", text)
        self.assertIn('quote_requests_total{path="/api/quote",code="200"} 1', text)

    def test_unknown_path(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.get("/missing")
        self.assertEqual(caught.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
