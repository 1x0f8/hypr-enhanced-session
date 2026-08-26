#!/usr/bin/env bash
# wayvnc-attach.sh
#
# Waits for the real Hyprland compositor's Wayland socket to appear,
# then execs wayvnc pointed at it. This is what lets wayvnc serve the
# ACTUAL running Hyprland desktop rather than spawning anything new.
#
# Designed to be run as a systemd --user unit that starts alongside
# (but does not block) the normal Hyprland login.

set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LISTEN_ADDR="127.0.0.1"
LISTEN_PORT="5950"
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
log "starting wayvnc on ${LISTEN_ADDR}:${LISTEN_PORT} ..."

exec /usr/bin/wayvnc \
    --config="${XDG_CONFIG_HOME:-$HOME/.config}/wayvnc/config" \
    "$LISTEN_ADDR" "$LISTEN_PORT"
