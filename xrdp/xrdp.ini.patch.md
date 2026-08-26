# Patching `/etc/xrdp/xrdp.ini`

`install.sh` does this step automatically and idempotently. This doc is
here for anyone who wants to apply (or review) the change by hand.

## Back up first

```bash
sudo cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
```

## Add a new session type, don't replace `[Xorg]`

Earlier drafts of this project pointed at repurposing the existing
`[Xorg]` section. Don't do that — keep `[Xorg]` as-is and add a
**new** section instead. That way the xrdp login screen's "Session"
dropdown offers both `Xorg` (the Xfce fallback, spawned fresh per
connection) and `Hyprland` (bridges into your real, already-running
desktop), and one broken session type can't strand you out of the
other.

Append this to the end of `/etc/xrdp/xrdp.ini`:

```ini
; Bridges Enhanced Session (RDP) to the already-running wayvnc instance
; attached to the real Hyprland compositor on 127.0.0.1:5950.
; pamusername/pampassword=asksame is required: wayvnc has enable_auth=false
; (loopback-only, trusts xrdp), so PAM is what actually gates access here.
[Hyprland]
name=Hyprland
lib=libvnc.so
ip=127.0.0.1
port=5950
username=ask
password=ask
pamusername=asksame
pampassword=asksame
```

Key points:
- `lib=libvnc.so` — xrdp's built-in RDP-to-VNC proxy module, instead
  of `libxup.so` (which spawns Xorg) or `port=-1` under `[Xvnc]`
  (which would spawn a *new*, blank Xvnc server).
- `port=5950` is a **fixed** port pointing at the wayvnc instance that
  `wayvnc-attach.service` keeps running — not `-1` or `ask`, since we
  always want that one existing session, never a fresh one.
- `pamusername=asksame` / `pampassword=asksame` are not optional here.
  Session types that use a fixed `lib=` proxy module (unlike `[Xorg]`/
  `[Xvnc]` with sesman-managed spawning) do **not** automatically run
  PAM on the credentials you type at the login screen. Since
  `config/wayvnc-config` disables VNC-level auth entirely (it only
  ever listens on loopback, trusting xrdp to have already checked the
  user), omitting these two lines would mean *any* username/password
  — including blank — gets straight into the desktop. `asksame` reuses
  the `username=ask`/`password=ask` fields you already typed, so
  there's still exactly one prompt, but it's now checked against the
  real Linux account via PAM.

While you're in there, two related settings worth having regardless
of session type (both fix a `[ERROR] Send pointer: client does not
support new cursors. The only valid bpp is 24, received 32` spam in
`/var/log/xrdp.log` — the RDP client negotiates 32bpp, but xrdp's
legacy cursor path wants 24bpp):

```ini
max_bpp=24
new_cursors=false
```

`install.sh` sets these in `[Globals]` automatically.

## Restart

```bash
sudo systemctl restart xrdp xrdp-sesman
```

This drops any active RDP connection immediately (including the one
you're likely running the command from). Reconnect afterward and pick
`Hyprland` from the Session dropdown.

## Rollback

```bash
sudo cp /etc/xrdp/xrdp.ini.bak /etc/xrdp/xrdp.ini
sudo systemctl restart xrdp xrdp-sesman
```
