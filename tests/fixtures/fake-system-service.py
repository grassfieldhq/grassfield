#!/usr/bin/env python3
"""A fake NetworkManager, BlueZ, the General pane's services or the portal permission store for the Settings D-Bus tests (tests/integration/settings_dbus.sh,
GF-049, ADR-0030).

    fake-system-service.py nm|bluez|general|upower|cupspk|permstore --log FILE --ready FILE [--fail 'Member=org.x.Error|message'] [--slow Member=SECONDS]

It owns org.freedesktop.NetworkManager (or org.bluez; or hostname1, timedate1, timesync1, locale1 and a systemd user manager) on
the bus named by DBUS_SYSTEM_BUS_ADDRESS, which the test sets to a
PRIVATE dbus-daemon. It REFUSES to start on anything else: GF_TEST_BUS=1 must be set, GF_TEST_BUS_DIR must name the test's
scratch directory, and every entry of the address must be a unix socket under that directory or loopback tcp (parsed, not
matched: percent-escapes, dots and lists do not get past it; never a real system bus). It serves a small, fixed world (see below), keeps the state its methods change (the radio, the
connection state, Powered, Connected) and appends one JSON line per call that reaches it to --log, so the test can say exactly
what the Settings app sent. With --fail, the named method answers with that D-Bus error instead; with --slow it answers after that many seconds.

The NetworkManager world: radio on; an Ethernet device and a Wi-Fi device wlan0 (connected, active AP 1); access points
"Home" (secured, strong, active), "Home" (secured, weak), "Cafe" (open), a saved Wi-Fi profile for "Home" and an Ethernet one.
For the network panes: wlan0's addresses (IP4Config, IP6Config), its active connection, a VPN profile (connected) and a WireGuard
one; Delete on a profile removes it; a join with the password "wrong horse" goes down (its active connection's State 4).
The BlueZ world: adapter hci0 powered (named gf-test, not discovering); paired Headphones (connected, battery 80), paired Mouse,
an unpaired device seen earlier, and an unpaired Keyboard K3 in range (an RSSI); discovery, Pair, Trusted and RemoveDevice keep
what they did.
The General world (one process, five names): hostname1 (the reference machine, a laptop), timedate1 (Europe/Paris, NTP on, a fixed
time; ListTimezones), timesync1 (a server and the fallback list), locale1 (LANG=en_US.UTF-8), systemd1 (the user manager: one of
the user's own services under GF_TEST_BUS_DIR/units, one a package ships; Enable/DisableUnitFiles, Reload). The Set* methods of
hostname1 and timedate1 keep what they were given, so a read afterwards shows it.
The UPower world: on battery; a laptop battery (70 %, discharging, 91.5 % of its design capacity, 212 cycles, a charge limit
at 80 % that EnableChargeThreshold switches, a charge history), a mouse's battery (not the computer's) and the display device.
The cups-pk-helper world (Printers, ADR-0030): org.opensuse.CupsPkHelper.Mechanism at "/", the methods Settings calls
(PrinterAdd, PrinterSetEnabled, PrinterSetAcceptJobs, PrinterDelete) and DevicesGet (which it never calls); each answers "" (CUPS
said yes) and keeps the queues it was given, a queue it does not know answers CUPS's "client-error-not-found".
The permission store world (Privacy & Security; on the same private bus, which the test also names as the session bus):
org.freedesktop.impl.portal.PermissionStore with Lookup, List, SetPermission and Delete as xdg-permission-store answers them
(a missing entry is org.freedesktop.portal.Error.NotFound, an unknown table lists empty). Location: Maps allowed (EXACT), Weather
not (NONE) and a malformed application id; the camera: Meet allowed, Booth "ask"; no background entry; saved screen-sharing
selections for Meet (a legacy UUID) and Studio (a current token, beginning with _); no remote desktop table. It also owns
org.freedesktop.portal.Desktop, which exports Background (version 2) and not RemoteDesktop.
"""
import argparse
import json
import os
import sys
import time
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

V = GLib.Variant
NM = "/org/freedesktop/NetworkManager"


def is_private_test_bus(addr, directory):
    """Every ';' entry is unix:path=<socket under directory> (percent-escapes decoded, dots resolved) or tcp on loopback."""
    if not addr or not directory:
        return False
    root = os.path.normpath(directory)
    entries = [e for e in addr.split(";") if e]
    if not entries:
        return False
    for entry in entries:
        transport, sep, rest = entry.partition(":")
        if not sep:
            return False
        kv = {}
        for pair in [p for p in rest.split(",") if p]:
            key, eq, value = pair.partition("=")
            if not eq or not key:
                return False
            kv[key] = urllib.parse.unquote(value)
        if transport == "unix":
            path = kv.get("path", "")
            if set(kv) - {"path", "guid"} or not path.startswith("/") or not os.path.normpath(path).startswith(root + "/"):
                return False
        elif transport == "tcp":
            if set(kv) - {"host", "port", "family", "guid"} or kv.get("host") not in ("127.0.0.1", "localhost", "::1"):
                return False
        else:
            return False
    return True


