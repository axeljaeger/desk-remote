# Desk Remote

[![Build](https://github.com/axeljaeger/desk-remote/actions/workflows/build.yml/badge.svg)](https://github.com/axeljaeger/desk-remote/actions/workflows/build.yml)

Desk Remote turns a touchscreen into a control panel for your Mac. Switch audio inputs and outputs, check microphone levels, control media playback, preview cameras, and adjust supported displays without leaving your current app.

The touchscreen client runs on the M5Stack Tab5. A macOS menu bar app connects it to the Mac over USB or a paired Wi-Fi connection. The development preview runs the shared Rust and Slint interface in a browser. A Raspberry Pi client is planned.

## Try it locally

On macOS 13 or later, build and open the companion with Apple's command-line developer tools installed.

```sh
sh companion/build.sh
open companion/build/Tab5Companion.app
```

To try the touchscreen interface without a Tab5, install Rust, Node.js and `wasm-pack`, then run the browser preview. It builds and starts the companion automatically.

```sh
rustup target add wasm32-unknown-unknown
node --watch web/serve.mjs
```

Open [the local preview](http://127.0.0.1:5173/). See the [development guide](docs/development.md) for firmware builds, flashing, Wi-Fi pairing and hardware diagnostics.

## Build artifacts

Both builds run in parallel on pull requests and on pushes to `main`. Open a completed [Build run](https://github.com/axeljaeger/desk-remote/actions/workflows/build.yml) to download its artifacts.

| Artifact | Contents |
| --- | --- |
| `desk-remote-tab5` | A merged ESP32-P4 image for fresh Tab5 boards and the app binary for updates to an existing installation. |
| `desk-remote-macos-arm64.zip` | A ZIP containing the ad hoc-signed macOS companion app for Apple silicon. |

## Project layout

| Path | Purpose |
| --- | --- |
| `ui/`, `src/` | Shared Slint UI, Rust state and client integrations |
| `companion/` | Swift macOS menu bar app and device services |
| `firmware/` | Tab5 board support, networking and ESP-IDF build |
| `web/` | Local WebAssembly preview and development server |

[Project handover and parallel work plan](HANDOVER.md) · [GPL-3.0 license](LICENSE)
