import AppKit
import Foundation
import SwiftUI

struct AudioRequest: Decodable {
    let type: String
    let version: Int
    let direction: AudioDirection?
    let id: String?
    let wifi: Int?
    let wifiIp: String?
    let lan: Bool?
    let token: String?
    let x: Int?
    let y: Int?
    let uiState: Tab5UITestState?
    let udpPort: UInt16?
    let portraitCamera: Bool?
    let brightness: Int?
}

private struct LanPairRequest: Encodable {
    let type = "lan_pair"
    let version = 1
    let address: String
    let key: [UInt8]
}

private struct WiFiRequest: Encodable {
    let type = "wifi_configure"
    let version = 1
    let ssid: String
    let password: String
}

private struct BoardMediaReply: Encodable {
    let type = "media_state"
    let version = 1
    let message: String
}

private struct MacMessage: Encodable {
    let type = "audio_state"
    let version = 1
    let audio: AudioState
    var tab5Connection: Tab5Connection? = nil
    var uiTestAvailable: Bool? = nil
    var displaysAvailable: Bool? = nil
}

private struct Tab5Connection: Encodable {
    let usbConnected: Bool
    let usbStatus: String
    let wlanConnected: Bool
    let wlanStatus: String
    let cameraTransport: TabletCameraTransport
}

@MainActor
private final class CompanionModel: ObservableObject {
    @Published private(set) var status = "Kein Tab5 verbunden"
    @Published private(set) var connected = false
    @Published private(set) var enabled = UserDefaults.standard.object(forKey: "usbEnabled") as? Bool ?? true
    @Published private(set) var input = "—"
    @Published private(set) var output = "—"
    @Published private(set) var audioError: String?
    @Published private(set) var wifiStatus: String?
    @Published private(set) var wifiCanConfigure = false
    @Published var wifiSSID = ""
    @Published var wifiPassword = ""
    @Published private(set) var wifiFeedback: String?
    @Published private(set) var lanStatus = "WLAN-Steuerung nicht gekoppelt"
    @Published private(set) var canPairLan = false

    private var link: SerialLink?
    private var port: String?
    private var lastHello: TimeInterval = 0
    private var nextScan: TimeInterval = 0
    private var nextSnapshot: TimeInterval = 0
    private var commandError: String?
    private var pendingMediaReply: BoardMediaReply?
    private var lan: LanLink?
    private var lanPair = LanPairing.load()
    private var wifiPeer: String?
    private var lastLanRequest: TimeInterval?
    private var preview: PreviewLink?
    private let meter = MicrophoneMeter()
    private let camera = CameraPreview()
    private let tabletCamera = CameraPreview(profile: .tablet)
    private let uiTest = Tab5UITestLink()
    @Published private(set) var previewStatus = "Browser-Verbindung wird gestartet"
    private var timer: Timer?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init() {
        if let lanPair { startLan(lanPair) }
        do {
            preview = try PreviewLink(onStatus: { [weak self] status in
                self?.previewStatus = status
            }, onRequest: { [weak self] request in
                self?.handlePreview(request)
            }, onCameraStream: { [weak self] ticket, connection in
                guard let self else { connection.cancel(); return }
                self.camera.openStream(ticket: ticket, connection: connection)
            })
        } catch {
            previewStatus = "Browser-Verbindung fehlgeschlagen: \(error.localizedDescription)"
        }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func toggleConnection() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "usbEnabled")
        if enabled {
            nextScan = 0
            status = "Kein Tab5 verbunden"
        } else {
            closeLink(status: "USB für Flashen freigegeben")
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastLanRequest, now - lastLanRequest > 3.5 {
            self.lastLanRequest = nil
            lanStatus = "Warte auf das Tab5 im WLAN"
        }
        meter.expire(now: now)
        camera.expire(now: now)
        tabletCamera.expire(now: now)
        if enabled, now >= nextScan {
            nextScan = now + 1
            let available = SerialLink.ports()
            if let port, !available.contains(port) {
                closeLink(status: "Tab5 getrennt")
            }
            if link == nil {
                switch available.count {
                case 0: status = "Kein Tab5 verbunden"
                case 1:
                    do {
                        link = try SerialLink(path: available[0])
                        port = available[0]
                        status = "Warte auf Tab5-Firmware"
                    } catch {
                        status = "USB-Port konnte nicht geöffnet werden. Seriellen Monitor schließen?"
                    }
                default: status = "Mehrere ESP-Geräte erkannt. Für den Test nur das Tab5 anschließen."
                }
            }
        }

        do {
            if let link {
                for payload in try link.readFrames() {
                    guard let message = try? decoder.decode(AudioRequest.self, from: payload),
                          message.version == 1 else { continue }
                    if message.type == "hello" {
                        lastHello = now
                        if !connected { nextSnapshot = 0 }
                        connected = true
                        status = "Tab5 verbunden"
                        updateWiFi(message)
                    } else if message.type == "select_audio", connected, now - lastHello < 3.5,
                              let direction = message.direction, let id = message.id {
                        selectAudio(direction, id: id)
                        nextSnapshot = 0
                    } else if message.type == "media_control", connected, now - lastHello < 3.5,
                              let id = message.id, let action = SystemMedia(rawValue: id) {
                        pendingMediaReply = BoardMediaReply(message: action.send().message)
                    }
                }
                if connected, now - lastHello > 3.5 {
                    connected = false
                    wifiStatus = nil
                    wifiCanConfigure = false
                    canPairLan = false
                    status = "Warte auf Tab5-Firmware"
                }
                try link.flush()
                if let reply = pendingMediaReply, let data = try? encoder.encode(reply), link.queue(data) {
                    pendingMediaReply = nil
                    try link.flush()
                }
            }
            if now >= nextSnapshot {
                nextSnapshot = now + 1
                refreshAudio()
                try link?.flush()
            }
        } catch {
            closeLink(status: "USB-Verbindung unterbrochen")
        }
    }

