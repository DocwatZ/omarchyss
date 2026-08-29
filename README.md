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
- Right-click play/pause, middle-click next, and scroll for previous/next.
- Optionally pause Spotify for the screensaver session and resume it on exit.
- Optional auto-close timer.
- Adjustable terminal font size (default: 28pt).
- Beat-reactive animation cycling, using Cava's live PipeWire audio frames.
- A registered Omarchy global action for binding a keyboard shortcut.

## Requirements

`ttfx`, `jq`, `hyprctl`, and either Alacritty or Foot are required. Spotify
metadata and controls require `playerctl`; beat-reactive effects require
`cava`.

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

## License

MIT. See [LICENSE](LICENSE).
