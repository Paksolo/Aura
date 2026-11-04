"""EchoSight standalone backend test client.

Generates a small sample PNG (no imaging deps required) and POSTs it to
POST http://localhost:8000/assist, then prints the server response.

Run:
    python test_client.py [--url http://localhost:8000/assist] [--query "..."]
                         [--api-key ...]
"""

import argparse
import os
import struct
import sys
import tempfile
import zlib

import requests


def write_sample_png(path: str, width: int = 128, height: int = 128) -> str:
    """Write a small RGB gradient PNG using only the standard library."""

    def chunk(chunk_type: bytes, data: bytes) -> bytes:
        body = chunk_type + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (None) for each scanline
        for x in range(width):
            r = int(255 * x / max(width - 1, 1))
            g = int(255 * y / max(height - 1, 1))
            b = 128
            raw.extend((r, g, b))

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw)))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Test the EchoSight /assist endpoint.")
    parser.add_argument(
        "--url", default="http://localhost:8000/assist", help="Full /assist URL."
    )
    parser.add_argument(
        "--query",
        default="What is in front of me? Any hazards?",
        help="Question sent alongside the image.",
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("ASSIST_API_KEY", ""),
        help="Bearer key (only needed when the server sets ASSIST_API_KEY).",
    )
    args = parser.parse_args()

    fd, sample_path = tempfile.mkstemp(prefix="echosight_sample_", suffix=".png")
    os.close(fd)
    write_sample_png(sample_path)
    print(f"Generated sample image: {sample_path}")

    headers = {"Authorization": f"Bearer {args.api_key}"} if args.api_key else None
    with open(sample_path, "rb") as fh:
        files = {"image": ("echosight_sample.png", fh, "image/png")}
        data = {"query": args.query}
        try:
            response = requests.post(
                args.url, data=data, files=files, headers=headers, timeout=120
            )
        except requests.RequestException as exc:
            print(f"Request failed: {exc}")
            return 1

    print(f"Status: {response.status_code}")
    try:
        payload = response.json()
    except ValueError:
        print("Non-JSON response body:")
        print(response.text)
        return 1

    print("Response JSON:")
    print(payload)
    if isinstance(payload, dict) and "spoken_guidance" in payload:
        print(f"\nSpoken guidance: {payload['spoken_guidance']}")
    return 0 if response.ok else 1


if __name__ == "__main__":
    sys.exit(main())
