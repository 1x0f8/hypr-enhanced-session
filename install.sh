#!/usr/bin/env bash
# install.sh — automates every phase in README.md end to end.
#
# Safe to re-run: every step checks current state first and skips
# (or repairs) rather than blindly redoing work. A single timestamped
# backup of /etc/xrdp/xrdp.ini is taken before the first edit.
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
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

confirm() {
    $ASSUME_YES && return 0
    read -r -p "[install] $* [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

XRDP_INI=/etc/xrdp/xrdp.ini
BACKUP_TAKEN=false

# Defined up front: referenced by the phase 0 checks as well as the
# install steps, and $XDG_RUNTIME_DIR may legitimately be unset (which
# would abort under `set -u` if dereferenced bare).
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
WAYVNC_SOCKET="$RUNTIME_DIR/wayvnc.sock"

# One backup, before the first modification of the run — not one per
# edit, and never zero because an earlier branch happened to skip.
backup_xrdp_ini_once() {
    $BACKUP_TAKEN && return 0
    local dest="${XRDP_INI}.bak.$(date +%s)"
    sudo cp -a "$XRDP_INI" "$dest"
    log "Backed up $XRDP_INI -> $dest"
    BACKUP_TAKEN=true
}

# Set key=value inside [Globals] ONLY. A plain file-wide `sed s///`
# would rewrite same-named keys in every session section too, and a
# file-wide `grep` would misreport whether [Globals] has the key.
set_globals_key() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$val" '
        BEGIN { in_g = 0; done = 0 }
        /^\[/ {
            # Leaving [Globals] without having seen the key: add it.
            if (in_g && !done) { print key "=" val; done = 1 }
            in_g = ($0 == "[Globals]")
            print
            next
        }
        in_g && $0 ~ "^" key "=" {
            if (!done) { print key "=" val; done = 1 }
            next
        }
        { print }
        END { if (in_g && !done) print key "=" val }
    ' "$XRDP_INI" > "$tmp"

    if cmp -s "$tmp" "$XRDP_INI"; then
        log "[Globals] $key already set to $val."
        rm -f "$tmp"
        return 0
    fi

    backup_xrdp_ini_once
    # tee writes through the existing inode, so mode/ownership survive.
    sudo tee "$XRDP_INI" < "$tmp" >/dev/null
    rm -f "$tmp"
    log "Set $key=$val in [Globals]."
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

# xrdp reaches the wayvnc socket inside $XDG_RUNTIME_DIR (mode 0700),
# which only works because xrdp runs as root. If it has been dropped to
# an unprivileged user, the bridge cannot connect and the fix is not a
# permission loosening on the runtime dir.
if grep -qE '^\s*user=' "$XRDP_INI" 2>/dev/null; then
    warn "xrdp.ini sets 'user=' — xrdp is not running as root, so it will not be"
    warn "able to open the wayvnc socket in $RUNTIME_DIR (mode 0700)."
    warn "Do NOT chmod that directory. See the Security note in README.md."
fi

# ---------------------------------------------------------------------------
log "Phase 1/2: install wayvnc-attach as a systemd --user unit"
# ---------------------------------------------------------------------------

mkdir -p ~/.local/bin ~/.config/systemd/user ~/.config/wayvnc

install -m 755 "$REPO_ROOT/scripts/wayvnc-attach.sh" ~/.local/bin/wayvnc-attach.sh
install -m 600 "$REPO_ROOT/config/wayvnc-config" ~/.config/wayvnc/config
install -m 644 "$REPO_ROOT/systemd/wayvnc-attach.service" ~/.config/systemd/user/wayvnc-attach.service

systemctl --user daemon-reload
systemctl --user restart wayvnc-attach.service
systemctl --user enable wayvnc-attach.service

log "Waiting for wayvnc to attach and create $WAYVNC_SOCKET ..."
for _ in $(seq 1 15); do
    if [ -S "$WAYVNC_SOCKET" ]; then
        break
    fi
    sleep 1
done

if [ ! -S "$WAYVNC_SOCKET" ]; then
    systemctl --user status wayvnc-attach.service --no-pager || true
    die "wayvnc never created $WAYVNC_SOCKET — see the status output above, or run: journalctl --user -u wayvnc-attach.service"
fi
log "wayvnc is listening on $WAYVNC_SOCKET."

# ---------------------------------------------------------------------------
log "Phase 3: wire xrdp to the wayvnc bridge"
# ---------------------------------------------------------------------------

[ -f "$XRDP_INI" ] || die "$XRDP_INI not found."

# Both fix the same 'client does not support new cursors' log spam.
set_globals_key max_bpp 24
set_globals_key new_cursors false

BEGIN_MARK='; >>> hypr-enhanced-session (managed block) >>>'
END_MARK='; <<< hypr-enhanced-session (managed block) <<<'

# Rewrite our managed block rather than appending a second one. Also
# migrates the pre-1.0 layout, which had a bare [Hyprland] section
# pointing at TCP 127.0.0.1:5950 and no markers.
render_block() {
    cat <<EOF
$BEGIN_MARK
; Bridges Enhanced Session (RDP) to the already-running wayvnc instance
; attached to the real Hyprland compositor.
;
; port= is an absolute path, which is how xrdp's libvnc.so selects a
; unix-socket connection instead of TCP (see vnc.c: con_port[0] == '/').
; No ip= is needed in that mode. The socket lives in a 0700 runtime
; directory, so only this user and root can reach it.
;
; pamusername/pampassword=asksame is REQUIRED, not decorative: wayvnc
; runs with enable_auth=false, so PAM is the only thing authenticating
; the remote user. Remove these two lines and any username/password —
; including blank — would get straight into the live desktop.
[Hyprland]
name=Hyprland
lib=libvnc.so
port=$WAYVNC_SOCKET
username=ask
password=ask
pamusername=asksame
pampassword=asksame
$END_MARK
EOF
}

strip_old_block() {
    # Comments and blanks are buffered rather than printed immediately,
    # so that the comment header sitting directly above a legacy
    # [Hyprland] section can be dropped along with it instead of being
    # orphaned above the new block.
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        {
            if ($0 == b) { skip = 1; nbuf = 0; next }
            if ($0 == e) { skip = 0; next }
            if (skip) next

            # Inside a legacy unmarked [Hyprland] section: drop lines
            # until the next section header.
            if (legacy) {
                if ($0 ~ /^\[/) { legacy = 0 } else { next }
            }

            if ($0 == "[Hyprland]") { legacy = 1; nbuf = 0; next }

            if ($0 ~ /^[;#]/ || NF == 0) { buf[nbuf++] = $0; next }

            for (i = 0; i < nbuf; i++) print buf[i]
            nbuf = 0
            print
        }
        END { for (i = 0; i < nbuf; i++) print buf[i] }
    ' "$XRDP_INI"
}

tmp="$(mktemp)"
{
    strip_old_block
    # Exactly one blank line before the block, regardless of what the
    # stripped file ended with.
    echo
    render_block
} > "$tmp"

# Collapse any run of blank lines left behind by stripping.
tmp2="$(mktemp)"
awk 'NF == 0 { blank++; next } { while (blank-- > 0) print ""; blank = 0; print }' "$tmp" > "$tmp2"
mv "$tmp2" "$tmp"

if cmp -s "$tmp" "$XRDP_INI"; then
    log "[Hyprland] session type already up to date."
    rm -f "$tmp"
else
    backup_xrdp_ini_once
    sudo tee "$XRDP_INI" < "$tmp" >/dev/null
    rm -f "$tmp"
    log "Installed [Hyprland] session type pointing at $WAYVNC_SOCKET."
fi

# ---------------------------------------------------------------------------
if ! $SKIP_FALLBACK_FIX; then
    log "Optional: fixing the Xorg/Xfce fallback session (black screen from xfwm4 compositing)"
    XINITRC="$HOME/.xinitrc"
    if [ -f "$XINITRC" ] && ! grep -q 'XRDP_SESSION' "$XINITRC"; then
        cp -a "$XINITRC" "${XINITRC}.bak.$(date +%s)"
        # Preserve the original mode; mktemp is 0600 and a plain mv
        # would silently impose that on ~/.xinitrc.
        orig_mode="$(stat -c %a "$XINITRC")"
        tmp="$(mktemp)"
        {
            echo 'if [ -n "$XRDP_SESSION" ]; then'
            echo '    xfconf-query -c xfwm4 -p /general/use_compositing -s false'
            echo 'fi'
            cat "$XINITRC"
        } > "$tmp"
        cat "$tmp" > "$XINITRC"   # write through the existing inode
        rm -f "$tmp"
        chmod "$orig_mode" "$XINITRC"
        log "Patched ~/.xinitrc to disable xfwm4 compositing only inside xrdp sessions."
    else
        log "~/.xinitrc missing or already patched, skipping."
    fi
fi

# ---------------------------------------------------------------------------
log "Phase 4: restart xrdp to pick up the config changes"
# ---------------------------------------------------------------------------

# xrdp's stock port= line listens on TCP 0.0.0.0:3389 as well as vsock.
# Enhanced Session only needs the vsock half; the TCP half publishes an
# RDP gateway into a LIVE desktop session to the whole network.
if grep -qE '^port=.*tcp://' "$XRDP_INI"; then
    if ss -tln 2>/dev/null | grep -qE '(^|\s)(0\.0\.0\.0|\*|\[::\]):3389\s'; then
        warn "xrdp is listening on TCP 0.0.0.0:3389, not just the Hyper-V vsock channel."
        warn "Anyone who can reach this host on 3389 and passes PAM lands in your LIVE"
        warn "desktop session. Restrict it with a firewall, or drop the 'tcp://:3389'"
        warn "half of the port= line in $XRDP_INI. See the Security note in README.md."
        if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
            log "(ufw is active — check 'sudo ufw status' to confirm 3389 is not allowed.)"
        else
            warn "(No active ufw detected — port 3389 may be reachable from the network.)"
        fi
    fi
fi

echo
echo "This will immediately drop any active RDP/Enhanced Session connection"
echo "(including one you might be running this script from)."
if confirm "Restart xrdp and xrdp-sesman now?"; then
    sudo systemctl restart xrdp xrdp-sesman
    log "Done. Reconnect via Hyper-V Enhanced Session and pick 'Hyprland' from the Session dropdown."
else
    log "Skipped. Config is staged — run 'sudo systemctl restart xrdp xrdp-sesman' yourself when ready."
fi