    private func closeLink(status: String) {
        link = nil
        port = nil
        connected = false
        wifiStatus = nil
        wifiCanConfigure = false
        canPairLan = false
        commandError = nil
        pendingMediaReply = nil
        self.status = status
    }

    private func updateWiFi(_ message: AudioRequest) {
        wifiPeer = message.wifiIp
        canPairLan = message.lan != nil && message.wifi == 2 && wifiPeer != nil
        wifiCanConfigure = message.wifi.map { (0...3).contains($0) } ?? false
        switch message.wifi {
        case 0: wifiStatus = "WLAN noch nicht eingerichtet"
        case 1: wifiStatus = "WLAN verbindet …"
        case 2: wifiStatus = message.wifiIp.map { "WLAN verbunden · \($0)" } ?? "WLAN verbunden"
        case 3: wifiStatus = "WLAN wartet auf einen neuen Verbindungsversuch"
        case 4: wifiStatus = "WLAN-Adapter nicht verfügbar. USB-Log prüfen."
        default: wifiStatus = "WLAN-Firmware erforderlich"
        }
    }

    func pairLan() {
        guard canPairLan, let wifiPeer, let link else { return }
        guard let address = LanPairing.localAddress(for: wifiPeer) else {
            lanStatus = "Mac und Tab5 müssen im selben lokalen IPv4-Netz sein"
            return
        }
        do {
            let pair = try LanPairing.create(address: address, key: lanPair?.key)
            try pair.save()
            if lanPair != pair || lan == nil || lastLanRequest == nil {
                lanPair = pair
                startLan(pair)
            }
            let request = try encoder.encode(LanPairRequest(address: pair.address, key: pair.key))
            if link.queue(request) {
                lanStatus = "WLAN-Kopplung gesendet · warte auf das Tab5"
            } else {
                lanStatus = "USB-Verbindung beschäftigt. Bitte erneut koppeln."
            }
        } catch {
            lanStatus = "WLAN-Kopplung fehlgeschlagen"
        }
    }

    private func startLan(_ pair: LanPairing) {
        lan = nil
        lastLanRequest = nil
        do {
            lan = try LanLink(pair: pair, onStatus: { [weak self] status in
                self?.lanStatus = status
            }, onRequest: { [weak self] payload in
                self?.handleLan(payload)
            })
        } catch {
            lanStatus = "WLAN-Server konnte nicht starten"
        }
    }

