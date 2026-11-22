import Foundation

/// A full speed test: latency + jitter, multi-stream download, multi-stream upload.
/// Measured against Cloudflare's public speed-test endpoints.
@MainActor
final class SpeedTester: ObservableObject {
    enum Phase: Equatable {
        case idle, latency, download, upload, done
        case failed(String)
    }

    struct TestResult: Codable, Identifiable {
        var id = UUID()
        var date: Date
        var pingMs: Double
        var jitterMs: Double
        var downMbps: Double
        var upMbps: Double
        var network: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var phaseProgress: Double = 0
    @Published private(set) var ping: Double?
    @Published private(set) var jitter: Double?
    @Published private(set) var down: Double?
    @Published private(set) var up: Double?
    @Published private(set) var history: [TestResult] = SpeedTester.loadHistory()

    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .latency, .download, .upload: return true
        default: return false
        }
    }

    /// 0…1 across the whole test, for the progress bar.
    var overallProgress: Double {
        switch phase {
        case .idle, .failed: return 0
        case .latency: return 0.10 * phaseProgress
        case .download: return 0.10 + 0.45 * phaseProgress
        case .upload: return 0.55 + 0.45 * phaseProgress
        case .done: return 1
        }
    }

    func start(networkLabel: String) {
        guard !isRunning else { return }
        ping = nil; jitter = nil; down = nil; up = nil
        liveMbps = 0
        phaseProgress = 0
        task = Task { await run(networkLabel: networkLabel) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        liveMbps = 0
        phaseProgress = 0
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - Run

    private func run(networkLabel: String) async {
        do {
            phase = .latency
            let (p, j) = try await measureLatency()
            ping = p
            jitter = j

            phase = .download
            phaseProgress = 0
            down = try await measureThroughput(.download, streams: 8, duration: 10)

            phase = .upload
            phaseProgress = 0
            liveMbps = 0
            up = try await measureThroughput(.upload, streams: 6, duration: 10)

            liveMbps = down ?? 0
            phase = .done

            let result = TestResult(date: Date(), pingMs: p, jitterMs: j,
                                    downMbps: down ?? 0, upMbps: up ?? 0, network: networkLabel)
            history.insert(result, at: 0)
            if history.count > 25 { history.removeLast(history.count - 25) }
            saveHistory()
        } catch is CancellationError {
            phase = .idle
        } catch let error as URLError where error.code == .cancelled {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Latency

    private func measureLatency() async throws -> (ping: Double, jitter: Double) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let rounds = 20
        var samples: [Double] = []
        for i in 0..<rounds {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=0&r=\(UUID().uuidString)")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let catcher = MetricsCatcher()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let (_, response) = try await session.data(for: request, delegate: catcher)
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SpeedTestError.badResponse
            }

            // Pure network round trip: time from request sent → first response byte,
            // minus the time Cloudflare's server spent processing (Server-Timing header).
            // This removes DNS, TLS and app overhead — the same method speed.cloudflare.com uses.
            var rtt = wallMs
            if let tx = catcher.metrics?.transactionMetrics.last,
               let sent = tx.requestStartDate, let firstByte = tx.responseStartDate {
                rtt = firstByte.timeIntervalSince(sent) * 1000
            }
            if let timing = http.value(forHTTPHeaderField: "Server-Timing"),
               let serverMs = Self.serverDuration(timing) {
                rtt = max(rtt - serverMs, 0.1)
            }

            // First rounds include connection setup; skip them.
            if i >= 3 { samples.append(rtt) }
            phaseProgress = Double(i + 1) / Double(rounds)
        }

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        var diffs: [Double] = []
        for i in 1..<samples.count { diffs.append(abs(samples[i] - samples[i - 1])) }
        let jitter = diffs.reduce(0, +) / Double(max(diffs.count, 1))
        return (median, jitter)
    }

    /// Parses "cfRequestDuration;dur=12.5" → 12.5
    private static func serverDuration(_ header: String) -> Double? {
        guard let range = header.range(of: "dur=") else { return nil }
        let rest = header[range.upperBound...]
        let number = rest.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    // MARK: - Throughput

    private func measureThroughput(_ direction: ThroughputProbe.Direction,
                                   streams: Int,
                                   duration: Double) async throws -> Double {
        let probe = ThroughputProbe(direction: direction)
        probe.start(streams: streams)
        defer { probe.stop() }

        let warmup = 2.0 // ignore TCP slow-start ramp-up
        let begin = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9 }

        var baseTime: Double?
        var baseBytes: Int64 = 0
        var window: [(t: Double, bytes: Int64)] = []
        var t = 0.0

        while true {
            try await Task.sleep(nanoseconds: 150_000_000)
            t = elapsed()
            let bytes = probe.bytes

            window.append((t, bytes))
            while window.count > 2, let first = window.first, t - first.t > 1.2 { window.removeFirst() }
            if let first = window.first, t > first.t {
                liveMbps = Double(bytes - first.bytes) * 8 / 1_000_000 / (t - first.t)
            }

            if baseTime == nil, t >= warmup {
                baseTime = t
                baseBytes = bytes
            }
            phaseProgress = min(t / duration, 1)

            if let error = probe.failure, bytes == 0, t > 3 { throw error }
            if t >= duration { break }
        }

        guard let start = baseTime, t > start else { throw SpeedTestError.noData }
        let measured = probe.bytes - baseBytes
        guard measured > 0 else { throw probe.failure ?? SpeedTestError.noData }
        return Double(measured) * 8 / 1_000_000 / (t - start)
    }

    // MARK: - Persistence

    private static let historyKey = "speedTestHistory"

    private static func loadHistory() -> [TestResult] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([TestResult].self, from: data) else { return [] }
        return items
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}

enum SpeedTestError: LocalizedError {
    case badResponse, noData

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The test server didn't respond correctly."
        case .noData: return "No data got through. Check your connection."
        }
    }
}

/// Captures timing metrics for a single request.
final class MetricsCatcher: NSObject, URLSessionTaskDelegate {
    var metrics: URLSessionTaskMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }
}

/// Keeps N parallel transfers saturating the link and counts every byte.
final class ThroughputProbe: NSObject, URLSessionDataDelegate {
    enum Direction { case download, upload }

    private let direction: Direction
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _running = false
    private var _failure: Error?
    private var failures = 0
    private var session: URLSession!
    private let uploadBody: Data

    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return _bytes }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return _failure }
    private var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }

    init(direction: Direction) {
        self.direction = direction
        self.uploadBody = direction == .upload ? Data(count: 10_000_000) : Data()
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start(streams: Int) {
        lock.lock(); _running = true; lock.unlock()
        for _ in 0..<streams { launch() }
    }

    func stop() {
        lock.lock(); _running = false; lock.unlock()
        session.invalidateAndCancel()
    }

    private func add(_ n: Int64) {
        lock.lock(); _bytes += n; lock.unlock()
    }

    private func launch() {
        guard running else { return }
        let task: URLSessionTask
        switch direction {
        case .download:
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            task = session.dataTask(with: request)
        case .upload:
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            task = session.uploadTask(with: request, from: uploadBody)
        }
        task.resume()
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if direction == .download { add(Int64(data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if direction == .upload { add(bytesSent) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running else { return }
        if let error {
            lock.lock()
            failures += 1
            _failure = error
            let tooMany = failures > 20
            lock.unlock()
            if tooMany { return }
        }
        launch() // keep the pipe full
    }
}
