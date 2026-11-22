import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac awake using macOS power assertions (the same mechanism `caffeinate` uses).
@MainActor
final class AwakeController: ObservableObject {
    enum Mode: Equatable {
        case indefinite
        case timed(Date)          // ends at this date
        case untilDownloadsFinish // ends after the network has been quiet for a while
    }

    static let allowDisplaySleepKey = "awakeAllowDisplaySleep"
    static let stopOnLowBatteryKey = "awakeStopOnLowBattery"
    static let showIndicatorKey = "awakeShowIndicator"
    static let lowBatteryThreshold = 20

    /// Download mode: below this many bytes/sec counts as "quiet" (~400 Kb/s).
    static let quietThreshold: Double = 50_000
    /// Download mode: quiet for this long → allow sleep again.
    static let quietGrace: TimeInterval = 120

    @Published private(set) var mode: Mode?
    @Published private(set) var now = Date()
    @Published private(set) var lastStopReason: String?
    @Published private(set) var quietSeconds: TimeInterval = 0

    var isActive: Bool { mode != nil }

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var timer: Timer?
    private var lastTraffic = Date()

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            allowDisplaySleepKey: false,
            stopOnLowBatteryKey: true,
            showIndicatorKey: true
        ])
    }

    var allowDisplaySleep: Bool { UserDefaults.standard.bool(forKey: Self.allowDisplaySleepKey) }
    var stopOnLowBattery: Bool { UserDefaults.standard.bool(forKey: Self.stopOnLowBatteryKey) }

    // MARK: Control

    func start(_ newMode: Mode) {
        releaseAssertion()
        mode = newMode
        lastStopReason = nil
        lastTraffic = Date()
        quietSeconds = 0

        if stopOnLowBattery, let battery = Self.batteryOnBatteryPower(), battery <= Self.lowBatteryThreshold {
            stop(reason: "Battery is at \(battery)%. Plug in to keep awake.")
            return
        }
        createAssertion()
        startTimer()
    }

    func start(minutes: Int) {
        start(.timed(Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }

    func stop(reason: String? = nil) {
        releaseAssertion()
        timer?.invalidate()
        timer = nil
        mode = nil
        lastStopReason = reason
    }

    func toggleIndefinite() {
        if isActive { stop() } else { start(.indefinite) }
    }

    /// Re-apply when the "let display sleep" option changes mid-session.
    func refreshAssertionType() {
        guard isActive else { return }
        releaseAssertion()
        createAssertion()
    }

    /// Fed once a second by the network monitor.
    func observeTraffic(bytesPerSecond: Double) {
        guard mode == .untilDownloadsFinish else { return }
        if bytesPerSecond >= Self.quietThreshold { lastTraffic = Date() }
        quietSeconds = Date().timeIntervalSince(lastTraffic)
        if quietSeconds >= Self.quietGrace {
            stop(reason: "Downloads finished. Your Mac can sleep normally again.")
        }
    }

    // MARK: Display helpers

    var remaining: TimeInterval? {
        if case .timed(let end) = mode { return max(end.timeIntervalSince(now), 0) }
        return nil
    }

    var statusTitle: String {
        switch mode {
        case nil: return "Off"
        case .indefinite: return "Awake"
        case .timed: return Self.format(remaining ?? 0)
        case .untilDownloadsFinish: return "Awake"
        }
    }

    var statusDetail: String {
        switch mode {
        case nil: return lastStopReason ?? "Your Mac sleeps on its normal schedule."
        case .indefinite: return "Staying awake until you turn this off."
        case .timed(let end):
            return "Staying awake until \(end.formatted(date: .omitted, time: .shortened))."
        case .untilDownloadsFinish:
            if quietSeconds < 3 { return "Network is busy. Staying awake." }
            let left = Int(max(Self.quietGrace - quietSeconds, 0))
            return "Network quiet. Will sleep in \(left)s unless traffic resumes."
        }
    }

    /// Short text for the menu bar indicator.
    var menuBarBadge: String? {
        switch mode {
        case nil: return nil
        case .timed: return Self.formatCompact(remaining ?? 0)
        case .indefinite: return "∞"
        case .untilDownloadsFinish: return "DL"
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func formatCompact(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h\(m % 60 > 0 ? "\(m % 60)" : "")" : "\(m)m"
    }

    // MARK: Internals

    private func createAssertion() {
        // String values of kIOPMAssertionTypePreventUserIdle{Display,System}Sleep.
        let type = allowDisplaySleep ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep"
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(255), // kIOPMAssertionLevelOn
                                                 "Driftline: Keep Awake" as CFString,
                                                 &assertionID)
        hasAssertion = result == kIOReturnSuccess
        if !hasAssertion {
            stop(reason: "macOS refused the keep-awake request (code \(result)).")
        }
    }

    private func releaseAssertion() {
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var tickCount = 0

    private func tick() {
        now = Date()
        if case .timed(let end) = mode, now >= end {
            stop(reason: "Timer finished. Your Mac can sleep normally again.")
            return
        }
        tickCount += 1
        if tickCount % 15 == 0, stopOnLowBattery,
           let battery = Self.batteryOnBatteryPower(), battery <= Self.lowBatteryThreshold {
            stop(reason: "Stopped at \(battery)% battery to save power.")
        }
    }

    /// Battery percentage, but only when running on battery (nil on AC or desktops).
    static func batteryOnBatteryPower() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc["Type"] as? String) == "InternalBattery",
                  (desc["Power Source State"] as? String) == "Battery Power",
                  let current = desc["Current Capacity"] as? Int,
                  let max = desc["Max Capacity"] as? Int, max > 0 else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }
}
