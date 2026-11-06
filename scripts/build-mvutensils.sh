#!/usr/bin/env bash
# Build and install MVUtensils into VapourSynth's plugin directory.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$BUILD_ROOT/mvutensils"

clone_repo "$MVUTENSILS_URL" "$SRC"

# VapourSynth is installed from a source tree, so meson's Python introspection
# can land plugins outside the interpreter's real site-packages. Pin both
# directories to the running interpreter's paths so mpv's runtime finds them.
VS_PURELIB="$("$(vs_python)" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
VS_PLATLIB="$("$(vs_python)" -c 'import sysconfig; print(sysconfig.get_paths()["platlib"])')"

meson setup "$SRC/build" "$SRC" \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Dpython.purelibdir="$VS_PURELIB" \
    -Dpython.platlibdir="$VS_PLATLIB"
ninja -C "$SRC/build" -j "$JOBS"
install_tree "MVUtensils installed" \
    ninja -C "$SRC/build" install

PLUGIN_DIR="$(vs_plugin_dir)/mvutensils"
echo "verify: $PLUGIN_DIR"
ls -1 "$PLUGIN_DIR"
"$(vs_python)" -c 'import vapoursynth as vs; print("namespace ok:", "mvu" in {p.namespace for p in vs.core.plugins()})'
