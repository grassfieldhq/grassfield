-- Real-session autostart (ADR-0001). The nested dev session does not use this file.

hl.on("hyprland.start", function()
  -- Hand the session environment to systemd and D-Bus activation (uwsm finalizes the compositor unit).
  local vars = "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE GRASSFIELD_SESSION"
  -- Pointer theme (cursor.lua, ADR-0014): uwsm finalize exports only the variables it is given, so the shell and
  -- D-Bus activated apps (systemd user units do not inherit Hyprland's environment) need these named.
  vars = vars .. " XCURSOR_THEME XCURSOR_SIZE HYPRCURSOR_THEME HYPRCURSOR_SIZE"
  local import_env = "if command -v uwsm >/dev/null; then uwsm finalize " .. vars .. "; else dbus-update-activation-environment --systemd " .. vars .. "; fi"

  -- Both units have ConditionEnvironment=GRASSFIELD_SESSION=1, which reads the environment that the import hands to
  -- systemd: they start only after that import has finished (a separate exec_cmd would race it and be skipped).
  -- One command, one import, then the units in order.
  --
  -- Global menus (ADR-0008): the menu bridge starts before the shell and before any application. It stays in
  -- standby (no com.canonical.AppMenu.Registrar) until the shell reports the plugin's appmenu feature, so apps
  -- started without the plugin keep their in-window menus. Apps check for the registrar once, at their start.
  --
  -- The password-prompt bridge (ADR-0035 D-9) is started next, without waiting for it (--no-block): it owns gcr's system
  -- prompter name only once the shell has connected to its socket, and until then (or without a shell) the stock prompter
  -- answers as before.
  --
  -- The Secret Service handover (ADR-0035 D-12) comes before the shell: `systemctl --user start` returns once a ksecretd left
  -- over from an earlier session has let go of org.freedesktop.secrets (at most 10 s), so no app the user opens from the
  -- Dock can reach KWallet there; the rest of the handover goes on in the background.
  --
  -- The Settings portal backend (ADR-0035 D-8) is started next, without waiting for it (--no-block): the shell never waits
  -- on it, and an app that reads the portal before it is up starts it by D-Bus activation and gets its values.
  --
  -- The security process (ADR-0041 step 1, S1: grassfield-security.service, a second Quickshell process beside the UI
  -- that hosts nothing moved yet; the lock, idle, the sleep inhibitor and the polkit agent move into it at S2 and S3) is
  -- started just before the shell, without waiting for it (--no-block): the shell never waits on it, and until S2 the
  -- shell keeps every security module.
  --
  -- grassfield-shell runs as a systemd user service so it restarts on crash (gate R1). It starts even when the
  -- import, the bridge, the prompter, the handover, the portal backend or the security process failed (";"): the bar then
  -- shows T0.
  --
  -- Session services that Omarchy's own session provides through its shell or its autostart (02 §5.3): crash and
  -- low-battery notifications, the pending-migrations notice, removable media (udiskie). Each unit has the same
  -- ConditionEnvironment and skips itself where it does not apply (no battery, no udiskie).
  -- grassfield-pacman-watch.path (ADR-0041 step 2b, U31) watches pacman's local database and asks the shell for a check
  -- once a transaction's burst settled: a package installed from a terminal is seen without waiting for the next
  -- scheduled check. grassfield-shell-watchdog.timer (ADR-0041 step 6a, SQ-5 A) asks the shell a question every 30 s and
  -- restarts a shell that stopped answering (three misses in a row).
  local services = "grassfield-crash-watch.service grassfield-battery-watch.service grassfield-migrate-notify.service grassfield-automount.service grassfield-pacman-watch.path grassfield-shell-watchdog.timer"
  hl.exec_cmd("{ " .. import_env .. "; } && systemctl --user start grassfield-menu-bridge.service; systemctl --user start --no-block grassfield-prompter.service; systemctl --user start grassfield-secrets-handover.service; systemctl --user start --no-block grassfield-portal-settings.service; systemctl --user start --no-block grassfield-security.service; systemctl --user start grassfield-shell.service; systemctl --user start " .. services)

  -- Default applications (decision F-19 of docs/specs/files.md, owner report 2026-11-07): Grassfield's own apps (Preview for
  -- pictures and PDF, Files for folders) become this session's defaults where the user's grassfield-mimeapps.list has no entry
  -- for the type yet. The XDG MIME applications specification reads that file before mimeapps.list only where
  -- XDG_CURRENT_DESKTOP names Grassfield (session.lua): the Omarchy session keeps its own defaults, and a choice the user makes
  -- here (Files' Get Info > Change All…) is never replaced. Grassfield Files does it and exits; no window.
  hl.exec_cmd("command -v grassfield-files >/dev/null && grassfield-files --seed-default-apps")

  -- What Omarchy's autostart does besides starting its shell: the power profile for the current power source, the
  -- post-boot hooks of ~/.config/omarchy/hooks, and the lid state (clamshell with an external display at start).
  hl.exec_cmd("command -v omarchy-powerprofiles-init >/dev/null && omarchy-powerprofiles-init")
  hl.exec_cmd("sleep 2; command -v omarchy-hook >/dev/null && omarchy-hook post-boot")
  hl.exec_cmd("/usr/lib/grassfield/grassfield-lid reconcile")
end)
