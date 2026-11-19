# ADR-0060: Shell surfaces animate by transforms; surfaces that come back are kept; regions update at rest or by steps
Status: Accepted (audit round 2, 2026-11-19) · Date: 2026-11-19 · Decider: integrator (audit fix brief 2) · Related: ADR-0039 (motion), ADR-0024 (glass), ADR-0056 (deferred surfaces), audit shell-ui-a A-05, A-06, A-08, A-11, design notes

## Context
The audit of shell/dock, overview, desktop, osd and launchpad found the same cost pattern in several surfaces: an animation that
changed item geometry (the Dock's magnified tiles laid out every frame; Overview's thumbnails resized with the zoom, re-allocating two
offscreen layers per window per frame), a compositor region that followed it (the Dock's input mask and blur region updated every
frame), a list model that rebuilt every delegate on any change (Overview's window items), a surface mapped again for each short
appearance (the OSD), and per-output copies of one heavy view (the Apps grid).

## Decision
1. A surface animates by transforms on items of fixed size. The Dock keeps its unmagnified layout and moves and scales tiles
   (`Magnify.shifts`, `Geometry.scaleOrigin`); Overview's thumbnails keep their content at a fixed size and scale it with the zoom.
   What is seen is unchanged (checked against the earlier layout in tests/shell/dock_transform.sh).
2. A heavy delegate loads only its kind's content (the Dock tile's per-kind Loader).
3. A compositor region (input mask, blur) is not updated per frame: it takes its widest extent for the duration of an interaction
   (the Dock's input region is the magnified shelf at its widest while hovered), or follows by whole steps and is exact at rest (the
   Dock's blur region, an eighth of a pitch).
4. A list of things with identities (windows, tiles) is a keyed model (ScriptModel with objectProp, or a diffed ListModel): a change
   creates or destroys only its own delegates, the others animate to their new places.
5. A captured image of something that does not change (a minimized window) is one frame, taken only by the surface that shows it.
6. A small surface that appears often stays mapped, empty and without input, where an idle mapped surface costs nothing; it is
   unmapped where it would (an overlay over a full-screen window would prevent direct scan-out). The OSD follows this.
7. One heavy view per surface, not per output: the Apps window moves to the display it opens on (it is unmapped while closed).
8. A long ambient fade (the wallpaper's 20 s phase fade) moves in steps a few times a second; a change during a fade retargets it
   without a jump (a third slot takes the new content over the fade in flight).

## Consequences
Per-frame work during the Dock's magnification is transforms and the shelf's length; Overview's zoom allocates its layers once;
window arrivals while Overview is open glide. The input region of a hovered Dock can be larger than the drawn shelf by up to half the
magnified growth at each end (input there goes to the Dock while the pointer is already on it). The phase fade redraws ~10 times a
second. Owner checks in a real session: frame pacing of the magnified Dock, the blur region's steps at the shelf's ends, the OSD over
full-screen video, the Apps window moving between displays.
