# ADR-0059: The plugin's window animations are retargetable tracks with their own clocks and carried velocity
Status: Accepted (audit fix round 2, compositor-wm scope, 2026-11-19; the owner asked for every finding to be fixed) · Date: 2026-11-19 · Decider: owner (delegated)

## Context
Stages (ADR-0013) and the Overview (overview.md v2) animate real windows drawn elsewhere with a transformer. Both ran one
global clock: every new target (a window opening during a swap, the shell's `on:true` again, a close requested early in
the opening) restarted every window's easing from zero velocity for a whole duration (audit WM-03, WM-17 and the design
note "retargeting without velocity"). macOS never stops an interrupted animation dead: it continues from the state on
screen with its velocity, and an animation whose target did not change is not disturbed. The shell sends the duration and
the timing curve (Tokens.motionCurve*, Reduce Motion: 0 ms) with each request; a spring with its own settle time would
ignore them.

## Options
1. Keep one clock; scale its duration on retarget.
2. A spring (critically damped) per window, its stiffness derived from the requested duration.
3. **One track per window: the shell's curve from the box on screen to the target, plus a cubic Hermite term that carries
   the velocity of the moment of the retarget and fades out with zero slope at the end; an unchanged target leaves the
   track alone; a mid-flight retarget scales its duration by the share of the way left (at least 30 %).**

## Decision
Option 3 (`compositor/src/core/Motion.hpp`, header only, unit-tested in OverviewTest `Motion*`). From rest a track is
exactly the shell's curve (the tokens keep their meaning, Reduce Motion stays 0 ms); position and velocity are continuous
across a retarget; a track ends at its target at rest. A reversal right after the start (the Overview closed 50 ms after
it opened) takes about as long as the way travelled, and windows retargeted together stay in step with those whose target
held. Minimize and restore interrupted by each other are reversals of a fixed path: they continue in time instead (core
`continueFrom`, `fadeElapsedFor`, as Genie already did): no jump, no transparent flash, only the rest of the duration.
Every plugin animation is stepped by the frames of the monitor that draws it (one ticker per monitor), never twice per
frame cycle.

## Consequences
- Option 2 was rejected because it would drop the shell's timing tokens and make Reduce Motion a special case; option 1
  because it cannot keep an unchanged window still.
- A carried velocity can overshoot a new target that lies behind the window's motion (as on macOS); the overshoot is
  bounded by the duration (at most about 15 % of duration × speed).
- Stages posts a notice only when its state changed (the shell fetched the full state after every notice).
