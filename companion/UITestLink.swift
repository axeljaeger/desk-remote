import CryptoKit
import Foundation

struct Tab5UITestState: Codable {
    let ack: String?
    let captureError: String?
    let page: Int
    let cameraRunning: Bool
    let cameraHasFrame: Bool
    let cameraFps: Int
    let cameraMessage: String
    let displayedFrames: UInt32?
    let cameraTiming: Tab5CameraTiming?
    let video: Tab5VideoMetrics?
    let wifiMode: Int?
    let wifiPowerSave: Bool?
    let lanDiscoveries: UInt32?
    let swipeMetrics: Tab5SwipeMetrics?
    let swipeAvailable: Bool?
    let swipeCacheReady: Bool?
    let swipeStripCache: Bool?
    let swipeDmaReady: Bool?
}

struct Tab5CameraTiming: Codable {
    let renderUs: UInt64
    let copyUs: UInt64
    let presentUs: UInt64
    let maxGapUs: UInt64
    let lateFrames: UInt32
    let portrait: Bool
    let software: Bool
}

struct Tab5SwipeMetrics: Codable {
    let frames: UInt32
    let cachedFrames: UInt32?
    let acceleratedFrames: UInt32?
    let dmaFrames: UInt32?
    let chromeCopies: UInt32?
    let renderUs: UInt64
    let presentUs: UInt64
    let frameSpanUs: UInt64
    let maxFrameGapUs: UInt64
}

struct Tab5VideoMetrics: Codable {
    let authenticated: UInt32
    let decoded: UInt32
    let headerErrors: UInt32
    let invalidLengths: UInt32
    let incompleteRecords: UInt32
    let authErrors: UInt32
    let jpegErrors: UInt32
    let udpPackets: UInt32?
    let udpFrames: UInt32?
    let udpLostFrames: UInt32?
    let tcpFallbacks: UInt32?
    let decodeUs: UInt32?
    let overwritten: UInt32?
}

struct Tab5UITestCommand: Encodable {
    let id = UUID().uuidString
    let action: String
    var x: Int? = nil
    var y: Int? = nil
    var wifiMode: Int? = nil
    var legacyWait: Bool? = nil
    var useCache: Bool? = nil
    var useDma: Bool? = nil
}

struct Tab5UITestPoll: Encodable {
    let type = "ui_test"
    let version = 1
    let command: Tab5UITestCommand?
}

struct Tab5UITestResult: Encodable {
    var error: String? = nil
    var id: String? = nil
    var uiState: Tab5UITestState? = nil
    var jpeg: Data? = nil
}

@MainActor
final class Tab5UITestLink {
    private var command: Tab5UITestCommand?
    private var commandIssued: TimeInterval = 0
    private var delivered = false
    private var state: Tab5UITestState?
    private var lastPoll: TimeInterval = 0
    private var image: Data?
    private var enabledUntil: TimeInterval = 0

    var enabled: Bool { ProcessInfo.processInfo.systemUptime < enabledUntil }

    func poll(_ state: Tab5UITestState) -> Tab5UITestPoll {
        lastPoll = ProcessInfo.processInfo.systemUptime
        self.state = state
        if let command, state.ack == command.id { delivered = true }
        return Tab5UITestPoll(command: enabled && commandIsCurrent && !delivered ? command : nil)
    }

