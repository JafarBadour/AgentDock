"""Fit prompt images into what the agent APIs accept.

The phone ships images as picked (up to a transfer cap). Agents reject
payloads over ~5 MB base64, sides past 8000 px, and anything other than
JPEG / PNG / GIF / WebP — so shrink or convert here, on the host, before the
image reaches ACP.

No hard dependency: tries Pillow, then ImageMagick, macOS `sips`, `ffmpeg`.
When none can help, the image passes through unchanged and the agent decides.
"""

from __future__ import annotations

import base64
import binascii
import os
import shutil
import struct
import subprocess
import tempfile
from typing import Callable, List, Optional, Tuple

# Decoded bytes; base64 of this stays under the 5 MB API limit.
MAX_BYTES = 3_750_000
# Longest side after a resize. Agents downscale past ~1568 px anyway.
MAX_EDGE = 2000
# Sides beyond this are rejected outright by the Claude API.
HARD_MAX_EDGE = 8000
SUPPORTED_MIMES = ("image/jpeg", "image/png", "image/gif", "image/webp")

_TIMEOUT_S = 30


def image_size(raw: bytes) -> Optional[Tuple[int, int]]:
    """(width, height) from a PNG / GIF / JPEG / WebP header, else None."""
    try:
        if raw[:8] == b"\x89PNG\r\n\x1a\n" and len(raw) >= 24:
            w, h = struct.unpack(">II", raw[16:24])
            return w, h
        if raw[:6] in (b"GIF87a", b"GIF89a") and len(raw) >= 10:
            w, h = struct.unpack("<HH", raw[6:10])
            return w, h
        if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
            chunk = raw[12:16]
            if chunk == b"VP8X" and len(raw) >= 30:
                w = int.from_bytes(raw[24:27], "little") + 1
                h = int.from_bytes(raw[27:30], "little") + 1
                return w, h
            if chunk == b"VP8 " and len(raw) >= 30:
                w, h = struct.unpack("<HH", raw[26:30])
                return w & 0x3FFF, h & 0x3FFF
            if chunk == b"VP8L" and len(raw) >= 25:
                bits = int.from_bytes(raw[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            return None
        if raw[:2] == b"\xff\xd8":
            i = 2
            while i + 9 < len(raw):
                if raw[i] != 0xFF:
                    i += 1
                    continue
                marker = raw[i + 1]
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                seg_len = struct.unpack(">H", raw[i + 2 : i + 4])[0]
                # SOF0..SOF15, minus DHT / JPG / DAC.
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    h, w = struct.unpack(">HH", raw[i + 5 : i + 9])
                    return w, h
                i += 2 + seg_len
    except (struct.error, IndexError):
        return None
    return None


def sniff_mime(raw: bytes) -> Optional[str]:
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if raw[:2] == b"\xff\xd8":
        return "image/jpeg"
    if raw[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return "image/webp"
    return None


def needs_fit(raw: bytes, mime: str) -> bool:
    if mime not in SUPPORTED_MIMES:
        return True
    if len(raw) > MAX_BYTES:
        return True
    size = image_size(raw)
    return size is not None and max(size) > HARD_MAX_EDGE


def fit_image(data_b64: str, mime: str) -> Tuple[str, str]:
    """Return (base64, mime) the agent will accept, or the input unchanged."""
    try:
        raw = base64.b64decode(data_b64, validate=False)
    except (binascii.Error, ValueError):
        return data_b64, mime
    mime = sniff_mime(raw) or (mime or "image/jpeg").lower()
    if not needs_fit(raw, mime):
        return data_b64, mime
    out = _shrink(raw)
    if out is None:
        return data_b64, mime
    return base64.b64encode(out).decode("ascii"), "image/jpeg"


def _shrink(raw: bytes) -> Optional[bytes]:
    """Re-encode as JPEG, longest side <= MAX_EDGE, under MAX_BYTES."""
    for edge, quality in ((MAX_EDGE, 85), (MAX_EDGE, 70), (1400, 70), (1000, 60)):
        out = None
        for backend in _BACKENDS:
            try:
                out = backend(raw, edge, quality)
            except Exception:  # noqa: BLE001 — try the next tool
                out = None
            if out:
                break
        if not out:
            return None  # no tool could decode it; retrying smaller won't help
        if len(out) <= MAX_BYTES:
            return out
    return None


def _pillow(raw: bytes, edge: int, quality: int) -> Optional[bytes]:
    try:
        from io import BytesIO

        from PIL import Image  # type: ignore
    except ImportError:
        return None
    with Image.open(BytesIO(raw)) as img:
        img.seek(0)
        img = img.convert("RGB")
        img.thumbnail((edge, edge))
        buf = BytesIO()
        img.save(buf, "JPEG", quality=quality, optimize=True)
        return buf.getvalue()


def _cli(argv_for: Callable[[str, str, int, int], Optional[List[str]]]):
    def run(raw: bytes, edge: int, quality: int) -> Optional[bytes]:
        with tempfile.TemporaryDirectory(prefix="adsm-img-") as tmp:
            src = os.path.join(tmp, "in")
            dst = os.path.join(tmp, "out.jpg")
            with open(src, "wb") as f:
                f.write(raw)
            argv = argv_for(src, dst, edge, quality)
            if not argv:
                return None
            subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=_TIMEOUT_S,
                check=True,
            )
            with open(dst, "rb") as f:
                return f.read() or None

    return run


def _magick_argv(src: str, dst: str, edge: int, quality: int) -> Optional[List[str]]:
    exe = shutil.which("magick") or shutil.which("convert")
    if not exe:
        return None
    return [
        exe,
        src + "[0]",
        "-auto-orient",
        "-resize",
        f"{edge}x{edge}>",
        "-quality",
        str(quality),
        "jpeg:" + dst,
    ]


def _sips_argv(src: str, dst: str, edge: int, quality: int) -> Optional[List[str]]:
    exe = shutil.which("sips")
    if not exe:
        return None
    argv = [exe, "-s", "format", "jpeg", "-s", "formatOptions", str(quality)]
    # `-Z` also upscales, so only pass it when the image is actually bigger.
    if _sips_longest_side(exe, src) > edge:
        argv += ["-Z", str(edge)]
    return argv + [src, "--out", dst]


def _sips_longest_side(exe: str, src: str) -> int:
    """Longest side per `sips -g`, or a huge value when it can't tell."""
    try:
        out = subprocess.run(
            [exe, "-g", "pixelWidth", "-g", "pixelHeight", src],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=_TIMEOUT_S,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return 1 << 30
    sides = [
        int(line.split(":", 1)[1])
        for line in out.splitlines()
        if line.strip().startswith(("pixelWidth:", "pixelHeight:"))
        and line.split(":", 1)[1].strip().isdigit()
    ]
    return max(sides) if len(sides) == 2 else 1 << 30


def _ffmpeg_argv(src: str, dst: str, edge: int, quality: int) -> Optional[List[str]]:
    exe = shutil.which("ffmpeg")
    if not exe:
        return None
    # ffmpeg's JPEG qscale: 2 (best) .. 31 (worst).
    q = max(2, min(31, round(2 + (100 - quality) * 29 / 100)))
    scale = (
        f"scale='if(gt(iw,ih),min({edge},iw),-2)':'if(gt(iw,ih),-2,min({edge},ih))'"
    )
    return [
        exe,
        "-nostdin",
        "-loglevel",
        "error",
        "-y",
        "-i",
        src,
        "-frames:v",
        "1",
        "-vf",
        scale,
        "-q:v",
        str(q),
        dst,
    ]


_BACKENDS = (_pillow, _cli(_magick_argv), _cli(_sips_argv), _cli(_ffmpeg_argv))
