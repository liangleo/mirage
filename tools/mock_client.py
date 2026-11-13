#!/usr/bin/env python3
"""Minimal Mirage client used to verify the Mac helper.

Connects, sends the shared HELLO vector, waits for SESSION_CONFIG and at least
60 VIDEO frames, and checks that the first video frame is a keyframe.
"""
import json
import os
import socket
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECTORS = os.path.join(ROOT, "protocol", "vectors.json")


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 7777

    with open(VECTORS, "r", encoding="utf-8") as handle:
        hello = bytes.fromhex(json.load(handle)["hello"]["hex"])

    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(1.0)
    sock.sendall(hello)

    buffer = b""
    frames = 0
    first_keyframe = None
    config = None
    deadline = time.time() + 15

    while frames < 60 and time.time() < deadline:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        buffer += chunk

        while len(buffer) >= 4:
            length = struct.unpack(">I", buffer[:4])[0]
            if len(buffer) < 4 + length:
                break
            frame_type = buffer[4]
            payload = buffer[5:4 + length]
            buffer = buffer[4 + length:]

            if frame_type == 2 and len(payload) >= 11:
                width, height, fps, codec, bitrate, rotation = struct.unpack(">HHBBIB", payload[:11])
                config = (width, height, fps, codec, bitrate, rotation)
            elif frame_type == 3 and len(payload) >= 18:
                flags = payload[1]
                if first_keyframe is None:
                    first_keyframe = bool(flags & 1)
                frames += 1
            elif frame_type == 7 and len(payload) == 8:
                sock.sendall(struct.pack(">IB", 9, 7) + payload)

    sock.close()

    if config is None:
        print("FAIL: no SESSION_CONFIG received")
        return 1
    print(
        f"config={config[0]}x{config[1]}@{config[2]} codec={config[3]} "
        f"frames={frames} first_keyframe={1 if first_keyframe else 0}"
    )
    return 0 if frames >= 60 and first_keyframe else 1


if __name__ == "__main__":
    raise SystemExit(main())