def refuse_unless_private_bus():
    addr = os.environ.get("DBUS_SYSTEM_BUS_ADDRESS", "")
    if os.environ.get("GF_TEST_BUS") != "1" or not is_private_test_bus(addr, os.environ.get("GF_TEST_BUS_DIR", "")):
        sys.exit("fake-system-service: refusing to run on %r: only a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR, DBUS_SYSTEM_BUS_ADDRESS)" % addr)
    return addr


class DBusError(Exception):
    """A handler's answer with this D-Bus error name (as the real service names it)."""

    def __init__(self, name, message):
        super().__init__(message)
        self.name = name
        self.message = message


def xml(text):
    return Gio.DBusNodeInfo.new_for_xml("<node>%s</node>" % text).interfaces[0]


class Service:
    def __init__(self, conn, log_path, fail, slow):
        self.conn = conn
        self.slow = slow  # {member: seconds}
        self.log_path = log_path
        self.fail = fail  # {member: (error name, message)}
        self.props = {}  # (path, iface) -> {name: GLib.Variant}
        self.setters = {}

    def log(self, **entry):
        with open(self.log_path, "a") as f:
            f.write(json.dumps(entry) + "\n")

    def register(self, path, iface_xml, methods=None, props=None, writable=()):
        info = xml(iface_xml)
        iface = info.name
        self.props[(path, iface)] = dict(props or {})
        methods = methods or {}

        def call(conn, sender, obj_path, interface, member, params, invocation):
            self.log(path=obj_path, iface=interface, member=member, args=params.print_(True))
            if member in self.slow:
                time.sleep(self.slow[member])
            if member in self.fail:
                invocation.return_dbus_error(*self.fail[member])
                return
            handler = methods.get(member)
            if handler is None:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", member)
                return
            try:
                invocation.return_value(handler(params))
            except DBusError as exc:
                invocation.return_dbus_error(exc.name, exc.message)
            except GLib.Error as exc:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", exc.message)

        def get(conn, sender, obj_path, interface, name):
            return self.props[(path, iface)].get(name)

        def set_(conn, sender, obj_path, interface, name, value):
            self.log(path=obj_path, iface=interface, member="Set", args="%s %s" % (name, value.print_(True)))
            if "Set" in self.fail:
                return False
            self.props[(path, iface)][name] = value
            return True

        self.conn.register_object(path, info, call, get, set_ if writable else None)


