# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZWM is a tiling window manager for macOS written in Swift. It uses an immutable tree model, diff-based layout, and a protocol-abstracted AX backend. Client-server architecture over UNIX socket.

## Build & Test Commands

```sh
./build-debug.sh                          # Debug build via SPM
./build-release.sh                        # Release build → .release/ (app bundle + CLI + signed tarball)
./run-tests.sh                            # Run all tests (swift test with framework flags)
swift test --filter TestClass/testMethod  # Run a single test
make install                              # Release build + install to /Applications/ and /usr/local/bin/
make signing-cert                         # One-time: self-signed identity so the Accessibility grant survives rebuilds
./scripts/release.sh patch                # Tag, build+sign, upload artifact, regenerate the Homebrew formula
```

Without a signing identity the bundle is ad-hoc signed, so TCC keys the
Accessibility grant to a cdhash that changes on every build and the grant must
be re-issued each install (`make reset-accessibility`, then re-grant).

## Signing & distribution

All code signing happens at **release time on the developer's machine**, never at
install time. brew's build sandbox applies a global `(deny file-write*)` and
denies reads of `~/Library/Keychains`, so a formula can neither create nor even
see a signing identity — attempting it there silently produces ad-hoc builds.

`build-release.sh` therefore signs the bundle and packages
`.release/zwm-macos-<arch>.tar.gz`, and the Homebrew formula installs that
prebuilt artifact instead of compiling. This keeps the designated requirement a
stable certificate-leaf hash, so the Accessibility grant survives upgrades.

It stays a **formula, not a cask**: formulae never set the quarantine attribute
(so a self-signed bundle faces no Gatekeeper prompt), and `service` keeps
`brew services` working — casks have no launchd support. The formula in
`../homebrew-tap` is generated output; edit the template in `scripts/release.sh`,
not the formula itself.

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
