# Golden exports of the Screenshot editor

Each PNG is the exporter's output (`apps/screenshot/src/exporter.cpp`, QPainter) for one tool drawn over a synthetic picture,
named `<case>@<scale>.png`: the picture is 160 x 100 at scale `1` and 200 x 125 at scale `1.25`, the shapes' coordinates and
widths are multiplied by the scale, as a capture at 1.25 makes them. The cases are in `tst_golden.cpp`: `arrow-straight`,
`arrow-curved`, `arrow-double`, `line`, `rectangle`, `rectangle-filled` (translucent), `ellipse`, `ellipse-filled`, and `scene`
(all of them over each other: the drawing order).

## Determinism

- The base picture is computed (checkers over a ramp); no file, font, theme or style takes part. The exporter reads nothing but
  the picture and the layers.
- The tests run with `QT_QPA_PLATFORM=offscreen` and `QT_QPA_PLATFORMTHEME` unset (`tst_main.cpp` forces offscreen).
- Qt's raster engine draws the shapes (no GPU).

## Tolerance

A pixel differs when any channel is off by more than **8 levels**; a golden fails when more than **0.5 %** of its pixels differ
(`kChannelTolerance` and `kPixelFraction` in `tst_golden.cpp`). The same code on the same Qt gives the same bytes; the margin is
for the anti-aliasing of an edge when Qt's rasteriser changes, which moves a few pixels along an edge by a few levels. A wrong
width, a shifted shape or a missing head moves far more than that. Each case also asserts that the export differs from the
picture, and `tst_annotations.cpp` checks exact pixels without any file.

## Regenerating

`tests/unit/screenshot/regenerate-goldens.sh` rewrites every file from the current build (`GF_UPDATE_GOLDENS=1`). Look at the
PNGs and at `git diff --stat` before committing: a changed golden is a changed drawing. On a failure the picture that came out is
written to `$GRASSFIELD_TEST_TMP` (or the temporary directory) as `golden-actual-<case>@<scale>.png`.