    private func handleLan(_ payload: Data) -> LanLink.Reply? {
        guard let request = try? decoder.decode(AudioRequest.self, from: payload), request.version == 1 else { return nil }
        let response: Data?
        switch request.type {
        case "get_audio", "select_audio", "display_list", "display_brightness":
            response = handlePreview(request, includeConnection: false)
        case "ui_test_poll":
            guard let state = request.uiState else { return nil }
            response = try? encoder.encode(uiTest.poll(state))
        case "ui_test_upload":
            guard let id = request.id, let receive = uiTest.upload(id: id) else { return nil }
            return .upload(receive)
        case "camera_list": response = try? encoder.encode(TabletCameraList(list: tabletCamera.list()))
        case "camera_read":
            guard let id = request.id else { return nil }
            let reading = tabletCamera.read(id: id, supportsPortrait: request.portraitCamera == true)
            response = try? encoder.encode(TabletCameraReading(reading: reading, id: id))
        case "camera_stop":
            tabletCamera.stop()
            response = try? encoder.encode(TabletCameraReading(reading: CameraReading(status: "idle")))
        case "camera_stream":
            guard let ticket = request.id else { return nil }
            return .video { [weak self] connection, encode in
                guard let self else { connection.cancel(); return }
                self.tabletCamera.openStream(ticket: ticket, connection: connection, encode: encode)
            }
        case "camera_stream_udp":
            guard let ticket = request.id, let port = request.udpPort, port >= 1024 else { return nil }
            return .videoDatagrams(port) { [weak self] connection, encode in
                self?.tabletCamera.openDatagrams(ticket: ticket, connection: connection, encode: encode) ?? false
            }
        case "media_control":
            guard let id = request.id, let action = SystemMedia(rawValue: id) else { return nil }
            response = try? encoder.encode(BoardMediaReply(message: action.send().message))
        default: return nil
        }
        if response != nil {
            if lastLanRequest == nil || lanStatus != "Tab5 per WLAN verbunden" { lanStatus = "Tab5 per WLAN verbunden" }
            lastLanRequest = ProcessInfo.processInfo.systemUptime
        }
        return response.map(LanLink.Reply.message)
    }

    func connectWiFi() {
        wifiFeedback = configureWiFi(ssid: wifiSSID, password: wifiPassword)
        if wifiFeedback == nil { wifiPassword = "" }
    }

    private func configureWiFi(ssid: String, password: String) -> String? {
        guard connected, wifiCanConfigure, let link else { return "Tab5 per USB verbinden" }
        guard (1...32).contains(ssid.utf8.count), !ssid.utf8.contains(0) else { return "Die SSID muss 1 bis 32 Byte lang sein" }
        let bytes = password.utf8
        let hex = bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        guard password.isEmpty || ((8...63).contains(bytes.count) && !bytes.contains(0)) || hex else {
            return "WLAN-Passwort mit 8 bis 63 Byte eingeben"
        }
        guard let request = try? encoder.encode(WiFiRequest(ssid: ssid, password: password)), link.queue(request) else {
            return "USB-Verbindung beschäftigt. Bitte erneut versuchen."
        }
        return nil
    }

    private func selectAudio(_ direction: AudioDirection, id: String) {
        do {
            try MacAudio.select(direction, uid: id)
            commandError = nil
        } catch {
            commandError = error.localizedDescription
        }
    }

    private func handlePreview(_ request: AudioRequest, includeConnection: Bool = true) -> Data? {
        guard request.version == 1 else { return nil }
        if includeConnection, request.type.hasPrefix("ui_test_") {
            return try? encoder.encode(uiTest.local(request, key: lanPair?.key,
                                                     setCameraPattern: tabletCamera.setTestPattern,
                                                     setCameraTransport: tabletCamera.setTestTransport,
                                                     setCameraLayout: tabletCamera.setTabletLayout,
                                                     setCameraFPS: tabletCamera.setTabletFPS))
        }
        switch request.type {
        case "display_list": return try? encoder.encode(DisplayControl.snapshot())
        case "display_brightness":
            guard let id = request.id, let value = request.brightness else { return nil }
            return try? encoder.encode(DisplayControl.setBrightness(id: id, value: value))
        case "media_control":
            guard let id = request.id, let action = SystemMedia(rawValue: id) else { return nil }
            return try? encoder.encode(action.send())
        case "camera_list": return try? encoder.encode(camera.list())
        case "camera_read":
            guard let id = request.id else { return nil }
            return try? encoder.encode(camera.read(id: id))
        case "camera_stop":
            camera.stop()
            return try? encoder.encode(CameraReading(status: "idle"))
        case "meter_read": return try? encoder.encode(meter.read())
        case "meter_stop":
            meter.stop()
            return try? encoder.encode(MeterReading(status: "idle"))
        case "get_audio": break
        case "select_audio":
            guard let direction = request.direction, let id = request.id else { return nil }
            selectAudio(direction, id: id)
        default: return nil
        }
        let connection = includeConnection ? Tab5Connection(
            usbConnected: connected, usbStatus: status,
            wlanConnected: lastLanRequest != nil, wlanStatus: lanStatus,
            cameraTransport: tabletCamera.transport
        ) : nil
        return try? encoder.encode(MacMessage(audio: refreshAudio(), tab5Connection: connection,
                                              uiTestAvailable: includeConnection ? nil : uiTest.enabled,
                                              displaysAvailable: true))
    }

