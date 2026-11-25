import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Network

struct CameraList: Encodable {
    let version = 1
    let cameras: [AudioDevice]
}

struct CameraReading: Encodable {
    let version = 1
    let status: String
    var ticket: String? = nil
    var message: String? = nil
    var transport: String? = nil
    var layout: String? = nil
}

struct TabletCameraList: Encodable {
    let type = "camera_list"
    let version = 1
    let list: CameraList
}

struct TabletCameraReading: Encodable {
    let type = "camera_status"
    let version = 1
    let reading: CameraReading
    var id: String? = nil
}

struct TabletCameraTransport: Encodable {
    var targetFps = 12
    var framesProduced = 0
    var streamsOpened = 0
    var framesWritten = 0
    var bytesWritten = 0
    var lastFrameBytes = 0
    var udpStreamsOpened = 0
    var udpFramesWritten = 0
    var udpPacketsWritten = 0
    var udpError: String? = nil
    var udpPathReason: String? = nil
}

@MainActor
final class CameraPreview {
    enum Profile { case browser, tablet }
    nonisolated fileprivate static let testPatternID = "pro-remote-ui-test-pattern"
    private let profile: Profile
    private var capture: CameraCapture?
    private var cameraID: String?
    private var cameraPortrait = false
    private var generation = UUID()
    private var latestFrame: Data?
    private var streams: [UUID: CameraStream] = [:]
    private var frameTime: TimeInterval = 0
    private var expiresAt: TimeInterval = 0
    private var failure: String?
    private var pendingPermission = false
    private var testPatternUntil: TimeInterval = 0
    private var preferDatagrams = true
    private(set) var transport = TabletCameraTransport()

    init(profile: Profile = .browser) {
        self.profile = profile
        if profile == .tablet {
            let fps = UserDefaults.standard.integer(forKey: "tabletCameraFPS")
            if (1...30).contains(fps) { transport.targetFps = fps }
        }
    }

    func setTabletFPS(_ fps: Int) {
        guard profile == .tablet else { return }
        stop()
        transport.targetFps = fps
        UserDefaults.standard.set(fps, forKey: "tabletCameraFPS")
    }

    func setTestTransport(_ transport: String) {
        guard profile == .tablet else { return }
        stop()
        preferDatagrams = transport == "udp"
    }

    func setTabletLayout(_ layout: String) {
        guard profile == .tablet else { return }
        stop()
        UserDefaults.standard.set(layout, forKey: "tabletCameraLayout")
    }

    func setTestPattern(_ enabled: Bool) {
        guard profile == .tablet else { return }
        stop()
        testPatternUntil = enabled ? ProcessInfo.processInfo.systemUptime + 60 : 0
    }

    func list() -> CameraList {
        if testPatternUntil > 0 {
            return CameraList(cameras: [AudioDevice(id: Self.testPatternID, name: "Testbild")])
        }
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return CameraList(cameras: devices.map { AudioDevice(id: $0.uniqueID, name: $0.localizedName) })
    }

    func read(id: String, supportsPortrait: Bool = false) -> CameraReading {
        if testPatternUntil > 0 {
            guard id == Self.testPatternID else { return CameraReading(status: "unavailable", message: "Testbild auswählen") }
        } else {
            guard id != Self.testPatternID else { return CameraReading(status: "unavailable", message: "Kamera auswählen") }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined:
                if !pendingPermission {
                    pendingPermission = true
                    AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                        Task { @MainActor in self?.pendingPermission = false }
                    }
                }
                return CameraReading(status: "pending", message: "Kamerazugriff am Mac bestätigen")
            case .authorized: break
            default:
                stop()
                return CameraReading(status: "denied", message: "Kamerazugriff für Pro Remote in macOS erlauben")
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        let portrait = profile == .tablet && supportsPortrait &&
            UserDefaults.standard.string(forKey: "tabletCameraLayout") == "dma"
        if id != cameraID || portrait != cameraPortrait { start(id: id, now: now, portrait: portrait) }
        expiresAt = now + 2
        if let failure { return CameraReading(status: "unavailable", message: failure) }
        if now - frameTime > 6 {
            stop()
            return CameraReading(status: "unavailable", message: "Die Kamera liefert kein Bild")
        }
        guard latestFrame != nil else { return CameraReading(status: "starting", message: "Kamera wird gestartet") }
        return CameraReading(status: "active", ticket: generation.uuidString,
                             transport: profile == .tablet && preferDatagrams ? "udp" : nil,
                             layout: portrait ? "portrait" : nil)
    }

