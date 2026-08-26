# Patching `/etc/xrdp/xrdp.ini`

`install.sh` does this step automatically and idempotently. This doc is
here for anyone who wants to apply (or review) the change by hand.

## Back up first

```bash
sudo cp -a /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
```

## Add a new session type, don't replace `[Xorg]`

Earlier drafts of this project pointed at repurposing the existing
`[Xorg]` section. Don't do that — keep `[Xorg]` as-is and add a
**new** section instead. That way the xrdp login screen's "Session"
dropdown offers both `Xorg` (the Xfce fallback, spawned fresh per
connection) and `Hyprland` (bridges into your real, already-running
desktop), and one broken session type can't strand you out of the
other.

Append this to the end of `/etc/xrdp/xrdp.ini`, replacing `1000` with
your own UID (`id -u`):

```ini
; >>> hypr-enhanced-session (managed block) >>>
[Hyprland]
name=Hyprland
lib=libvnc.so
port=/run/user/1000/wayvnc.sock
username=ask
password=ask
pamusername=asksame
pampassword=asksame
; <<< hypr-enhanced-session (managed block) <<<
```

`install.sh` wraps the section in those two marker comments so that
re-running it rewrites the block in place instead of appending a
second copy. If you are editing by hand you can drop the markers.

Key points:

- `lib=libvnc.so` — xrdp's built-in RDP-to-VNC proxy module, instead
  of `libxup.so` (which spawns Xorg) or `port=-1` under `[Xvnc]`
  (which would spawn a *new*, blank Xvnc server).
- `port=` is an **absolute path**, not a number. That is how
  `libvnc.so` chooses a unix-socket connection over TCP — see
  `vnc.c:lib_mod_connect()`, which selects `TRANS_MODE_UNIX` when
  `con_port[0] == '/'`. There is deliberately **no `ip=` line**: it is
  only read on the TCP path, and xrdp logs a "not needed" warning if
  you leave one in.
- The socket lives in `$XDG_RUNTIME_DIR`, which is mode `0700` and
  owned by you. That directory permission is the access control for
  the VNC leg — see the security note below.
- `pamusername=asksame` / `pampassword=asksame` are not optional here.
  Session types that use a fixed `lib=` proxy module (unlike `[Xorg]`/
  `[Xvnc]` with sesman-managed spawning) do **not** authenticate on
  their own. Setting `pamusername` is what flips xrdp into gateway-login
  mode (`xrdp_mm.c`: `if (gw_username != NULL) self->use_gw_login = 1;`),
  and a failed check aborts the connection rather than falling through.
  `asksame` means "prompt, then reuse the credentials already typed",
  so there is still exactly one prompt — but it is now checked against
  the real Linux account via PAM. Since `config/wayvnc-config` disables
  VNC-level auth entirely, omitting these two lines would mean *any*
  username/password — including blank — gets straight into the desktop.

## Why a unix socket instead of `ip=127.0.0.1` / `port=5950`

Earlier versions of this project pointed xrdp at wayvnc over loopback
TCP. That works, but loopback is a *network* boundary, not a
*privilege* boundary: with `enable_auth=false`, **any** local process
that could open a TCP socket got full screen capture and input
injection into the live session. Input injection into a live desktop
means typing into a terminal, i.e. arbitrary command execution as the
desktop user. It also defeated app sandboxes — anything granted
network access but deliberately denied Wayland access could reach the
port and escape confinement.

A unix socket in a `0700` directory moves that decision to the kernel:
only the owning user and root can open it. xrdp runs as root by
default, which is how it still reaches through.

**If you set `user=`/`group=` in `xrdp.ini`** (xrdp's own config
recommends running unprivileged), xrdp can no longer open a socket
inside your `0700` runtime dir and the bridge breaks. The fix is *not*
to loosen the runtime directory — that re-opens the hole for every
local process. Put the socket somewhere both can reach with a tight
group instead, e.g. a directory owned `root:xrdp` mode `0750`.

## Cursor / bpp settings

Two related settings worth having regardless of session type (both fix
a `[ERROR] Send pointer: client does not support new cursors. The only
valid bpp is 24, received 32` spam in `/var/log/xrdp.log` — the RDP
client negotiates 32bpp, but xrdp's legacy cursor path wants 24bpp):

```ini
max_bpp=24
new_cursors=false
```

These belong in `[Globals]`. `install.sh` sets them there specifically,
scoped to that section — a file-wide search-and-replace would also
rewrite same-named keys inside individual session sections.

## Network exposure

Check what xrdp actually listens on before you rely on this:

```bash
ss -tln | grep 3389
grep '^port=' /etc/xrdp/xrdp.ini
```

The stock line is `port=vsock://-1:3389 tcp://:3389`, which binds
**both** the Hyper-V vsock channel and TCP `0.0.0.0:3389`. Enhanced
Session only needs the vsock half. See the Security note in the README
before leaving the TCP half enabled.

## Restart

```bash
sudo systemctl restart xrdp xrdp-sesman
```

This drops any active RDP connection immediately (including the one
you're likely running the command from). Reconnect afterward and pick
`Hyprland` from the Session dropdown.

## Rollback

```bash
sudo cp -a /etc/xrdp/xrdp.ini.bak /etc/xrdp/xrdp.ini
sudo systemctl restart xrdp xrdp-sesman
```
