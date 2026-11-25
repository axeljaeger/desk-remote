import AppKit
import CoreGraphics

struct MediaReply: Encodable {
    let version = 1
    let ok: Bool
    let message: String
}

enum SystemMedia: String {
    case previous, toggle, next

    @MainActor
    func send() -> MediaReply {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let setting = version.majorVersion == 27 && version.minorVersion < 3
                ? "Gerätesteuerung und Datenzugriff" : "Bedienungshilfen"
            return MediaReply(ok: false, message: "Pro Remote unter Datenschutz & Sicherheit → \(setting) erlauben")
        }
        let key: Int
        switch self {
        case .previous: key = Int(NX_KEYTYPE_REWIND)
        case .toggle: key = Int(NX_KEYTYPE_PLAY)
        case .next: key = Int(NX_KEYTYPE_FAST)
        }
        guard let down = Self.event(key: key, transition: .keyDown),
              let up = Self.event(key: key, transition: .keyUp) else {
            return MediaReply(ok: false, message: "Medientaste konnte nicht erzeugt werden")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.005)
        up.post(tap: .cghidEventTap)
        return MediaReply(ok: true, message: "Tastendruck an macOS übergeben")
    }

    private static func event(key: Int, transition: NSEvent.EventType) -> CGEvent? {
        let state = transition.rawValue
        // AppKit's event flags hold the raw state. The subtype payload shifts it by a byte.
        return NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                  modifierFlags: NSEvent.ModifierFlags(rawValue: state),
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                  subtype: 8, data1: (key << 16) | (Int(state) << 8), data2: -1)?.cgEvent
    }
}
