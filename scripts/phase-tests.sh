#!/usr/bin/env bash
# phase-tests.sh
#
# Run each function manually, in order, reporting back what happens
# at each phase before moving to the next. Don't wire xrdp in until
# phase 2 passes — otherwise you can't tell which layer broke.

phase0_check_prereqs() {
    echo "== Phase 0: prerequisites =="
    echo -n "wayvnc installed? "; command -v wayvnc && echo yes || echo "NO -> sudo pacman -S wayvnc"
    echo -n "Hyprland running? "; pgrep -x Hyprland >/dev/null && echo yes || echo "NO -> is a session logged in?"
    echo -n "Wayland socket present? "; ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" | grep -q '^wayland-' && echo yes || echo "NO"
    echo -n "xrdp listening on 3389? "; ss -tlnp 2>/dev/null | grep -q ':3389 ' && echo yes || echo "NO -> systemctl status xrdp"
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
    echo "Running: WAYLAND_DISPLAY=$(basename "$sock") wayvnc 127.0.0.1 5950"
    echo "(Ctrl+C to stop once you've confirmed the next check passes)"
    WAYLAND_DISPLAY="$(basename "$sock")" wayvnc 127.0.0.1 5950
}

phase1b_confirm_listening() {
    echo "== Phase 1b: from a SECOND terminal, while phase1 is still running =="
    echo -n "Is something listening on 5950? "
    ss -tlnp 2>/dev/null | grep -q ':5950 ' && echo yes || echo "NO -- wayvnc did not start correctly, check its stderr"
    echo "Raw VNC handshake check (should print something starting with RFB):"
    timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/5950; head -c12 <&3' || echo "connection failed"
}

phase2_install_systemd_unit() {
    echo "== Phase 2: install as a systemd --user unit =="
    mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/wayvnc
    cp scripts/wayvnc-attach.sh ~/.local/bin/wayvnc-attach.sh
    chmod +x ~/.local/bin/wayvnc-attach.sh
    cp config/wayvnc-config ~/.config/wayvnc/config
    cp systemd/wayvnc-attach.service ~/.config/systemd/user/wayvnc-attach.service
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
