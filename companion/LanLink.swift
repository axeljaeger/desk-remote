import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct LanPairing: Codable, Equatable {
    let address: String
    let key: [UInt8]

    var discoveryID: String {
        let context = Data("pro-remote-bonjour-v1".utf8)
        let digest = HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: key))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Pro Remote/LAN", isDirectory: true)
    }

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pairing.json")),
              let pair = try? JSONDecoder().decode(Self.self, from: data), pair.key.count == 32 else { return nil }
        return pair
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)
        try JSONEncoder().encode(self).write(to: Self.directory.appendingPathComponent("pairing.json"), options: .atomic)
    }

    static func create(address: String, key: [UInt8]?) throws -> Self {
        if let key { return Self(address: address, key: key) }
        return Self(address: address, key: Array(try randomBytes(32)))
    }

    static func localAddress(for peer: String) -> String? {
        var remote = in_addr()
        guard inet_pton(AF_INET, peer, &remote) == 1 else { return nil }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(first) }
        var best: (address: in_addr, bits: Int)?
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            let interface = current.pointee
            entry = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let ip = interface.ifa_addr, ip.pointee.sa_family == UInt8(AF_INET),
                  let mask = interface.ifa_netmask else { continue }
            let address = ip.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let subnet = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard subnet != 0, address.s_addr != remote.s_addr,
                  address.s_addr & subnet == remote.s_addr & subnet,
                  subnet.nonzeroBitCount > (best?.bits ?? 0) else { continue }
            best = (address, subnet.nonzeroBitCount)
        }
        guard var address = best?.address else { return nil }
        var string = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &string, socklen_t(string.count)) != nil else { return nil }
        return String(cString: string)
    }
}

