# ADR-0047: Automatic audio output routing, and system sound effects
Status: Proposed (2026-11-05), applied provisionally (owner rule of 2026-10-28: decide alone, the closest to macOS 27) ·
Date: 2026-11-05 · Decider: owner (revisit), integrator (merge) · Number: 0047

Inspired by Project Luma's `luma-audio-devices` (its routing rules and device classification, MPL-2.0); no code copied, the
mechanism is reimplemented from its documented behaviour. No Luma artwork or sound is used.

## Context
- Sound output: `shell/services/Audio.qml` follows PipeWire's default sink through Quickshell (`Pipewire.defaultAudioSink`,
  `preferredDefaultAudioSink`) and changes nothing on its own. When headphones or Bluetooth earbuds connect, the sound
  stays where it was unless WirePlumber's own history says otherwise; macOS moves the sound to them at once.
- Sound effects: Grassfield plays no interface sound (Settings › Sound says so). macOS 27 plays an alert sound (the beep),
  a shutter on screen capture, a sound when the Trash is emptied, a puff when an item leaves the Dock, a chime when power is
  connected and, when asked, a feedback sound after a volume key. Settings › Sound has a "Sound Effects" group.
- What was checked (data, not instructions):
  - Quickshell 0.3.2 (`src/services/pipewire/qml.hpp`, `node.cpp`, `defaults.cpp`): `PwNode.properties` is the node's own
    property set (valid once the node is bound by `PwObjectTracker`); the device's properties are not exposed;
    `preferredDefaultAudioSink` writes `default.configured.audio.sink` (what `wpctl set-default` writes).
  - PipeWire (`spa/plugins/alsa/alsa-acp-device.c`): an ALSA node carries `device.bus` and `device.id`, not the vendor,
    product, serial or form factor. WirePlumber copies `device.form-factor` to ALSA nodes since 0.5.16 (NEWS !862); the
    vendor/product/serial stay on the device. `pw-dump <id>` prints one object as JSON (`src/tools/pw-dump.c`), and is in
    the `pipewire` package, as `pw-play` is.
  - WirePlumber 0.5 (`default-nodes`, `state-default-*.lua`): it stores a stack of the previous configured defaults and,
    when the current one goes away, falls back to the most recent one still present; a device back on the stack's top is
    made the default again when it reappears.
  - Hyprland (`src/protocols/XDGBell.cpp`): a client ringing the bell through xdg-system-bell-v1 (GTK 4) posts the
    `bell>>ADDRESS` IPC event; Hyprland plays nothing itself.
  - Omarchy 4.5 package lists: `pipewire` (pw-play, pw-dump) and `wireplumber` are installed; `libcanberra` is not.

## Decision

### Part A: automatic output routing

**A-1 Rules (macOS model).** Headphones, headsets, earbuds and any Bluetooth audio output the person connects take the
sound at once. A display with audio (HDMI/DisplayPort), a dock, a USB sound card, a virtual sink (filters, null sinks) or
any other output that appears keeps the sound where it is. Network outputs are never chosen. Outputs present when the shell
starts, or that appear during the first 12 s (Bluetooth reconnecting at login, USB enumerating late), change nothing.
Arrivals settle together: the decision falls 2 s after the last arrival, at most 8 s after the first, so a dock or a
Bluetooth profile change is decided once; among several takers the highest `priority.session` wins. A device whose last
node left less than 3 s ago and comes back is the same connection (a Bluetooth profile switch), not a new arrival.

