import Darwin
import Foundation
import IOKit
import IOKit.serial

final class SerialLink {
    static let prefix = Data("@tab5 ".utf8)
    private let descriptor: Int32
    private var incoming = Data()
    private var outgoing = Data()
    private var discardLine = false

    static func ports() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [String] = []
        let flags = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, flags)
            }
            if (property("idVendor") as? NSNumber)?.intValue == 0x303a,
               (property("idProduct") as? NSNumber)?.intValue == 0x1001,
               let port = property(kIOCalloutDeviceKey) as? String {
                ports.append(port)
            }
        }
        return ports.sorted()
    }

    init(path: String) throws {
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.posixError() }
        var state = termios()
        guard tab5_serial_exclusive(descriptor) == 0,
              tcgetattr(descriptor, &state) == 0 else {
            let failure = Self.posixError()
            Darwin.close(descriptor)
            throw failure
        }
        cfmakeraw(&state)
        state.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetspeed(&state, speed_t(B115200))
        guard tcsetattr(descriptor, TCSANOW, &state) == 0 else {
            let failure = Self.posixError()
            Darwin.close(descriptor)
            throw failure
        }
    }

    deinit { Darwin.close(descriptor) }

    func readFrames() throws -> [Data] {
        var payloads: [Data] = []
        var bytes = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<8 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { break }
                throw Self.posixError()
            }
            if count == 0 { break }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if !discardLine, incoming.starts(with: Self.prefix) {
                        if incoming.last == 13 { incoming.removeLast() }
                        payloads.append(Data(incoming.dropFirst(Self.prefix.count)))
                    }
                    incoming.removeAll(keepingCapacity: true)
                    discardLine = false
                } else if incoming.count == 2048 {
                    discardLine = true
                } else if !discardLine {
                    incoming.append(byte)
                }
            }
        }
        return payloads
    }

    func queue(_ payload: Data) -> Bool {
        guard outgoing.isEmpty, payload.count + Self.prefix.count + 1 <= 16 * 1024 else { return false }
        outgoing = Self.prefix
        outgoing.append(payload)
        outgoing.append(10)
        return true
    }

    func flush() throws {
        guard !outgoing.isEmpty else { return }
        let count = outgoing.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            throw Self.posixError()
        }
        outgoing.removeFirst(count)
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