    @discardableResult
    private func refreshAudio() -> AudioState {
        let snapshot: AudioState
        do {
            snapshot = try MacAudio.snapshot(error: commandError)
        } catch {
            snapshot = AudioState(inputs: [], outputs: [], activeInput: "", activeOutput: "", error: error.localizedDescription)
        }
        input = snapshot.inputs.first { $0.id == snapshot.activeInput }?.name ?? "—"
        output = snapshot.outputs.first { $0.id == snapshot.activeOutput }?.name ?? "—"
        audioError = snapshot.error
        if connected, let link, let data = try? encoder.encode(MacMessage(audio: snapshot)), !link.queue(data), data.count >= 16 * 1024 - 6 {
            audioError = "Die Audiogeräteliste ist für diese Firmware zu groß."
        }
        return snapshot
    }
}

@main
struct Tab5CompanionApp: App {
    @StateObject private var model = CompanionModel()

    init() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--quit-running" {
            exit(Self.quitRunning(bundlePath: arguments[2]))
        }
        if CommandLine.arguments.contains("--list-audio") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(MacAudio.snapshot()), as: UTF8.self))
                print("USB: \(SerialLink.ports().joined(separator: ", "))")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            exit(0)
        }
    }

    private static func quitRunning(bundlePath: String) -> Int32 {
        let target = URL(fileURLWithPath: bundlePath, isDirectory: true).resolvingSymlinksInPath()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tab5.companion").filter {
            $0.bundleURL?.resolvingSymlinksInPath() == target && $0.processIdentifier != getpid()
        }
        for app in apps where !app.isTerminated { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(4)
        while apps.contains(where: { !$0.isTerminated }) {
            let next = Date().addingTimeInterval(0.05)
            if next >= deadline {
                fputs("Die laufende Pro-Remote-App konnte nicht beendet werden.\n", stderr)
                return 1
            }
            RunLoop.current.run(until: next)
        }
        return 0
    }

    var body: some Scene {
        MenuBarExtra("Pro Remote", systemImage: "hifispeaker") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pro Remote").font(.headline)
                Label(model.lanStatus, systemImage: "wifi").foregroundStyle(.secondary)
                Label("USB · \(model.status)", systemImage: "cable.connector").foregroundStyle(.secondary)
                Label(model.previewStatus, systemImage: "macwindow").foregroundStyle(.secondary)
                Divider()
                LabeledContent("Eingabe", value: model.input)
                LabeledContent("Ausgabe", value: model.output)
                if let error = model.audioError { Text(error).foregroundStyle(.red).font(.caption) }
                if let wifiStatus = model.wifiStatus {
                    Divider()
                    DisclosureGroup("Tab5-WLAN") {
                        Text(wifiStatus).font(.caption).foregroundStyle(.secondary)
                        if model.wifiCanConfigure {
                            TextField("WLAN-Name (SSID)", text: $model.wifiSSID)
                            SecureField("WLAN-Passwort", text: $model.wifiPassword)
                            Button("Mit WLAN verbinden") { model.connectWiFi() }
                                .disabled(model.wifiSSID.isEmpty)
                            if let feedback = model.wifiFeedback { Text(feedback).foregroundStyle(.red).font(.caption) }
                        }
                        if model.canPairLan { Button("WLAN-Steuerung koppeln") { model.pairLan() } }
                    }
                }
                Divider()
                HStack {
                    Button(model.enabled ? "USB freigeben" : "USB verbinden") { model.toggleConnection() }
                    Spacer()
                    Button("Beenden") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(16)
            .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
