#!/usr/bin/env python3
"""Drives the Linux build through AT-SPI, the accessibility tree Slint
exposes, and its tray through D-Bus, as a desktop's tray would. Run it with
smoke-linux.sh, which gives it a display and a D-Bus session of its own.

It checks the table and sorting, grouping off, End Task and Force Quit on
throwaway `sleep` processes it starts (and always ends), the keyboard
(with xdotool, when installed), Start at sign-in, a Startup switch,
History, one running copy, and the tray's title, icon and menu, ending
with the menu's Quit. Settings, history and autostart entries go to
temporary folders, so nothing of the user's is touched.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import warnings

import gi

# Gio's register_object is marked deprecated in newer PyGObject, but its
# replacement is missing from the versions current Ubuntu ships.
warnings.filterwarnings("ignore", category=DeprecationWarning)
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

failures = 0


def check(ok, what):
    global failures
    print(("ok: " if ok else "FAIL: ") + what, flush=True)
    if not ok:
        failures += 1


def pump(seconds=0.0):
    """Lets D-Bus calls (the tray's, AT-SPI's events) through for a while."""
    end = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while True:
        while context.pending():
            context.iteration(False)
        if time.monotonic() >= end:
            return
        time.sleep(0.05)


def wait_for(probe, seconds=10.0, step=0.25):
    """Probes until it gives something truthy, or the time is up."""
    end = time.monotonic() + seconds
    while True:
        found = probe()
        if found or time.monotonic() >= end:
            return found
        pump(step)


# --- A tray host: a minimal StatusNotifierWatcher, as desktops run. ----------

WATCHER = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>
"""
registered = []  # (bus name, object path)


def on_watcher_call(connection, sender, path, interface, method, parameters, invocation):
    if method == "RegisterStatusNotifierItem":
        (service,) = parameters.unpack()
        if service.startswith("/"):
            registered.append((sender, service))
        else:
            registered.append((service, "/StatusNotifierItem"))
    invocation.return_value(None)


def on_watcher_property(connection, sender, path, interface, name):
    if name == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", [bus + path for bus, path in registered])
    if name == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    return GLib.Variant("i", 0)


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
bus.register_object(
    "/StatusNotifierWatcher",
    Gio.DBusNodeInfo.new_for_xml(WATCHER).interfaces[0],
    on_watcher_call,
    on_watcher_property,
    None,
)
Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE, None, None)


def item_property(name):
    service, path = registered[0]
    reply = bus.call_sync(
        service,
        path,
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", name)),
        GLib.VariantType("(v)"),
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )
    return reply.unpack()[0]


def menu_items():
    """The tray menu's entries, as (id, label)."""
    service, _ = registered[0]
    menu = item_property("Menu")
    reply = bus.call_sync(
        service,
        menu,
        "com.canonical.dbusmenu",
        "GetLayout",
        GLib.Variant("(iias)", (0, -1, [])),
        None,
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )
    _, (_, _, children) = reply.unpack()
    return menu, [(child[0], child[1].get("label", "")) for child in children]


# --- The app, through AT-SPI. ---------------------------------------------------

binary = sys.argv[1]
home = tempfile.mkdtemp(prefix="otm-smoke-")
environment = dict(os.environ, XDG_CONFIG_HOME=os.path.join(home, "config"), XDG_DATA_HOME=os.path.join(home, "data"))
instance = f"smoke-{os.getpid()}"
autostart = os.path.join(home, "config", "autostart")
os.makedirs(autostart)
with open(os.path.join(autostart, "smoke-entry.desktop"), "w") as entry:
    entry.write("[Desktop Entry]\nType=Application\nName=Smoke Entry\nExec=true\n")

Atspi.init()
app = subprocess.Popen([binary, "--instance", instance, "--exit-after", "180"], env=environment)
sleepers = []


def sleeper():
    """A `sleep` whose parent has gone, so it heads a group of its own."""
    pid = int(subprocess.check_output(["sh", "-c", "sleep 120 >/dev/null 2>&1 & echo $!"]).strip())
    sleepers.append(pid)
    return pid


def running(pid):
    try:
        with open(f"/proc/{pid}/stat") as stat:
            return stat.read().split(")")[-1].split()[0] != "Z"
    except FileNotFoundError:
        return False


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child is not None and child.get_process_id() == app.pid:
            return child
    return None