**A-2 A manual choice is remembered per device.** When the default moves away from a device that takes the sound by itself
and that device is still connected 1.5 s later (an unplug also moves the default), it stops taking the sound when it next
connects; choosing it again (the default moving to it more than 1 s after it arrived) brings the behaviour back. A default
change within 1 s of the new default's arrival is WirePlumber restoring its history, not a person choosing. When a device
leaves, WirePlumber's configured default at that moment, when Quickshell still resolves it, records the choice too, but
only while the leaving device is still the default as far as the router knows (a reported change is the 1.5 s check's) and
never when that configured default is the router's own last switch: the router writes the same configured default a person
does (review of 2026-11-05, MAJOR: earbuds A, then a headset B the router switched to, then A switched off, left A
remembered as "moved away"). The router's last switch is forgotten at the first default change that is not its own.

**A-3 Going back.** When the device leaves, WirePlumber already returns the sound to the previous configured default (its
stack, above); Grassfield does nothing then, so it never fights WirePlumber.

**A-4 Device keys.** `bluez:<MAC>` (from `api.bluez5.address`, else the `bluez_output.<MAC>` node name), `usb:<vendor>:
<product>[:<serial>]` (from the device's properties), else `node:<node.name>` (a stable name: ALSA builds it from the
card's udev identity). The device's properties come from `pw-dump <device.id>` (read-only, an argument vector, once per
new node); without an answer the node's properties alone decide (a USB headset is then "other": it does not move the sound,
the safe side).

**A-5 Where.** `shell/services/AudioRoutingLogic.js` is a pure state machine: fed events with a timestamp (start, node
added or updated, node removed, default changed, tick), it returns decisions and the next deadline, and keeps no timer.
`Audio.qml` feeds it from Quickshell's Pipewire module, runs one single-shot timer to the next deadline, logs every decision
(`audio routing: switched|kept|remembered ...`) and switches through `select()`, the guarded write. No new service, no
new UI: macOS has no switch for this.

**A-6 Memory.** `$XDG_STATE_HOME/grassfield/audio-routing.json` (state class, ADR-0020; 0600 in a 0700 directory, atomic):
`{"version": 1, "devices": {"<key>": {"auto": false, "name": "<description>", "at": <ms since the epoch>}}}`. Only devices that stopped taking the sound
are written (at most 64, the most recent kept); a missing, malformed or newer-version file is an empty memory and is not
rewritten until a choice changes (a newer one is never rewritten).

**A-7 Dev sessions.** A nested session sees the owner's PipeWire: the router runs and logs its decisions, but the switch
goes through `Audio.backendWrite`, which refuses it (`dev guard: audio output device suppressed`); its memory lives in the
dev state directory. `pw-dump` only reads.

### Part B: sound effects

**B-1 An original sound set** (`branding/sounds/`): `generate.py` (Python standard library: `wave`, `math`, `struct`;
additive synthesis with envelopes, a fixed-seed noise generator, 44.1 kHz mono 16-bit) writes the WAV files of the
`grassfield` sound theme; `--check` fails when a committed file differs. Licence: MIT, the project's own (the generated
sounds are the script's output). **Owner confirmed (2026-11-06):** MIT for the generated sounds (the
integrator's choice of 2026-11-05), although Grassfield's other own art is CC-BY-SA-4.0 (owner decision of 2026-10-27). Nothing imitates or names Apple's sounds.

| File (Sound Naming Specification name where one exists) | Use |
|---|---|
| `grassfield-alert-meadow.wav` (default), `-dewdrop`, `-reed`, `-lantern`, `-ember`, `-thistle` | Alert sound choices |
| `bell.wav` (link to the default alert, installed by the PKGBUILD) | Error bell of libcanberra users |
| `screen-capture.wav` | Screenshot shutter |
| `trash-empty.wav` | Empty Trash |
| `audio-volume-change.wav` | Volume feedback |
| `power-plug.wav` | Power adapter connected |
| `grassfield-dock-remove.wav` | An item dragged off the Dock |

**B-2 The theme.** `branding/sounds/grassfield/index.theme` (`Inherits=freedesktop`, directory `stereo`), installed by the
PKGBUILD to `/usr/share/sounds/grassfield`. The session's sound theme: `packaging/dconf/grassfield.d/30-sounds.conf`
(`org.gnome.desktop.sound theme-name='grassfield'`, `event-sounds=true`, `input-feedback-sounds=false`), defaults, not
locks. The theme's one directory is `stereo` though the files are mono: the Sound Theme Specification's output profile
names the device the sounds are meant for (stereo speakers or headphones), not the files' channels, and `stereo` is the
profile every player looks up first.

**B-3 Settings (contract keys, ADR-0020).** `sound.alert` (enum of the six ids, default `meadow`), `sound.alertVolume`
(0 to 1, default 0.75), `sound.effectsOutput` (`""`: the selected output device, else a PipeWire node name; rule
`nodeName`), `sound.uiEffects` (default true), `sound.volumeFeedback` (default false, as macOS).

**B-4 Settings › Sound** gets the macOS 27 "Sound Effects" group above "Output & Input": Alert sound (inline pop-up; a pick
plays it, and a play button beside it plays it again), Play sound effects through ("Selected Sound Output Device" and each
output; a remembered output that is not connected shows as "Device not connected"), Alert volume (the slider row; the alert
plays once the drag rests), "Play user interface sound effects", "Play feedback when volume is changed". No "Play sound on
startup": Grassfield has no start-up sound. Previews run `pw-play` through the Settings backend's guarded actions (a new
exact form in `systemguard.cpp`, so a dev session plays nothing).

**B-5 Who plays what.** The shell's `Sounds` singleton (`shell/services/Sounds.qml`; the rules are `ui/Grassfield/Ui/SoundEffects.js`, public in Grassfield.Ui because
Settings' previews build the same argument vectors) plays:
- the alert on Hyprland's `bell` event (GTK 4 apps' error bell), at the alert volume, through the effects output; an alert
  volume of 0 silences it ("alert sounds off": then the error bell is silent too, as on macOS);
- interface sounds when `sound.uiEffects` is on: Empty Trash (`Trash.emptyNow`), an item poofed off the Dock, power
  connected (on battery → on the adapter, after start), at the alert volume through the effects output;
