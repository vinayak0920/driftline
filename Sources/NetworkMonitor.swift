import Foundation
import Combine

/// Samples interface counters once a second and publishes live throughput.
@MainActor
final class NetworkMonitor: ObservableObject {
    struct Sample: Equatable {
        let down: Double   // bytes per second
        let up: Double
    }

    static let historyLength = 90

    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var history: [Sample] = Array(repeating: Sample(down: 0, up: 0), count: historyLength)
    @Published private(set) var peakDown: Double = 0
    @Published private(set) var peakUp: Double = 0
    @Published private(set) var sessionDown: UInt64 = 0
    @Published private(set) var sessionUp: UInt64 = 0
    @Published private(set) var sessionStart = Date()
    @Published private(set) var interfaceName: String?
    @Published private(set) var interfaceKind: NetInfo.Kind = .offline

    /// Called after every sample so the menu bar can redraw.
    var onTick: (() -> Void)?

    private var last: [String: Counters] = [:]
    private var lastTime: TimeInterval = 0
    private var timer: Timer?
    private var tickCount = 0

    func start() {
        last = NetStats.read()
        lastTime = ProcessInfo.processInfo.systemUptime
        refreshInterface()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.05
        // .common keeps it ticking while menus / popovers are being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func resetSession() {
        peakDown = 0
        peakUp = 0
        sessionDown = 0
        sessionUp = 0
        sessionStart = Date()
    }

    private func tick() {
        let now = NetStats.read()
        let time = ProcessInfo.processInfo.systemUptime
        let dt = max(time - lastTime, 0.001)

        var rxDelta: UInt64 = 0
        var txDelta: UInt64 = 0
        for (name, current) in now {
            guard let previous = last[name] else { continue }
            // If a counter went backwards the interface was reset; count from zero.
            rxDelta &+= current.rx >= previous.rx ? current.rx - previous.rx : current.rx
            txDelta &+= current.tx >= previous.tx ? current.tx - previous.tx : current.tx
        }
        last = now
        lastTime = time

        let downRate = Double(rxDelta) / dt
        let upRate = Double(txDelta) / dt

        down = downRate
        up = upRate
        sessionDown &+= rxDelta
        sessionUp &+= txDelta
        peakDown = max(peakDown, downRate)
        peakUp = max(peakUp, upRate)

        var h = history
        h.removeFirst()
        h.append(Sample(down: downRate, up: upRate))
        history = h

        tickCount += 1
        if tickCount % 3 == 0 { refreshInterface() }

        onTick?()
    }

    private func refreshInterface() {
        let primary = NetInfo.primaryInterface()
        interfaceName = primary
        interfaceKind = NetInfo.kind(of: primary)
    }
}
