#!/usr/bin/env python3
"""Mock Mirage Mac server: streams an Annex-B H.264 file to one client.

Useful for developing the Android app without the real Mac helper.
"""
import argparse
import hashlib
import os
import socket
import ssl
import struct
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def split_annexb(data: bytes) -> list[bytes]:
    positions = []
    index = 0
    while True:
        found = data.find(b"\x00\x00\x01", index)
        if found < 0:
            break
        positions.append(found)
        index = found + 3

    nal_units = []
    for index, position in enumerate(positions):
        end = positions[index + 1] if index + 1 < len(positions) else len(data)
        nal = data[position + 3:end]
        if nal.endswith(b"\x00"):
            nal = nal[:-1]
        if nal:
            nal_units.append(nal)
    return nal_units


def group_frames(nal_units: list[bytes]) -> list[tuple[bytes, bool]]:
    frames = []
    group = []
    for nal in nal_units:
        group.append(nal)
        nal_type = nal[0] & 0x1F
        if nal_type in (1, 5):
            payload = b"".join(b"\x00\x00\x00\x01" + unit for unit in group)
            frames.append((payload, any((unit[0] & 0x1F) == 5 for unit in group)))
            group = []
    if group:
        payload = b"".join(b"\x00\x00\x00\x01" + unit for unit in group)
        frames.append((payload, any((unit[0] & 0x1F) == 5 for unit in group)))
    return frames


def frame_bytes(frame_type: int, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload) + 1) + bytes([frame_type]) + payload


def session_config(width: int, height: int, fps: int, bitrate: int) -> bytes:
    payload = struct.pack(">HHBBIB", width, height, fps, 1, bitrate, 0)
    return frame_bytes(2, payload)


def video_frame(frame_id: int, timestamp_us: int, payload: bytes, keyframe: bool) -> bytes:
    header = struct.pack(">BBIQI", 1, 1 if keyframe else 0, frame_id, timestamp_us, 0)
    return frame_bytes(3, header + payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--port", type=int, default=7777)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tls-cert", default=None)
    parser.add_argument("--tls-key", default=None)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=800)
    parser.add_argument("--bitrate", type=int, default=20_000_000)
    args = parser.parse_args()

    with open(args.file, "rb") as handle:
        frames = group_frames(split_annexb(handle.read()))
    if not frames:
        print("no frames parsed from", args.file)
        return 1

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(1)

    context = None
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        with open(args.tls_cert, "rb") as handle:
            pem = handle.read()
        der = ssl.PEM_cert_to_DER_cert(pem.decode())
        print("tls fingerprint=" + hashlib.sha256(der).hexdigest(), flush=True)
    print(f"listening={args.host}:{args.port} frames={len(frames)} fps={args.fps}", flush=True)

    while True:
        connection, _ = listener.accept()
        if context is not None:
            try:
                connection = context.wrap_socket(connection, server_side=True)
            except (ssl.SSLError, OSError) as error:
                print("tls handshake failed:", error, flush=True)
                connection.close()
                continue
            print("tls handshake ok", flush=True)
        connection.settimeout(0.01)
        print("client connected", flush=True)
        try:
            run_session(connection, frames, args)
        except (ConnectionError, OSError, TimeoutError) as error:
            print("client disconnected:", error, flush=True)
        finally:
            connection.close()


def run_session(connection: socket.socket, frames, args) -> None:
    buffer = b""
    hello_seen = False
    sent_config = False
    frame_id = 0
    index = 0
    period = 1.0 / args.fps
    next_send = time.monotonic()

    while True:
        try:
            chunk = connection.recv(65536)
            if not chunk:
                return
            buffer += chunk
        except socket.timeout:
            pass

        while len(buffer) >= 4:
            length = struct.unpack(">I", buffer[:4])[0]
            if len(buffer) < 4 + length:
                break
            frame_type = buffer[4]
            payload = buffer[5:4 + length]
            buffer = buffer[4 + length:]
            if frame_type == 1:
                hello_seen = True
                print("hello received", flush=True)
            elif frame_type == 7 and len(payload) == 8:
                connection.sendall(frame_bytes(7, payload))
            elif frame_type == 8:
                return

        if not hello_seen:
            time.sleep(0.005)
            continue

        if not sent_config:
            connection.sendall(session_config(args.width, args.height, args.fps, args.bitrate))
            print("config sent", flush=True)
            sent_config = True
            next_send = time.monotonic()

        now = time.monotonic()
        if now < next_send:
            time.sleep(min(next_send - now, 0.005))
            continue

        payload, keyframe = frames[index % len(frames)]
        timestamp_us = int((now - next_send) * 1_000_000)
        connection.sendall(video_frame(frame_id, max(0, timestamp_us), payload, keyframe))
        frame_id += 1
        index += 1
        next_send += period
        if next_send < now - 1.0:
            next_send = now


if __name__ == "__main__":
    raise SystemExit(main())