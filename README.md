# ZWM

A tiling window manager for macOS, written in Swift.

ZWM automatically arranges your windows into non-overlapping tiles using a binary tree layout. It uses vim-style keybindings, supports multiple workspaces, and runs as a lightweight background app with a CLI for control.

## Features

- **Binary tree tiling** — windows are split horizontally or vertically, forming a tree you navigate and rearrange
- **Vim-style keybindings** — `alt-h/j/k/l` to focus, `alt-shift-h/j/k/l` to move
- **Workspaces** — 9 workspaces per monitor, switched with `alt-1` through `alt-9`
- **Configurable gaps** — inner and outer gaps between windows
- **Window rules** — auto-float specific apps or window titles
- **Hot-reload config** — edit your config and changes apply immediately
- **Multi-monitor support** — each monitor gets its own set of workspaces
- **CLI control** — `zwm` command to query and control the window manager

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ toolchain (Xcode 16+ or matching CommandLineTools)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)

## Install

```sh
git clone https://github.com/your-user/zwm.git
cd zwm
make install
```

This builds a release binary, copies `ZWM.app` to `/Applications/`, and installs the `zwm` CLI to `/usr/local/bin/`. A default config is placed at `~/.zwm.toml` if one doesn't already exist.

To start:

```sh
open /Applications/ZWM.app
```

Then grant Accessibility permission when prompted.

## Uninstall

```sh
make uninstall
```

Config files are left in place.

## Configuration

ZWM reads config from `~/.zwm.toml` or `~/.config/zwm/zwm.toml`. Changes are picked up automatically.

```toml
[gaps]
inner = 8
outer = 8

[keybindings.main]
# Focus
alt-h = "focus left"
alt-j = "focus down"
alt-k = "focus up"
alt-l = "focus right"

# Move
alt-shift-h = "move left"
alt-shift-j = "move down"
alt-shift-k = "move up"
alt-shift-l = "move right"

# Layout
alt-enter = "layout horizontal"
alt-v = "layout vertical"
alt-f = "fullscreen"

# Workspaces
alt-1 = "workspace 1"
alt-shift-1 = "move-to-workspace 1"
# ... alt-2 through alt-9

# Close window
alt-shift-q = "close"

# Reload config
alt-shift-r = "reload-config"

# Window rules — float specific apps or titles
[[on-window-detected]]
match-app-name = "Finder"
run = "layout floating"

[[on-window-detected]]
match-title = "Settings"
run = "layout floating"
```

See `resources/default-config.toml` for the full default configuration.

## CLI

The `zwm` CLI communicates with the running server over a UNIX socket.

```sh
zwm focus left
zwm move right
zwm workspace 3
zwm move-to-workspace 2
zwm layout horizontal
zwm layout vertical
zwm fullscreen
zwm close
zwm reload-config
zwm list-windows
zwm list-workspaces
```

## Architecture

ZWM is built around an **immutable tree model**. The window tree is a value type — every mutation produces a new tree. Layout is computed as a pure function of tree state and monitor geometry, then a diff engine compares old and new layouts and only issues Accessibility API calls for frames that actually changed.

All inputs (Accessibility events, workspace notifications, mouse events, CLI commands) flow through a coalescing event queue. macOS Accessibility calls are abstracted behind a `WindowBackend` protocol, which is swapped for a `MockBackend` in tests.

The server (`zwm-server`) runs as a background macOS app. The CLI (`zwm`) sends JSON commands over a UNIX socket and prints the response.

## Development

```sh
./build-debug.sh           # Debug build
./run-tests.sh             # Run all tests
swift test --filter Foo     # Run specific tests
make build                  # Build via make
make test                   # Test via make
```

## Acknowledgments

ZWM is heavily inspired by [AeroSpace](https://github.com/nikitabobko/AeroSpace), an excellent tiling window manager for macOS. Many of the core ideas — tree-based tiling, vim-style keybindings, and the overall user experience — owe a debt to AeroSpace's design.

## License

MIT