    func upload(id: String) -> (@MainActor (Data) -> Void)? {
        guard commandIsCurrent, command?.action == "capture", command?.id == id else { return nil }
        return { [weak self] jpeg in
            guard let self, self.commandIsCurrent, self.command?.id == id,
                  jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2).elementsEqual([0xff, 0xd9]) else { return }
            self.image = jpeg
            self.delivered = true
        }
    }

    func local(_ request: AudioRequest, key: [UInt8]?, setCameraPattern: (Bool) -> Void,
               setCameraTransport: (String) -> Void, setCameraLayout: (String) -> Void,
               setCameraFPS: (Int) -> Void) -> Tab5UITestResult {
        guard let key, let token = request.token, let code = Data(base64Encoded: token),
              HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data("pro-remote-tab5-ui-test-v1".utf8),
                                                    using: SymmetricKey(data: key)) else {
            return Tab5UITestResult(error: "UI-Test nicht autorisiert")
        }
        enabledUntil = ProcessInfo.processInfo.systemUptime + 5 * 60
        switch request.type {
        case "ui_test_status":
            guard online else { return Tab5UITestResult() }
            return Tab5UITestResult(id: commandIsCurrent ? command?.id : nil, uiState: state)
        case "ui_test_image":
            guard commandIsCurrent, let id = request.id, command?.id == id, command?.action == "capture" else {
                return Tab5UITestResult(error: "Screenshot-Auftrag abgelaufen")
            }
            return Tab5UITestResult(error: state?.ack == id ? state?.captureError : nil, id: id, jpeg: image)
        case "ui_test_tap":
            guard let x = request.x, let y = request.y, (0..<1280).contains(x), (0..<720).contains(y) else {
                return Tab5UITestResult(error: "Tap liegt außerhalb des Displays")
            }
            return schedule(Tab5UITestCommand(action: "tap", x: x, y: y))
        case "ui_test_capture": return schedule(Tab5UITestCommand(action: "capture"))
        case "ui_test_lan_rediscover":
            guard state?.lanDiscoveries != nil, state?.cameraRunning == false else {
                return Tab5UITestResult(error: "Bonjour-Test braucht aktuelle Tab5-Firmware und eine gestoppte Kamera")
            }
            return schedule(Tab5UITestCommand(action: "lan_rediscover"))
        case "ui_test_swipe_metrics":
            guard let id = request.id, ["legacy", "fast", "cached", "ppa"].contains(id),
                  state?.swipeAvailable == true, state?.cameraRunning == false else {
                return Tab5UITestResult(error: "Swipe-Test braucht aktuelle Tab5-Firmware und eine gestoppte Kamera")
            }
            let useCache = id == "cached" || id == "ppa"
            if useCache, state?.swipeCacheReady != true {
                return Tab5UITestResult(error: "Seiten-Cache ist noch nicht bereit")
            }
            return schedule(Tab5UITestCommand(action: "swipe_metrics", legacyWait: id == "legacy",
                                              useCache: useCache, useDma: id == "cached"))
        case "ui_test_wifi_mode":
            guard let id = request.id, let mode = ["default": 0, "awake": 1, "compatible": 2][id],
                  state?.wifiMode != nil, state?.cameraRunning == false else {
                return Tab5UITestResult(error: "WLAN-Test braucht aktuelle Tab5-Firmware und eine gestoppte Kamera")
            }
            return schedule(Tab5UITestCommand(action: "wifi_mode", wifiMode: mode))
        case "ui_test_camera_pattern":
            guard let id = request.id, id == "on" || id == "off" else {
                return Tab5UITestResult(error: "Testbildmodus muss on oder off sein")
            }
            setCameraPattern(id == "on")
            return Tab5UITestResult()
        case "ui_test_camera_transport":
            guard let id = request.id, id == "tcp" || id == "udp", state?.cameraRunning != true else {
                return Tab5UITestResult(error: "Für den Transportwechsel die Kameravorschau stoppen")
            }
            setCameraTransport(id)
            return Tab5UITestResult()
        case "ui_test_camera_layout":
            guard let id = request.id, id == "ppa" || id == "dma", state?.cameraRunning != true else {
                return Tab5UITestResult(error: "Für den Wechsel der Bildaufbereitung die Kameravorschau stoppen")
            }
            setCameraLayout(id)
            return Tab5UITestResult()
        case "ui_test_camera_fps":
            guard let id = request.id, let fps = Int(id), (1...30).contains(fps), state?.cameraRunning != true else {
                return Tab5UITestResult(error: "Für eine Senderate von 1 bis 30 FPS die Kameravorschau stoppen")
            }
            setCameraFPS(fps)
            return Tab5UITestResult()
        default: return Tab5UITestResult(error: "Unbekannter UI-Testbefehl")
        }
    }

    private var online: Bool { state != nil && ProcessInfo.processInfo.systemUptime - lastPoll < 3.5 }
    private var commandIsCurrent: Bool { command != nil && ProcessInfo.processInfo.systemUptime - commandIssued < 20 }

    private func schedule(_ next: Tab5UITestCommand) -> Tab5UITestResult {
        guard online else { return Tab5UITestResult(error: "Tab5-Firmware mit UI-Test ist nicht verbunden") }
        if commandIsCurrent, let command {
            let captureFailed = state?.ack == command.id && state?.captureError != nil
            if !delivered || (command.action == "capture" && image == nil && !captureFailed) {
                return Tab5UITestResult(error: "Auf dem Tab5 läuft bereits ein UI-Testbefehl")
            }
        }
        command = next
        commandIssued = ProcessInfo.processInfo.systemUptime
        delivered = false
        image = nil
        return Tab5UITestResult(id: next.id)
    }
}
