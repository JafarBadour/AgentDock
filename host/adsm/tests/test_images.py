"""Unit tests for host-side prompt image fitting."""

from __future__ import annotations


import base64
import os
import struct
import unittest
import zlib

from adsm import images


def _png(width: int, height: int, noisy: bool = False) -> bytes:
    """A valid RGB PNG built with the stdlib only."""
    row_len = width * 3
    rows = []
    for y in range(height):
        if noisy:
            row = os.urandom(row_len)
        else:
            row = bytes((x * 7 + y * 3) & 0xFF for x in range(row_len))
        rows.append(b"\x00" + row)
    raw = b"".join(rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body) & 0xFFFFFFFF
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 1))
        + chunk(b"IEND", b"")
    )


def _has_backend() -> bool:
    return images._shrink(_png(8, 8)) is not None


class ImageSizeTest(unittest.TestCase):
    def test_png(self) -> None:
        self.assertEqual(images.image_size(_png(31, 17)), (31, 17))

    def test_gif(self) -> None:
        raw = b"GIF89a" + struct.pack("<HH", 640, 480) + b"\x00" * 8
        self.assertEqual(images.image_size(raw), (640, 480))

    def test_jpeg_sof(self) -> None:
        app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
        sof0 = b"\xff\xc0" + struct.pack(">HBHH", 11, 8, 1200, 1600) + b"\x03"
        raw = b"\xff\xd8" + app0 + sof0 + b"\x00" * 16
        self.assertEqual(images.image_size(raw), (1600, 1200))

    def test_unknown(self) -> None:
        self.assertIsNone(images.image_size(b"not an image at all"))


class FitImageTest(unittest.TestCase):
    def test_small_supported_image_passes_through(self) -> None:
        data = base64.b64encode(_png(40, 30)).decode()
        self.assertEqual(images.fit_image(data, "image/png"), (data, "image/png"))

    def test_sniffed_mime_overrides_wrong_label(self) -> None:
        data = base64.b64encode(_png(4, 4)).decode()
        self.assertEqual(images.fit_image(data, "image/jpeg")[1], "image/png")

    def test_garbage_passes_through(self) -> None:
        self.assertEqual(images.fit_image("%%%", "image/png")[0], "%%%")

    def test_needs_fit(self) -> None:
        small = _png(4, 4)
        self.assertFalse(images.needs_fit(small, "image/png"))
        self.assertTrue(images.needs_fit(small, "image/heic"))
        self.assertTrue(images.needs_fit(b"x" * (images.MAX_BYTES + 1), "image/png"))

    @unittest.skipUnless(_has_backend(), "no image tool on this machine")
    def test_oversized_image_is_shrunk_to_jpeg(self) -> None:
        raw = _png(2400, 1800, noisy=True)
        self.assertGreater(len(raw), images.MAX_BYTES)
        data, mime = images.fit_image(base64.b64encode(raw).decode(), "image/png")
        out = base64.b64decode(data)
        self.assertEqual(mime, "image/jpeg")
        self.assertLessEqual(len(out), images.MAX_BYTES)
        w, h = images.image_size(out)
        self.assertLessEqual(max(w, h), images.MAX_EDGE)
        self.assertAlmostEqual(w / h, 2400 / 1800, delta=0.02)


if __name__ == "__main__":
    unittest.main()
