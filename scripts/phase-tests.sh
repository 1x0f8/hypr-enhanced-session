#!/usr/bin/env bash
# phase-tests.sh
#
# Run each function manually, in order, reporting back what happens
# at each phase before moving to the next. Don't wire xrdp in until
# phase 2 passes — otherwise you can't tell which layer broke.
#
# Note: wayvnc listens on a unix socket in $XDG_RUNTIME_DIR, not a TCP
# port, so these checks look for a socket file rather than a listener.

WAYVNC_SOCKET="${WAYVNC_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/wayvnc.sock}"

phase0_check_prereqs() {
    echo "== Phase 0: prerequisites =="
    echo -n "wayvnc installed? "; command -v wayvnc && echo yes || echo "NO -> sudo pacman -S wayvnc"
    echo -n "Hyprland running? "; pgrep -x Hyprland >/dev/null && echo yes || echo "NO -> is a session logged in?"
    echo -n "Wayland socket present? "; ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" | grep -q '^wayland-' && echo yes || echo "NO"
    echo -n "xrdp listening on 3389? "; ss -tlnp 2>/dev/null | grep -q ':3389 ' && echo yes || echo "NO -> systemctl status xrdp"
    echo -n "xrdp running as root (needed to reach the 0700 runtime dir)? "
    ps -o user= -C xrdp 2>/dev/null | grep -qx root && echo yes || echo "NO -> see README Security note"
}

phase1_manual_wayvnc() {
    echo "== Phase 1: run wayvnc manually in the foreground =="
    echo "This does NOT use the systemd unit yet -- just confirms wayvnc"
    echo "can attach to Hyprland and serve something at all."
    sock="$(find "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" -maxdepth 1 -name 'wayland-*' -not -name '*.lock' | head -n1)"
    if [ -z "$sock" ]; then
        echo "No Wayland socket found. Stop here -- Hyprland isn't up."
        return 1
    fi
    echo "Using WAYLAND_DISPLAY=$(basename "$sock")"
    echo "Running: wayvnc --unix-socket $WAYVNC_SOCKET"
    echo "(Ctrl+C to stop once you've confirmed the next check passes)"
    rm -f "$WAYVNC_SOCKET"
    WAYLAND_DISPLAY="$(basename "$sock")" wayvnc --unix-socket "$WAYVNC_SOCKET"
}

phase1b_confirm_listening() {
    echo "== Phase 1b: from a SECOND terminal, while phase1 is still running =="
    echo -n "Does the socket exist? "
    [ -S "$WAYVNC_SOCKET" ] && echo "yes ($WAYVNC_SOCKET)" || echo "NO -- wayvnc did not start correctly, check its stderr"
    echo -n "Runtime dir mode (want 700): "; stat -c '%a %U' "$(dirname "$WAYVNC_SOCKET")"
    echo "Raw VNC handshake check (should print something starting with RFB):"
    if command -v socat >/dev/null 2>&1; then
        timeout 2 socat -u "UNIX-CONNECT:$WAYVNC_SOCKET" - 2>/dev/null | head -c 12
        echo
    else
        python3 - "$WAYVNC_SOCKET" <<'EOF'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
    print(s.recv(12))
except Exception as e:
    print("connection failed:", e)
EOF
    fi
}

phase2_install_systemd_unit() {
    echo "== Phase 2: install as a systemd --user unit =="
    # Resolve paths relative to this script, not the caller's cwd.
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
    mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/wayvnc
    install -m 755 "$root/scripts/wayvnc-attach.sh" ~/.local/bin/wayvnc-attach.sh || return 1
    install -m 600 "$root/config/wayvnc-config" ~/.config/wayvnc/config || return 1
    install -m 644 "$root/systemd/wayvnc-attach.service" ~/.config/systemd/user/wayvnc-attach.service || return 1
    systemctl --user daemon-reload
    systemctl --user enable --now wayvnc-attach.service
    sleep 2
    systemctl --user status wayvnc-attach.service --no-pager
    echo "Re-run the phase1b check now that it's managed by systemd."
}

phase3_xrdp_proxy() {
    echo "== Phase 3: only after phase 2 is confirmed working =="
    echo "This phase is manual -- see xrdp/xrdp.ini.patch.md"
    echo "After patching and restarting xrdp, connect via Hyper-V"
    echo "Enhanced Session from the Windows host and watch:"
    echo "  sudo tail -f /var/log/xrdp.log /var/log/xrdp-sesman.log"
}

echo "Usage: source this file, then call phase0_check_prereqs, phase1_manual_wayvnc, etc. one at a time."