def nodes(root, depth=0):
    if root is None or depth > 40:
        return
    yield root
    try:
        count = root.get_child_count()
    except GLib.Error:
        return
    for index in range(count):
        try:
            child = root.get_child_at_index(index)
        except GLib.Error:
            continue
        yield from nodes(child, depth + 1)


def find(role, pattern=None, every=False):
    """Accessibles with this role name ("button", "list item"...) whose name matches."""
    root = application()
    if root is None:
        return [] if every else None
    root.clear_cache()
    found = []
    for node in nodes(root):
        try:
            if node.get_role_name() == role and (pattern is None or re.search(pattern, node.get_name() or "")):
                if not every:
                    return node
                found.append(node)
        except GLib.Error:
            continue
    return found if every else None


def labels(pattern):
    return [node.get_name() for node in find("label", pattern, every=True)]


def press(node):
    node.get_action_iface().do_action(0)
    pump(0.6)


def press_button(name):
    button = wait_for(lambda: find("button", f"^{re.escape(name)}$"), 5)
    if button is None:
        raise RuntimeError(f"No button named {name}.")
    press(button)


def row(pid):
    return find("list item", f", PID {pid},")


def selected(node):
    return node is not None and node.get_state_set().contains(Atspi.StateType.SELECTED)


try:
    window = wait_for(lambda: find("frame") or find("window"), 30)
    check(window is not None and window.get_name() == "OpenTaskManager", "the window, titled OpenTaskManager")

    rows = wait_for(lambda: [r for r in find("list item", ", PID \\d+", every=True)], 20)
    check(len(rows) >= 5, f"the table lists processes ({len(rows)} rows in view)")
    check(find("button", "^CPU, sorted highest first$") is not None, "starts sorted by CPU, highest first")

    grouping = find("check box", "^Group by app$")
    if grouping is not None and grouping.get_state_set().contains(Atspi.StateType.CHECKED):
        press(grouping)
    check(not find("list item", ", group of \\d+ processes", every=True), "Group by app off lists every process flat")

    # Newest processes first, so the test's own appear at the top.
    press(find("button", "^PID"))
    check(find("button", "^PID, sorted highest first$") is not None, "clicking PID sorts highest first")

    first = sleeper()
    target = wait_for(lambda: row(first), 10)
    check(target is not None, f"a new process appears (sleep, PID {first})")
    press(target)
    check(selected(row(first)), "selecting it marks it selected")
    press_button("End Task")
    check(wait_for(lambda: not running(first), 5), "End Task ends it (SIGTERM)")
    check(wait_for(lambda: labels(f"^Asked sleep \\(PID {first}\\) to quit\\.$"), 3), "and says so")

    second = sleeper()
    press(wait_for(lambda: row(second), 10))
    press_button("Force Quit…")
    check(bool(labels(f"^Force quit sleep \\(PID {second}\\)\\? It stops at once")), "Force Quit asks first")
    press_button("Cancel")
    check(running(second) and not labels("^Force quit "), "Cancel ends nothing")
    press_button("Force Quit…")
    press_button("Force Quit")
    check(wait_for(lambda: not running(second), 5), "confirming ends it (SIGKILL)")
    check(bool(labels(f"^Ended sleep \\(PID {second}\\) at once\\.$")), "and says so")
    press_button("Dismiss")

    # The keyboard, typed into the virtual display.
    if shutil.which("xdotool"):
        third = sleeper()
        node = wait_for(lambda: row(third), 10)
        extents = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        subprocess.run(["xdotool", "mousemove", str(extents.x + 20), str(extents.y + extents.height // 2), "click", "1"], check=True)
        pump(0.6)
        check(selected(row(third)), "a click selects a row and gives the table the keyboard")
        subprocess.run(["xdotool", "key", "Down"], check=True)
        pump(0.6)
        check(not selected(row(third)), "Down moves the selection on")
        subprocess.run(["xdotool", "key", "Up"], check=True)
        pump(0.6)
        check(selected(row(third)), "Up moves it back")
        subprocess.run(["xdotool", "key", "shift+Delete"], check=True)
        pump(0.6)
        check(bool(labels(f"^Force quit sleep \\(PID {third}\\)\\?")), "Shift+Delete asks to force quit")
        subprocess.run(["xdotool", "key", "Escape"], check=True)
        pump(0.6)
        check(not labels("^Force quit ") and running(third), "Esc cancels")
        subprocess.run(["xdotool", "key", "Delete"], check=True)
        check(wait_for(lambda: not running(third), 5), "Delete ends it")
        subprocess.run(["xdotool", "key", "Escape"], check=True)
        pump(0.4)
    else:
        print("skipped: the keyboard checks (no xdotool)")

    # Start at sign-in: an autostart entry in the account's (here temporary) folder.
    entry = os.path.join(autostart, f"opentaskmanager-{instance}.desktop")
    press(find("check box", "^Start at sign-in$"))
    written = wait_for(lambda: os.path.exists(entry), 3)
    text = open(entry).read() if written else ""
    check(f'Exec="{binary}" --hidden --instance {instance}' in text, "Start at sign-in writes an autostart entry")
    press(find("check box", "^Start at sign-in$"))
    check(wait_for(lambda: not os.path.exists(entry), 3), "and turning it off removes it")

    # Startup: the test's entry, switched off and on.
    press(find("page tab", "^Startup$"))
    listed = wait_for(lambda: find("list item", "^Smoke Entry, "), 5)
    check(listed is not None and listed.get_name().startswith("Smoke Entry, Enabled, Your autostart folder"), "the Startup page lists the test's entry")
    switch = next((node for node in nodes(listed) if node is not listed and node.get_action_iface() is not None), None)
    if switch is not None:
        press(switch)
        check(wait_for(lambda: find("list item", "^Smoke Entry, Disabled, "), 3) is not None, "its switch turns it off")
        check("Hidden=true" in open(os.path.join(autostart, "smoke-entry.desktop")).read(), "with Hidden=true in its entry")
    else:
        check(False, "a switch on the Startup row")

    # History: a record comes every 10 s.
    press(find("page tab", "^History$"))
    check(wait_for(lambda: labels(" recorded in this range"), 25), "History shows what was recorded")
    check(bool(wait_for(lambda: labels("\\(PID \\d+\\) . CPU "), 5)), "and the busiest processes at now")
    slider = find("slider")
    if slider is not None:
        slider.get_value_iface().set_current_value(0)
        check(wait_for(lambda: labels("^Nothing recorded at "), 3), "the hour's start, before the app ran, is a gap")
    press(find("page tab", "^Processes$"))

    # One copy: a second launch hands over and exits.
    second_copy = subprocess.run([binary, "--instance", instance], env=environment, timeout=15)
    check(second_copy.returncode == 0 and app.poll() is None, "a second launch hands over and exits")

    # The tray: registered with the host, with its title, icon and menu.
    check(wait_for(lambda: registered, 10), "the tray icon registers with the desktop's tray host")
    if registered:
        check(item_property("Title") == "OpenTaskManager", "titled OpenTaskManager")
        pixmaps = item_property("IconPixmap")
        check(bool(pixmaps) and pixmaps[0][0] >= 16 and len(pixmaps[0][2]) == pixmaps[0][0] * pixmaps[0][1] * 4, "with an icon drawn from CPU load")
        menu, entries = menu_items()
        labels_in_menu = [label for _, label in entries]
        check("Open OpenTaskManager" in labels_in_menu and "Quit OpenTaskManager" in labels_in_menu, f"and a menu: {labels_in_menu}")
        quit_id = next((ident for ident, label in entries if label == "Quit OpenTaskManager"), None)
        if quit_id is not None:
            bus.call_sync(
                registered[0][0],
                menu,
                "com.canonical.dbusmenu",
                "Event",
                GLib.Variant("(isvu)", (quit_id, "clicked", GLib.Variant("s", ""), 0)),
                None,
                Gio.DBusCallFlags.NONE,
                5000,
                None,
            )
            try:
                app.wait(10)
            except subprocess.TimeoutExpired:
                pass
            check(app.poll() is not None, "Quit in the tray menu quits the app")
finally:
    for pid in sleepers:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if app.poll() is None:
        app.kill()
        app.wait()
    shutil.rmtree(home, ignore_errors=True)

if failures:
    print(f"{failures} check(s) failed")
    sys.exit(1)
print("All smoke checks passed.")
