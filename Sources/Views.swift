import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var tester: SpeedTester
    @ObservedObject var awake: AwakeController
    @ObservedObject var friends: FriendsController
    @ObservedObject var mixer: AppVolumeMixer
    @ObservedObject var updater: Updater

    @AppStorage(Prefs.useBitsKey) private var useBits = true
    @AppStorage(Prefs.menuStyleKey) private var menuStyle = MenuStyle.stacked.rawValue
    @AppStorage(Updater.autoCheckKey) private var autoUpdate = true
    @ObservedObject var ui: UIState

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Live", test = "Test", awake = "Awake", sound = "Sound", friends = "Friends", history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            UpdateBanner(updater: updater)

            Picker("", selection: $ui.tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)

            Group {
                switch ui.tab {
                case .live: LiveSection(monitor: monitor, useBits: useBits)
                case .test: TestSection(tester: tester, networkLabel: networkLabel)
                case .awake: AwakeSection(awake: awake, ui: ui)
                case .sound: SoundSection(mixer: mixer)
                case .friends: FriendsSection(friends: friends, ui: ui)
                case .history: HistorySection(tester: tester)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()

            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: PopoverMetrics.width, height: PopoverMetrics.height)
    }

    private var networkLabel: String {
        if let name = monitor.interfaceName { return "\(monitor.interfaceKind.rawValue) · \(name)" }
        return monitor.interfaceKind.rawValue
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Driftline").font(.system(size: 14, weight: .bold, design: .rounded))
                Text("by Apavin").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.interfaceKind == .offline ? Color.red : Color.green)
                    .frame(width: 6, height: 6)
                Image(systemName: monitor.interfaceKind.symbol).font(.system(size: 10, weight: .semibold))
                Text(networkLabel).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
    }

    private var footer: some View {
        HStack {
            Text(sessionSummary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Toggle("Show speeds in bits (Mb/s)", isOn: $useBits)
                Picker("Menu bar style", selection: $menuStyle) {
                    ForEach(MenuStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { ui.loginEnabled },
                    set: { LoginItem.set($0); ui.loginEnabled = LoginItem.isEnabled }
                ))
                Toggle("Keep Mac awake", isOn: Binding(
                    get: { awake.isActive },
                    set: { $0 ? awake.start(.indefinite) : awake.stop() }
                ))
                Divider()
                Button("Reset session stats") { monitor.resetSession() }
                Divider()
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                Text("Version \(updater.currentVersion)")
                Divider()
                Button("Quit Driftline") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var sessionSummary: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Session started \(f.localizedString(for: monitor.sessionStart, relativeTo: Date()))"
    }
}

// MARK: - Live

struct LiveSection: View {
    @ObservedObject var monitor: NetworkMonitor
    let useBits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Readout(title: "DOWNLOAD", color: .driftDown, bytesPerSecond: monitor.down, bits: useBits)
                Readout(title: "UPLOAD", color: .driftUp, bytesPerSecond: monitor.up, bits: useBits)
            }

            FlowGraph(samples: monitor.history, bits: useBits)
                .frame(height: 120)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(label: "Peak down", value: RateFormat.short(monitor.peakDown, bits: useBits), color: .driftDown)
                StatTile(label: "Peak up", value: RateFormat.short(monitor.peakUp, bits: useBits), color: .driftUp)
                StatTile(label: "Received", value: RateFormat.total(monitor.sessionDown), color: .driftDown)
                StatTile(label: "Sent", value: RateFormat.total(monitor.sessionUp), color: .driftUp)
            }
        }
    }
}

struct Readout: View {
    let title: String
    let color: Color
    let bytesPerSecond: Double
    let bits: Bool

