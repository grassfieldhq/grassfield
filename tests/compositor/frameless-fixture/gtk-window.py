#!/usr/bin/env python3
"""A GTK 3 window of a given app id, for tests/compositor/frameless_chrome.sh (Firefox's two title bar modes).

    gtk-window.py APP_ID TITLE 0|1

With 1 the window decorates itself client-side with an empty title bar widget, as Firefox does for its own frame
(widget/gtk nsWindow: gtk_window_set_titlebar with an empty widget; GTK 3 then asks KDE server-decoration for client mode);
with 0 it is a plain GTK 3 window, as Firefox with its "Title Bar" option on (GTK 3 asks for server mode and draws no bar).
"""
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402


def main():
    app_id, title, csd = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
    GLib.set_prgname(app_id)
    window = Gtk.Window(title=title)
    window.set_default_size(420, 220)
    if csd:
        window.set_titlebar(Gtk.Fixed())
    window.add(Gtk.Label(label=title))
    window.connect("destroy", Gtk.main_quit)
    window.show_all()
    print("READY", flush=True)
    Gtk.main()


main()