    func openStream(ticket: String, connection: NWConnection) {
        openStream(ticket: ticket, connection: connection) { frame in
            var part = Data("--proremote-frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            part.append(frame)
            part.append(contentsOf: [13, 10])
            return part
        }
    }

    func openStream(ticket: String, connection: NWConnection, encode: @escaping (Data) -> Data?) {
        let paced = profile == .tablet
        if !startStream(ticket: ticket, connection: connection, datagrams: false, encode: { frame in
            guard let packet = encode(frame) else { return nil }
            if !paced { return [packet] }
            return stride(from: 0, to: packet.count, by: 1024).map { offset in
                packet.subdata(in: offset..<min(offset + 1024, packet.count))
            }
        }) { connection.cancel() }
    }

    func openDatagrams(ticket: String, connection: NWConnection, encode: @escaping (Data) -> [Data]?) -> Bool {
        profile == .tablet && preferDatagrams && startStream(ticket: ticket, connection: connection, datagrams: true, encode: encode)
    }

    private func startStream(ticket: String, connection: NWConnection, datagrams: Bool,
                             encode: @escaping (Data) -> [Data]?) -> Bool {
        guard UUID(uuidString: ticket) == generation, let latestFrame else { return false }
        if profile == .tablet {
            for stream in streams.values { stream.close() }
            streams.removeAll()
            transport.streamsOpened += 1
            if datagrams {
                transport.udpStreamsOpened += 1
                transport.udpError = nil
                transport.udpPathReason = nil
            }
        }
        let id = UUID()
        let stream = CameraStream(connection: connection, datagrams: datagrams, encode: encode,
                                  onWritten: { [weak self] count in
            guard let self, self.profile == .tablet else { return }
            self.transport.framesWritten += 1
            self.transport.bytesWritten += count
            self.transport.lastFrameBytes = count
            if datagrams { self.transport.udpFramesWritten += 1 }
        }, onPacket: { [weak self] in
            if datagrams { self?.transport.udpPacketsWritten += 1 }
        }, onError: { [weak self] error, path in
            if datagrams {
                self?.transport.udpError = String(describing: error)
                if let path, path.status == .unsatisfied {
                    self?.transport.udpPathReason = String(describing: path.unsatisfiedReason)
                }
            }
        }, onClosed: { [weak self] in self?.streams.removeValue(forKey: id) })
        streams[id] = stream
        stream.send(latestFrame)
        return true
    }

    func expire(now: TimeInterval) {
        if testPatternUntil > 0 && now >= testPatternUntil { setTestPattern(false) }
        if cameraID != nil && now >= expiresAt { stop() }
    }

    func stop() {
        generation = UUID()
        cameraID = nil
        latestFrame = nil
        failure = nil
        for stream in streams.values { stream.close() }
        streams.removeAll()
        capture?.stop()
        capture = nil
    }

    private func start(id: String, now: TimeInterval, portrait: Bool) {
        stop()
        cameraID = id
        cameraPortrait = portrait
        frameTime = now
        let current = generation
        let fps = profile == .tablet ? transport.targetFps : 24
        let capture = CameraCapture(profile: profile, portrait: portrait, fps: fps) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                switch result {
                case .frame(let jpeg):
                    if self.profile == .tablet { self.transport.framesProduced += 1 }
                    self.latestFrame = jpeg
                    for stream in self.streams.values { stream.send(jpeg) }
                    self.frameTime = ProcessInfo.processInfo.systemUptime
                case .failed(let message): self.failure = message
                }
            }
        }
        self.capture = capture
        capture.start(id: id)
    }
}

@MainActor
private final class CameraStream {
    private let connection: NWConnection
    private let datagrams: Bool
    private let encode: (Data) -> [Data]?
    private let onWritten: (Int) -> Void
    private let onPacket: () -> Void
    private let onError: @MainActor (NWError, NWPath?) -> Void
    private var sending = false
    private var closed = false

    init(connection: NWConnection, datagrams: Bool, encode: @escaping (Data) -> [Data]?, onWritten: @escaping (Int) -> Void,
         onPacket: @escaping () -> Void, onError: @escaping @MainActor (NWError, NWPath?) -> Void,
         onClosed: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.datagrams = datagrams
        self.encode = encode
        self.onWritten = onWritten
        self.onPacket = onPacket
        self.onError = onError
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .waiting(let error): Task { @MainActor in onError(error, connection?.currentPath) }
            case .failed(let error): Task { @MainActor in onError(error, connection?.currentPath); onClosed() }
            case .cancelled: Task { @MainActor in onClosed() }
            default: break
            }
        }
        if datagrams {
            connection.start(queue: .main)
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak connection] _, _, _, _ in
                connection?.cancel()
            }
        }
    }

    func send(_ frame: Data) {
        guard !sending, !closed else { return }
        guard let packets = encode(frame), !packets.isEmpty else {
            if !datagrams { close() }
            return
        }
        sending = true
        write(packets, index: 0, total: packets.reduce(0) { $0 + $1.count })
    }

    private func write(_ packets: [Data], index: Int, total: Int) {
        guard !closed else { return }
        connection.send(content: packets[index], completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let error {
                    self.onError(error, self.connection.currentPath)
                    self.close()
                    return
                }
                self.onPacket()
                if index + 1 == packets.count {
                    self.sending = false
                    self.onWritten(total)
                } else {
                    // Space writes so the Tab5's Wi-Fi coprocessor sees a bounded burst.
                    try? await Task.sleep(for: .milliseconds(self.datagrams ? 2 : 3))
                    self.write(packets, index: index + 1, total: total)
                }
            }
        })
    }

    func close() {
        closed = true
        connection.cancel()
    }
}