    var body: some View {
        let p = RateFormat.parts(bytesPerSecond, bits: bits)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(p.value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(p.unit)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .animation(.easeOut(duration: 0.3), value: p.value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Smoothed dual-area graph of the last 90 seconds.
struct FlowGraph: View {
    let samples: [NetworkMonitor.Sample]
    let bits: Bool

    private var ceiling: Double {
        let peak = samples.map { max($0.down, $0.up) }.max() ?? 0
        return max(peak * 1.15, 12_500) // floor: 100 Kb/s so idle doesn't look noisy
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                // Grid
                for i in 1...3 {
                    let y = size.height * CGFloat(i) / 4
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.primary.opacity(0.07)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                draw(\.up, color: .driftUp, in: context, size: size)
                draw(\.down, color: .driftDown, in: context, size: size)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(RateFormat.short(ceiling, bits: bits))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(6)

            Text("90s")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func draw(_ key: KeyPath<NetworkMonitor.Sample, Double>, color: Color,
                      in context: GraphicsContext, size: CGSize) {
        guard samples.count > 1 else { return }
        let step = size.width / CGFloat(samples.count - 1)
        let points: [CGPoint] = samples.enumerated().map { i, s in
            let ratio = CGFloat(s[keyPath: key] / ceiling)
            return CGPoint(x: CGFloat(i) * step, y: size.height - ratio * (size.height - 8) - 2)
        }

        var line = Path()
        line.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            line.addQuadCurve(to: mid, control: points[i - 1])
        }
        line.addLine(to: points[points.count - 1])

        var area = line
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()

        context.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.35), color.opacity(0.0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        if let last = points.last {
            let dot = Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(color))
        }
    }
}

// MARK: - Speed test

struct TestSection: View {
    @ObservedObject var tester: SpeedTester
    let networkLabel: String

    var body: some View {
        VStack(spacing: 12) {
            ArcGauge(mbps: gaugeValue, caption: caption, tint: gaugeTint)
                .frame(height: 170)

            ProgressView(value: tester.overallProgress)
                .progressViewStyle(.linear)
                .tint(gaugeTint)
                .opacity(tester.isRunning ? 1 : 0)

            HStack(spacing: 6) {
                MetricPill(label: "Ping", value: tester.ping.map { String(format: "%.0f", $0) }, unit: "ms",
                           active: tester.phase == .latency, color: .secondary)
                MetricPill(label: "Jitter", value: tester.jitter.map { String(format: "%.1f", $0) }, unit: "ms",
                           active: tester.phase == .latency, color: .secondary)
                MetricPill(label: "Down", value: tester.down.map(RateFormat.mbps), unit: "Mbps",
                           active: tester.phase == .download, color: .driftDown)
                MetricPill(label: "Up", value: tester.up.map(RateFormat.mbps), unit: "Mbps",
                           active: tester.phase == .upload, color: .driftUp)
            }

            Button {
                if tester.isRunning { tester.cancel() } else { tester.start(networkLabel: networkLabel) }
            } label: {
                Text(buttonTitle).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(tester.isRunning ? .gray : .driftDown)
        }
    }

    private var gaugeValue: Double {
        switch tester.phase {
        case .download, .upload: return tester.liveMbps
        case .done: return tester.down ?? 0
        default: return 0
        }
    }

    private var gaugeTint: Color { tester.phase == .upload ? .driftUp : .driftDown }

    private var caption: String {
        switch tester.phase {
        case .idle: return "Ready when you are"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download…"
        case .upload: return "Testing upload…"
        case .done: return "Download · test complete"
        case .failed(let message): return message
        }
    }

    private var buttonTitle: String {
        switch tester.phase {
        case .idle, .failed: return "Start Speed Test"
        case .done: return "Run Again"
        default: return "Cancel"
        }
    }
}

/// 270° gauge on a log scale (0 → 1 Gbps) so both slow and fast lines read well.
struct ArcGauge: View {
    let mbps: Double
    let caption: String
    let tint: Color

    private let maxMbps = 1000.0
    private var fraction: Double { min(log10(1 + max(mbps, 0)) / log10(1 + maxMbps), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.45), tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: tint.opacity(0.45), radius: 6)

            ForEach([0.0, 10, 100, 1000], id: \.self) { mark in
                let f = log10(1 + mark) / log10(1 + maxMbps)
                let angle = Angle.degrees(135 + 270 * f).radians
                Text(mark >= 1000 ? "1G" : String(Int(mark)))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .offset(x: CGFloat(cos(angle)) * 56, y: CGFloat(sin(angle)) * 56)
            }

            VStack(spacing: 0) {
                Text(RateFormat.mbps(mbps))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Mbps").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                    .padding(.top, 4)
            }
        }
        .frame(width: 160, height: 160)
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

struct MetricPill: View {
    let label: String
    let value: String?
    let unit: String
    let active: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color == .secondary ? Color.primary : color))
            Text(unit).font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(active ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(active ? (color == .secondary ? Color.primary.opacity(0.3) : color) : .clear, lineWidth: 1)
        )
    }
}

// MARK: - Keep Awake

struct AwakeSection: View {
    @ObservedObject var awake: AwakeController
    @AppStorage(AwakeController.allowDisplaySleepKey) private var allowDisplaySleep = false
    @AppStorage(AwakeController.stopOnLowBatteryKey) private var stopOnLowBattery = true
    @AppStorage(AwakeController.showIndicatorKey) private var showIndicator = true
    @ObservedObject var ui: UIState

    private struct Preset: Identifiable {
        let label: String
        let minutes: Int?
        var id: String { label }
    }

    private let presets: [Preset] = [
        Preset(label: "∞", minutes: nil), Preset(label: "15m", minutes: 15), Preset(label: "30m", minutes: 30),
        Preset(label: "1h", minutes: 60), Preset(label: "2h", minutes: 120), Preset(label: "4h", minutes: 240),
        Preset(label: "8h", minutes: 480)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard

            Text("START A SESSION")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                ForEach(presets) { preset in
                    AwakeChip(title: preset.label, selected: isHighlighted(preset.label)) {
                        ui.awakeSelected = preset.label
                        if let minutes = preset.minutes { awake.start(minutes: minutes) }
                        else { awake.start(.indefinite) }
                    }
                }
            }

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 10.5, weight: .semibold))
                    Text("Until").font(.system(size: 11.5, weight: .semibold))
                    DatePicker("", selection: $ui.untilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 78)
                    Button("Go") { startUntil() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(isHighlighted("until") ? Color.driftAwake.opacity(0.25) : Color.primary.opacity(0.07)))

