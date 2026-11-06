# MVUtensils frame interpolation for mpv's vapoursynth filter.
#
# MVUtensils (namespace `mvu`) is a cleaner, faster rewrite of MVTools. It
# estimates a block motion field (Super -> AnalyseMany) and rebuilds in-between
# frames (FlowFPS). Everything runs on the CPU using wide SIMD (SSE2/AVX2/
# AVX-512), so there is no GPU/OpenCL/Vulkan runtime to install.
#
# Run with:
#   mpv --vf=vapoursynth=/path/to/mvutensils.vpy video.mkv
#
# The PRESET and SCALE settings are the main performance levers.

import vapoursynth as vs

from fractions import Fraction
import os
import re

core = vs.core


def _ensure_mvutensils():
    # Prefer the plugins autoloaded from VapourSynth's plugin directory. That is
    # where the manifest lives, which selects the instruction-set build matching
    # the running CPU. Fall back to an explicit load so a source checkout works
    # without installing system-wide; pick the build the CPU can run.
    if "mvu" in {plugin.namespace for plugin in core.plugins()}:
        return
    script_path = globals().get("__file__")
    here = os.path.dirname(os.path.abspath(script_path)) if script_path else ""
    try:
        with open("/proc/cpuinfo") as cpuinfo:
            flags = cpuinfo.read()
    except OSError:
        flags = ""
    sonames = ["mvutensils.zn4.so" if "avx512f" in flags else
               "mvutensils.avx2.so" if "avx2" in flags else
               "mvutensils.so"]
    for directory in (here, core_plugin_dir(), "/usr/local/lib/vapoursynth"):
        if not directory:
            continue
        for sub in ("", "mvutensils"):
            for soname in sonames:
                path = os.path.join(directory, sub, soname)
                if os.path.exists(path):
                    core.std.LoadPlugin(path)
                    return


def core_plugin_dir():
    # VapourSynth autoloads from its own package directory, which can be
    # different from `here` in a source checkout.
    return os.path.join(os.path.dirname(vs.__file__), "plugins")


_ensure_mvutensils()


# --- configuration -----------------------------------------------------------

# Motion-search effort. The search is CPU-bound and the usual bottleneck:
#   "quality"     small blocks, half-pixel, uneven multi-hexagon + SATD
#   "balanced"    small blocks, half-pixel, hexagon
#   "performance" large blocks, full-pixel, hexagon -- fastest per frame
#   "realtime"    performance with a cheaper diamond search
PRESET = "performance"

# Target frame rate expressed as a multiple of the source rate. 2/1 doubles the
# rate, turning a 30 fps clip into 60 fps.
RATE_NUM = 2
RATE_DEN = 1

# Absolute target frame rate; overrides the multiplier when both are set.
FPS_NUM = 60
FPS_DEN = 1

# Analyse/render at this fraction of the source size, then scale back up. The
# search cost falls with pixel count, so this is the biggest speed lever, at
# some softness.
SCALE = 1.0

# Advanced overrides, applied on top of the preset. Each must be consistent.
_OVERRIDES = {
    # "blksize": 8,     # block size; must be a legal MVUtensils size
    # "overlap": 4,     # block overlap, <= blksize/2
    # "pel": 2,         # sub-pixel accuracy: 1, 2 or 4
    # "search": 2,      # 0 diamond, 1 exhaustive, 2 hexagon, 3 UMH
    # "searchparam": 2, # search radius/step
    # "satd": True,     # SATD block metric (slower, more accurate)
    # "mvlambda": 1000, # motion-coherence penalty; 0 disables smoothing
    # "refine": False,  # add a Recalculate pass at half block size
}

# -----------------------------------------------------------------------------

_PRESETS = {
    "quality": dict(
        blksize=8, overlap=4, pel=2, search=3, searchparam=2, satd=True,
    ),
    "balanced": dict(
        blksize=8, overlap=4, pel=2, search=2, searchparam=2, satd=False,
    ),
    "performance": dict(
        blksize=16, overlap=8, pel=1, search=2, searchparam=1, satd=False,
    ),
    "realtime": dict(
        blksize=16, overlap=8, pel=1, search=0, searchparam=1, satd=False,
    ),
}


def _settings(preset):
    if preset not in _PRESETS:
        raise ValueError("unknown preset %r" % preset)
    settings = dict(_PRESETS[preset])
    settings.setdefault("mvlambda", 1000)
    settings.setdefault("refine", False)
    settings.update(_OVERRIDES)
    return settings


def _parse_rate(value):
    # "48", "47.95" or "48000/1001" -> (num, den).
    if "/" in value:
        num, den = value.split("/", 1)
        return int(num), int(den)
    frac = Fraction(value).limit_denominator(100000)
    return frac.numerator, frac.denominator


def _parse_user_data(raw):
    # mpv's vapoursynth filter passes its `user-data` suboption here verbatim.
    # Accept ";", "," and whitespace separated tokens:
    #   fps=48          absolute target frame rate (48, 47.95, 48000/1001)
    #   rate=2          target as a multiple of the source rate (2 or 5/2)
    #   preset=...      quality | balanced | performance | realtime
    #   block=8         motion block size
    #   overlap=4       block overlap
    #   pel=2           sub-pixel accuracy
    #   search=2        motion-search algorithm
    #   satd=1          use SATD instead of SAD
    #   refine=1        add a Recalculate pass at half block size
    #   scale=0.5       run the pipeline at this fraction, then upscale
    # A bare token (e.g. "48") is treated as an absolute target frame rate.
    options = {}
    raw = (raw or "").replace(",", ";")
    raw = re.sub(r"\s*=\s*", "=", raw)
    for chunk in raw.split(";"):
        for token in chunk.split():
            if "=" in token:
                key, value = token.split("=", 1)
                key = key.strip().lower()
                if key:
                    options[key] = value.strip()
            else:
                options.setdefault("fps", token)
    return options


