#!/bin/zsh
# Builds Windows/Chipng/Assets/Chipng.ico (+ a 64px PNG for the title bar)
# from Resources/AppIcon.icns. Run Scripts/make-icon.swift first if the art changed.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
for s in 16 20 24 32 40 48 64 128 256; do
  sips -s format png -z $s $s Resources/AppIcon.icns --out "$TMP/$s.png" >/dev/null
done
cp "$TMP/64.png" Windows/Chipng/Assets/Chipng-64.png
python3 -I - "$TMP" Windows/Chipng/Assets/Chipng.ico <<'PY'
import struct, sys, os
src, out = sys.argv[1], sys.argv[2]
sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
images = [open(os.path.join(src, f"{s}.png"), "rb").read() for s in sizes]
header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, data = b"", b""
for s, img in zip(sizes, images):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(img), offset + len(data))
    data += img
open(out, "wb").write(header + entries + data)
PY
rm -rf "$TMP"
echo "✓ Windows/Chipng/Assets/Chipng.ico"
