# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZWM is a tiling window manager for macOS written in Swift. It uses an immutable tree model, diff-based layout, and a protocol-abstracted AX backend. Client-server architecture over UNIX socket.

## Build & Test Commands

```sh
./build-debug.sh                          # Debug build via SPM
./build-release.sh                        # Release build → .release/ (app bundle + CLI)
./run-tests.sh                            # Run all tests (swift test with framework flags)
swift test --filter TestClass/testMethod  # Run a single test
make install                              # Release build + install to /Applications/ and /usr/local/bin/
```

## Architecture

- **Immutable tree** — `TreeState` is a value type. Mutations return new instances. Layout is a pure function of tree + monitor geometry.
- **Diff engine** — compares old/new `LayoutResult`, only issues AX calls for changed frames.
- **Event queue** — all inputs (AX, NSWorkspace, mouse, CLI) flow through a coalescing `EventQueue` actor.
- **WindowBackend protocol** — abstracts macOS AX calls. `AXBackend` is the real implementation; `MockBackend` is used in tests.
- **Client-server** — `zwm` CLI sends JSON `CommandRequest` over UNIX socket, server returns `CommandResponse`.
- **MouseTracker** — passive `CGEvent` tap (`.listenOnly`) in `ZWMApp/main.swift` for focus-follows-mouse.

## SPM Targets

- **ZWMApp** — server executable entry point
- **ZWMServer** — core library (tree, layout, diff, events, commands, backend, socket)
- **ZWMCli** — CLI executable
- **ZWMCommon** — shared types (CmdArgs, CommandRequest/Response)
- **PrivateApi** — C header for `_AXUIElementGetWindow`
- **ZWMServerTests** — tests against MockBackend

## Key Paths

- **Config** — all behavior is hardcoded in `EngineConfig.swift` (no config file)
- **Log** — `/tmp/zwm.log`
- **Socket** — UNIX domain socket (path from `SocketPath`)

## Code Style

- Swift 6.0+, macOS 14+ deployment target
- 4-space indent, 120-char line limit
- All tree/layout types must be `Sendable`
- Business logic never imports Accessibility framework directly — always go through `WindowBackend`
