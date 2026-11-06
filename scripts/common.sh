#!/usr/bin/env bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Building on the workspace is unreliable when it is a network mount, so the
# build tree defaults to a local directory.
BUILD_ROOT="${BUILD_ROOT:-/var/tmp/mpv-mvutensils-build}"
PREFIX="${PREFIX:-/usr/local}"
JOBS="${JOBS:-$(nproc)}"

# MVUtensils is a C++20 / API 4.2 VapourSynth plugin; VapourSynth is pinned to
# R79 so the same install can also run the older API 3 plugins (see NOTES.md).
MVUTENSILS_URL="${MVUTENSILS_URL:-https://github.com/myrsloik/mvutensils.git}"

clone_repo() {
    local url="$1"
    local dir="$2"
    shift 2
    local ref=""
    local args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[i]}" == "--branch" ]]; then
            ref="${args[i + 1]}"
        fi
    done
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" fetch --depth 1 origin "${ref:-HEAD}"
        git -C "$dir" checkout -q --detach FETCH_HEAD
    else
        mkdir -p "$(dirname "$dir")"
        git clone --depth 1 "$@" "$url" "$dir"
    fi
}

install_tree() {
    local message="$1"
    shift
    if [[ -w "$(dirname "$PREFIX")" ]]; then
        "$@"
    else
        sudo "$@"
    fi
    echo "$message"
}

# VapourSynth installs into the Python purelib directory. Prefer the interpreter
# VapourSynth itself is bound to, so the plugin directory matches the runtime
# mpv loads.
vs_python() {
    command -v python3.14 >/dev/null 2>&1 && { echo python3.14; return; }
    echo python3
}

vs_plugin_dir() {
    "$(vs_python)" -c 'import vapoursynth, os; print(os.path.join(os.path.dirname(vapoursynth.__file__), "plugins"))'
}
