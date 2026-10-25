#!/bin/bash
# Runs the Linux smoke test (smoke-linux.py) on a display of its own (Xvfb)
# in a D-Bus session of its own, with accessibility turned on as a screen
# reader would, so it never touches the user's desktop.
#
# Usage: cross/scripts/smoke-linux.sh PATH_TO_OPENTASKMANAGER
# Needs Xvfb, dbus-run-session, gdbus, at-spi2-core and Python's GObject
# bindings with Atspi; xdotool too for the keyboard checks.
set -euo pipefail

if [[ -z ${OTM_SMOKE_SESSION:-} ]]; then
    export OTM_SMOKE_SESSION=1
    # The session's services log their start-up, and AT-SPI's client library
    # warns about a cache signal it doesn't know; none of it is the test's.
    exec 2> >(grep --line-buffered -v -E 'dbind-WARNING|dbus-daemon|xdg-desktop-portal|pw\.conf|SpiRegistry|^[[:space:]]*$' >&2)
    exec dbus-run-session -- "$0" "$@"
fi

binary=$(realpath "$1")
here=$(dirname "$(realpath "$0")")
display=:${OTM_SMOKE_DISPLAY:-97}

Xvfb "$display" -screen 0 1280x900x24 -nolisten tcp 2>/dev/null &
xvfb=$!
trap 'kill "$xvfb" 2>/dev/null || true' EXIT
for _ in $(seq 50); do
    [[ -e /tmp/.X11-unix/X${display#:} ]] && break
    sleep 0.1
done
[[ -e /tmp/.X11-unix/X${display#:} ]] || { echo "Xvfb didn't start on $display" >&2; exit 1; }
export DISPLAY=$display
unset WAYLAND_DISPLAY

# Accessibility on, as a screen reader or the desktop's own setting turns it on.
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled "<true>" > /dev/null

python3 "$here/smoke-linux.py" "$binary"
