import Foundation
import Network
import NookCore

/// One-shot OAuth redirect receiver for the RFC 8252 loopback pattern.
///
/// - Binds only to 127.0.0.1 on a random port, local connections only.
/// - Accepts exactly `GET /nook-callback?…`; anything else gets a 404 and is closed.
/// - Delivers the first callback, lets the caller answer it, then shuts down.
/// - Requires the sandbox `network.server` entitlement (opt-in builds only).
final class LoopbackRedirectReceiver: @unchecked Sendable {
    enum ReceiverError: LocalizedError {
        case couldNotStart(String)
        case portInUse(UInt16)
        case timedOut
        case stopped

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let why): return "Couldn't start the sign-in listener (\(why))."
            case .portInUse(let port): return "Port \(port) on 127.0.0.1 is in use by another app, so Nook can't receive Spotify's sign-in redirect. Quit that app and try again."
            case .timedOut: return "Sign-in timed out. Try again."
            case .stopped: return "Sign-in was cancelled."
            }
        }
    }

    private let queue = DispatchQueue(label: "Nook.LoopbackRedirect")
    // All mutable state below is confined to `queue`.
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var requestedPort: UInt16?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: (url: URL, connection: NWConnection)?
    private var answeringConnection: NWConnection?
    private var finished = false

    /// Starts listening on 127.0.0.1 — on `port` (the registered redirect port) or, if nil, any free
    /// port (self-tests). Returns the bound port.
    func start(port requestedPort: UInt16? = nil) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.requestedPort = requestedPort
                let parameters = NWParameters.tcp
                let nwPort = requestedPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
                parameters.acceptLocalOnly = true
                parameters.allowLocalEndpointReuse = false
                let listener: NWListener
                do {
                    listener = try NWListener(using: parameters)
                } catch {
                    continuation.resume(throwing: ReceiverError.couldNotStart(error.localizedDescription))
                    return
                }
                self.listener = listener
                self.readyContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the first valid callback (or times out).
    func nextCallback(timeout: Duration) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(ReceiverError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.finished, self.pendingCallback == nil {
                    continuation.resume(throwing: ReceiverError.stopped)
                } else if let pending = self.pendingCallback {
                    self.pendingCallback = nil
                    self.answeringConnection = pending.connection
                    continuation.resume(returning: pending.url)
                } else {
                    self.callbackContinuation = continuation
                }
            }
        }
    }

    /// Answers the browser that delivered the callback, then stops listening.
    func respond(success: Bool) {
        queue.async {
            if let connection = self.answeringConnection {
                connection.send(content: LoopbackCallback.response(success: success), completion: .contentProcessed { _ in connection.cancel() })
                self.answeringConnection = nil
            }
            self.shutDown()
        }
    }

    func stop() {
        queue.async { self.fail(ReceiverError.stopped, onQueue: true) }
    }

    // MARK: Queue-confined internals

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case .failed(let error):
            let failure: ReceiverError
            if case .posix(let code) = error, code == .EADDRINUSE, let requestedPort {
                failure = .portInUse(requestedPort)
            } else {
                failure = .couldNotStart(error.localizedDescription)
            }
            readyContinuation?.resume(throwing: failure)
            readyContinuation = nil
            fail(failure, onQueue: true)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !finished else { connection.cancel(); return }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            guard !self.finished, let data, let url = LoopbackCallback.callbackURL(fromRequest: data, port: self.port) else {
                // Not our redirect (e.g. a favicon request), or already done: refuse and keep waiting.
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if let continuation = self.callbackContinuation {
                self.callbackContinuation = nil
                self.answeringConnection = connection
                continuation.resume(returning: url)
            } else if self.pendingCallback == nil {
                self.pendingCallback = (url, connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func fail(_ error: Error, onQueue: Bool = false) {
        guard onQueue else {
            queue.async { self.fail(error, onQueue: true) }
            return
        }
        callbackContinuation?.resume(throwing: error)
        callbackContinuation = nil
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        shutDown()
    }

    private func shutDown() {
        finished = true
        listener?.cancel()
        listener = nil
        pendingCallback?.connection.cancel()
        pendingCallback = nil
    }
}
