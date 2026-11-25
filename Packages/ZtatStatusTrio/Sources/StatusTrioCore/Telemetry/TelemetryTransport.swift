// ZTAT-PATCH: Disabled telemetry network transport completely; zero URLSession or network traffic.
import Foundation

protocol TelemetryTransport: Sendable {
    func send(request: URLRequest) async throws -> HTTPURLResponse
}

struct URLSessionTelemetryTransport: TelemetryTransport {
    init(configuration _: TelemetryConfiguration) {}

    func send(request _: URLRequest) async throws -> HTTPURLResponse {
        throw TelemetryTransportError.disabled
    }
}

enum TelemetryTransportError: Error {
    case nonHTTPResponse
    case disabled
}
