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
   xrdp   --  [Hyprland] session type, lib=libvnc.so, port=5950
      | VNC over 127.0.0.1 (loopback only)
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
   virtual-keyboard protocols) — and serves it on `127.0.0.1:5950`.
   Loopback-only: nothing outside the VM can reach it directly.
3. **xrdp** gets a new session type, `[Hyprland]`, that doesn't spawn
   anything — it's xrdp's built-in RDP-to-VNC proxy module
   (`lib=libvnc.so`) pointed at that fixed port. Your existing `[Xorg]`
   fallback session stays in the login dropdown untouched, so a broken
   layer in this bridge can't strand you.

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
   starts it, and waits for it to actually come up on port 5950.
4. Patches `/etc/xrdp/xrdp.ini`: adds the `[Hyprland]` session type
   (backing up the original first), and sets `max_bpp=24` /
   `new_cursors=false` in `[Globals]` (fixes a `client does not
   support new cursors` error spam that's unrelated to Hyprland but
   you'll hit it regardless of session type).
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
the exact output of that phase's function, `ss -tlnp | grep -E
'5950|3389'`, and (once you're on phase 3) `sudo tail -50
/var/log/xrdp.log /var/log/xrdp-sesman.log`.

## What you get, and what you don't

- Video and input (mouse, keyboard) — your real Hyprland desktop,
  tiling and animations included.
- **No dynamic resize.** Unlike the `[Xorg]` fallback, this bridge
  won't resize to match your RDP client window — it's fixed at
  whatever resolution Hyprland's output is currently running.
  Check with `wayvncctl output-list`.
- **No audio, no clipboard.** Those are a separate, currently
  unresolved problem on Hyper-V regardless of this approach.
- Known upstream quirks worth knowing about before you rely on this:
  multi-monitor virtual-pointer binding
  ([hyprwm/Hyprland#3262](https://github.com/hyprwm/Hyprland/issues/3262))
  and modifier-key passthrough
  ([hyprwm/Hyprland#974](https://github.com/hyprwm/Hyprland/issues/974))
  have both had reports of quirks over wayvnc. Shouldn't matter for a
  single-display VM, but test your actual keybinds early.

## Security note

`config/wayvnc-config` deliberately disables VNC-level authentication
(`enable_auth=false`) and only listens on `127.0.0.1`. That's safe
*only* because xrdp's `[Hyprland]` section is the thing actually
authenticating the remote user, via `pamusername=asksame` /
`pampassword=asksame` (checked against real PAM, i.e. your normal
Linux password). If you ever change wayvnc to listen on a non-loopback
address, enable `enable_auth=true` and set a password there too — see
`xrdp/xrdp.ini.patch.md` for the full reasoning.

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
sudo cp /etc/xrdp/xrdp.ini.bak.<timestamp> /etc/xrdp/xrdp.ini
sudo systemctl restart xrdp xrdp-sesman
systemctl --user disable --now wayvnc-attach.service
```

(`install.sh` prints the exact backup filename it created, timestamped
so repeated runs never clobber an earlier backup.)
