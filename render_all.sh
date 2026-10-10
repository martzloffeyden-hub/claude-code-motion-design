#!/usr/bin/env bash
# Renders every shot of SINGULARITY at final quality (1920x1080, 60 fps) into
# lossless-ish intermediate segments, then assembles the final MP4.
# Needs an X display for the GL context (Xvfb works) — llvmpipe is fine.
set -euo pipefail
cd "$(dirname "$0")"
export DISPLAY="${DISPLAY:-:99}"
if ! pgrep -f "Xvfb $DISPLAY" >/dev/null 2>&1; then (Xvfb "$DISPLAY" -screen 0 1920x1080x24 >/dev/null 2>&1 &); sleep 1; fi
SHOTS="${SHOTS:-void emerge anatomy distort collapse final}"
for s in $SHOTS; do
  echo "=== rendering $s ==="
  python3 src/render.py --shot "$s" --crf 8
done
[ "${SKIP_ASSEMBLE:-0}" = "1" ] && exit 0
python3 src/sound_design.py
python3 src/assemble.py
