# mvutensils notes

## What this project is

`mpv` built with the VapourSynth filter, plus the MVUtensils motion-estimation
plugin and an interpolation script, packaged as an all-in-one snap. The goal is
frame-rate conversion (e.g. 1080p24 -> 60 fps) that runs on modest CPUs.

This is the CPU-only counterpart to the sibling `mpv-rife` (Vulkan neural
interpolation) and `mpv-svp` (OpenCL-assisted) projects.

## Why MVUtensils

[MVUtensils](https://github.com/myrsloik/mvutensils) (namespace `mvu`) is a
cleanup/refactor of VapourSynth MVTools by myrsloik, the VapourSynth author. It
fixes long-standing MVTools bugs (right/bottom border handling), uses
cache-friendlier algorithms and wider SIMD (SSE2/AVX2/AVX-512), and reduces
`Super`/`Analyse`/`Degrain` memory use.

Key properties that make it a good fit here:

- **CPU only.** There is no GPU compute path, so there is nothing extra to
  install for it to work. Its SIMD kernels are compiled per instruction-set
  level and the matching build is chosen at load time, which is where most of
  the speed comes from.
- **VapourSynth API 4.2**, built with C++20, so it needs a reasonably modern
  toolchain but no special SDK.

## VapourSynth version

MVUtensils declares `-DVS_USE_API_42` and `manifest.vs` (a variant-selection
manifest, introduced with newer VapourSynth). VapourSynth is pinned to **R79**
here for two reasons:

1. R79 still accepts both API 4.x and the older API 3 compatibility layer, so a
   single install can load MVUtensils and (if desired) the older API 3 plugins.
2. R79 is already the pin used by the sibling projects, so the host build is
   shared. Unlike those projects, MVUtensils does **not** need R79 (it is API
   4.2); any R80+ would also work. The pin is a convenience, not a constraint.

`manifest.vs` autoload is supported by R79: the plugin directory is scanned
recursively and a subdirectory containing a manifest is loaded as one plugin,
with the manifest naming the plugin to load. That is how the correct
`mvutensils.<variant>.so` is picked per CPU.

## Plugin install directory

MVUtensils' meson uses the Python interpreter's site-packages:

```meson
install_dir = py.get_install_dir() / 'vapoursynth/plugins/mvutensils'
```

`py.get_install_dir()` follows meson's `python.purelibdir` / `python.platlibdir`.
On Ubuntu 26.04 the distro interpreter reports
`/usr/local/lib/python3.14/dist-packages` (because `python3.14` is a
`/usr/local` install) whereas the *snap* base's interpreter reports
`/usr/lib/python3/dist-packages`. The build script and the snap part therefore
pin both directories explicitly, so the DLLs and `manifest.vs` land in the same
place the VapourSynth package lives and are autoloaded.

The script also falls back to `core.std.LoadPlugin()` with a CPU-appropriate
variant when the namespace is absent (a source checkout without a system-wide
install).

## Performance

MVUtensils' motion search and frame rendering are both CPU work; there is no GPU
offload. Measured on the actual target, an **i3-1315U** (4 threads: 2 P-cores +
2 E-cores, Alder Lake, AVX2 but no AVX-512), running as a KVM guest under load.
Output is 1080p -> 60 fps, 240 frames, `concurrent-frames=8`, `--vo=null`,
`--untimed`:

| Setting | output fps (approx.) |
| --- | --- |
| `preset=quality` | ~10 |
| `preset=balanced` | ~25 |
| `preset=performance` (16x16, full size) | ~32 |
| `preset=performance;block=16;scale=0.75` | ~40 |
| `preset=performance;block=16;scale=0.5` | ~50 |
| `preset=performance;block=32;scale=0.6` | ~45 |

The i3-1315U has two P-cores and two E-cores; MVUtensils parallelises across
frames, so the effective throughput depends on how many frames are in flight.
`concurrent-frames=8` measured best (2 was clearly worse: ~25 fps vs ~32 at full
size), and the default `auto` is only about 4, so the bundled `[mvu]` profile
sets 8.

**Conclusion:** on this CPU, real-time 1080p->60 is reachable only with the
`scale` lever (interpolating at half size). That is what the `[fast]` profile
does (`block=16;scale=0.5`). Without scaling the search is the bottleneck and
the pipeline is roughly 2x too slow. This is expected: the interpolation cost
scales with pixel count and output frames per second, and the search is a
per-pixel, per-block match.

Memory stays modest: `Analyse` peaks around 300-450 MB for 1080p.

## Levers, in impact order

1. **`scale`** (run search + render at a fraction, then upscale) — the biggest
   lever, roughly linear in pixel count. Costs sharpness.
2. **`preset`** — `performance` vs `quality` is a ~3x gap (large blocks and
   full-pixel search vs small blocks, half-pixel and UMH+SATD).
3. **`block`** — larger blocks mean far less search work. Must be a legal size:
   4x4, 8x4, 8x8, 16x2, 16x8, 16x16, 32x16, 32x32, 64x32, 64x64, 128x64,
   128x128. The script clamps `overlap` when only `block` is set.
4. **target rate** — `fps=48`/`30` reduces output frames per second.
5. **`--hwdec=auto-copy`** — offloads decode so it does not compete with the
   search for CPU. It must be a copy-back decoder (system memory), since a
   VapourSynth filter reads frames on the CPU.

`concurrent-frames` beyond ~8-12 does not help; the search saturates the cores.

## Options passed through mpv

mpv's `vapoursynth` filter defines a `user-data` suboption forwarded to the
`.vpy` as the global `user_data`. The script parses it for `fps`, `rate`,
`preset`, `block`, `overlap`, `pel`, `search`, `satd`, `refine` and `scale`. As
in the sibling projects, the value must be quoted when it contains `=`
(`user-data="fps=48"`), and the whole `--vf=` value quoted from the shell.

Note on rate semantics: unlike SVP, MVUtensils' `FlowFPS(num, den)` takes an
**absolute** output rate, so `rate=3` is turned into `source * 3` in the script
before being passed on. The output frame count is floored, so a short clip at a
fractional rate loses the final partial frame.

## Snap packaging notes

- Base `core26` to match the Ubuntu 26.04 host. `snapcraft pack
  --destructive-mode` avoids LXD.
- The MVUtensils runtime dependencies are only `libzimg2` and
  `libfftw3-single3` (plus `libstdc++`/`libgcc` from the base).
- Video: mpv only enables X11 when `x11`, `xscrnsaver`, `xext`, `xpresent` and
  `xrandr` are all found, so `libxss-dev`/`libxv-dev` are build deps and the
  matching runtime is staged. Wayland outputs (`wlshm`, `dmabuf-wayland`) are
  compiled in; the launcher rewrites a relative `WAYLAND_DISPLAY` to an absolute
  path because snapd remaps `XDG_RUNTIME_DIR`.
- Audio: the `pipewire` plug is `deny-auto-connection`, so the launcher points
  `SPA_PLUGIN_DIR`, `PIPEWIRE_MODULE_DIR`, `PIPEWIRE_CONFIG_DIR`, and the host
  runtime socket paths at the host user runtime dir; `pulse` against the host
  pipewire-pulse socket is the fallback. `snap connect
  mpv-mvutensils:pipewire` enables the native output.
- VSScript keys its Python interpreter lookup on the path `libvsscript.so` was
  loaded from, which contains the snap revision, so the launcher regenerates
  `vapoursynth.toml` after a refresh.

## Environment

- Build host: Ubuntu 26.04, x86_64, 4 vCPUs, ~7.7 GB RAM, ~2.5 GB free disk.
  The workspace is on a network mount, so build trees live under `/var/tmp`.
- The host is a KVM guest presenting an i3-1315U (AVX2, no AVX-512); there is no
  usable GPU (`1234:1111` virtual VGA), but MVUtensils does not need one.
- `snapcraft` 9.1.3, `vspipe`/VapourSynth R79 and an mpv with VapourSynth are
  already installed from the sibling projects.
