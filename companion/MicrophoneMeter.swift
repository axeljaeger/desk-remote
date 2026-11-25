import Accelerate
import AVFoundation
import Foundation
import os

struct MeterReading: Encodable {
    let version = 1
    let status: String
    var rmsDB: Double = -60
    var peakDB: Double = -60
    var clipping = false
    var message: String? = nil
}

@MainActor
final class MicrophoneMeter {
    private struct Samples {
        var squaredSum = 0.0
        var count = 0
        var peak: Float = 0
    }

    private var samples = OSAllocatedUnfairLock(initialState: Samples())
    private var engine: AVAudioEngine?
    private var deviceID = ""
    private var expiresAt: TimeInterval = 0
    private var checkDeviceAt: TimeInterval = 0
    private var pendingPermission = false
    private var rmsDB = -60.0
    private var heldPeak = -60.0
    private var holdUntil: TimeInterval = 0
    private var clipUntil: TimeInterval = 0
    private var previousRead: TimeInterval = 0

    func read() -> MeterReading {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            if !pendingPermission {
                pendingPermission = true
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    Task { @MainActor in self?.pendingPermission = false }
                }
            }
            return MeterReading(status: "pending", message: "Mikrofonzugriff am Mac bestätigen")
        case .authorized: break
        default:
            stop()
            return MeterReading(status: "denied", message: "Mikrofonzugriff für Pro Remote in macOS erlauben")
        }

        let now = ProcessInfo.processInfo.systemUptime
        if engine?.isRunning != true || now >= checkDeviceAt {
            let currentDevice = MacAudio.defaultUID(.input)
            if engine?.isRunning != true || currentDevice != deviceID {
                stop()
                guard !currentDevice.isEmpty, start(deviceID: currentDevice) else {
                    return MeterReading(status: "unavailable", message: "Mikrofon konnte nicht geöffnet werden")
                }
            }
            checkDeviceAt = now + 0.5
        }
        expiresAt = now + 2

        let block = samples.withLock { state in
            let block = state
            state = Samples()
            return block
        }
        if block.count > 0 { rmsDB = Self.decibels(sqrt(block.squaredSum / Double(block.count))) }
        let peak = Self.decibels(Double(block.peak))
        if peak >= heldPeak && block.count > 0 {
            heldPeak = peak
            holdUntil = now + 1
        } else if now > holdUntil {
            heldPeak = max(peak, heldPeak - 26 * (now - max(previousRead, holdUntil)))
        }
        if block.peak >= 0.999 { clipUntil = now + 1.5 }
        previousRead = now
        return MeterReading(status: "active", rmsDB: rmsDB, peakDB: heldPeak, clipping: now < clipUntil)
    }

    func expire(now: TimeInterval) {
        if engine != nil && now >= expiresAt { stop() }
    }

    func stop() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
        }
        samples = OSAllocatedUnfairLock(initialState: Samples())
        rmsDB = -60
        heldPeak = -60
        holdUntil = 0
        clipUntil = 0
        previousRead = ProcessInfo.processInfo.systemUptime
    }

    private func start(deviceID: String) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { return false }
        let destination = samples
        input.installTap(onBus: 0, bufferSize: 512, format: nil) { @Sendable buffer, _ in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = vDSP_Length(buffer.frameLength)
            let stride = vDSP_Stride(buffer.stride)
            var squaredSum = 0.0
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var squared: Float = 0
                var maximum: Float = 0
                vDSP_svesq(channels[channel], stride, &squared, frames)
                vDSP_maxmgv(channels[channel], stride, &maximum, frames)
                squaredSum += Double(squared)
                peak = max(peak, maximum)
            }
            let block = Samples(squaredSum: squaredSum, count: Int(frames) * Int(buffer.format.channelCount), peak: peak)
            _ = destination.withLockIfAvailable { state in
                state.squaredSum += block.squaredSum
                state.count += block.count
                state.peak = max(state.peak, block.peak)
            }
        }
        do {
            try engine.start()
            self.engine = engine
            self.deviceID = deviceID
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    private static func decibels(_ amplitude: Double) -> Double {
        min(0, 20 * log10(max(0.001, amplitude)))
    }
}
