# hypr-enhanced-session

Bridges Hyper-V Enhanced Session Mode to your **real, already-running
Hyprland session** on Omarchy (or any Hyprland-based Arch setup) —
instead of spawning a separate Xorg/Xfce desktop just for the RDP
connection.

If you've ever connected to a Hyprland VM over Hyper-V's Enhanced
Session and landed on a fallback XFCE desktop (or a black screen)
instead of your actual tiling setup, this is why, and this fixes it.

## The problem, in one paragraph

Hyper-V's Enhanced Session Mode works by having VMConnect speak RDP
over a `hv_sock` (VMBus socket) channel to an RDP server inside the
guest — on Linux guests, that's `xrdp`. By default, when a session
connects, xrdp's `sesman` spawns a **fresh Xorg server** and runs
`startwm.sh` inside it. That's fine for X11 desktops. It doesn't work
for Hyprland: Hyprland is Wayland-only, it owns the display itself
(DRM/KMS), and it fundamentally can't run *inside* an X11 session the
way XFCE can. There's no `startwm.sh` trick that fixes this — it's an
architecture mismatch, not a config bug.

## The fix, in one diagram

```
Windows host (VMConnect / Hyper-V Manager)
      | RDP over hv_sock (Enhanced Session)
      v
   xrdp   --  [Hyprland] session type, lib=libvnc.so,
      |       port=$XDG_RUNTIME_DIR/wayvnc.sock
      | VNC over a unix socket in a 0700 directory
      v
  wayvnc  --  attached to your ALREADY-RUNNING Hyprland compositor
      |
      v
  Hyprland  (your actual desktop — animations, keybinds, everything)
```

Three pieces, each doing one job:

1. **Hyprland runs exactly as it does today.** Nothing about your
   normal login changes.
2. **[wayvnc](https://github.com/any1/wayvnc)** attaches to that
   already-running compositor — it's a VNC server purpose-built for
   wlroots-based Wayland compositors (screen capture via
   `wlr-screencopy`, input injection via the virtual-pointer/
   virtual-keyboard protocols) — and serves it on a **unix socket**
   at `$XDG_RUNTIME_DIR/wayvnc.sock`, not a TCP port. That directory
   is mode `0700`, so the kernel limits who can connect to you and
   root.
3. **xrdp** gets a new session type, `[Hyprland]`, that doesn't spawn
   anything — it's xrdp's built-in RDP-to-VNC proxy module
   (`lib=libvnc.so`) pointed at that socket path. Your existing
   `[Xorg]` fallback session stays in the login dropdown untouched, so
   a broken layer in this bridge can't strand you.

## Quick start

```bash
git clone <this-repo-url>
cd hypr-enhanced-session
./install.sh
```

That's the whole tutorial, if you trust the script. It:

1. Checks Hyprland and xrdp are actually installed and running.
2. Installs `wayvnc` if it's missing.
3. Installs `scripts/wayvnc-attach.sh` to `~/.local/bin/`, its config
   to `~/.config/wayvnc/config`, and a systemd `--user` unit that
   keeps it attached to Hyprland across logins — then enables and
   starts it, and waits for its socket to actually appear at
   `$XDG_RUNTIME_DIR/wayvnc.sock`.
4. Patches `/etc/xrdp/xrdp.ini`: adds the `[Hyprland]` session type
   pointing at that socket (taking one timestamped backup before the
   first edit), and sets `max_bpp=24` / `new_cursors=false` in
   `[Globals]` (fixes a `client does not support new cursors` error
   spam that's unrelated to Hyprland but you'll hit it regardless of
   session type). Upgrading from an older install migrates the
   previous loopback-TCP `[Hyprland]` section in place.
5. Optionally patches `~/.xinitrc` so the `[Xorg]` fallback session
   doesn't black-screen from `xfwm4` compositing over a GPU-less
   virtual display (skip with `--skip-fallback-fix` if you don't use
   that fallback).
6. Asks before restarting `xrdp`/`xrdp-sesman` — **this drops any
   active RDP connection immediately**, including one you might be
   running the script from. Pass `--yes` to skip the prompt.

Every step is idempotent — checks current state before writing
anything, so re-running after a failure (or a VM restart) is safe.

Then: reconnect via Hyper-V Enhanced Session, and in the login
dialog's **Session** dropdown, pick `Hyprland` instead of `Xorg`.
Log in with your normal Linux username/password — xrdp authenticates
that against PAM before it ever bridges through to wayvnc.

## Manually, phase by phase

If you'd rather understand (or debug) each layer before wiring
everything together, `scripts/phase-tests.sh` gives you the same
steps as functions you call one at a time:

```bash
sudo pacman -S --needed wayvnc     # phase 0 prerequisite
source scripts/phase-tests.sh
phase0_check_prereqs
phase1_manual_wayvnc               # foreground, watch for errors
# from a second terminal/tab:
phase1b_confirm_listening
# once confirmed, Ctrl+C phase1, then:
phase2_install_systemd_unit
phase1b_confirm_listening          # re-check, now systemd-managed
# only once phase 2 is solid, see xrdp/xrdp.ini.patch.md for phase 3
```

At each phase, the useful things to check if something doesn't work:
the exact output of that phase's function, `ls -l
"$XDG_RUNTIME_DIR/wayvnc.sock"` and `ss -tlnp | grep 3389`, and (once
you're on phase 3) `sudo tail -50 /var/log/xrdp.log
/var/log/xrdp-sesman.log`.

If phase 3 fails with a connection error, check that xrdp is running
as root (`ps -o user= -C xrdp`) — it needs that to reach a socket
inside your `0700` runtime directory.

## What you get, and what you don't

- Video and input (mouse, keyboard) — your real Hyprland desktop,
  tiling and animations included.
- **No dynamic resize.** Unlike the `[Xorg]` fallback, this bridge
  won't resize to match your RDP client window — it's fixed at
  whatever resolution Hyprland's output is currently running.
  Check with `wayvncctl output-list`.
- **Single-user only.** The bridge points at one user's wayvnc socket,
  so any account that passes PAM lands in *that* user's desktop. Fine
  on a personal VM, a privilege escalation on a shared machine — see
  the Security note.
- **No audio, no clipboard.** Those are a separate, currently
  unresolved problem on Hyper-V regardless of this approach.
- Known upstream quirks worth knowing about before you rely on this:
  multi-monitor virtual-pointer binding
  ([hyprwm/Hyprland#3262](https://github.com/hyprwm/Hyprland/issues/3262))
  and modifier-key passthrough
  ([hyprwm/Hyprland#974](https://github.com/hyprwm/Hyprland/issues/974))
  have both had reports of quirks over wayvnc. Shouldn't matter for a
  single-display VM, but test your actual keybinds early.

## Alternatives

[hypr-rdp](https://github.com/MuNeNiCK/hypr-rdp) is a native RDP
server for Hyprland — no xrdp, no wayvnc. It has audio (PipeWire
RDPSND), clipboard, and hardware-accelerated H.264 video, all of
which this bridge lacks. If you just want RDP into your running
Hyprland session and don't specifically care about Hyper-V, it's the
more capable option.

Why this project exists anyway: hypr-rdp only binds plain TCP sockets
(checked its `Cargo.toml` and source — no vsock dependency or
reference anywhere). Hyper-V's Enhanced Session Mode connects over
`AF_VSOCK`/`hv_sock`, not TCP, which is exactly what xrdp's
`port=vsock://-1:3389` handles. So hypr-rdp can't be pointed at
Enhanced Session directly today — this bridge exists to cover that
transport gap, at the cost of the features above.

If you don't need Enhanced Session specifically (e.g. you're fine
using regular `mstsc.exe` over a normal network connection to the
VM instead of VMConnect), hypr-rdp is worth trying directly instead
of this whole setup.

