#!/usr/bin/env bash
# Generate an Annex-B H.264 test stream without B-frames and with repeated
# parameter sets, suitable for tools/mock_mac.py.
set -euo pipefail

out="${1:-/tmp/mirage_test.h264}"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1280x800:rate=60 -t 10 \
  -c:v libx264 -profile:v high -bf 0 -g 600 -pix_fmt yuv420p \
  -x264-params repeat-headers=1 \
  -f h264 "$out"

echo "wrote $out"