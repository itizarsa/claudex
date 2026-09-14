import Foundation
import NIOCore

/// A provider response whose head has arrived and whose body has not.
struct UpstreamResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: UpstreamBody
}

/// Sends one request to a provider backend and returns as soon as the status and headers are
/// known, with the body still arriving.
///
/// `URLSession.bytes(for:)` would be three lines, but it yields one `UInt8` at a time: a long
/// token stream through it costs a suspension per byte. The delegate hands over whole chunks.
///
/// Suspending the task when the consumer falls behind is the other reason for the delegate.
/// Without it a slow local reader turns a long response into unbounded memory, which for a
/// process that streams model output all day is the difference between a proxy and a leak.
final class UpstreamClient: NSObject, @unchecked Sendable {
    /// Bytes buffered ahead of the consumer before the upstream task is paused, and the level
    /// it must fall back to before reading resumes. Two marks rather than one so a busy
    /// stream does not pause and resume on every chunk.
    private let highWater: Int
    private let lowWater: Int

    private let lock = NSLock()
    private var pending: [Int: Transfer] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // No resource timeout: a long completion is a working request, not a stuck one. The
        // request timeout still catches a backend that never answers at all.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    fileprivate final class Transfer {
        var head: CheckedContinuation<(Int, [String: String]), Error>?
        var body: AsyncThrowingStream<ByteBuffer, Error>.Continuation?
        var buffered = 0
        var paused = false

        /// Resuming a continuation twice traps, and either the head callback or the
        /// completion callback can be the first to see a given transfer end.
        func takeHead() -> CheckedContinuation<(Int, [String: String]), Error>? {
            defer { head = nil }
            return head
        }
    }

    init(highWater: Int = 1 << 20, lowWater: Int = 1 << 18) {
        self.highWater = highWater
        self.lowWater = lowWater
    }

    func send(_ request: URLRequest) async throws -> UpstreamResponse {
        let task = session.dataTask(with: request)
        let transfer = Transfer()
        let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        transfer.body = continuation
        lock.withLock { pending[task.taskIdentifier] = transfer }

        // Cancelling the client's request must cancel the upstream one. Anything still in
        // flight against a provider is spending that account's quota on a response nobody
        // will read.
        continuation.onTermination = { [weak self] _ in
            task.cancel()
            self?.lock.withLock { self?.pending[task.taskIdentifier] = nil }
        }

        let (status, headers): (Int, [String: String]) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                lock.withLock { transfer.head = head }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }

        return UpstreamResponse(
            status: status,
            headers: headers,
            body: UpstreamBody(stream: stream) { [weak self] consumed in
                self?.drain(consumed, task: task)
            }
        )
    }

    /// The consumer took `consumed` bytes; let the upstream task read again if that brought
    /// the buffer back under the low mark.
    private func drain(_ consumed: Int, task: URLSessionTask) {
        let resume: Bool = lock.withLock {
            guard let transfer = pending[task.taskIdentifier] else { return false }
            transfer.buffered -= consumed
            guard transfer.paused, transfer.buffered <= lowWater else { return false }
            transfer.paused = false
            return true
        }
        if resume { task.resume() }
    }
}

extension UpstreamClient: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        let head = lock.withLock { pending[dataTask.taskIdentifier]?.takeHead() }
        head?.resume(returning: (http?.statusCode ?? 0, headers))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let pause: Bool = lock.withLock {
            guard let transfer = pending[dataTask.taskIdentifier] else { return false }
            transfer.buffered += data.count
            transfer.body?.yield(ByteBuffer(bytes: data))
            guard !transfer.paused, transfer.buffered > highWater else { return false }
            transfer.paused = true
            return true
        }
        if pause { dataTask.suspend() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let transfer else { return }
        // A failure before the head arrived has to surface as a thrown request, not as an
        // empty body behind a status nobody produced.
        if let head = lock.withLock({ transfer.takeHead() }) {
            head.resume(throwing: error ?? URLError(.badServerResponse))
            transfer.body?.finish()
            return
        }
        transfer.body?.finish(throwing: error)
    }
}

/// The upstream body, reporting each chunk as the consumer takes it so the client can decide
/// whether to keep reading. A plain `AsyncThrowingStream` cannot do this: it buffers whatever
/// it is handed and never says when that buffer emptied.
struct UpstreamBody: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let stream: AsyncThrowingStream<ByteBuffer, Error>
    let onConsume: @Sendable (Int) -> Void

    func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator(), onConsume: onConsume)
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<ByteBuffer, Error>.Iterator
        let onConsume: @Sendable (Int) -> Void

        mutating func next() async throws -> ByteBuffer? {
            guard let buffer = try await base.next() else { return nil }
            onConsume(buffer.readableBytes)
            return buffer
        }
    }
}
