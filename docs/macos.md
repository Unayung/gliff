# macOS client and host

Gliff can connect from macOS to Hyprland, from Hyprland to macOS, or between
Macs. Both ends speak the same protocol over SSH. macOS needs version 13
Ventura or later, Rust, and Xcode Command Line Tools for a source build.

## Install on a Mac

Install GTK 4 and libadwaita from Homebrew (`brew install gtk4 libadwaita`),
then run `bin/install-macos` in the checkout. It builds the client and host,
installs `~/Applications/Gliff.app`, and creates `~/.local/bin/gliff` and
`~/.local/bin/gliff-server`. Homebrew and rustup locations are included in the
build PATH, so this also works from an SSH session.

To retain permission grants across source updates, sign with a development
certificate from your keychain. Find its SHA-1 fingerprint with
`security find-identity -v -p codesigning`, then install with
`GLIFF_CODESIGN_IDENTITY=<fingerprint> bin/install-macos`. The installer saves
that choice in the app and reuses it on future updates. Without a certificate
it uses ad-hoc signing, which can require renewed grants after each rebuild.

The client is the GTK client Linux uses, with tabs, recent machines and
reconnection. Open Gliff and enter an SSH address, or run:

```
~/.local/bin/gliff user@linux-host
~/.local/bin/gliff --mirror user@linux-host
```

The Linux host needs Gliff installed and a running Hyprland session. By
default it gets a screen that follows the Mac window, and its workspaces move
onto it for the session; `--mirror` shows its focused screen instead.
`gliff --discover` lists nearby Gliff desktops as JSON. The app asks for
Local Network access on macOS versions that require it; enable Gliff under
System Settings → Privacy & Security → Local Network.

## Mac packages and release signing

`bin/package-macos --development` builds an ad-hoc signed ZIP and checksum in
`target/macos`, without changing an installed app. Development archives are
for testing and require macOS permission grants for that build. CI builds and
packages Apple Silicon and Intel independently.

Public releases use the maintainer's **Developer ID Application** certificate,
hardened runtime, notarization, and a stapled ticket. They include the app icon
and license notices. Configure the CI secrets `GLIFF_MACOS_CERTIFICATE_BASE64`
(exported certificate and private key as a base64-encoded P12),
`GLIFF_MACOS_CERTIFICATE_PASSWORD`, `GLIFF_MACOS_SIGNING_IDENTITY` (SHA-1),
`GLIFF_APPLE_ID`, `GLIFF_APPLE_TEAM_ID`, and `GLIFF_APPLE_APP_PASSWORD`
(notarization app-specific password). These credentials belong to the project
maintainer; do not commit them. Tag builds fail if signing is not configured,
and publish both Mac architectures and their SHA-256 checksums after validation.

For a local release build, set `GLIFF_CODESIGN_IDENTITY` to the Developer ID
fingerprint and `GLIFF_NOTARY_PROFILE` to a profile created with
`xcrun notarytool store-credentials`, then run `bin/package-macos`.
The packaging command does not accept a development certificate for a public
release and verifies Gatekeeper acceptance after notarization. See Apple's
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The binaries target macOS13. Live capture/input testing has currently been on
an M1 Max running macOS26.6.2; the Intel CI job checks builds and unit behavior,
not Screen Recording, Accessibility, or older operating-system runtime behavior.

## Discover nearby Omarchy desktops

The Mac browses `_gliff._tcp` Bonjour services on the local network. Linux
packages include a desktop-session service that advertises the SSH endpoint
through Avahi, including the logged-in username and SSH port. It starts with
the desktop and stops on logout; it does not capture video or open a Gliff TCP
listener. SSH and Avahi must be running on the host. Discovery requires both
computers on a network that permits mDNS multicast.

For a source installation, run `bin/enable-discovery` as the Linux desktop
user after building. Installed packages provide `gliff-enable-discovery`.
Use `--ssh-port 2222` for nonstandard SSH ports and `--disable` to stop
advertising. To run the publisher manually:

```
gliff-server --advertise
gliff-server --advertise --ssh-port 2222
```

Check discovery from the Mac without opening a viewer:

```
gliff --discover
```

This prints nearby computers as JSON after a bounded scan. A service's
advertised user is a suggestion; you can edit the SSH address. Host identity
and authentication are checked by SSH. First-time host confirmation and key
passphrase/password prompts appear as native dialogs. For a manual connection
with a nonstandard port, use `gliff --port 2222 user@host`.

Bonjour discovery is local to the LAN. Enter an SSH address manually for
routed networks, jump hosts and VPN-only peers.

## Host the Mac

On the Mac, choose **Gliff → Enable Remote Control…**, or run:

```
~/.local/bin/gliff-server --permissions --request
```

In System Settings → Privacy & Security, enable Gliff for Screen Recording
(Screen & System Audio Recording in recent releases) and Accessibility.
These grants allow capture and remote input; SSH access alone does not grant
screen capture. Reconnect after changing them. The Mac must have a logged-in
GUI session. Changing from ad-hoc signing to a certificate requires a new grant
once; subsequent builds with that certificate keep the same signing identity.

The SSH host launches a separate instance of Gliff through LaunchServices.
Capture and input run in that app's privacy context, and SSH relays the
connection through a private Unix socket. Permission checks also use this
path, so they check Gliff rather than the SSH daemon. The bridge uses bounded
buffers and closes the host instance when the connection ends.

From Linux:

```
gliff user@mac-host
```

The SSH launcher checks the app bundle when the SSH PATH lacks `gliff-server`.
An explicit `--server-bin` still overrides that discovery.

The main display is selected by default. List displays on the Mac with
`gliff-server --outputs`, then select one with:

```
gliff --output display-1 user@mac-host
```

Display IDs come from the Mac; use the ID listed by `--outputs`. A mirrored
stream fits the client's window while pointer coordinates remain in the Mac's
logical display coordinates. macOS hosts mirror physical screens; asked for
a screen of their own (the client's default), they mirror the main display.

## Current differences from Linux

- The client decodes on the GPU: two VideoToolbox sessions decode main and
  aux at the same time, and a Metal kernel (`gliff-mac`) recombines 4:4:4,
  matching the CPU reference bit for bit. It falls back to OpenH264 when the
  GPU path is unavailable.
- On a Retina display the header's 1x button renders the remote's screen at 1x
  and enlarges it by whole pixels, a quarter of the bandwidth.
- Command maps to Super; Option maps to Alt. Hardware key positions are
  translated between macOS and evdev. Keyboard layouts use US on a Hyprland
  host, since the Mac client supplies no XKB keymap, and the active Mac layout
  on a Mac host.
- The clipboard prefetches what the remote offers, since macOS reads the
  clipboard owner's data unprompted, and sends the Mac's clipboard when the
  window comes to the front.
- Mac hosts stream like Linux hosts: Dual420 4:4:4 at up to 60 fps, at the
  display's native pixels scaled into the client's window (at most
  4096×2304). ScreenCaptureKit, a Metal split kernel (the twin of
  gliff-vk's) and two VideoToolbox sessions run in one native process, so
  no frame passes through the CPU. The server grants one encode at a time
  and adapts bitrate, frame rate, chroma and size with the Linux server's
  estimator, controller and ladder (`gliff-server/src/rate.rs`);
  `--low-bandwidth` starts at 4:2:0. Without a hardware encoder the host
  falls back to OpenH264 at 30 fps and at most 1920×1200, as does host
  `--video cpu`. To debug a host session, start the server with
  `GLIFF_HOST_LOG=/tmp/gliff-host.log` (and `RUST_LOG`): the host app,
  launched through LaunchServices, writes its log there.
- A client may ask for the cursor painted into the video
  (`cursor-in-video`). Linux hosts then skip the separate cursor capture
  session, avoiding Hyprland 0.56's cursor-session crash on display
  disconnection. The GTK client keeps drawing the cursor locally.

## Verify

Run `scripts/check.sh` on both platforms. The macOS checks include a capped
native pipe-reader memory regression,
without opening a window or capturing a screen. It verifies that temporary
Foundation buffers are released after each packet and that Retina-size
packets use bounded read buffers rather than churning large allocations.

The opt-in viewer regression feeds240 Retina-size frames to a temporary
window, bounds memory and cleans up without SSH or capture:

```
python3 scripts/macos-viewer-check.py
```

With a nearby host advertising Gliff, the optional integration check exercises
the actual picker, SSH-field prefill, deduplication and cancellation without
opening an SSH or video session:

```
python3 scripts/macos-discovery-check.py --expect-host computer.local --expect-user user
```

On a Mac:

```
gliff-server --permissions
gliff-server --outputs
gliff --check-frames 8 user@linux-host
```

From Linux, check a Mac host with:

```
gliff-probe --video cpu serve-test --ssh user@mac-host --frames 8
```

This also verifies a mirrored resize and keyframe decoding, using the same
SSH discovery as the GUI client.

`--check-frames` connects over SSH and decodes real frames without opening a
window. To exercise the UI, run the same connection without that flag and
check pointer motion, typing, resize, release/focus behavior and a text paste
in both directions. On Linux, `scripts/e2e.sh` verifies the video and input
paths in a nested Hyprland session, including the shared-memory software path.