def _as_bool(value):
    return value.strip().lower() not in ("0", "false", "no", "off")


def _source_fps(clip):
    # mpv's video_in clip reports 0/0 fps; the real rate is in container_fps.
    if clip.fps_num and clip.fps_den:
        return clip.fps_num, clip.fps_den
    if container_fps:
        frac = Fraction(container_fps).limit_denominator(100000)
        return frac.numerator, frac.denominator
    raise RuntimeError("could not determine source frame rate")


def _target_rate(options, source_num, source_den):
    # Returns an absolute (num, den). FPS_NUM/FPS_DEN take precedence over the
    # RATE multiplier default; an explicit fps/rate in user-data wins over both.
    if "fps" in options:
        fps_num, fps_den = _parse_rate(options["fps"])
        return fps_num, fps_den
    if "rate" in options:
        rate_num, rate_den = _parse_rate(options["rate"])
        return source_num * rate_num, source_den * rate_den
    if FPS_NUM is not None and FPS_DEN is not None:
        return FPS_NUM, FPS_DEN
    return source_num * RATE_NUM, source_den * RATE_DEN


def _apply_overrides(settings, options):
    if "block" in options:
        settings["blksize"] = int(options["block"])
        # Keep the preset's overlap valid for the new block size unless the
        # caller pins it explicitly.
        settings["overlap"] = min(settings["overlap"], settings["blksize"] // 2)
    if "overlap" in options:
        settings["overlap"] = int(options["overlap"])
    if "pel" in options:
        settings["pel"] = int(options["pel"])
    if "search" in options:
        settings["search"] = int(options["search"])
    if "satd" in options:
        settings["satd"] = _as_bool(options["satd"])
    if "refine" in options:
        settings["refine"] = _as_bool(options["refine"])
    if settings["overlap"] > settings["blksize"] // 2:
        raise ValueError("overlap must be <= blksize/2")


def _interpolate(node, settings, rate_num, rate_den):
    super_clip = core.mvu.Super(
        node,
        blksize=[settings["blksize"]] * 2,
        overlap=[settings["overlap"]] * 2,
        pel=settings["pel"],
        onelevel=False,
    )
    vectors = core.mvu.AnalyseMany(
        super_clip,
        search=settings["search"],
        searchparam=settings["searchparam"],
        satd=settings["satd"],
        mvlambda=settings["mvlambda"],
    )
    if settings["refine"]:
        fine = max(4, settings["blksize"] // 2)
        fine_overlap = max(2, settings["overlap"] // 2)
        fine_super = core.mvu.Super(
            node,
            blksize=[fine] * 2,
            overlap=[fine_overlap] * 2,
            pel=settings["pel"],
            onelevel=True,
        )
        vectors = core.mvu.Recalculate(
            fine_super, vectors,
            blksize=[fine] * 2,
            overlap=[fine_overlap] * 2,
        )
    return core.mvu.FlowFPS(
        node, super_clip, vectors, num=rate_num, den=rate_den,
    )


def main():
    clip = video_in
    if clip is None:
        return

    options = _parse_user_data(globals().get("user_data", ""))
    settings = _settings(options.get("preset", PRESET))
    _apply_overrides(settings, options)

    scale = float(options.get("scale", SCALE))
    if not 0.0 < scale <= 1.0:
        raise ValueError("scale must be in (0, 1]")

    source_num, source_den = _source_fps(clip)
    rate_num, rate_den = _target_rate(options, source_num, source_den)

    # MVUtensils handles GRAY and YUV at 8-16 bit integer or 32 bit float; other
    # families (e.g. RGB from an image source) are converted once up front.
    node = clip
    output_width, output_height = clip.width, clip.height
    if clip.format.color_family not in (vs.GRAY, vs.YUV):
        node = core.resize.Bicubic(node, format=vs.YUV420P8)

    if scale != 1.0:
        scaled_w = max(16, int(clip.width * scale) & ~1)
        scaled_h = max(16, int(clip.height * scale) & ~1)
        node = core.resize.Bicubic(node, scaled_w, scaled_h)

    node = core.std.AssumeFPS(node, fpsnum=source_num, fpsden=source_den)

    smooth = None
    error = None
    try:
        smooth = _interpolate(node, settings, rate_num, rate_den)
    except vs.Error as exc:
        error = exc
    if smooth is None:
        # MVUtensils needs enough resolution to build its hierarchical pyramid
        # and at least two frames to interpolate. Pass frames through so
        # playback still works.
        print(
            "mvutensils.vpy: interpolation unavailable for this source (%s); "
            "passing frames through" % error
        )
        smooth = core.std.AssumeFPS(
            clip, fpsnum=source_num, fpsden=source_den
        )

    if scale != 1.0:
        smooth = core.resize.Bicubic(
            smooth, output_width, output_height, format=clip.format.id,
        )
    smooth = core.std.AssumeFPS(
        smooth, fpsnum=smooth.fps_num, fpsden=smooth.fps_den,
    )

    smooth.set_output()


main()
