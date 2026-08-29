"""Regenerate windows/runner/resources/app_icon.ico as the canonical
multi-size Windows ICO that *both* rc.exe and Inno Setup 6 accept.

Background
----------
``flutter build windows`` embeds ``app_icon.ico`` via ``rc.exe`` (see
``windows/runner/Runner.rc`` -> ``IDI_APP_ICON ICON "resources\\app_icon.ico"``).
Microsoft's resource compiler enforces one strict rule on the 256x256
icon entry: **it must be PNG-compressed**, not raw BMP. Storing the 256
entry as a raw 32-bpp BMP makes rc.exe abort with::

    RC2175 : icon file ... is not in a valid format

The universally-accepted Windows ICO layout — and the one emitted by
Visual Studio and Windows Explorer — is:

    16x16  -> 32-bpp BGRA BMP  (with AND mask)
    32x32  -> 32-bpp BGRA BMP  (with AND mask)
    48x48  -> 32-bpp BGRA BMP  (with AND mask)
    256x256 -> PNG (compressed)

This tool reads the high-res brand master and writes that exact layout,
preserving the teal / node-link EverLink look on every DPI.

Usage (from repo root)::

    python scripts/regenerate_windows_ico.py
    # or, after running once, override sources/versions:
    python scripts/regenerate_windows_ico.py --out path/to/out.ico
"""
from __future__ import annotations

import argparse
import io
import struct
import sys
from pathlib import Path

from PIL import Image

# Canonical Windows ICO layout: small sizes as raw 32-bpp BGRA BMP, 256 as PNG.
SPECS: list[tuple[int, str]] = [(16, "bmp"), (32, "bmp"), (48, "bmp"), (256, "png")]


def _bmp_entry(im: Image.Image) -> bytes:
    """Encode a 32-bpp BGRA BMP DIB with a zero AND mask (ICO-compatible)."""
    w, h = im.size
    px = im.load()
    # XOR: bottom-up BGRA rows.
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    # AND mask: 1 bpp monochrome, one byte per pixel-row-padded-to-4-bytes.
    # All zeros -> "no mask transparency" (alpha channel carries transparency).
    and_mask = bytearray(((w + 31) // 32) * 4 * h)
    # BITMAPINFOHEADER: biHeight = 2 * h because the AND mask follows the XOR.
    dib = struct.pack(
        "<IiiHHIIiiII",
        40,         # biSize
        w,          # biWidth
        2 * h,      # biHeight (XOR + AND, bottom-up)
        1,          # biPlanes
        32,         # biBitCount
        0,          # biCompression (BI_RGB)
        len(xor),   # biSizeImage
        0, 0, 0, 0, # ppm, clr used/important
    )
    return bytes(dib) + bytes(xor) + bytes(and_mask)


def _png_entry(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def build_canonical_ico(master: Image.Image) -> bytes:
    """Assemble the canonical multi-size ICO from a high-res RGBA master."""
    dir_entries: list[bytes] = []
    bodies: list[bytes] = []
    data_offset = 6 + 16 * len(SPECS)
    for size, kind in SPECS:
        if kind == "bmp":
            data = _bmp_entry(master.resize((size, size), Image.LANCZOS))
            w = b = size
        else:  # "png"
            data = _png_entry(master)
            w = b = 0  # 0 means 256 in ICONDIRENTRY
        dir_entries.append(
            struct.pack(
                "<BBBBHHII",
                w & 0xFF, b & 0xFF, 0, 0,  # width, height, colorCount, reserved
                1, 32,                       # planes, bitCount
                len(data), data_offset,      # bytesInRes, imageOffset
            )
        )
        bodies.append(data)
        data_offset += len(data)
    header = struct.pack("<HHH", 0, 1, len(SPECS))  # reserved, type=1, count
    return header + b"".join(dir_entries) + b"".join(bodies)


def _verify(ico_bytes: bytes) -> None:
    """Parse and print the ICONDIR entries — cheap structural sanity check."""
    reserved, type_, count = struct.unpack("<HHH", ico_bytes[:6])
    if (reserved, type_) != (0, 1):
        raise SystemExit(f"bad ICONDIR header: reserved={reserved} type={type_}")
    off = 6
    for i in range(count):
        w, b, _cc, _rsv, planes, bpp, size, offset = struct.unpack(
            "<BBBBHHII", ico_bytes[off:off + 16]
        )
        sig = ico_bytes[offset:offset + 8]
        is_png = sig[:8] == b"\x89PNG\r\n\x1a\n"
        print(
            f"  #{i} {w or 256:>3}x{b or 256:<3} bpp={bpp:<2} bytes={size:<6} "
            f"{'PNG' if is_png else 'BMP'}"
        )
        off += 16


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--master",
        default=str(repo_root / "assets" / "icon" / "icon_source.png"),
        help="High-res RGBA source PNG (default: assets/icon/icon_source.png)",
    )
    parser.add_argument(
        "--out",
        default=str(repo_root / "windows" / "runner" / "resources" / "app_icon.ico"),
        help="Output ICO path (default: windows/runner/resources/app_icon.ico)",
    )
    args = parser.parse_args()

    master = Image.open(args.master).convert("RGBA")
    if master.size[0] < 256 or master.size[1] < 256:
        print(
            f"warning: master {master.size} is smaller than 256; "
            "upscaling will soften the 256x256 entry.",
            file=sys.stderr,
        )

    ico = build_canonical_ico(master)
    Path(args.out).write_bytes(ico)
    print(f"wrote {args.out} ({len(ico)} bytes)")
    _verify(ico)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
