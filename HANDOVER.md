# Desk Remote handover

Imported from the local `tab5` project on 25 November 2026. The application uses a shared Rust and Slint interface, with a macOS companion as the host and Tab5 firmware as the current touchscreen client. The browser preview is the quickest way to work on the interface. Start with the [development guide](docs/development.md) for setup and diagnostics.

## Current baseline

| Area | Implemented |
| --- | --- |
| Audio | The companion reads the Mac's inputs and outputs and switches the defaults. The browser can measure the selected microphone. |
| Media and displays | The client sends global media keys and lists monitors with brightness control where macOS exposes it. |
| Camera | The browser receives MJPEG over loopback. The Tab5 receives JPEG frames over paired Wi-Fi using encrypted UDP with TCP fallback. Leaving the page stops the preview. |
| Tab5 connectivity | USB handles setup and control. After pairing, the client prefers the authenticated LAN link and uses Bonjour to rediscover the Mac. |
| Raspberry Pi | A native client is planned. The first milestone is a Linux build of the shared UI running on Pi hardware. |

Pairing data lives on the Mac and Tab5. macOS manages device permissions for the bundle identifier `dev.tab5.companion`, which appears in the menu bar as Pro Remote. The repository contains the build defaults and dependency locks. The former local Wi-Fi build had a UDP receive mailbox of 6 while `firmware/sdkconfig.defaults` specifies 16. Use 16 for fresh builds and record the effective value when comparing camera performance.

## Parallel work

Use one branch or worktree per task. Keep changes to the shared UI callbacks, message schema and pairing behavior visible to the affected owners before implementing a change that crosses those boundaries.

| Task | Primary files | Done when |
| --- | --- | --- |
| **Tab5 hardware baseline** | `firmware/`, `src/tab5.rs`, `src/page_cache.rs` | A fresh build flashes and boots. USB audio switching, Wi-Fi rediscovery, and camera start and stop work on a paired unit. Record FPS, transport and render timings for both camera layouts. |
| **macOS and browser baseline** | `companion/`, `web/`, `src/web_preview.rs` | From a fresh clone, the app builds and the preview reloads. Verify audio changes in both directions, media keys, microphone start and stop, camera teardown and reconnect, and monitor selection. Record the Mac and macOS version. |
| **Raspberry Pi prototype** | A Linux client entry point, `Cargo.toml` and the native Slint backend | The shared UI builds and runs on the chosen Pi and display. Confirm touch navigation and selection with a fixture. Document the Pi model, OS, display backend and build command. |

The three tasks can start together. The Pi prototype can use sample data while the Tab5 and macOS checks run. Before connecting it to a real companion, document which existing USB or LAN messages it will reuse, and coordinate any additions with both client and companion work. Start the integration with audio enumeration and selection, then use the hardware baselines when adding camera playback.

For a new chat, open this repository, read this handover and pick one task. Use the table's completion criteria and leave the tested environment and any remaining gaps in the resulting issue or pull request.
