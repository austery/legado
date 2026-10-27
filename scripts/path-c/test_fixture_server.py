"""Loopback fixtures must not depend on the hosted runner's reverse DNS."""
from http.client import HTTPConnection
import json
from threading import Thread
import unittest
from unittest.mock import patch

from boundary_fixture_server import BoundaryHandler
from engine_fixture_server import EngineHandler
from fixture_server import FixtureServer, Handler


class FixtureStartupTest(unittest.TestCase):
    def test_both_fixtures_serve_http_without_reverse_dns(self) -> None:
        for handler, endpoint, count in [(Handler, "/sources.json", 1),
                                         (EngineHandler, "/engine-sources.json", 9)]:
            with self.subTest(endpoint=endpoint):
                with patch("socket.getfqdn", side_effect=AssertionError("Reverse DNS unavailable")):
                    with FixtureServer(("127.0.0.1", 0), handler) as server:
                        worker = Thread(target=server.serve_forever, daemon=True)
                        worker.start()
                        connection = HTTPConnection("127.0.0.1", server.server_port, timeout=2)
                        try:
                            connection.request("GET", endpoint)
                            response = connection.getresponse()
                            self.assertEqual(response.status, 200)
                            sources = json.loads(response.read())
                            self.assertEqual(len(sources), count)
                            self.assertTrue(all(source["bookSourceUrl"].startswith("http://127.0.0.1:")
                                                for source in sources))
                        finally:
                            connection.close()
                            server.shutdown()
                            worker.join(timeout=2)


class FindRequestObservationTest(unittest.TestCase):
    def test_observer_counts_real_requests_without_counting_itself_or_other_books(self) -> None:
        with FixtureServer(("127.0.0.1", 0), BoundaryHandler) as server:
            worker = Thread(target=server.serve_forever, daemon=True); worker.start()
            connection = HTTPConnection("127.0.0.1", server.server_port, timeout=2)
            try:
                def read(path: str) -> bytes:
                    connection.request("GET", path)
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    return response.read()
                self.assertEqual(json.loads(read("/runs/find-observer/control/requests")), [])
                read("/runs/find-observer/sources.json")
                expected = ["/sources.json"]
                self.assertEqual(json.loads(read("/runs/find-observer/control/requests")), expected)
                self.assertEqual(json.loads(read("/runs/find-observer/control/requests")), expected)
                self.assertEqual(json.loads(read("/runs/find-other/control/requests")), [])
            finally:
                connection.close(); server.shutdown(); worker.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
