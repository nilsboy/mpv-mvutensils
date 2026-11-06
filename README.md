# mpv-mvutensils

[MVUtensils](https://github.com/myrsloik/mvutensils) motion-estimation frame
interpolation for [mpv](https://mpv.io/), exposed through VapourSynth, plus an
all-in-one snap.

MVUtensils estimates motion between frames and synthesises in-between frames,
raising the effective frame rate for smoother motion — e.g. 1080p24 → 60 fps.
It is a CPU-only filter (wide SIMD, no GPU compute runtime required), making it
the lightest of the frame-interpolation approaches to deploy.

## How it works

```
mpv --vf=vapoursynth=vapoursynth/mvutensils.vpy  video.mkv
```

mpv's `vapoursynth` filter runs `vapoursynth/mvutensils.vpy`. That script takes
the decoded frames via `video_in`, builds a motion field and rebuilds the clip
at the target rate:

- `Super` prepares the clip and its hierarchical pyramid.
- `AnalyseMany` searches for motion vectors (`Analyse` per direction).
- `FlowFPS` renders the interpolated frames.

Everything runs inside the MVUtensils VapourSynth plugin (`mvu` namespace); no
external manager or GPU runtime is involved.

## Requirements

- Linux x86_64. The scripts target Ubuntu but should work on any distro with
  meson/ninja and the listed dev packages.
- No GPU is required. MVUtensils uses AVX2/AVX-512 where available and falls
  back to baseline SSE2 otherwise; the CPU is the only performance limit.

## Build

Everything is built from source because Ubuntu does not package VapourSynth and
its mpv is not built with VapourSynth support.

```sh
sudo scripts/install-deps.sh          # distro build dependencies
scripts/build-vapoursynth.sh          # VapourSynth R79 runtime + headers
scripts/build-mvutensils.sh           # MVUtensils plugin
scripts/build-libplacebo.sh           # libplacebo (only if your distro lacks it)
scripts/build-mpv.sh                  # mpv with -Dvapoursynth=enabled
```

Install to `/usr/local` by default; override with `PREFIX=/your/prefix`.

## Usage

Play a file with interpolation:

```sh
mpv --vf=vapoursynth=vapoursynth/mvutensils.vpy video.mkv
```

Or use the bundled config, which adds `[mvu]`, `[fast]` and `[quality]`
profiles and a runtime toggle bound to `Ctrl+m`:

```sh
mpv --config-dir=mpv --profile=mvu video.mkv
```

In the snap, a relative `vapoursynth=` path that is not present in the current
directory is resolved against the snap's bundled `/vapoursynth/mvutensils.vpy`,
so the command above works from anywhere.

The toggle script reads the vpy path from `script-opts/mvu-toggle.conf`.

### Profiles

| Profile | Effect |
| --- | --- |
| `mvu` | Interpolation on, target 60 fps, best default quality/speed balance |
| `fast` | 1080p→60 on a weak CPU: 16x16 blocks, interpolation at 50% size |
| `quality` | Small blocks, half-pixel, uneven multi-hexagon search |

`fast` is the configuration measured to sustain 1080p→60 on a 4-thread
i3-1315U. See [NOTES.md](NOTES.md) for the benchmark table.

### Overriding options from the command line

mpv's `vapoursynth` filter has a `user-data` suboption passed to the script
verbatim, so the target rate and search settings can be changed per invocation.
mpv's suboption parser requires the value to be quoted when it contains `=`;
use `"..."` or `[...]`, and separate multiple options with `;` or `,`:

```sh
# Retarget to 48 fps:
mpv --vf='vapoursynth=vapoursynth/mvutensils.vpy:user-data="48"' video.mkv

# A fast 1080p configuration:
mpv --vf='vapoursynth=vapoursynth/mvutensils.vpy:user-data=[preset=performance;block=16;scale=0.5]' video.mkv
```

Recognised tokens:

| Token | Meaning |
| --- | --- |
| `fps=48` (or a bare `48`) | Absolute target frame rate; accepts `47.95` or `48000/1001` |
| `rate=2` (or `5/2`) | Target as a multiple of the source rate |
| `preset=quality\|balanced\|performance\|realtime` | Motion-search preset |
| `block=16` | Motion block size (legal sizes up to 128x128) |
| `overlap=8` | Block overlap, ≤ `block`/2 |
| `pel=2` | Sub-pixel accuracy: 1, 2 or 4 |
| `search=2` | Search algorithm: 0 diamond, 1 exhaustive, 2 hexagon, 3 UMH |
| `satd=1` | Use SATD instead of SAD as the block metric |
| `refine=1` | Add a `Recalculate` pass at half block size |
| `scale=0.5` | Run the pipeline at this fraction, then upscale (biggest speedup) |

`fps`/`rate` take precedence over the defaults in the script (`FPS_NUM`/
`FPS_DEN`); if neither is given, the hardcoded 60 fps target applies.

### mvutensils.vpy options

Configuration lives at the top of `vapoursynth/mvutensils.vpy`:

| Option | Meaning |
| --- | --- |
| `PRESET` | Motion-search effort: `quality`, `balanced`, `performance` (default), `realtime` |
| `FPS_NUM`, `FPS_DEN` | Absolute target frame rate; default `60`/`1` |
| `RATE_NUM`, `RATE_DEN` | Frame-rate multiplier, used when `FPS_NUM` is unset |
| `SCALE` | Analyse/render at this fraction of the source, then upscale; default `1.0` |

Per-parameter overrides (`blksize`, `overlap`, `pel`, `search`, `searchparam`,
`satd`, `mvlambda`, `refine`) are available in `_OVERRIDES`.

### If playback is too slow

The motion search dominates and is CPU-only. In rough order of impact:

1. **`scale=0.5`** — run search *and* render at half the source size and
   upscale. Roughly 2x faster, at some softness. This is what `[fast]` uses.
2. **A larger `block`** — 16x16 or 32x32 instead of 8x8 cuts search work
   sharply.
3. **`preset=performance`** (the default) or **`realtime`** — large blocks,
   full-pixel search.
4. **Lower the target rate** — `user-data="48"` or `"30"`; cost scales with
   output frames per second.
5. Use `--hwdec=auto-copy` (already in the bundled config) so decoding does not
   compete for CPU.

`concurrent-frames=8` is set in the bundled profiles; on a 4-thread CPU that is
where throughput peaks.

## Snap

An all-in-one snap bundles mpv, VapourSynth, the MVUtensils plugin and the
config/profiles. The snap is built against `core26`, matching this project's
Ubuntu 26.04 host:

```sh
cd snap && snapcraft pack
sudo snap install --dangerous ./mpv-mvutensils_*.snap
```

The default managed build uses LXD; `snapcraft pack --destructive-mode` builds
directly on the host (no LXD required) and is what the project targets.

The snap requires the `pipewire` interface to talk to the host PipeWire daemon;
it is not auto-connected:

```sh
sudo snap connect mpv-mvutensils:pipewire
```

Without it, mpv falls back to the bundled PulseAudio client against the host
pipewire-pulse socket.

Video output uses X11 (`x11`, `xv`, `x11egl`, `x11vk`) or Wayland (`wlshm`,
`dmabuf-wayland`, `wayland`, `waylandvk`) depending on `DISPLAY`/
`WAYLAND_DISPLAY`. The `x11`, `wayland` and `opengl` interfaces are
auto-connected; only `pipewire` needs the manual connect above.

Because MVUtensils is CPU-only, the snap does not need any GPU compute ICD; it
still bundles Mesa's Vulkan/VA-API drivers for mpv's video output and
`--hwdec=auto-copy`.

## Tests

```sh
tests/run-tests.sh
```

Covers the vpy script syntax/load and frame-rate conversion, an end-to-end
interpolation correctness check (a moving bar must land between its source
positions), the mpv `vapoursynth` filter availability, the MVUtensils plugin
payload and runtime deps, the snap audio payload, and that the X11/Wayland video
outputs are built and bundled.

## Notes

See [NOTES.md](NOTES.md) for design, performance measurements and environment
details.
