#!/usr/bin/env bash
# Check that the snap bundles the MVUtensils plugin and its runtime deps, and
# installs it into the VapourSynth plugin directory so the autoloader finds it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="$REPO_ROOT/snap/snapcraft.yaml"
SNAP="${SNAP_FILE:-$(ls -1 "$REPO_ROOT"/dist/mpv-mvutensils_*.snap 2>/dev/null | head -1 || true)}"

fail=0
require() {
    local file="$1"
    local pattern="$2"
    if ! grep -qE "$pattern" "$file"; then
        echo "FAIL: $file is missing /$pattern/"
        fail=1
    fi
}

echo "==> snapcraft.yaml builds MVUtensils from source"
require "$YAML" 'myrsloik/mvutensils'
require "$YAML" 'python.purelibdir=/usr/lib/python3/dist-packages'

echo "==> snapcraft.yaml stages the MVUtensils runtime deps"
for pkg in libzimg2 libfftw3-single3; do
    require "$YAML" "^[[:space:]]*-[[:space:]]*$pkg[[:space:]]*$"
done

echo "==> launcher exposes the plugin directory to VapourSynth"
require "$REPO_ROOT/snap/bin/mpv-mvutensils" 'VAPOURSYNTH_EXTRA_PLUGIN_PATH'

if [[ -n "$SNAP" && -f "$SNAP" ]]; then
    if ! command -v unsquashfs >/dev/null; then
        echo "SKIP: unsquashfs not installed, cannot inspect $SNAP"
    else
        echo "==> $SNAP contains the MVUtensils plugin variant DLLs and manifest"
        listing="$(unsquashfs -l "$SNAP" 2>/dev/null)"
        for path in \
            'usr/lib/python3/dist-packages/vapoursynth/plugins/mvutensils/manifest.vs' \
            'usr/lib/python3/dist-packages/vapoursynth/plugins/mvutensils/mvutensils.so' \
            'usr/lib/python3/dist-packages/vapoursynth/plugins/mvutensils/mvutensils.avx2.so' \
            'usr/lib/python3/dist-packages/vapoursynth/plugins/mvutensils/mvutensils.zn4.so' \
            'usr/lib/python3/dist-packages/vapoursynth/libvsscript.so' \
            'usr/lib/x86_64-linux-gnu/libzimg.so.2' \
            'usr/lib/x86_64-linux-gnu/libfftw3f.so.3'; do
            if ! grep -q "$path" <<<"$listing"; then
                echo "FAIL: $SNAP is missing $path"
                fail=1
            fi
        done
    fi
else
    echo "SKIP: no snap in dist/, rebuild to inspect the payload"
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "PASS: snap ships the MVUtensils plugin"