def nm_world(svc):
    wifi_dev = NM + "/Devices/2"
    aps = {
        NM + "/AccessPoint/1": (b"Home", 71, 1, 0, 0x188),
        NM + "/AccessPoint/2": (b"Home", 40, 1, 0, 0x188),
        NM + "/AccessPoint/3": (b"Cafe", 55, 0, 0, 0),
    }

    def prop(path, iface, name):
        return svc.props[(path, iface)][name]

    def setprop(path, iface, name, value):
        svc.props[(path, iface)][name] = value

    profiles = [NM + "/Settings/1", NM + "/Settings/2", NM + "/Settings/3", NM + "/Settings/4"]
    active_iface = "org.freedesktop.NetworkManager.Connection.Active"
    vpn_uuid = "5b6c7d8e-9f00-4a1b-8c2d-3e4f5a6b7c8e"

    def add_and_activate(p):
        settings = p.unpack()[0]
        psk = settings.get("802-11-wireless-security", {}).get("psk", "")
        # A wrong password: NetworkManager takes the profile, the connection goes down (no agent gives it another password).
        setprop(NM + "/ActiveConnection/2", active_iface, "State", V("u", 4 if psk == "wrong horse" else 2))
        if psk != "wrong horse":
            setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 100))
        return V("(oo)", (NM + "/Settings/9", NM + "/ActiveConnection/2"))

    def deactivate(p):
        path = p.unpack()[0]
        if (path, active_iface) not in svc.props:
            raise GLib.Error("not an active connection")
        setprop(path, active_iface, "State", V("u", 4))
        setprop(NM, "org.freedesktop.NetworkManager", "ActiveConnections",
                V("ao", [a for a in prop(NM, "org.freedesktop.NetworkManager", "ActiveConnections").unpack() if a != path]))

    svc.register(NM, '<interface name="org.freedesktop.NetworkManager">'
                     '<property name="WirelessEnabled" type="b" access="readwrite"/>'
                     '<property name="ActiveConnections" type="ao" access="read"/>'
                     '<method name="GetDevices"><arg direction="out" type="ao"/></method>'
                     '<method name="ActivateConnection"><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="in" type="o"/><arg direction="out" type="o"/></method>'
                     '<method name="DeactivateConnection"><arg direction="in" type="o"/></method>'
                     '<method name="AddAndActivateConnection"><arg direction="in" type="a{sa{sv}}"/><arg direction="in" type="o"/><arg direction="in" type="o"/>'
                     '<arg direction="out" type="o"/><arg direction="out" type="o"/></method></interface>',
                 methods={
                     "GetDevices": lambda p: V("(ao)", ([NM + "/Devices/1", wifi_dev],)),
                     "ActivateConnection": lambda p: (setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 100)), V("(o)", (NM + "/ActiveConnection/1",)))[1],
                     "DeactivateConnection": lambda p: deactivate(p),
                     "AddAndActivateConnection": add_and_activate,
                 },
                 props={"WirelessEnabled": V("b", True), "ActiveConnections": V("ao", [NM + "/ActiveConnection/1", NM + "/ActiveConnection/3"])},
                 writable=("WirelessEnabled",))
    device_xml = ('<interface name="org.freedesktop.NetworkManager.Device"><property name="DeviceType" type="u" access="read"/>'
                  '<property name="Interface" type="s" access="read"/><property name="State" type="u" access="read"/>'
                  '<property name="HwAddress" type="s" access="read"/><property name="ActiveConnection" type="o" access="read"/>'
                  '<property name="Ip4Config" type="o" access="read"/><property name="Ip6Config" type="o" access="read"/>'
                  '<method name="Disconnect"/></interface>')
    svc.register(NM + "/Devices/1", device_xml, methods={"Disconnect": lambda p: None},
                 props={"DeviceType": V("u", 1), "Interface": V("s", "eth0"), "State": V("u", 20), "HwAddress": V("s", "3C:52:82:00:00:01"),
                        "ActiveConnection": V("o", "/"), "Ip4Config": V("o", "/"), "Ip6Config": V("o", "/")})
    svc.register(NM + "/Devices/1", '<interface name="org.freedesktop.NetworkManager.Device.Wired"><property name="Speed" type="u" access="read"/></interface>',
                 props={"Speed": V("u", 1000)})
    svc.register(wifi_dev, device_xml,
                 methods={"Disconnect": lambda p: (setprop(wifi_dev, "org.freedesktop.NetworkManager.Device", "State", V("u", 30)),
                                                   setprop(wifi_dev, "org.freedesktop.NetworkManager.Device.Wireless", "ActiveAccessPoint", V("o", "/")), None)[2]},
                 props={"DeviceType": V("u", 2), "Interface": V("s", "wlan0"), "State": V("u", 100), "HwAddress": V("s", "3C:52:82:00:00:02"),
                        "ActiveConnection": V("o", NM + "/ActiveConnection/1"), "Ip4Config": V("o", NM + "/IP4Config/2"), "Ip6Config": V("o", NM + "/IP6Config/2")})
    svc.register(wifi_dev, '<interface name="org.freedesktop.NetworkManager.Device.Wireless">'
                           '<property name="ActiveAccessPoint" type="o" access="read"/><property name="Bitrate" type="u" access="read"/>'
                           '<method name="GetAllAccessPoints"><arg direction="out" type="ao"/></method>'
                           '<method name="RequestScan"><arg direction="in" type="a{sv}"/></method></interface>',
                 methods={"GetAllAccessPoints": lambda p: V("(ao)", (sorted(aps),)), "RequestScan": lambda p: None},
                 props={"ActiveAccessPoint": V("o", NM + "/AccessPoint/1"), "Bitrate": V("u", 866000)})
    for path, (ssid, strength, flags, wpa, rsn) in aps.items():
        svc.register(path, '<interface name="org.freedesktop.NetworkManager.AccessPoint"><property name="Ssid" type="ay" access="read"/>'
                           '<property name="Strength" type="y" access="read"/><property name="Flags" type="u" access="read"/>'
                           '<property name="WpaFlags" type="u" access="read"/><property name="RsnFlags" type="u" access="read"/>'
                           '<property name="Frequency" type="u" access="read"/></interface>',
                     props={"Ssid": V("ay", ssid), "Strength": V("y", strength), "Flags": V("u", flags), "WpaFlags": V("u", wpa), "RsnFlags": V("u", rsn),
                            "Frequency": V("u", 5180)})
    svc.register(NM + "/IP4Config/2", '<interface name="org.freedesktop.NetworkManager.IP4Config"><property name="AddressData" type="aa{sv}" access="read"/>'
                                      '<property name="Gateway" type="s" access="read"/><property name="NameserverData" type="aa{sv}" access="read"/></interface>',
                 props={"AddressData": V("aa{sv}", [{"address": V("s", "192.168.20.34"), "prefix": V("u", 24)}]), "Gateway": V("s", "192.168.20.1"),
                        "NameserverData": V("aa{sv}", [{"address": V("s", "192.168.20.1")}, {"address": V("s", "9.9.9.9")}])})
    svc.register(NM + "/IP6Config/2", '<interface name="org.freedesktop.NetworkManager.IP6Config"><property name="AddressData" type="aa{sv}" access="read"/>'
                                      '<property name="Gateway" type="s" access="read"/></interface>',
                 props={"AddressData": V("aa{sv}", [{"address": V("s", "fd00:20::34"), "prefix": V("u", 64)}]), "Gateway": V("s", "fe80::1")})
    active_xml = ('<interface name="org.freedesktop.NetworkManager.Connection.Active"><property name="Id" type="s" access="read"/>'
                  '<property name="Uuid" type="s" access="read"/><property name="State" type="u" access="read"/></interface>')
    svc.register(NM + "/ActiveConnection/1", active_xml, props={"Id": V("s", "Maison"), "Uuid": V("s", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"), "State": V("u", 2)})
    svc.register(NM + "/ActiveConnection/2", active_xml, props={"Id": V("s", "Home"), "Uuid": V("s", "99999999-0000-4000-8000-000000000009"), "State": V("u", 1)})
    svc.register(NM + "/ActiveConnection/3", active_xml, props={"Id": V("s", "Office VPN"), "Uuid": V("s", vpn_uuid), "State": V("u", 2)})
    svc.register(NM + "/Settings", '<interface name="org.freedesktop.NetworkManager.Settings"><method name="ListConnections"><arg direction="out" type="ao"/></method></interface>',
                 methods={"ListConnections": lambda p: V("(ao)", (list(profiles),))})
    conn_xml = ('<interface name="org.freedesktop.NetworkManager.Settings.Connection"><method name="GetSettings"><arg direction="out" type="a{sa{sv}}"/></method>'
                '<method name="Delete"/></interface>')

    def delete(path):
        if path in profiles:
            profiles.remove(path)

    def connection(path, settings):
        svc.register(path, conn_xml, methods={"GetSettings": lambda p: V("(a{sa{sv}})", (settings,)), "Delete": lambda p: delete(path)})

    connection(NM + "/Settings/1", {"connection": {"type": V("s", "802-11-wireless"), "uuid": V("s", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"), "id": V("s", "Maison")},
                                    "802-11-wireless": {"ssid": V("ay", b"Home")}})
    connection(NM + "/Settings/2", {"connection": {"type": V("s", "802-3-ethernet"), "uuid": V("s", "11111111-2222-3333-4444-555555555555"), "id": V("s", "Wired")}})
    connection(NM + "/Settings/3", {"connection": {"type": V("s", "vpn"), "uuid": V("s", vpn_uuid), "id": V("s", "Office VPN")}})
    connection(NM + "/Settings/4", {"connection": {"type": V("s", "wireguard"), "uuid": V("s", "6c7d8e9f-0011-4b2c-9d3e-4f5a6b7c8d9f"), "id": V("s", "Home WireGuard")}})
    # The profile a join adds (AddAndActivateConnection): only its Delete is called.
    connection(NM + "/Settings/9", {"connection": {"type": V("s", "802-11-wireless"), "uuid": V("s", "99999999-0000-4000-8000-000000000009"), "id": V("s", "Home")}})
    return "org.freedesktop.NetworkManager"


def bluez_world(svc):
    adapter = "/org/bluez/hci0"
    devices = {
        adapter + "/dev_AA_BB_CC_DD_EE_FF": ("AA:BB:CC:DD:EE:FF", "Headphones", "WH-1000", True, True),
        adapter + "/dev_11_22_33_44_55_66": ("11:22:33:44:55:66", None, "Mouse", True, False),
        adapter + "/dev_66_66_66_66_66_66": ("66:66:66:66:66:66", None, "Seen only", False, False),
        adapter + "/dev_33_33_33_33_33_33": ("33:33:33:33:33:33", "Keyboard K3", "Keyboard K3", False, False),
    }
    extra = {  # Icon, RSSI (in range), Battery1 Percentage
        adapter + "/dev_AA_BB_CC_DD_EE_FF": ("audio-headphones", None, 80),
        adapter + "/dev_33_33_33_33_33_33": ("input-keyboard", -48, None),
    }
    batteries = {path: e[2] for path, e in extra.items() if e[2] is not None}

    def device_props(path, address, alias, name, paired, connected):
        p = {"Address": V("s", address), "Name": V("s", name), "Paired": V("b", paired), "Connected": V("b", connected), "Adapter": V("o", adapter),
             "Trusted": V("b", False)}
        if alias:
            p["Alias"] = V("s", alias)
        icon, rssi, _ = extra.get(path, (None, None, None))
        if icon:
            p["Icon"] = V("s", icon)
        if rssi is not None:
            p["RSSI"] = V("n", rssi)
        return p

    def set_adapter(name, value):
        svc.props[(adapter, "org.bluez.Adapter1")][name] = value

    def remove_device(p):
        path = p.unpack()[0]
        if path not in devices:
            raise GLib.Error("Does Not Exist")
        del devices[path]

    adapter_xml = ('<interface name="org.bluez.Adapter1"><property name="Address" type="s" access="read"/><property name="Powered" type="b" access="readwrite"/>'
                   '<property name="Alias" type="s" access="read"/><property name="Discovering" type="b" access="read"/>'
                   '<property name="Discoverable" type="b" access="read"/><method name="StartDiscovery"/><method name="StopDiscovery"/>'
                   '<method name="RemoveDevice"><arg direction="in" type="o"/></method></interface>')
    svc.register(adapter, adapter_xml,
                 methods={"StartDiscovery": lambda p: set_adapter("Discovering", V("b", True)), "StopDiscovery": lambda p: set_adapter("Discovering", V("b", False)),
                          "RemoveDevice": remove_device},
                 props={"Address": V("s", "00:11:22:33:44:55"), "Powered": V("b", True), "Alias": V("s", "gf-test"), "Discovering": V("b", False),
                        "Discoverable": V("b", False)}, writable=("Powered",))
    dev_xml = ('<interface name="org.bluez.Device1"><property name="Address" type="s" access="read"/><property name="Alias" type="s" access="read"/>'
               '<property name="Name" type="s" access="read"/><property name="Paired" type="b" access="read"/><property name="Connected" type="b" access="read"/>'
               '<property name="Adapter" type="o" access="read"/><property name="Trusted" type="b" access="readwrite"/>'
               '<property name="Icon" type="s" access="read"/><property name="RSSI" type="n" access="read"/>'
               '<method name="Connect"/><method name="Disconnect"/><method name="Pair"/></interface>')
    for path, spec in list(devices.items()):
        props = device_props(path, *spec)

        def make(path=path):
            def setp(name, value):
                svc.props[(path, "org.bluez.Device1")][name] = V("b", value)

            return {"Connect": lambda p: setp("Connected", True), "Disconnect": lambda p: setp("Connected", False), "Pair": lambda p: setp("Paired", True)}

        svc.register(path, dev_xml, methods=make(), props=props, writable=("Trusted",))

    def managed(_):
        objects = {adapter: {"org.bluez.Adapter1": dict(svc.props[(adapter, "org.bluez.Adapter1")])}}
        for path in devices:
            objects[path] = {"org.bluez.Device1": dict(svc.props[(path, "org.bluez.Device1")])}
            if path in batteries:
                objects[path]["org.bluez.Battery1"] = {"Percentage": V("y", batteries[path])}
        return V("(a{oa{sa{sv}}})", (objects,))

    svc.register("/", '<interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg direction="out" type="a{oa{sa{sv}}}"/></method></interface>',
                 methods={"GetManagedObjects": managed})
    return "org.bluez"


def upower_world(svc):
    root = "/org/freedesktop/UPower"
    battery = root + "/devices/battery_BAT0"
    mouse = root + "/devices/mouse_hidpp_battery_0"
    display = root + "/devices/DisplayDevice"
    device_xml = ('<interface name="org.freedesktop.UPower.Device"><property name="Type" type="u" access="read"/>'
                  '<property name="PowerSupply" type="b" access="read"/><property name="IsPresent" type="b" access="read"/>'
                  '<property name="Percentage" type="d" access="read"/><property name="State" type="u" access="read"/>'
                  '<property name="TimeToEmpty" type="x" access="read"/><property name="TimeToFull" type="x" access="read"/>'
                  '<property name="Capacity" type="d" access="read"/><property name="ChargeCycles" type="i" access="read"/>'
                  '<property name="ChargeThresholdSupported" type="b" access="read"/><property name="ChargeThresholdEnabled" type="b" access="read"/>'
                  '<property name="ChargeEndThreshold" type="u" access="read"/><property name="HasHistory" type="b" access="read"/>'
                  '<method name="GetHistory"><arg direction="in" type="s"/><arg direction="in" type="u"/><arg direction="in" type="u"/>'
                  '<arg direction="out" type="a(udu)"/></method>'
                  '<method name="EnableChargeThreshold"><arg direction="in" type="b"/></method></interface>')

    def enable(p):
        svc.props[(battery, "org.freedesktop.UPower.Device")]["ChargeThresholdEnabled"] = V("b", p.unpack()[0])

    def history(p):
        kind, span, points = p.unpack()
        return V("(a(udu))", ([(1792800000, 80.0, 2), (1792803600, 75.5, 2)] if kind == "charge" else [],))

    common = {"TimeToEmpty": V("x", 0), "TimeToFull": V("x", 0), "Capacity": V("d", 0.0), "ChargeCycles": V("i", -1),
              "ChargeThresholdSupported": V("b", False), "ChargeThresholdEnabled": V("b", False), "ChargeEndThreshold": V("u", 0),
              "HasHistory": V("b", False)}
    svc.register(battery, device_xml, methods={"GetHistory": history, "EnableChargeThreshold": enable},
                 props=dict(common, Type=V("u", 2), PowerSupply=V("b", True), IsPresent=V("b", True), Percentage=V("d", 70.0), State=V("u", 2),
                            TimeToEmpty=V("x", 7200), Capacity=V("d", 91.5), ChargeCycles=V("i", 212), ChargeThresholdSupported=V("b", True),
                            ChargeEndThreshold=V("u", 80), HasHistory=V("b", True)))
    svc.register(mouse, device_xml, methods={"GetHistory": history},
                 props=dict(common, Type=V("u", 2), PowerSupply=V("b", False), IsPresent=V("b", True), Percentage=V("d", 40.0), State=V("u", 2)))
    svc.register(display, device_xml, methods={"GetHistory": history},
                 props=dict(common, Type=V("u", 2), PowerSupply=V("b", True), IsPresent=V("b", True), Percentage=V("d", 71.0), State=V("u", 2),
                            TimeToEmpty=V("x", 7300)))
    svc.register(root, '<interface name="org.freedesktop.UPower"><property name="OnBattery" type="b" access="read"/>'
                       '<method name="EnumerateDevices"><arg direction="out" type="ao"/></method></interface>',
                 methods={"EnumerateDevices": lambda p: V("(ao)", ([mouse, battery],))}, props={"OnBattery": V("b", True)})
    return "org.freedesktop.UPower"


def cupspk_world(svc):
    queues = {"GF_Office": {"enabled": True, "accepting": True}}
    name = "org.opensuse.CupsPkHelper.Mechanism"
    s = '<arg direction="in" type="s"/>'
    out = '<arg direction="out" type="s"/>'

    def add(p):
        queues[p[0]] = {"enabled": False, "accepting": False, "uri": p[1], "ppd": p[2]}
        return V("(s)", ("",))

    def setter(key):
        def run(p):
            if p[0] not in queues:
                return V("(s)", ("client-error-not-found",))
            queues[p[0]][key] = p[1]
            return V("(s)", ("",))
        return run

    def delete(p):
        return V("(s)", ("",) if queues.pop(p[0], None) is not None else ("client-error-not-found",))

    svc.register("/", '<interface name="%s">'
                      '<method name="PrinterAdd">%s%s%s%s%s%s</method>'
                      '<method name="PrinterSetEnabled">%s<arg direction="in" type="b"/>%s</method>'
                      '<method name="PrinterSetAcceptJobs">%s<arg direction="in" type="b"/>%s%s</method>'
                      '<method name="PrinterDelete">%s%s</method>'
                      '<method name="DevicesGet"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="as"/>'
                      '<arg direction="in" type="as"/>%s<arg direction="out" type="a{ss}"/></method></interface>'
                      % (name, s, s, s, s, s, out, s, out, s, s, out, s, out, out),
                 methods={"PrinterAdd": add, "PrinterSetEnabled": setter("enabled"), "PrinterSetAcceptJobs": setter("accepting"),
                          "PrinterDelete": delete, "DevicesGet": lambda p: V("(sa{ss})", ("", {}))})
    return name


def permstore_world(svc):
    tables = {
        "location": {"location": {"org.example.Maps": ["EXACT", "1792800000"], "org.example.Weather": ["NONE", "0"], "../x": ["EXACT", "0"]}},
        "devices": {"camera": {"org.example.Meet": ["yes"], "org.example.Booth": ["ask"]}},
        "screencast": {"00000000-1111-2222-3333-444444444444": {"org.example.Meet": ["yes"]},
                       "_0000_fake_0000_0000_": {"org.example.Studio": ["yes"]},
                       # A host app xdg-desktop-portal 1.22 could not name (xdp-app-info-host.c: ""), with a lasting grant.
                       "hostToken_0000": {"": ["yes"]}},
    }
    name = "org.freedesktop.impl.portal.PermissionStore"

    def entry(table, id_):
        found = tables.get(table, {}).get(id_)
        if found is None:
            raise DBusError("org.freedesktop.portal.Error.NotFound", "No entry for %s" % id_)
        return found

    def lookup(p):
        return V("(a{sas}v)", (entry(p[0], p[1]), V("y", 0)))

    def set_permission(p):
        table, create, id_, app, value = p.unpack()
        if not create:
            entry(table, id_)
        tables.setdefault(table, {}).setdefault(id_, {})[app] = list(value)

    def delete(p):
        entry(p[0], p[1])
        del tables[p[0]][p[1]]

    s = '<arg direction="in" type="s"/>'
    svc.register("/org/freedesktop/impl/portal/PermissionStore", '<interface name="%s">'
                 '<method name="Lookup">%s%s<arg direction="out" type="a{sas}"/><arg direction="out" type="v"/></method>'
                 '<method name="List">%s<arg direction="out" type="as"/></method>'
                 '<method name="SetPermission">%s<arg direction="in" type="b"/>%s%s<arg direction="in" type="as"/></method>'
                 '<method name="Delete">%s%s</method></interface>' % (name, s, s, s, s, s, s, s, s),
                 methods={"Lookup": lookup, "List": lambda p: V("(as)", (sorted(tables.get(p[0], {})),)),
                          "SetPermission": set_permission, "Delete": delete})
    # The desktop portal exports Background and not RemoteDesktop (a backend that implements only the first): GDBus itself
    # answers a Get on the missing interface with InvalidArgs, as the real portal's does.
    portal = "org.freedesktop.portal.Desktop"
    svc.register("/org/freedesktop/portal/desktop", '<interface name="org.freedesktop.portal.Background">'
                 '<property name="version" type="u" access="read"/></interface>', props={"version": V("u", 2)})
    return [name, portal]


def general_world(svc):
    directory = os.environ["GF_TEST_BUS_DIR"]
    host, time_, sync, locale, systemd = ("/org/freedesktop/hostname1", "/org/freedesktop/timedate1", "/org/freedesktop/timesync1",
                                          "/org/freedesktop/locale1", "/org/freedesktop/systemd1")

    def setp(path, iface, name, value):
        svc.props[(path, iface)][name] = value

    hi = "org.freedesktop.hostname1"
    svc.register(host, '<interface name="org.freedesktop.hostname1">'
                       '<property name="PrettyHostname" type="s" access="read"/><property name="StaticHostname" type="s" access="read"/>'
                       '<property name="Hostname" type="s" access="read"/><property name="Chassis" type="s" access="read"/>'
                       '<property name="HardwareVendor" type="s" access="read"/><property name="HardwareModel" type="s" access="read"/>'
                       '<method name="SetPrettyHostname"><arg direction="in" type="s"/><arg direction="in" type="b"/></method>'
                       '<method name="SetStaticHostname"><arg direction="in" type="s"/><arg direction="in" type="b"/></method></interface>',
                 methods={"SetPrettyHostname": lambda p: setp(host, hi, "PrettyHostname", V("s", p[0])),
                          "SetStaticHostname": lambda p: setp(host, hi, "StaticHostname", V("s", p[0]))},
                 props={"PrettyHostname": V("s", "Grassfield Reference"), "StaticHostname": V("s", "grassfield-reference"),
                        "Hostname": V("s", "grassfield-reference"), "Chassis": V("s", "laptop"), "HardwareVendor": V("s", "Grassfield"),
                        "HardwareModel": V("s", "Reference Laptop 14")})
    ti = "org.freedesktop.timedate1"
    svc.register(time_, '<interface name="org.freedesktop.timedate1">'
                        '<property name="Timezone" type="s" access="read"/><property name="NTP" type="b" access="read"/>'
                        '<property name="CanNTP" type="b" access="read"/><property name="NTPSynchronized" type="b" access="read"/>'
                        '<property name="LocalRTC" type="b" access="read"/><property name="TimeUSec" type="t" access="read"/>'
                        '<method name="SetNTP"><arg direction="in" type="b"/><arg direction="in" type="b"/></method>'
                        '<method name="SetTimezone"><arg direction="in" type="s"/><arg direction="in" type="b"/></method>'
                        '<method name="SetTime"><arg direction="in" type="x"/><arg direction="in" type="b"/><arg direction="in" type="b"/></method>'
                        '<method name="ListTimezones"><arg direction="out" type="as"/></method></interface>',
                 methods={"SetNTP": lambda p: setp(time_, ti, "NTP", V("b", p[0])),
                          "SetTimezone": lambda p: setp(time_, ti, "Timezone", V("s", p[0])),
                          "SetTime": lambda p: setp(time_, ti, "TimeUSec", V("t", p[0])),
                          "ListTimezones": lambda p: V("(as)", (["Europe/Paris", "Europe/Zurich", "America/New_York", "UTC", "../etc/passwd"],))},
                 props={"Timezone": V("s", "Europe/Paris"), "NTP": V("b", True), "CanNTP": V("b", True), "NTPSynchronized": V("b", True),
                        "LocalRTC": V("b", False), "TimeUSec": V("t", 1792832460000000)})
    svc.register(sync, '<interface name="org.freedesktop.timesync1.Manager">'
                       '<property name="ServerName" type="s" access="read"/><property name="LinkNTPServers" type="as" access="read"/>'
                       '<property name="SystemNTPServers" type="as" access="read"/><property name="FallbackNTPServers" type="as" access="read"/></interface>',
                 props={"ServerName": V("s", "2.arch.pool.ntp.org"), "LinkNTPServers": V("as", []), "SystemNTPServers": V("as", []),
                        "FallbackNTPServers": V("as", ["0.arch.pool.ntp.org", "1.arch.pool.ntp.org", "2.arch.pool.ntp.org"])})
    svc.register(locale, '<interface name="org.freedesktop.locale1"><property name="Locale" type="as" access="read"/></interface>',
                 props={"Locale": V("as", ["LANG=en_US.UTF-8"])})
    units = {directory + "/units/sync.service": "enabled", directory + "/units/backup.service": "disabled",
             "/usr/lib/systemd/user/shipped.service": "enabled"}

    def enable(names, on):
        for path in list(units):
            if path.rsplit("/", 1)[-1] in names:
                units[path] = "enabled" if on else "disabled"

    svc.register(systemd, '<interface name="org.freedesktop.systemd1.Manager">'
                          '<method name="ListUnitFilesByPatterns"><arg direction="in" type="as"/><arg direction="in" type="as"/><arg direction="out" type="a(ss)"/></method>'
                          '<method name="EnableUnitFiles"><arg direction="in" type="as"/><arg direction="in" type="b"/><arg direction="in" type="b"/>'
                          '<arg direction="out" type="b"/><arg direction="out" type="a(sss)"/></method>'
                          '<method name="DisableUnitFiles"><arg direction="in" type="as"/><arg direction="in" type="b"/><arg direction="out" type="a(sss)"/></method>'
                          '<method name="Reload"/></interface>',
                 methods={"ListUnitFilesByPatterns": lambda p: V("(a(ss))", (sorted(units.items()),)),
                          "EnableUnitFiles": lambda p: (enable(p[0], True), V("(ba(sss))", (False, [])))[1],
                          "DisableUnitFiles": lambda p: (enable(p[0], False), V("(a(sss))", ([],)))[1],
                          "Reload": lambda p: None})
    return ["org.freedesktop.hostname1", "org.freedesktop.timedate1", "org.freedesktop.timesync1", "org.freedesktop.locale1",
            "org.freedesktop.systemd1"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("service", choices=["nm", "bluez", "general", "upower", "cupspk", "permstore"])
    ap.add_argument("--log", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--fail", action="append", default=[])
    ap.add_argument("--slow", action="append", default=[])
    args = ap.parse_args()
    addr = refuse_unless_private_bus()
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    fail = {}
    for spec in args.fail:
        member, _, rest = spec.partition("=")
        name, _, message = rest.partition("|")
        fail[member] = (name, message)
    slow = {spec.partition("=")[0]: float(spec.partition("=")[2]) for spec in args.slow}
    svc = Service(conn, args.log, fail, slow)
    worlds = {"nm": nm_world, "bluez": bluez_world, "general": general_world, "upower": upower_world, "cupspk": cupspk_world,
              "permstore": permstore_world}
    names = worlds[args.service](svc)
    names = names if isinstance(names, list) else [names]
    owned = set()

    def acquired(c, n):
        owned.add(n)
        if len(owned) == len(names):
            with open(args.ready, "w") as f:
                f.write("ready\n")

    for name in names:
        Gio.bus_own_name_on_connection(conn, name, Gio.BusNameOwnerFlags.NONE, acquired, None)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
