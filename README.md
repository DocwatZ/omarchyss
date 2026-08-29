# OmarchySS

OmarchySS is an [Omarchy](https://omarchy.org/) bar plugin that launches a
dedicated terminal screensaver. It uses TTFX animations, can render the
current Spotify artist and title, and supplies Spotify controls directly from
the bar.

## Features

- Left-click to start or stop a dedicated Alacritty or Foot screensaver window.
- TTFX effect selection, including a random mode.
- Render Omarchy branding, custom text, or the current Spotify artist and
  track title.
- Right-click opens a Spotify popup, middle-click next, and scroll for
  previous/next.
- The popup shows album art, track/artist, a live progress bar with seek,
  volume, shuffle/repeat, and transport controls — all driven directly by
  Quickshell's native MPRIS service, so it updates instantly and works with
  any MPRIS player (not just Spotify).
- Optional Spotify catalog **search** from the same popup: search by song or
  artist and start playback on a device, using the Spotify Web API. This is
  a separate, opt-in feature from the MPRIS controls above (see
  [Spotify search setup](#spotify-search-setup)).
- Optionally pause Spotify for the screensaver session and resume it on exit.
- Optional auto-close timer.
- Adjustable terminal font size (default: 28pt).
- Beat-reactive animation cycling, using Cava's live PipeWire audio frames.
- A registered Omarchy global action for binding a keyboard shortcut.

## Requirements

`ttfx`, `jq`, `hyprctl`, and either Alacritty or Foot are required. Spotify
metadata and popup controls require `playerctl` (used only for the
screensaver's own pause-on-start/resume-on-stop) and a running MPRIS-capable
player (e.g. the Spotify desktop app); beat-reactive effects require `cava`.
Spotify search additionally requires `python3` and `secret-tool` (part of
`libsecret`), both of which ship by default on Omarchy.

```bash
omarchy pkg add playerctl cava
```

## Install

```bash
omarchy plugin add https://github.com/DocwatZ/omarchyss.git --enable
```

Configure OmarchySS through the bar widget settings. Its launch/stop action is
also available as:

```bash
~/.config/omarchy/plugins/io.github.docwatz.omarchyss/bin/omarchyss start
```

## Shortcut

The plugin registers `io.github.docwatz.omarchyss:toggle`. Add a persistent
Hyprland binding in `~/.config/hypr/bindings.lua`, selecting a key that does
not conflict with your existing bindings:

```lua
hl.bind("SUPER + SHIFT + S", hl.dsp.global("io.github.docwatz.omarchyss:toggle"))
```

## Spotify search setup

Player controls (play/pause/seek/volume/shuffle/repeat) work out of the box
via MPRIS — no setup needed. Searching Spotify's catalog and starting
playback of a chosen track needs the Spotify **Web API**, which requires a
free developer app and a one-time login:

1. Create an app at the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
   Any name/description is fine.
2. In the app's settings, add this exact **Redirect URI**:
   `http://127.0.0.1:8945/callback`
3. Copy the app's **Client ID**, then run:
   ```bash
   PLUGIN_DIR=~/.config/omarchy/plugins/io.github.docwatz.omarchyss
   python3 "$PLUGIN_DIR/bin/omarchyss-spotify" setup <your-client-id>
   ```
4. Either run `python3 "$PLUGIN_DIR/bin/omarchyss-spotify" auth` once from a
   terminal, or click **Connect Spotify** in the bar widget's popup — a
   browser window opens for you to approve access, and the resulting refresh
   token is stored in your system keyring (`secret-tool`/gnome-keyring), not
   in a plaintext file.
5. Search and playback (`/v1/me/player/play`) require an active **Spotify
   Premium** account and a running/open Spotify Connect device (e.g. the
   desktop app).

Nothing is sent anywhere except Spotify's own API — the Client ID/token
never leave your machine.

## License

MIT. See [LICENSE](LICENSE).
