#!/usr/bin/env python3
"""A fake polkit authority for tests/security/authagent_registration.sh (ADR-0041 S3, the opus delta review of S3, MAJOR-1),
on a private "system" bus of the test's own.

  fake-polkit-authority.py --log FILE [--refuse N] [--delay-ms MS [--delay-from K]]

Owns org.freedesktop.PolicyKit1 and serves org.freedesktop.PolicyKit1.Authority at /org/freedesktop/PolicyKit1/Authority:
RegisterAuthenticationAgent and RegisterAuthenticationAgentWithOptions refuse the first N calls as polkitd 126 refuses a
second agent for a session ("An authentication agent already exists for the given subject"), then accept;
with --delay-ms, the K-th call and every later one (--delay-from, default 1) is answered MS later, as a hung polkitd
answers (Quickshell's registration call is synchronous, so its caller stands still meanwhile: the opus review of S3,
round 2, MINOR-A); UnregisterAuthenticationAgent answers. It never calls an agent back (no request is ever started). Each call is one line in
FILE, flushed: "<epoch ms> register <object path> refused|accepted", "<epoch ms> unregister <object path>"; "#owned" once
the name is held. Refuses any bus that is not under GF_TEST_BUS_DIR (the rule of the tests' fakes). Test data only. Run it
with python3 -I.
"""
import argparse
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

NAME = "org.freedesktop.PolicyKit1"
PATH = "/org/freedesktop/PolicyKit1/Authority"
XML = """<node><interface name="org.freedesktop.PolicyKit1.Authority">
  <method name="RegisterAuthenticationAgent">
    <arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>
  </method>
  <method name="RegisterAuthenticationAgentWithOptions">
    <arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/>
  </method>
  <method name="UnregisterAuthenticationAgent">
    <arg type="(sa{sv})" direction="in"/><arg type="s" direction="in"/>
  </method>
  <property name="BackendName" type="s" access="read"/>
  <property name="BackendVersion" type="s" access="read"/>
  <property name="BackendFeatures" type="u" access="read"/>
</interface></node>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--refuse", type=int, default=0)
    ap.add_argument("--delay-ms", type=int, default=0)
    ap.add_argument("--delay-from", type=int, default=1)
    args = ap.parse_args()

    address = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
    root = os.environ.get("GF_TEST_BUS_DIR", "")
    if not root or not address.startswith("unix:path=" + root + "/"):
        sys.exit("fake-polkit-authority: refused: not a private test bus under GF_TEST_BUS_DIR")

    log = open(args.log, "a", buffering=1, encoding="utf-8")
    bus = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    calls = [0]

    def now():
        return int(time.time() * 1000)

    def call(conn, sender, path, iface, method, params, invocation):
        if method in ("RegisterAuthenticationAgent", "RegisterAuthenticationAgentWithOptions"):
            calls[0] += 1
            agent_path = params.unpack()[2]
            refused = calls[0] <= args.refuse
            log.write("%d register %s %s\n" % (now(), agent_path, "refused" if refused else "accepted"))

            def answer():
                if refused:
                    invocation.return_dbus_error("org.freedesktop.PolicyKit1.Error.Failed",
                                                 "An authentication agent already exists for the given subject")
                else:
                    invocation.return_value(None)
                return False

            if args.delay_ms > 0 and calls[0] >= args.delay_from:
                GLib.timeout_add(args.delay_ms, answer)
            else:
                answer()
        elif method == "UnregisterAuthenticationAgent":
            log.write("%d unregister %s\n" % (now(), params.unpack()[1]))
            invocation.return_value(None)
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def get(conn, sender, path, iface, prop):
        return {"BackendName": GLib.Variant("s", "fake"), "BackendVersion": GLib.Variant("s", "0"),
                "BackendFeatures": GLib.Variant("u", 0)}[prop]

    node = Gio.DBusNodeInfo.new_for_xml(XML)
    bus.register_object(PATH, node.interfaces[0], call, get, None)
    # The fake of the previous phase may still hold the name for a moment after it was stopped: ask again for up to 5 s.
    for _ in range(50):
        reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                              GLib.Variant("(su)", (NAME, 4)), GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, 5000, None)
        if reply.unpack()[0] == 1:
            break
        time.sleep(0.1)
    else:
        sys.exit("fake-polkit-authority: could not own " + NAME)
    log.write("#owned\n")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