## Security note

Read this before deploying on anything but a single-user VM.

**Two things gate access, and both matter.**

1. **PAM, on the RDP leg.** `pamusername=asksame` / `pampassword=asksame`
   in the `[Hyprland]` section are what actually authenticate the
   remote user against your real Linux account. Setting `pamusername`
   is what flips xrdp into gateway-login mode, and a failed check
   aborts the connection. Delete those two lines and any
   username/password — including blank — gets straight into your live
   desktop.
2. **Filesystem permissions, on the VNC leg.** `config/wayvnc-config`
   sets `enable_auth=false`, so **anything that can open the wayvnc
   socket gets full screen capture and input injection** into your
   live session — and input injection means typing commands into your
   terminal as you. That is safe only because the socket lives in
   `$XDG_RUNTIME_DIR` (mode `0700`, owned by you). Do **not** move it
   back to a loopback TCP port with auth off: loopback is a network
   boundary, not a privilege boundary, and that hands the same access
   to every local process and to any sandboxed app with network
   permission but no Wayland permission.

**xrdp must run as root** for this to work, since it has to open a
socket inside your `0700` runtime dir. If you set `user=`/`group=` in
`xrdp.ini`, the bridge breaks — and the fix is *not* to loosen the
runtime directory. See `xrdp/xrdp.ini.patch.md` for a group-based
alternative.

**xrdp listens on TCP as well as vsock.** The stock config line is
`port=vsock://-1:3389 tcp://:3389`, so xrdp binds `0.0.0.0:3389` in
addition to the Hyper-V channel. Enhanced Session only needs the vsock
half. Check with `ss -tln | grep 3389`. Anyone who can reach that port
and passes PAM lands in your **live** desktop with everything you have
open — rather than the fresh, separate session the `[Xorg]` fallback
would give them. Either firewall it or drop the `tcp://:3389` half.
`install.sh` warns if it finds the port open and no active firewall,
but it does not configure one for you.

**Any account that passes PAM reaches the desktop of whoever is running
wayvnc** — the `[Hyprland]` section points at one specific user's
socket. On a single-user VM that is exactly what you want. On a
multi-user machine it is a privilege escalation: a second user with a
valid login lands in *your* session. Don't deploy this as-is there.

## Files

- `install.sh` — the automated installer described above.
- `scripts/wayvnc-attach.sh` — waits for Hyprland's Wayland socket,
  then execs wayvnc against it.
- `scripts/phase-tests.sh` — source it, call each phase function in
  order for manual/debug installation.
- `config/wayvnc-config` — installed to `~/.config/wayvnc/config`.
- `systemd/wayvnc-attach.service` — user unit wrapping
  `wayvnc-attach.sh`, installed to `~/.config/systemd/user/`.
- `xrdp/xrdp.ini.patch.md` — the exact `/etc/xrdp/xrdp.ini` change
  `install.sh` makes, with full reasoning, for anyone applying it by
  hand or reviewing what the script does before running it.

## Rollback

```bash
sudo cp -a /etc/xrdp/xrdp.ini.bak.<timestamp> /etc/xrdp/xrdp.ini
sudo systemctl restart xrdp xrdp-sesman
systemctl --user disable --now wayvnc-attach.service
rm -f "$XDG_RUNTIME_DIR/wayvnc.sock"
```

(`install.sh` prints the exact backup filename it created, timestamped
so repeated runs never clobber an earlier backup. It takes exactly one
backup per run, before its first edit.)
