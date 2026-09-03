"""Unit tests for ADSM protocol helpers."""

from __future__ import annotations

import json
import unittest

from adsm import protocol


class ProtocolTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        raw = protocol.encode(protocol.ok(7, {"a": 1}))
        msg = protocol.decode_line(raw.decode("utf-8"))
        assert msg is not None
        self.assertEqual(msg["id"], 7)
        self.assertEqual(msg["result"]["a"], 1)

    def test_event(self) -> None:
        ev = protocol.event("chat-1", 3, "text", text="hi")
        self.assertEqual(ev["method"], "event")
        self.assertEqual(ev["params"]["seq"], 3)
        self.assertEqual(ev["params"]["kind"], "text")
        self.assertEqual(ev["params"]["text"], "hi")

    def test_assemble_chunk_payload_base64(self) -> None:
        import base64

        original = {"id": 9, "method": "ping", "params": {}}
        raw = json.dumps(original, separators=(",", ":")).encode("utf-8")
        b64 = base64.b64encode(raw).decode("ascii")
        mid = len(b64) // 2
        msg = protocol.assemble_chunk_payload([b64[:mid], b64[mid:]], encoding="base64")
        self.assertEqual(msg["id"], 9)
        self.assertEqual(msg["method"], "ping")

    def test_chunk_constants(self) -> None:
        self.assertLess(protocol.CHUNK_SOFT_LIMIT, 64 * 1024)
        self.assertEqual(protocol.CHUNK_METHOD, "rpc.chunk")
        self.assertEqual(protocol.VERSION, "0.4.2")


class ChunkIngestTest(unittest.TestCase):
    def test_ingest_reassembles_out_of_order(self) -> None:
        from adsm.daemon import Daemon

        d = Daemon()

        class _W:
            pass

        writer = _W()  # type: ignore[assignment]
        original = {"id": 3, "method": "ping", "params": {}}
        raw = json.dumps(original, separators=(",", ":")).encode("utf-8")
        import base64

        b64 = base64.b64encode(raw).decode("ascii")
        parts = [b64[:10], b64[10:20], b64[20:]]
        # Deliver 2, 0, 1
        self.assertIsNone(
            d._ingest_chunk(
                writer,  # type: ignore[arg-type]
                {"reqId": 3, "i": 2, "n": 3, "encoding": "base64", "data": parts[2]},
            )
        )
        self.assertIsNone(
            d._ingest_chunk(
                writer,  # type: ignore[arg-type]
                {"reqId": 3, "i": 0, "n": 3, "encoding": "base64", "data": parts[0]},
            )
        )
        msg = d._ingest_chunk(
            writer,  # type: ignore[arg-type]
            {"reqId": 3, "i": 1, "n": 3, "encoding": "base64", "data": parts[1]},
        )
        assert msg is not None
        self.assertEqual(msg["method"], "ping")
        self.assertEqual(msg["id"], 3)
        self.assertEqual(d._chunk_bufs, {})


class PathsTest(unittest.TestCase):
    def test_tmux_name_truncated(self) -> None:
        from adsm import paths

        long_id = "x" * 100
        name = paths.tmux_session_name(long_id)
        self.assertTrue(name.startswith("ad-"))
        self.assertLessEqual(len(name), 3 + 24)


if __name__ == "__main__":
    unittest.main()
