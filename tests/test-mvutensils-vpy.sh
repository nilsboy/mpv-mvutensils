#!/usr/bin/env bash
# Run synthetic YUV clips through mvutensils.vpy with vspipe and check that
# MVUtensils raises the frame rate to the configured target, including
# per-invocation overrides passed through mpv's `user-data` mechanism.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPY="$REPO_ROOT/vapoursynth/mvutensils.vpy"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v vspipe >/dev/null; then
    echo "SKIP: vspipe not installed"
    exit 0
fi

echo "==> syntax check"
python3 -c "import ast,sys; ast.parse(open('$VPY').read())"

# mpv provides video_in and container_fps; emulate both for vspipe. The clip is
# small and short so the CPU-only search finishes quickly, but large enough for
# MVUtensils' hierarchical pyramid. The user_data variable mirrors mpv's
# `user-data` suboption.
write_harness() {
    local out="$1" user_data="$2"
    cat > "$out" <<EOF
import vapoursynth as vs
import numpy as np
core = vs.core
W, H, L = 192, 128, 4
base = core.std.BlankClip(width=W, height=H, length=L, fpsnum=24, fpsden=1,
                          format=vs.YUV420P8)
_yy, _xx = np.mgrid[0:H, 0:W]
def draw(n, f):
    out = f.copy()
    shift = (n * 11) % 64
    pat = (((_xx + shift) * 3 + (_yy + shift) * 5) % 256).astype(np.uint8)
    np.frombuffer(out[0], dtype=np.uint8)[:] = pat.reshape(-1)
    return out
video_in = core.std.ModifyFrame(base, base, draw)
video_in = core.std.SetFrameProps(video_in, _Matrix=6, _Range=1)
container_fps = 24.0
user_data = $user_data
exec(compile(open("$VPY").read(), "$VPY", "exec"))
EOF
}

info_for() {
    local harness="$1"
    if ! vspipe --info "$harness" > "$WORK/info.txt" 2> "$WORK/err.txt"; then
        if grep -qiE "no function named|LoadPlugin|mvu|mvutensils" "$WORK/err.txt"; then
            echo "SKIP: MVUtensils plugin not available"
            cat "$WORK/err.txt"
            exit 0
        fi
        echo "FAIL: vspipe failed"
        cat "$WORK/err.txt"
        exit 1
    fi
}

check() {
    local label="$1" harness="$2" want_frames="$3" want_fps="$4"
    info_for "$harness"
    local frames fps
    frames="$(sed -n 's/^Frames: //p' "$WORK/info.txt")"
    fps="$(sed -n 's/^FPS: //p' "$WORK/info.txt")"
    if [[ "$frames" != "$want_frames" ]]; then
        echo "FAIL: $label: expected $want_frames frames, got '$frames'"
        cat "$WORK/info.txt"
        exit 1
    fi
    if [[ "$fps" != "$want_fps"* ]]; then
        echo "FAIL: $label: expected fps '$want_fps', got '$fps'"
        exit 1
    fi
    echo "PASS: $label -> $frames frames @$fps"
}

# Default: 4 frames at 24 fps, absolute 60 fps target -> 10 frames.
echo "==> default target"
write_harness "$WORK/default.vpy" '""'
check "default" "$WORK/default.vpy" "10" "60/1"

# Absolute override via a bare number, as passed to mpv's user-data.
echo "==> user-data bare 48 (absolute fps)"
write_harness "$WORK/u48.vpy" '"48"'
check "user-data=48" "$WORK/u48.vpy" "8" "48/1"

# Named fps override.
echo "==> user-data fps=48"
write_harness "$WORK/fps48.vpy" '"fps=48"'
check "user-data=fps=48" "$WORK/fps48.vpy" "8" "48/1"

# Rational target rate (NTSC film). FlowFPS floors the output length, so
# 4 source frames at 29.97 fps is 4 full output frames.
echo "==> user-data fps=30000/1001"
write_harness "$WORK/ntsc.vpy" '"fps=30000/1001"'
check "user-data=fps=30000/1001" "$WORK/ntsc.vpy" "4" "30000/1001"

# Multiplier form: 24 fps x 3 = 72 fps.
echo "==> user-data rate=3"
write_harness "$WORK/rate3.vpy" '"rate=3"'
check "user-data=rate=3" "$WORK/rate3.vpy" "12" "72/1"

# Multiple tokens, as mpv passes them (semicolon separated).
echo "==> user-data fps=48;preset=balanced"
write_harness "$WORK/multi.vpy" '"fps=48;preset=balanced"'
check "user-data=fps=48;preset=balanced" "$WORK/multi.vpy" "8" "48/1"

# The "realtime" preset changes search effort, not the output rate.
echo "==> user-data preset=realtime"
write_harness "$WORK/rt.vpy" '"48;preset=realtime"'
check "user-data=48;preset=realtime" "$WORK/rt.vpy" "8" "48/1"

# scale=0.5 keeps the output size and rate.
echo "==> user-data scale=0.5 keeps the output size and rate"
write_harness "$WORK/scale.vpy" '"48;scale=0.5"'
check "user-data=48;scale=0.5" "$WORK/scale.vpy" "8" "48/1"
info_for "$WORK/scale.vpy"
width="$(sed -n 's/^Width: //p' "$WORK/info.txt")"
height="$(sed -n 's/^Height: //p' "$WORK/info.txt")"
if [[ "$width" != "192" || "$height" != "128" ]]; then
    echo "FAIL: scale produced ${width}x${height}, expected 192x128"
    exit 1
fi
echo "PASS: scale kept ${width}x${height}"

# A block-size override must still produce the configured rate.
echo "==> user-data block=32"
write_harness "$WORK/block.vpy" '"48;block=32"'
check "user-data=block=32" "$WORK/block.vpy" "8" "48/1"

# refine=1 adds a Recalculate pass and must still produce the configured rate.
echo "==> user-data refine=1"
write_harness "$WORK/refine.vpy" '"48;refine=1"'
check "user-data=refine=1" "$WORK/refine.vpy" "8" "48/1"

# A block size with no matching overlap must not abort playback: the script
# clamps overlap, so the rate target still applies.
echo "==> user-data block=4 clamps overlap"
write_harness "$WORK/block4.vpy" '"48;block=4"'
check "user-data=block=4" "$WORK/block4.vpy" "8" "48/1"

# A tiny source cannot build the search pyramid; the script passes frames
# through instead of failing.
echo "==> tiny source falls back to passthrough"
cat > "$WORK/tiny.vpy" <<EOF
import vapoursynth as vs
core = vs.core
video_in = core.std.BlankClip(width=4, height=4, length=4, fpsnum=24,
                              fpsden=1, format=vs.YUV420P8)
container_fps = 24.0
user_data = ""
exec(compile(open("$VPY").read(), "$VPY", "exec"))
EOF
info_for "$WORK/tiny.vpy"
frames="$(sed -n 's/^Frames: //p' "$WORK/info.txt")"
fps="$(sed -n 's/^FPS: //p' "$WORK/info.txt")"
if [[ "$frames" != "4" || "$fps" != "24/1"* ]]; then
    echo "FAIL: tiny passthrough: got $frames frames @$fps, expected 4 @24/1"
    exit 1
fi
echo "PASS: tiny passthrough -> $frames frames @$fps"

echo "PASS: user-data overrides are honoured"