private func randomBytes(_ count: Int) throws -> Data {
    var bytes = Data(count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return bytes
}

@MainActor
final class LanLink {
    enum Reply {
        case message(Data)
        case video(@MainActor (NWConnection, @escaping (Data) -> Data?) -> Void)
        case videoDatagrams(UInt16, @MainActor (NWConnection, @escaping (Data) -> [Data]?) -> Bool)
        case upload(@MainActor (Data) -> Void)
    }
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]

    init(pair: LanPairing, onStatus: @escaping @MainActor (String) -> Void,
         onRequest: @escaping @MainActor (Data) -> Reply?) throws {
        guard pair.key.count == 32 else { throw POSIXError(.EINVAL) }
        let key = SymmetricKey(data: Data(pair.key))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: 5176)
        let identity = pair.discoveryID
        listener.service = NWListener.Service(name: "Pro Remote \(identity.prefix(8))",
                                              type: "_proremote._tcp", domain: "local.",
                                              txtRecord: NWTXTRecord(["pair": identity]))
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: onStatus("Warte auf das Tab5 im WLAN")
                case .failed, .waiting: onStatus("WLAN-Server konnte nicht starten. Mac-Adresse und Freigabe prüfen.")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.connections.count < 8,
                      case .hostPort(let host, _) = connection.endpoint,
                      case .ipv4(let peer) = host,
                      let address = LanPairing.localAddress(for: peer.debugDescription).flatMap(IPv4Address.init)
                else { connection.cancel(); return }
                self.accept(connection, key: key, localAddress: address, onRequest: onRequest)
            }
        }
        listener.start(queue: .main)
    }

    deinit {
        listener.cancel()
        for connection in connections.values { connection.cancel() }
    }

    private func accept(_ connection: NWConnection, key: SymmetricKey, localAddress: IPv4Address,
                        onRequest: @escaping @MainActor (Data) -> Reply?) {
        guard let challenge = try? randomBytes(16) else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        let detach: @MainActor () -> Void = { [weak self] in self?.connections.removeValue(forKey: id) }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: Task { @MainActor in detach() }
            default: break
            }
        }
        connection.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        connection.send(content: challenge, completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            Self.receive(connection, key: key, challenge: challenge, localAddress: localAddress,
                         onRequest: onRequest, detach: detach)
        })
    }

    nonisolated private static func receive(_ connection: NWConnection, key: SymmetricKey, challenge: Data, localAddress: IPv4Address,
                                             onRequest: @escaping @MainActor (Data) -> Reply?, detach: @escaping @MainActor () -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else { connection.cancel(); return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (29...1052).contains(length) else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { record, _, _, error in
                guard error == nil, let record, record.count == length,
                      let box = try? AES.GCM.SealedBox(combined: record),
                      let request = try? AES.GCM.open(box, using: key, authenticating: challenge + Data([0])) else {
                    connection.cancel()
                    return
                }
                Task { @MainActor in
                    switch onRequest(request) {
                    case .message(let reply):
                        guard (1...16384).contains(reply.count),
                              let packet = seal(reply, key: key, aad: challenge + Data([1])) else { connection.cancel(); return }
                        connection.send(content: packet, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    case .video(let start):
                        detach()
                        var sequence: UInt32 = 0
                        start(connection) { frame in
                            guard frame.count <= 131072, sequence < UInt32.max else { return nil }
                            var index = sequence.bigEndian
                            let aad = challenge + Data([2]) + withUnsafeBytes(of: &index) { Data($0) }
                            guard let packet = seal(frame, key: key, aad: aad) else { return nil }
                            sequence += 1
                            return packet
                        }
                    case .videoDatagrams(let port, let start):
                        guard case .hostPort(let host, _) = connection.endpoint,
                              case .ipv4 = host, let remotePort = NWEndpoint.Port(rawValue: port),
                              let accepted = seal(Data([1]), key: key, aad: challenge + Data([1])) else {
                            connection.cancel()
                            return
                        }
                        let parameters = NWParameters.udp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
                        let video = NWConnection(host: host, port: remotePort, using: parameters)
                        var sequence: UInt32 = 0
                        guard start(video, { frame in
                            guard sequence < UInt32.max else { return nil }
                            defer { sequence += 1 }
                            return videoPackets(frame, sequence: sequence, key: key, challenge: challenge)
                        }) else {
                            video.cancel()
                            connection.cancel()
                            return
                        }
                        connection.send(content: accepted, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in connection.cancel() })
                    case .upload(let onImage):
                        receiveImage(connection, key: key, aad: challenge + Data([3]), onImage: onImage)
                    case nil: connection.cancel()
                    }
                }
            }
        }
    }

    nonisolated private static func videoPackets(_ frame: Data, sequence: UInt32, key: SymmetricKey,
                                                  challenge: Data) -> [Data]? {
        guard (1...32768).contains(frame.count) else { return nil }
        var index = sequence.bigEndian
        var size = UInt16(frame.count).bigEndian
        let prefix = withUnsafeBytes(of: &index) { Data($0) } + withUnsafeBytes(of: &size) { Data($0) }
        var packets: [Data] = []
        for offset in stride(from: 0, to: frame.count, by: 1024) {
            var fragment = UInt16(offset / 1024).bigEndian
            let header = prefix + withUnsafeBytes(of: &fragment) { Data($0) }
            let content = frame.subdata(in: offset..<min(offset + 1024, frame.count))
            guard let sealed = sealBody(content, key: key, aad: challenge + Data([4]) + header) else { return nil }
            packets.append(header + sealed)
        }
        return packets
    }

    nonisolated private static func receiveImage(_ connection: NWConnection, key: SymmetricKey, aad: Data,
                                                  onImage: @escaping @MainActor (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard error == nil, let header, header.count == 4 else { connection.cancel(); return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard (29...131100).contains(length) else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { record, _, _, error in
                defer { connection.cancel() }
                guard error == nil, let record, record.count == length,
                      let box = try? AES.GCM.SealedBox(combined: record),
                      let image = try? AES.GCM.open(box, using: key, authenticating: aad) else { return }
                Task { @MainActor in onImage(image) }
            }
        }
    }

    nonisolated private static func seal(_ reply: Data, key: SymmetricKey, aad: Data) -> Data? {
        guard let body = sealBody(reply, key: key, aad: aad) else { return nil }
        var size = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + body
    }

    nonisolated private static func sealBody(_ reply: Data, key: SymmetricKey, aad: Data) -> Data? {
        guard var nonceBytes = try? randomBytes(12) else { return nil }
        nonceBytes[0] |= 0x80
        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes) else { return nil }
        return try? AES.GCM.seal(reply, using: key, nonce: nonce, authenticating: aad).combined
    }
}
