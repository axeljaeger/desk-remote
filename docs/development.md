# Local development and hardware setup

The Tab5 uses Rust and Slint for the swipeable Ton, Medien and Kamera screens.
The macOS menu-bar app manages Core Audio devices and provides the browser
with live microphone levels and a camera preview. The Tab5 uses USB for audio
device switching. Medien sends the Mac's global play/pause, previous and next
media keys. On first use, allow Pro Remote under System Settings → Privacy &
Security → Accessibility. macOS picks the playback target. The app currently
does not read the system session list or artwork from Control Center.

## Browser preview

With Rust, the `wasm32-unknown-unknown` target, Node.js, `wasm-pack` and Apple's
command-line developer tools installed:

```sh
node --watch web/serve.mjs
```

Open [the browser preview](http://127.0.0.1:5173/). The server starts
the macOS app and rebuilds it when Swift, C or bundle settings change. After a
successful build it replaces the app and the browser reconnects automatically.
If a build fails, the running version stays available and the preview points
to the terminal for the build error. Select a device in the browser to
change the macOS default, or switch in macOS and see it reflected in the
preview within about a second. Both services listen on `127.0.0.1` only and
the Tab5 does not need to be plugged in. Until the browser first connects,
it displays example devices. A lost live connection clears the device list
and the preview reconnects automatically.

Drag horizontally or click a tab to switch screens. Changes to
`ui/companion.slint` and the Rust sources trigger a WebAssembly rebuild and a
browser reload. The preview also reloads when `web/index.html` changes and
remembers the selected screen. Node's
watch mode restarts the server when `web/serve.mjs` changes. Switch to watch
mode once if the server was started with `node web/serve.mjs`.

In the Ton screen, select **Messen** under **Mikrofonpegel** to measure the
current macOS input. Approve the macOS microphone prompt on the first run.
The browser receives only RMS and peak in dBFS and a clipping flag. **Stoppen**,
leaving the screen or hiding the browser preview ends the measurement. The Mac
also stops the capture if the preview disconnects.

In **Kamera**, select a Mac camera on the left and click **Vorschau starten**.
Approve camera access in macOS on first use. While the preview runs, you can
switch cameras from the list. The companion sends a binary MJPEG stream over
loopback, up to 640 × 480 pixels and 24 frames per second. The browser displays
the stream as an image aligned with the Slint preview panel. The control requests
check capture state independently of the stream. **Stoppen**, leaving the camera
screen, hiding the page or losing the connection ends the preview.

## Standalone macOS app

On macOS 13 or newer with Apple’s command-line developer tools installed:

```sh
sh companion/build.sh
open companion/build/Tab5Companion.app
```

The app appears in the menu bar, shows the current system input and output,
and looks for the Tab5. Once it receives the versioned USB handshake, it sends
the current audio state and refreshes it once per second. After switching a
device, it reads back the macOS selection. Use **USB freigeben** to close the
port before flashing or opening a serial monitor, and **USB verbinden** to
resume after the update.

The build signs ad hoc by default. Set `PRO_REMOTE_SIGN_IDENTITY` to a local
development signing identity if macOS repeatedly prompts for camera or microphone
access after rebuilds.

## Tab5 firmware

The Tab5 camera panel uses the existing paired WLAN link. Choose a camera and
select **Vorschau starten**. The Mac opens the selected camera after permission
is granted and sends baseline JPEG frames at a default target of 12 fps over an encrypted
UDP stream with TCP fallback. The ESP32-P4 decodes each frame in hardware.
The panel reports displayed frames per second. Leaving the panel or selecting
**Stoppen** releases the camera. On loss of the control connection the Mac
stops the capture after the lease expires.
The Tab5 disables Wi-Fi power saving for the stream and restores its usual
mode when playback stops, without reconnecting to the network.

With the preview stopped, `node companion/ui-test.mjs camera-layout ppa` selects
480 × 272 frames that the ESP32-P4 scales and rotates. `camera-layout dma` selects
304 × 544 frames prepared by the Mac for direct DMA2D copies into the Tab5
framebuffer. The companion remembers the selection. The `status` command reports
decode, copy, and display handoff timings during playback.
With the preview stopped, `node companion/ui-test.mjs camera-fps 25` sets the
tablet camera's target frame rate for testing. The companion remembers the rate.
Use `camera-fps 12` to restore the default. The browser preview uses its own rate.

The **Monitore** page lists the Mac's connected displays. Select one to see its
current mode. The brightness buttons adjust the selected display's hardware
backlight when macOS exposes it. The companion discovers displays with
AppKit/Core Graphics and checks the optional DisplayServices brightness
interface at runtime. A display without hardware brightness support still
appears in the list. The same page is available in the browser preview.

The firmware targets the ESP32-P4 Tab5 with an ST7123 display and touch
controller. It uses Espressif’s ST7123 drivers and an Apache-2.0 panel
initialization table from Espressif’s Tab5 board support package.

CI uses ESP-IDF 5.4.2 with IDF Component Manager 2.5.0. To match the CI build,
activate ESP-IDF and run the following commands from the project root.

```sh
rustup target add riscv32imafc-unknown-none-elf
python -m pip install idf-component-manager==2.5.0
unset IDF_COMPONENT_LOCAL_STORAGE_URL
idf.py -C firmware -B "$PWD/firmware/build/wifi" -D "SDKCONFIG=$PWD/firmware/build/wifi/sdkconfig" build
```

Keep the serial monitor closed while the companion owns the port. On a Tab5
that already has this project’s partition table, replace only the app with:

```sh
idf.py -C firmware -B "$PWD/firmware/build/wifi" -D "SDKCONFIG=$PWD/firmware/build/wifi/sdkconfig" -p /dev/cu.usbmodem1101 app-flash
```

On a fresh board, use `flash` instead to install the bootloader and partition
table as well. For the end-to-end test, connect the app, switch between two
available devices from the Ton screen, and check the selection in macOS. Then
switch back in macOS and check that the Tab5 updates.

After flashing, reconnect USB in Pro Remote. Open **Tab5-WLAN** in the Mac menu,
enter your 2.4 GHz network name and password, then choose **Mit WLAN verbinden**.
The Tab5 reports its connection state and DHCP address via USB. Successful
credentials are stored in the Tab5's NVS and reused after reboot. The build
targets the factory C6 Wi-Fi firmware and updates only the P4 application.

Once the Tab5 has a WLAN address, keep it connected by USB and click
**WLAN-Steuerung koppeln** in the same menu. The Mac and Tab5 must be on the
same local IPv4 subnet. USB exchanges the Mac address and a pairing key. The
Tab5 stores the pairing in NVS and prefers WLAN once the authenticated link
is ready. The Mac accepts local IPv4 connections on TCP 5176 and exchanges
AES-GCM records with the Tab5. If the saved address fails, the Tab5 looks for
the paired companion's Bonjour service and saves the new address after an
authenticated reply. The network must carry local multicast for discovery.
USB remains available for setup. With the camera preview stopped,
`node companion/ui-test.mjs lan-rediscover` exercises the authenticated
discovery path without changing either device's network configuration.

### USB messages

Each message is a UTF-8 JSON object prefixed with `@tab5 ` and terminated with
a line feed. The receiver ignores other lines, including serial logs. Version
1 supports these messages:

- `hello` (Tab5 → Mac) identifies the firmware and keeps the connection alive.
- `audio_state` (Mac → Tab5) carries inputs, outputs, active IDs and any error.
- `select_audio` (Tab5 → Mac) carries `direction` (`input` or `output`) and the
  Core Audio device ID from the latest state.
- `media_control` (Tab5 → Mac) carries an `id` of `previous`, `toggle` or `next`.
- `media_state` (Mac → Tab5) reports whether the Mac accepted the command.
- `wifi_configure` (Mac → Tab5) carries the SSID and passphrase over USB.
  The Tab5 adds its WLAN state and IP address to the `hello` message.
- `lan_pair` (Mac → Tab5) carries the Mac's LAN IPv4 address and the shared
  pairing key. The optional `lan` field in `hello` reports link readiness.
