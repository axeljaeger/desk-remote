import CoreAudio
import Foundation

enum AudioDirection: String, Decodable {
    case input
    case output

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
}

struct AudioDevice: Encodable {
    let id: String
    let name: String
}

struct AudioState: Encodable {
    let inputs: [AudioDevice]
    let outputs: [AudioDevice]
    let activeInput: String
    let activeOutput: String
    let error: String?
}

enum AudioFailure: Error, LocalizedError {
    case query(OSStatus)
    case deviceMissing
    case rejected(OSStatus)

    var errorDescription: String? {
        switch self {
        case .query(let status): return "Audio-Geräte konnten nicht gelesen werden (\(status))."
        case .deviceMissing: return "Das gewählte Audio-Gerät ist nicht verfügbar."
        case .rejected(let status): return "macOS hat den Gerätewechsel abgelehnt (\(status))."
        }
    }
}

enum MacAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func snapshot(error: String? = nil) throws -> AudioState {
        let devices = try deviceIDs()
        return AudioState(
            inputs: entries(devices, direction: .input),
            outputs: entries(devices, direction: .output),
            activeInput: defaultUID(.input),
            activeOutput: defaultUID(.output),
            error: error
        )
    }

    static func select(_ direction: AudioDirection, uid: String) throws {
        guard var device = try deviceIDs().first(where: {
            nameProperty($0, kAudioDevicePropertyDeviceUID) == uid && hasChannels($0, direction)
        }) else { throw AudioFailure.deviceMissing }

        var property = address(direction.defaultSelector)
        let result = AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: device)), &device)
        guard result == noErr else { throw AudioFailure.rejected(result) }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() throws -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyDevices)
        var byteCount: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(system, &property, 0, nil, &byteCount)
        guard result == noErr else { throw AudioFailure.query(result) }
        let stride = MemoryLayout<AudioObjectID>.stride
        var devices = [AudioObjectID](repeating: 0, count: Int(byteCount) / stride)
        if devices.isEmpty { return [] }
        result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &byteCount, $0.baseAddress!)
        }
        guard result == noErr else { throw AudioFailure.query(result) }
        return devices.prefix(Int(byteCount) / stride).filter { !isTemporaryDefaultAggregate($0) }
    }

    private static func isTemporaryDefaultAggregate(_ device: AudioObjectID) -> Bool {
        guard let name = nameProperty(device, kAudioObjectPropertyName), name.hasPrefix("CADefaultDeviceAggregate-"),
              name.range(of: #"^CADefaultDeviceAggregate-[0-9]+-[0-9]+$"#, options: .regularExpression) != nil else { return false }
        var property = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: transport))
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &transport) == noErr
            && transport == kAudioDeviceTransportTypeAggregate
    }

    private static func entries(_ devices: [AudioObjectID], direction: AudioDirection) -> [AudioDevice] {
        devices.compactMap { device in
            guard hasChannels(device, direction),
                  let id = nameProperty(device, kAudioDevicePropertyDeviceUID),
                  let name = nameProperty(device, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultUID(_ direction: AudioDirection) -> String {
        var property = address(direction.defaultSelector)
        var device: AudioObjectID = 0
        var byteCount = UInt32(MemoryLayout.size(ofValue: device))
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &byteCount, &device) == noErr,
              device != 0 else { return "" }
        return nameProperty(device, kAudioDevicePropertyDeviceUID) ?? ""
    }

    private static func nameProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &property, 0, nil, &byteCount, UnsafeMutableRawPointer($0))
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasChannels(_ device: AudioObjectID, _ direction: AudioDirection) -> Bool {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: direction.scope)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &byteCount) == noErr,
              Int(byteCount) >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &byteCount, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }
}