                AwakeChip(title: "Downloads", icon: "arrow.down.circle",
                          selected: awake.mode == .untilDownloadsFinish) {
                    ui.awakeSelected = "downloads"
                    awake.start(.untilDownloadsFinish)
                }
                .help("Stay awake while data is flowing. Sleep again after 2 minutes of quiet.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Let the display sleep, keep the Mac running", isOn: $allowDisplaySleep)
                Toggle("Stop at \(AwakeController.lowBatteryThreshold)% battery", isOn: $stopOnLowBattery)
                Toggle("Show the timer in the menu bar", isOn: $showIndicator)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        }
        .onChange(of: allowDisplaySleep) { _ in awake.refreshAssertionType() }
        .onChange(of: awake.isActive) { active in if !active { ui.awakeSelected = nil } }
    }

    private var statusCard: some View {
        let active = awake.isActive
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(active ? Color.driftAwake.opacity(0.18) : Color.primary.opacity(0.06))
                Image(systemName: active ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(active ? Color.driftAwake : Color.secondary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text(active ? "KEEPING AWAKE" : "SLEEPING NORMALLY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(awake.statusTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(awake.statusDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(active ? "Stop" : "Keep Awake") {
                if active { awake.stop() } else { ui.awakeSelected = "∞"; awake.start(.indefinite) }
            }
            .buttonStyle(.borderedProminent)
            .tint(active ? .gray : .driftAwake)
            .foregroundStyle(active ? Color.white : Color.black)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(active ? Color.driftAwake.opacity(0.5) : .clear, lineWidth: 1))
    }

    private func isHighlighted(_ label: String) -> Bool {
        awake.isActive && ui.awakeSelected == label
    }

    private func startUntil() {
        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute], from: ui.untilTime)
        guard var target = cal.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: Date())
        else { return }
        if target <= Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target } // tomorrow
        ui.awakeSelected = "until"
        awake.start(.timed(target))
    }
}

struct AwakeChip: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(Capsule().fill(selected ? Color.driftAwake : Color.primary.opacity(0.07)))
            .foregroundStyle(selected ? Color.black : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History

struct HistorySection: View {
    @ObservedObject var tester: SpeedTester

    var body: some View {
        if tester.history.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("No tests yet").font(.system(size: 12, weight: .medium))
                Text("Run a speed test and your results will be saved here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(tester.history) { result in HistoryRow(result: result) }
                    }
                }
                HStack {
                    Text("\(tester.history.count) saved")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { tester.clearHistory() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .medium))
                }
            }
        }
    }
}

struct HistoryRow: View {
    let result: SpeedTester.TestResult

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11, weight: .medium))
                Text(result.network).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer()
            value("▼", RateFormat.mbps(result.downMbps), .driftDown)
            value("▲", RateFormat.mbps(result.upMbps), .driftUp)
            Text("\(Int(result.pingMs.rounded())) ms")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func value(_ arrow: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(arrow).font(.system(size: 7, weight: .black)).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: 58, alignment: .trailing)
    }
}

// MARK: - Logo

/// Original mark: two offset currents inside a rounded tile.
struct LogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.07, green: 0.16, blue: 0.24),
                                              Color(red: 0.04, green: 0.09, blue: 0.14)],
                                     startPoint: .top, endPoint: .bottom))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Path { p in
                    p.move(to: CGPoint(x: w * 0.18, y: h * 0.40))
                    p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.40),
                               control1: CGPoint(x: w * 0.40, y: h * 0.18),
                               control2: CGPoint(x: w * 0.60, y: h * 0.62))
                }
                .stroke(Color.driftUp, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: w * 0.18, y: h * 0.62))
                    p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.62),
                               control1: CGPoint(x: w * 0.40, y: h * 0.40),
                               control2: CGPoint(x: w * 0.60, y: h * 0.84))
                }
                .stroke(Color.driftDown, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}

// MARK: - Update banner

struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .available(let release):
            banner {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.driftDown)
                Text("Driftline \(release.version) is available")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button("Update") { updater.installAvailable() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.driftDown)
            }
        case .downloading(let progress):
            banner {
                Text("Downloading update…").font(.system(size: 11))
                ProgressView(value: progress).progressViewStyle(.linear).tint(.driftDown)
            }
        case .installing:
            banner {
                ProgressView().controlSize(.small)
                Text("Installing. Driftline will reopen in a moment.").font(.system(size: 11))
            }
        default:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.driftDown.opacity(0.12)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}
