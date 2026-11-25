import AppKit
import Darwin

struct DisplayState: Encodable {
    let type = "display_state"
    let version = 1
    let displays: [DisplayInfo]
    var error: String? = nil
}

struct DisplayInfo: Encodable {
    let id: String
    let name: String
    let detail: String
    let brightness: Int?
}

@MainActor
enum DisplayControl {
    // Apple displays expose hardware brightness here. Resolve the optional
    // symbols at runtime so display discovery works without this framework.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                                        RTLD_LAZY | RTLD_LOCAL)
    private static let get = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let set = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    private static func brightness(_ id: CGDirectDisplayID) -> Int? {
        var level: Float = 0
        guard let get, set != nil, get(id, &level) == 0, level.isFinite, (0...1).contains(level) else { return nil }
        return Int((level * 100).rounded())
    }

    static func snapshot() -> DisplayState {
        let screenID = NSDeviceDescriptionKey("NSScreenNumber")
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let id = (screen.deviceDescription[screenID] as? NSNumber)?.uint32Value else { return nil }
            return (id, screen)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let connected = status == .success ? Array(ids.prefix(Int(count))) : screens.map { $0.0 }
        return DisplayState(displays: connected.enumerated().map { index, id in
            let screen = screens.first { $0.0 == id }?.1
            var details = [String]()
            if CGDisplayIsMain(id) != 0 { details.append("Hauptdisplay") }
            if CGDisplayIsBuiltin(id) != 0 { details.append("Integriert") }
            if CGDisplayIsInMirrorSet(id) != 0 { details.append("Gespiegelt") }
            if let mode = CGDisplayCopyDisplayMode(id) {
                details.append("\(mode.width) × \(mode.height)")
                if mode.refreshRate > 0 { details.append("\(Int(mode.refreshRate.rounded())) Hz") }
            }
            return DisplayInfo(id: String(id), name: screen?.localizedName ?? "Monitor \(index + 1)",
                               detail: details.joined(separator: " · "), brightness: brightness(id))
        })
    }

    static func setBrightness(id: String, value: Int) -> DisplayState {
        guard let display = CGDirectDisplayID(id), CGDisplayIsOnline(display) != 0,
              (0...100).contains(value), brightness(display) != nil, let set else {
            var state = snapshot()
            state.error = "Helligkeit für dieses Display nicht verfügbar"
            return state
        }
        let result = set(display, Float(value) / 100)
        var state = snapshot()
        if result != 0 { state.error = "Helligkeit konnte nicht geändert werden" }
        return state
    }
}
