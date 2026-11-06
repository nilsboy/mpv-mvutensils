#!/usr/bin/env bash
# Verify that MVUtensils actually synthesises motion-compensated in-between
# frames, not just repeats. MVUtensils is CPU-only, so this can run anywhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPY="$REPO_ROOT/vapoursynth/mvutensils.vpy"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v vspipe >/dev/null; then
    echo "SKIP: vspipe not installed"
    exit 0
fi

# A bright vertical bar jumps from x=8 (frame 0) to x=24 (frame 1). With a 2x
# rate the interpolated frame at the halfway point should place the bar near
# x=16, i.e. strictly between the two source positions. The script prints the
# detected bar centre for each output frame.
cat > "$WORK/motion.vpy" <<EOF
import vapoursynth as vs
import numpy as np
core = vs.core
W, H = 64, 64

def make(n, f):
    out = f.copy()
    np.frombuffer(out[0], dtype=np.uint8)[:] = 16
    x = 8 if n == 0 else 24
    plane = np.frombuffer(out[0], dtype=np.uint8).reshape(H, W)
    plane[:, x:x + 4] = 235
    return out

base = core.std.BlankClip(width=W, height=H, length=2, fpsnum=24, fpsden=1,
                          format=vs.YUV420P8)
src = core.std.ModifyFrame(base, base, make)
video_in = src
container_fps = 24.0
# Use the accurate preset so the single moving edge is resolved; the fast
# presets trade this precision for speed.
user_data = "rate=2;preset=quality"

# Capture the node the script sets as output without disturbing it.
captured = {}
_orig_set_output = vs.VideoNode.set_output
def _capture(self, *args, **kwargs):
    captured["node"] = self
    return _orig_set_output(self, *args, **kwargs)
vs.VideoNode.set_output = _capture

exec(compile(open("$VPY").read(), "$VPY", "exec"))

smooth = captured["node"]
for n in range(smooth.num_frames):
    f = smooth.get_frame(n)
    p = np.frombuffer(f[0], dtype=np.uint8).reshape(H, W)
    col = int((p > 128).any(axis=0).nonzero()[0][0])
    props = f.props
    print("FRAME %d bar=%d" % (n, col))
EOF

if ! vspipe --info "$WORK/motion.vpy" >/dev/null 2> "$WORK/err.txt"; then
    echo "FAIL: vspipe could not build the interpolation graph"
    cat "$WORK/err.txt"
    exit 1
fi

# The script's prints only run at frame-request time; vspipe --info does not
# evaluate frames, so request them by writing to a null sink.
vspipe "$WORK/motion.vpy" -- > "$WORK/out.txt" 2> "$WORK/err.txt" || true
if ! grep -q "FRAME" "$WORK/out.txt"; then
    echo "FAIL: no frame measurements captured"
    cat "$WORK/out.txt" "$WORK/err.txt"
    exit 1
fi

bar0="$(sed -n 's/^FRAME 0 bar=//p' "$WORK/out.txt")"
bar1="$(sed -n 's/^FRAME 1 bar=//p' "$WORK/out.txt")"
bar2="$(sed -n 's/^FRAME 2 bar=//p' "$WORK/out.txt")"
echo "bar centres: frame0=$bar0 frame1=$bar1 frame2=$bar2"

if [[ "$bar0" != "8" ]]; then
    echo "FAIL: frame 0 bar at $bar0, expected 8"
    exit 1
fi
if [[ -z "$bar1" || "$bar1" -le 8 || "$bar1" -ge 24 ]]; then
    echo "FAIL: interpolated frame 1 bar at '$bar1', expected strictly between 8 and 24"
    exit 1
fi
if [[ "$bar2" != "24" ]]; then
    echo "FAIL: frame 2 bar at $bar2, expected 24"
    exit 1
fi

echo "PASS: MVUtensils synthesised a motion-compensated frame at $bar1"
