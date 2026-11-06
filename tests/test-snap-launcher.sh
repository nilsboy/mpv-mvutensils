#!/usr/bin/env bash
# Exercise the snap launcher's vapoursynth= argument handling without installing
# the snap. The relevant shell is extracted and run with a fake $SNAP tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_ROOT/snap/bin/mpv-mvutensils"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SNAP="$WORK/snap"
mkdir -p "$SNAP/vapoursynth"
: > "$SNAP/vapoursynth/mvutensils.vpy"

# Run the launcher's rewrite loop in isolation. The launcher execs mpv at the
# end, so extract the setup, loop and duplicate-filter removal.
sed -n '/^user_vf=0/,/^done$/p' "$LAUNCHER" > "$WORK/rewrite.sh"
sed -n '/^if \[ "\$user_vf" -eq 1 \]/,/^fi$/p' "$LAUNCHER" >> "$WORK/rewrite.sh"
printf '%s\n' 'printf "%s\n" "$@"' >> "$WORK/rewrite.sh"
if [[ ! -s "$WORK/rewrite.sh" ]]; then
    echo "FAIL: could not extract the rewrite logic from $LAUNCHER"
    exit 1
fi

rewrite() {
    # shellcheck disable=SC1090
    SNAP="$SNAP" sh -c '
        set -eu
        SNAP="'"$SNAP"'"
        . "'"$WORK"'/rewrite.sh"
    ' sh "$@"
}

fail=0
expect() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label"
        echo "  want: $want"
        echo "  got:  $got"
        fail=1
    else
        echo "PASS: $label"
    fi
}

echo "==> relative path resolves to the bundled script"
expect "relative path" \
    "$(cd / && rewrite 'vapoursynth=vapoursynth/mvutensils.vpy')" \
    "vapoursynth=$SNAP/vapoursynth/mvutensils.vpy
--vf-remove=@mvu"

echo "==> relative path with a user-data suboption keeps the suboption"
expect "path + user-data" \
    "$(cd / && rewrite 'vapoursynth=vapoursynth/mvutensils.vpy:user-data="fps=48"')" \
    "vapoursynth=$SNAP/vapoursynth/mvutensils.vpy:user-data=\"fps=48\"
--vf-remove=@mvu"

echo "==> a user-supplied filter drops the profile's duplicate @mvu"
expect "dedupe" \
    "$(cd / && rewrite --profile=mvu 'vapoursynth=vapoursynth/mvutensils.vpy')" \
    "--profile=mvu
vapoursynth=$SNAP/vapoursynth/mvutensils.vpy
--vf-remove=@mvu"

echo "==> an explicitly labelled @mvu override is left alone"
expect "labelled override" \
    "$(cd / && rewrite --vf-add='@mvu:vapoursynth=vapoursynth/mvutensils.vpy:user-data=30')" \
    "--vf-add=@mvu:vapoursynth=$SNAP/vapoursynth/mvutensils.vpy:user-data=30"

echo "==> absolute path is left alone"
expect "absolute path + user-data" \
    "$(cd / && rewrite 'vapoursynth=/somewhere/else.vpy:user-data=48')" \
    "vapoursynth=/somewhere/else.vpy:user-data=48
--vf-remove=@mvu"

echo "==> a path that exists in the cwd is not rewritten"
expect "cwd path" \
    "$(cd "$SNAP" && rewrite 'vapoursynth=vapoursynth/mvutensils.vpy')" \
    "vapoursynth=vapoursynth/mvutensils.vpy
--vf-remove=@mvu"

echo "==> no vapoursynth argument means no duplicate-filter removal"
expect "profile only" \
    "$(cd / && rewrite --profile=mvu video.mkv)" \
    "--profile=mvu
video.mkv"

echo "==> unrelated arguments are untouched"
expect "other args" \
    "$(cd / && rewrite --fullscreen video.mkv)" \
    "--fullscreen
video.mkv"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "PASS: launcher handles vapoursynth= paths and profile duplicates"
