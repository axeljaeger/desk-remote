import Foundation
import Network

// The preview server opens a loopback connection for each command or video stream.
final class PreviewLink {
    private let listener: NWListener

    init(onStatus: @MainActor @escaping (String) -> Void,
         onRequest: @MainActor @escaping (AudioRequest) -> Data?,
         onCameraStream: @MainActor @escaping (String, NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        let port: NWEndpoint.Port = 5174
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            let status: String
            switch state {
            case .ready: status = "Live-Vorschau verfügbar"
            case .failed(let error), .waiting(let error):
                status = "Browser-Verbindung fehlgeschlagen (127.0.0.1:5174): \(error.debugDescription)"
            default: return
            }
            Task { @MainActor in onStatus(status) }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            let timeout = DispatchWorkItem { [weak connection] in
                connection?.cancel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            Self.receive(connection, timeout: timeout, onRequest: onRequest, onCameraStream: onCameraStream)
        }
        listener.start(queue: .main)
    }

    deinit { listener.cancel() }

    private static func receive(_ connection: NWConnection, data: Data = Data(), timeout: DispatchWorkItem,
                                onRequest: @MainActor @escaping (AudioRequest) -> Data?,
                                onCameraStream: @MainActor @escaping (String, NWConnection) -> Void) {
        let limit = 4096
        connection.receive(minimumIncompleteLength: 1, maximumLength: limit - data.count) { chunk, _, complete, error in
            var request = data
            if let chunk { request.append(chunk) }
            if let newline = request.firstIndex(of: 10), error == nil,
               let message = try? JSONDecoder().decode(AudioRequest.self, from: request[..<newline]) {
                timeout.cancel()
                Task { @MainActor in
                    if message.type == "camera_stream", message.version == 1, let ticket = message.id {
                        onCameraStream(ticket, connection)
                        return
                    }
                    guard var response = onRequest(message) else { connection.cancel(); return }
                    response.append(10)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error == nil, !complete, request.count < limit {
                receive(connection, data: request, timeout: timeout, onRequest: onRequest, onCameraStream: onCameraStream)
            } else {
                connection.cancel()
            }
        }
    }
}
