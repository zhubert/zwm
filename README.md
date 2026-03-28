# ZWM

A tiling window manager for macOS, written in Swift.

> **This is personalized software.** ZWM does exactly what I want from a window manager — but it probably won't do what *you* want out of the box. If it looks interesting, fork it and tweak it to fit your workflow!

ZWM automatically arranges your windows into an equal-sized grid layout. It supports multiple workspaces and runs as a lightweight background app with a CLI for control.

## Features

- **Grid tiling** — windows are arranged in an equal-sized grid, oriented horizontally or vertically
- **Workspaces** — 9 workspaces per monitor
- **Workspace overflow** — when a workspace hits its tiling limit (4 windows), new windows automatically overflow to the next workspace
- **Auto-float small windows** — windows smaller than 1/8 of the monitor area are automatically floated
- **Window rules** — Finder, Preferences, and System Settings windows are automatically floated
- **Focus-follows-mouse** — windows are focused on hover without clicking
- **Multi-monitor support** — each monitor gets its own set of workspaces
- **CLI control** — `zwm` command to query and control the window manager

## Requirements

- macOS 14 (Sonoma) or later
- Accessibility permission (System Settings > Privacy & Security > Accessibility)

## Install

```sh
brew install zhubert/tap/zwm
```

Start ZWM as a background service:

```sh
brew services start zwm
```

Then grant Accessibility permission when prompted.

To stop:

```sh
brew services stop zwm
```

### Build from source

```sh
git clone https://github.com/zhubert/zwm.git
cd zwm
make install
```

This builds a release binary, copies `ZWM.app` to `/Applications/`, and installs the `zwm` CLI to `/usr/local/bin/`.

## Uninstall

```sh
brew uninstall zwm
```

Or if built from source:

```sh
make uninstall
```

## CLI

The `zwm` CLI communicates with the running server over a UNIX socket. Run `zwm --help` for available commands.

Examples:

```sh
zwm focus left
zwm workspace 3
zwm move-to-workspace 2
zwm layout floating
zwm list-windows
zwm debug-tree
```

## Architecture

ZWM is built around an **immutable tree model**. The window tree is a value type — every mutation produces a new tree. Layout is computed as a pure function of tree state and monitor geometry, then a diff engine compares old and new layouts and only issues Accessibility API calls for frames that actually changed.

All inputs (Accessibility events, workspace notifications, mouse events, CLI commands) flow through a coalescing event queue. macOS Accessibility calls are abstracted behind a `WindowBackend` protocol, which is swapped for a `MockBackend` in tests.

The server (`zwm-server`) runs as a background macOS app. The CLI (`zwm`) sends JSON commands over a UNIX socket and prints the response.

All behavior is hardcoded — there is no configuration file. To change settings, edit `EngineConfig.swift` and rebuild.

## Development

```sh
./build-debug.sh           # Debug build
./run-tests.sh             # Run all tests
swift test --filter Foo     # Run specific tests
```

## Acknowledgments

ZWM is heavily inspired by [AeroSpace](https://github.com/nikitabobko/AeroSpace), an excellent tiling window manager for macOS. Many of the core ideas — tree-based tiling and the overall user experience — owe a debt to AeroSpace's design.

## License

MIT