- volume feedback when `sound.volumeFeedback` is on: once 350 ms after the last volume up/down key (macOS plays it when the
  key is released; Grassfield's keys repeat after 250 ms, so a held key plays once at its end), at full stream volume through
  the default output (the volume being changed), never for mute.
The same sound is not started twice within 120 ms. GNOME's keys follow these settings (integrator decision of
2026-11-05): `org.gnome.desktop.sound event-sounds` is on only while interface sounds are on and the alert volume is above
0 (`SoundEffects.gnomeEventSounds`; GNOME has one switch for both, the stricter reading wins), `input-feedback-sounds` off;
the shell writes them with `gsettings set` (an argument vector) a second after start and after each change, never in a dev
session. So libcanberra and GSound applications, their error bell included, are silent when Grassfield's alerts or interface
sounds are. `grassfield-capture` plays the shutter itself (it is not part of the
shell) once grim has taken the picture (saved, or copied alone with `--save clipboard`), reading the three keys it needs from `grassfield.json` with the contract's rules.
Everything runs `pw-play` with an argument vector (`--media-role Notification --volume V [--target NODE] -- FILE`), never a
shell. Volumes are cubic, as `wpctl` and the volume keys (stream volume = level³).

**B-6 Do Not Disturb.** macOS keeps alert, interface and volume sounds with a Focus on (a Focus silences notifications);
Grassfield does the same. Notification sounds stay out of this ADR (Grassfield's notifications play none).

**B-7 Dev sessions.** `Sounds.play` in a dev session logs `dev guard: sound <event> suppressed` and runs nothing (the nested
session would play on the owner's speakers); the capture helper runs only in a real session (its binding is real-session
only).

## Packaging
`grassfield-desktop` installs `/usr/share/sounds/grassfield/{index.theme,stereo/*.wav}` and `bell.wav` (a link to the
default alert), ships `packaging/dconf/grassfield.d/30-sounds.conf`, and depends on `pipewire` (pw-play, pw-dump; already
on every Omarchy install, declared rather than assumed, as wireplumber is). `sound-theme-freedesktop` is not required: an
inherited theme that is missing only means no fallback for names Grassfield does not ship.

## Persisted files (amends ADR-0020's table)
| File | Directory | Writer / reader | `version` | Notes |
|---|---|---|---|---|
| `audio-routing.json` (ADR-0047 A-6) | state (0600 in 0700, `services/write-private.sh`) | shell / shell | 1 | the devices that stopped taking the sound; at most 64; a newer version is read as empty and never rewritten |

## Failure modes
- Wired headphones in a laptop's jack are a port of the built-in sink (ALSA's route changes on that node; no node appears),
  and Quickshell exposes neither routes nor port availability, so they never take the sound when the default is another
  output (HDMI, a dock, USB). PipeWire itself moves the built-in sink's route to the headphones, which covers the usual case
  (the built-in output is the default). Watching the card's routes would mean polling `pw-dump` or a `pw-mon` process:
  not cheap or reliable enough for this slice (review of 2026-11-05, MINOR 3: recorded as a limit).
- `gsettings` without the org.gnome.desktop.sound schema (gsettings-desktop-schemas missing): the write fails, nothing else.
- No PipeWire, or Quickshell not ready: no routing; `pw-play` missing: no sound (one warning per start).
- `pw-dump` fails or times out (2 s): the node's own properties decide (A-4).
- A wall-clock jump: deadlines are timestamps of `Date.now()`; a jump at worst decides early or late once.
- A user repeat delay above 350 ms (Settings › Keyboard): a held volume key plays the feedback also at its start.
- The effects output gone: the shell plays through the default output; the capture helper leaves the fallback to
  WirePlumber (a missing target falls back to the default).

## Tests
- `tests/unit/tst_audioroutinglogic.qml`: classification, keys, startup grace, settle and its cap, takers and priority,
  memory (move away, unplug, WirePlumber restore, choose again, removal with the configured default), reconnect, deadlines,
  persistence (version, malformed, cap).
- `tests/unit/tst_soundslogic.qml` (SoundEffects.js): alert files, argument vectors, volumes, targets, settings gates,
  debounce, repeat gap; `tests/unit/tst_settingssystem.qml`: the Sound Effects group (pick and preview, outputs, alert
  volume, switches, dev session).
- `tests/unit/tst_settingscontract.qml` vectors for the new keys; `tests/unit/settings/tst_systemguard.cpp` for `pw-play`.
- `branding/sounds/generate.py --check`; `tests/shell/capture.sh` (a `pw-play` fake: played after a save and after a copy to
  the clipboard, not when the switch is off or the alert volume is 0, not when no picture was taken).
- `tests/shell/audio_dev_guard.sh`: the guard body also checks that `Sounds.play` runs nothing in dev and that GNOME's
  keys are not written (a `gsettings` shim), and that both run in the control.
- `tst_audioroutinglogic.qml` after the review: the router's switch then the first device leaving (reported or not yet),
  two takers in a row, a person's choice after a router switch, a device that never had the sound; each of the four
  conditions of the removal rule has a mutant that fails a test.

## NOT VERIFIED (cloud container: no PipeWire, Quickshell runtime or Hyprland)
- Routing on real hardware (Bluetooth earbuds, a USB headset, an HDMI display, a dock); WirePlumber's fallback on unplug.
- That `pw-dump <id>` answers within 2 s on the owner's machine; the node properties of the owner's devices.
- Every sound played (`pw-play`, volumes, `--target`), Hyprland's `bell` from a GTK 4 app, the capture shutter.
- Settings › Sound's new group: visual NOT verified.
