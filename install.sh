#!/usr/bin/env bash
# install.sh — automates every phase in README.md end to end.
#
# Safe to re-run: every step checks current state first and skips
# (or repairs) rather than blindly redoing work. Steps that touch
# /etc/xrdp/xrdp.ini or /etc/systemd take a timestamped backup before
# writing anything.
#
# Usage:
#   ./install.sh              interactive (asks before restarting xrdp)
#   ./install.sh --yes        non-interactive (auto-confirms the xrdp restart)
#   ./install.sh --skip-fallback-fix
#                              skip the optional Xorg/Xfce fallback-session
#                              fixes (cursor bpp, compositing) and only set
#                              up the Hyprland bridge

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=false
SKIP_FALLBACK_FIX=false

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=true ;;
        --skip-fallback-fix) SKIP_FALLBACK_FIX=true ;;
        --help|-h)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg (see --help)" >&2
            exit 1
            ;;
    esac
done

log()  { echo "[install] $*"; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

confirm() {
    $ASSUME_YES && return 0
    read -r -p "[install] $* [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
log "Phase 0: prerequisites"
# ---------------------------------------------------------------------------

command -v Hyprland >/dev/null 2>&1 || die "Hyprland not found — this script assumes a Hyprland-based system (e.g. Omarchy)."
pgrep -x Hyprland >/dev/null 2>&1 || die "Hyprland isn't running. Log into your normal graphical session first, then re-run this."
command -v xrdp >/dev/null 2>&1 || die "xrdp not found — install it first (sudo pacman -S xrdp xorgxrdp)."
systemctl is-active --quiet xrdp || die "xrdp.service isn't active — run 'sudo systemctl enable --now xrdp xrdp-sesman' first."

if ! command -v wayvnc >/dev/null 2>&1; then
    log "wayvnc not found, installing..."
    sudo pacman -S --needed --noconfirm wayvnc
else
    log "wayvnc already installed ($(wayvnc --version | head -n1))."
fi

# ---------------------------------------------------------------------------
log "Phase 1/2: install wayvnc-attach as a systemd --user unit"
# ---------------------------------------------------------------------------

mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/wayvnc

install -m 755 "$REPO_ROOT/scripts/wayvnc-attach.sh" ~/.local/bin/wayvnc-attach.sh
install -m 600 "$REPO_ROOT/config/wayvnc-config" ~/.config/wayvnc/config
install -m 644 "$REPO_ROOT/systemd/wayvnc-attach.service" ~/.config/systemd/user/wayvnc-attach.service

systemctl --user daemon-reload
systemctl --user enable --now wayvnc-attach.service

log "Waiting for wayvnc to attach and start listening on 127.0.0.1:5950..."
for _ in $(seq 1 15); do
    if ss -tln 2>/dev/null | grep -q ':5950 '; then
        break
    fi
    sleep 1
done

if ! ss -tln 2>/dev/null | grep -q ':5950 '; then
    systemctl --user status wayvnc-attach.service --no-pager || true
    die "wayvnc never started listening on 5950 — see the status output above, or run: journalctl --user -u wayvnc-attach.service"
fi
log "wayvnc is listening on 127.0.0.1:5950."

# ---------------------------------------------------------------------------
log "Phase 3: wire xrdp to the wayvnc bridge"
# ---------------------------------------------------------------------------

XRDP_INI=/etc/xrdp/xrdp.ini
[ -f "$XRDP_INI" ] || die "$XRDP_INI not found."

if ! grep -q '^max_bpp=' "$XRDP_INI"; then
    log "Adding max_bpp=24 to [Globals] (fixes 'client does not support new cursors' errors)."
    sudo cp "$XRDP_INI" "${XRDP_INI}.bak.$(date +%s)"
    sudo sed -i '/^\[Globals\]/a max_bpp=24' "$XRDP_INI"
elif ! grep -q '^max_bpp=24' "$XRDP_INI"; then
    log "Setting existing max_bpp to 24 (fixes 'client does not support new cursors' errors)."
    sudo cp "$XRDP_INI" "${XRDP_INI}.bak.$(date +%s)"
    sudo sed -i 's/^max_bpp=.*/max_bpp=24/' "$XRDP_INI"
else
    log "max_bpp=24 already set."
fi

if grep -q '^new_cursors=' "$XRDP_INI"; then
    sudo sed -i 's/^new_cursors=.*/new_cursors=false/' "$XRDP_INI"
else
    sudo sed -i '/^\[Globals\]/a new_cursors=false' "$XRDP_INI"
fi

if grep -q '^\[Hyprland\]' "$XRDP_INI"; then
    log "[Hyprland] session type already present in xrdp.ini, leaving it alone."
else
    log "Appending [Hyprland] session type to xrdp.ini."
    sudo cp "$XRDP_INI" "${XRDP_INI}.bak.$(date +%s)"
    sudo tee -a "$XRDP_INI" >/dev/null <<'EOF'

; Bridges Enhanced Session (RDP) to the already-running wayvnc instance
; attached to the real Hyprland compositor on 127.0.0.1:5950.
; pamusername/pampassword=asksame is required: wayvnc has enable_auth=false
; (loopback-only, trusts xrdp), so PAM is what actually gates access here.
; See xrdp/xrdp.ini.patch.md for the full explanation.
[Hyprland]
name=Hyprland
lib=libvnc.so
ip=127.0.0.1
port=5950
username=ask
password=ask
pamusername=asksame
pampassword=asksame
EOF
fi

# ---------------------------------------------------------------------------
if ! $SKIP_FALLBACK_FIX; then
    log "Optional: fixing the Xorg/Xfce fallback session (black screen from xfwm4 compositing)"
    XINITRC="$HOME/.xinitrc"
    if [ -f "$XINITRC" ] && ! grep -q 'XRDP_SESSION' "$XINITRC"; then
        cp "$XINITRC" "${XINITRC}.bak.$(date +%s)"
        tmp="$(mktemp)"
        {
            echo 'if [ -n "$XRDP_SESSION" ]; then'
            echo '    xfconf-query -c xfwm4 -p /general/use_compositing -s false'
            echo 'fi'
            cat "$XINITRC"
        } > "$tmp"
        mv "$tmp" "$XINITRC"
        log "Patched ~/.xinitrc to disable xfwm4 compositing only inside xrdp sessions."
    else
        log "~/.xinitrc missing or already patched, skipping."
    fi
fi

# ---------------------------------------------------------------------------
log "Phase 4: restart xrdp to pick up the config changes"
# ---------------------------------------------------------------------------

echo
echo "This will immediately drop any active RDP/Enhanced Session connection"
echo "(including one you might be running this script from)."
if confirm "Restart xrdp and xrdp-sesman now?"; then
    sudo systemctl restart xrdp xrdp-sesman
    log "Done. Reconnect via Hyper-V Enhanced Session and pick 'Hyprland' from the Session dropdown."
else
    log "Skipped. Config is staged — run 'sudo systemctl restart xrdp xrdp-sesman' yourself when ready."
fi
