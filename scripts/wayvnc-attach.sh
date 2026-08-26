#!/usr/bin/env bash
# wayvnc-attach.sh
#
# Waits for the real Hyprland compositor's Wayland socket to appear,
# then execs wayvnc pointed at it. This is what lets wayvnc serve the
# ACTUAL running Hyprland desktop rather than spawning anything new.
#
# wayvnc listens on a UNIX DOMAIN SOCKET inside $XDG_RUNTIME_DIR, not
# on a TCP port. That directory is mode 0700 and owned by you, so the
# kernel restricts who can reach the socket to you and root. This
# matters because wayvnc runs with authentication disabled: anything
# that can open the socket gets full screen capture AND input
# injection into your live session (i.e. it can type commands into
# your terminal). A loopback TCP port would have granted that to every
# local process and every sandboxed app with network access, which is
# not a boundary we want here.
#
# Designed to be run as a systemd --user unit that starts alongside
# (but does not block) the normal Hyprland login.

set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCKET_PATH="${WAYVNC_SOCKET:-$RUNTIME_DIR/wayvnc.sock}"
MAX_WAIT_SECS=60

log() { echo "[wayvnc-attach] $*"; }

find_wayland_socket() {
    # Hyprland (and most wlroots compositors) create a socket like
    # $XDG_RUNTIME_DIR/wayland-1. We scan rather than hardcode the
    # number since it can shift if other sockets already exist.
    find "$RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' -not -name '*.lock' 2>/dev/null | head -n1
}

log "waiting for a Hyprland Wayland socket under $RUNTIME_DIR ..."

elapsed=0
sock=""
while [ "$elapsed" -lt "$MAX_WAIT_SECS" ]; do
    sock="$(find_wayland_socket || true)"
    if [ -n "$sock" ]; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -z "$sock" ]; then
    log "ERROR: no Wayland socket appeared after ${MAX_WAIT_SECS}s. Is Hyprland running?"
    exit 1
fi

export WAYLAND_DISPLAY
WAYLAND_DISPLAY="$(basename "$sock")"
log "found Wayland socket: $WAYLAND_DISPLAY"

# wayvnc won't bind if a stale socket file is left behind by an
# unclean shutdown. Only this unit ever owns this path, so clearing it
# is safe; systemd guarantees the previous instance is already gone.
if [ -e "$SOCKET_PATH" ]; then
    log "removing stale socket at $SOCKET_PATH"
    rm -f "$SOCKET_PATH"
fi

log "starting wayvnc on unix socket $SOCKET_PATH ..."

exec /usr/bin/wayvnc \
    --config="${XDG_CONFIG_HOME:-$HOME/.config}/wayvnc/config" \
    --unix-socket \
    "$SOCKET_PATH"
