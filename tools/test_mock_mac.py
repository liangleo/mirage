#!/usr/bin/env python3
"""Checks that mock_mac emits the same 18-byte VIDEO header as the apps."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mock_mac


class VideoHeaderTest(unittest.TestCase):
    def test_header_matches_protocol(self):
        payload = b"\x00\x00\x00\x01\x67\x42"
        frame = mock_mac.video_frame(7, 123_456, payload, keyframe=True)

        length = struct.unpack(">I", frame[:4])[0]
        self.assertEqual(length, 1 + 18 + len(payload))
        self.assertEqual(frame[4], 3)

        codec = frame[5]
        flags = frame[6]
        frame_id = struct.unpack(">I", frame[7:11])[0]
        timestamp = struct.unpack(">Q", frame[11:19])[0]
        reserved = struct.unpack(">I", frame[19:23])[0]

        self.assertEqual((codec, flags, frame_id, timestamp, reserved), (1, 1, 7, 123_456, 0))
        self.assertEqual(frame[23:], payload)


if __name__ == "__main__":
    unittest.main()