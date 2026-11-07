#!/usr/bin/python3 -I
# A ScreenCast portal client that captures as Chromium's WebRTC capturer (BaseCapturerPipeWire) does when a page asks to share
# the screen: one capture for the browser's own picker preview, then the real one, from the same D-Bus connection, the second
# with the restore token the first one got (RestoreTokenManager). Each capture: CreateSession, SelectSources (a monitor, not
# multiple, cursor embedded, persist_mode, the token), Start, OpenPipeWireRemote, frames read with GStreamer's pipewiresrc
# (none read when GStreamer's Python bindings or pipewiresrc are missing), Close. Prints one JSON line per capture.
# Usage: client.py <persist_mode>
import json
import os
import sys
import time

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst
    Gst.init(None)
    HAVE_GST = Gst.ElementFactory.find("pipewiresrc") is not None
except (ImportError, ValueError):
    HAVE_GST = False

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
sc = dbus.Interface(bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop"),
                    "org.freedesktop.portal.ScreenCast")
sender = bus.get_unique_name()[1:].replace(".", "_")
counter = [0]


def request(call, *args, options):
    counter[0] += 1
    token = "gf%d_%d" % (os.getpid(), counter[0])
    options = dict(options, handle_token=token)
    path = "/org/freedesktop/portal/desktop/request/%s/%s" % (sender, token)
    loop = GLib.MainLoop()
    got = {}

    def on_response(code, results):
        got.update(code=int(code), results=results)
        loop.quit()

    match = bus.add_signal_receiver(on_response, "Response", "org.freedesktop.portal.Request", path=path)
    call(*args, dbus.Dictionary(options, signature="sv"))
    GLib.timeout_add_seconds(20, loop.quit)
    loop.run()
    match.remove()
    return got.get("code", -1), got.get("results", {})


def frames(fd, node, want=2, seconds=8):
    # Frames as RGB, each summed up by its mean and spread (a blank or white picture has no spread).
    pipe = Gst.parse_launch("pipewiresrc fd=%d path=%d always-copy=true ! videoconvert ! video/x-raw,format=RGB ! "
                            "appsink name=sink max-buffers=1 drop=true sync=false" % (fd, node))
    sink = pipe.get_by_name("sink")
    pipe.set_state(Gst.State.PLAYING)
    seen = []
    deadline = time.monotonic() + seconds
    while len(seen) < want and time.monotonic() < deadline:
        sample = sink.emit("try-pull-sample", Gst.SECOND // 2)
        if sample is None:
            continue
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if not ok:
            continue
        data = bytes(info.data)
        buf.unmap(info)
        values = data[::max(1, len(data) // 20000)]
        mean = sum(values) / len(values)
        spread = (sum((v - mean) ** 2 for v in values) / len(values)) ** 0.5
        seen.append({"mean": round(mean, 1), "spread": round(spread, 1)})
    pipe.set_state(Gst.State.NULL)
    return seen


def capture(persist_mode, restore_token):
    out = {"token_given": bool(restore_token)}
    code, results = request(sc.CreateSession, options={"session_handle_token": "gfs%d_%d" % (os.getpid(), counter[0] + 1)})
    if code != 0:
        return dict(out, failed="CreateSession %d" % code)
    session = dbus.ObjectPath(str(results["session_handle"]))
    opts = {"types": dbus.UInt32(1), "multiple": False, "cursor_mode": dbus.UInt32(2), "persist_mode": dbus.UInt32(persist_mode)}
    if restore_token:
        opts["restore_token"] = restore_token
    code, _ = request(sc.SelectSources, session, options=opts)
    if code != 0:
        return dict(out, failed="SelectSources %d" % code)
    code, results = request(sc.Start, session, "", options={})
    if code != 0:
        return dict(out, failed="Start %d" % code)
    out["token"] = str(results.get("restore_token", "")) or None
    streams = results.get("streams", [])
    out["streams"] = len(streams)
    if streams and HAVE_GST:
        fd = sc.OpenPipeWireRemote(session, dbus.Dictionary({}, signature="sv")).take()
        out["frames"] = frames(fd, int(streams[0][0]))
        os.close(fd)
    dbus.Interface(bus.get_object("org.freedesktop.portal.Desktop", session), "org.freedesktop.portal.Session").Close()
    return out


persist = int(sys.argv[1])
first = capture(persist, "")
print(json.dumps(first), flush=True)
print(json.dumps(capture(persist, first.get("token") or "")), flush=True)