private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case frame(Data)
        case failed(String)
    }

    // Use the same queue for camera changes and frame callbacks.
    private static let queue = DispatchQueue(label: "dev.tab5.companion.camera")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let publish: @Sendable (Event) -> Void
    private let profile: CameraPreview.Profile
    private let portrait: Bool
    private let fps: Int
    private var session: AVCaptureSession?
    private var patternTimer: DispatchSourceTimer?
    private var patternIndex = 0
    private var nextFrame: TimeInterval = 0

    init(profile: CameraPreview.Profile, portrait: Bool, fps: Int, publish: @escaping @Sendable (Event) -> Void) {
        self.profile = profile
        self.portrait = portrait
        self.fps = fps
        self.publish = publish
    }

    func start(id: String) {
        Self.queue.async {
            if self.profile == .tablet && id == CameraPreview.testPatternID {
                self.startTestPattern()
                return
            }
            guard let device = AVCaptureDevice(uniqueID: id), device.isConnected,
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.publish(.failed("Die gewählte Kamera ist nicht verfügbar"))
                return
            }
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            guard session.canAddInput(input) else { self.publish(.failed("Kamera konnte nicht geöffnet werden")); return }
            session.addInput(input)
            guard session.canAddOutput(output) else { self.publish(.failed("Kamera-Vorschau konnte nicht gestartet werden")); return }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: Self.queue)
            self.session = session
            session.startRunning()
            if !session.isRunning { self.publish(.failed("Kamera konnte nicht geöffnet werden")) }
        }
    }

    func stop() {
        Self.queue.async {
            self.patternTimer?.cancel()
            self.patternTimer = nil
            self.session?.stopRunning()
            self.session = nil
        }
    }

    private func startTestPattern() {
        let frames = (0..<4).compactMap { phase in
            let width = 480, height = 272
            var pixels = Data(count: width * height * 4)
            pixels.withUnsafeMutableBytes { pixelBytes in
                let colors = pixelBytes.bindMemory(to: UInt8.self)
                var random: UInt32 = UInt32(phase + 1)
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        random = 1_664_525 &* random &+ 1_013_904_223
                        let texture = Int((random >> 27) & 31)
                        let bar = (x + phase * 120) % width < 48 ? 36 : 0
                        colors[i] = UInt8(x / 4 + texture + bar)
                        colors[i + 1] = UInt8(y / 2 + texture + bar)
                        colors[i + 2] = UInt8(50 + texture + bar)
                        colors[i + 3] = 255
                    }
                }
            }
            let image = CIImage(bitmapData: pixels, bytesPerRow: width * 4,
                                size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
            return baselineJPEG(tabletFrame(image))
        }
        guard frames.count == 4 else { publish(.failed("Testbild konnte nicht erzeugt werden")); return }
        patternIndex = 0
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publish(.frame(frames[self.patternIndex]))
            self.patternIndex = (self.patternIndex + 1) % frames.count
        }
        patternTimer = timer
        timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard session != nil, now >= nextFrame, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        nextFrame = max(now, nextFrame + 1.0 / Double(fps))
        let image = CIImage(cvPixelBuffer: pixels)
        if profile == .tablet {
            if let jpeg = baselineJPEG(tabletFrame(image)) { publish(.frame(jpeg)) }
            return
        }
        let bounds = CGSize(width: 640, height: 480)
        let scale = min(1, bounds.width / image.extent.width, bounds.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let preview = scaled.cropped(to: CGRect(x: 0, y: 0, width: min(bounds.width, floor(scaled.extent.width)),
                                                           height: min(bounds.height, floor(scaled.extent.height))))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [quality: 0.72]
        let jpeg = context.jpegRepresentation(of: preview, colorSpace: colorSpace, options: options)
        if let jpeg {
            publish(.frame(jpeg))
        }
    }

    private func tabletFrame(_ image: CIImage) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: portrait ? 544 : 480, height: portrait ? 304 : 272)
        let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (rect.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (rect.height - scaled.extent.height) / 2 - scaled.extent.minY))
        let preview = centered.composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
        return portrait ? preview.oriented(.left) : preview
    }

    private func baselineJPEG(_ image: CIImage) -> Data? {
        guard let pixels = context.createCGImage(image, from: image.extent) else { return nil }
        let first = encodeJPEG(pixels, quality: 0.38)
        if let first, first.count <= 8 * 1024 { return first }
        return encodeJPEG(pixels, quality: 0.20) ?? first
    }

    private func encodeJPEG(_ pixels: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ]
        CGImageDestinationAddImage(destination, pixels, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
