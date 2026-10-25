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

ready=$(mktemp)
if [[ -n ${OTM_SMOKE_DISPLAY:-} ]]; then
    # A display number given (WSL: Xvfb can't make its socket file there, so
    # it can't pick one itself, but it listens on the abstract socket).
    Xvfb ":$OTM_SMOKE_DISPLAY" -screen 0 1280x900x24 -nolisten tcp 2>/dev/null &
    sleep 2
    echo "$OTM_SMOKE_DISPLAY" > "$ready"
else
    # Xvfb picks a free display and writes its number once it's ready.
    Xvfb -displayfd 3 -screen 0 1280x900x24 -nolisten tcp 3>"$ready" 2>/dev/null &
fi
xvfb=$!
trap 'kill "$xvfb" 2>/dev/null || true; rm -f "$ready"' EXIT
for _ in $(seq 100); do
    [[ -s $ready ]] && break
    sleep 0.1
done
[[ -s $ready ]] || { echo "Xvfb didn't start" >&2; exit 1; }
DISPLAY=:$(tr -d '[:space:]' < "$ready")
export DISPLAY
unset WAYLAND_DISPLAY

# Accessibility on, as a screen reader or the desktop's own setting turns it on.
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled "<true>" > /dev/null

python3 "$here/smoke-linux.py" "$binary"
