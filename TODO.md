- [x] build mpv with mvutensils
- [x] optimize for running on a i3-1315U with 1080p → 60 FPS
- [x] make sure pipewire and wayland are supported
- [x] test if everything works
- [x] build a snap

## Follow-ups

- [ ] benchmark real 1080p→60 on the target GPU/display session; the
      measurements here were made headless (`--vo=null --untimed`), so display
      sync (`video-sync=display-resample`) could not be exercised
- [ ] verify PipeWire playback and a Wayland video output on a graphical
      session; this host has no display (`tty`) and no usable GPU
- [ ] consider bundling the `mvutensils` `Depan*` filters as a stabilisation
      profile; they are built and installed but not yet exposed by a config

## Notes on the 1080p→60 goal

MVUtensils is CPU-only. On the 4-thread i3-1315U the search cannot sustain
1080p→60 at full resolution; the `[fast]` profile reaches it by interpolating at
50% size (`block=16;scale=0.5`). See NOTES.md for the benchmark table. The
`scale` lever is the single most effective speed-up (roughly linear in pixel
count).
