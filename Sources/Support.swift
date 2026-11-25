import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Preferences

enum MenuStyle: String, CaseIterable, Identifiable {
    case stacked, inline, downOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .stacked: return "Stacked (↑ over ↓)"
        case .inline: return "Inline (↓ … ↑ …)"
        case .downOnly: return "Download only"
        }
    }
}

enum Prefs {
    static let useBitsKey = "useBits"
    static let menuStyleKey = "menuStyle"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [useBitsKey: true, menuStyleKey: MenuStyle.stacked.rawValue])
    }

    static var useBits: Bool { UserDefaults.standard.bool(forKey: useBitsKey) }
    static var menuStyle: MenuStyle {
        MenuStyle(rawValue: UserDefaults.standard.string(forKey: menuStyleKey) ?? "") ?? .stacked
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Driftline: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Formatting

enum RateFormat {
    /// Splits a bytes/sec rate into a display value and unit (decimal units, like macOS).
    static func parts(_ bytesPerSecond: Double, bits: Bool) -> (value: String, unit: String) {
        var v = max(bytesPerSecond, 0) * (bits ? 8 : 1) / 1000
        let units = bits ? ["Kb/s", "Mb/s", "Gb/s"] : ["KB/s", "MB/s", "GB/s"]
        var i = 0
        while v >= 999.5 && i < units.count - 1 { v /= 1000; i += 1 }
        let value = v < 99.95 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return (value, units[i])
    }

    static func short(_ bytesPerSecond: Double, bits: Bool) -> String {
        let p = parts(bytesPerSecond, bits: bits)
        return "\(p.value) \(p.unit)"
    }

    static func mbps(_ value: Double) -> String {
        if value <= 0 { return "0" }
        if value < 10 { return String(format: "%.2f", value) }
        if value < 100 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    static func total(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

// MARK: - Palette

extension Color {
    static let driftDown = Color(red: 0.20, green: 0.82, blue: 0.80)  // lagoon
    static let driftUp = Color(red: 1.00, green: 0.47, blue: 0.36)    // ember
    static let driftAwake = Color(red: 1.00, green: 0.78, blue: 0.30) // sunrise
}

// MARK: - Menu bar rendering

enum StatusRenderer {
    /// Two-line readout drawn as a template image so it adapts to light/dark menu bars.
    static func stacked(down: String, up: String, downActive: Bool, upActive: Bool, awakeBadge: String? = nil) -> NSImage {
        let badgeWidth: CGFloat = awakeBadge == nil ? 0 : 24
        let width: CGFloat = 70 + badgeWidth
        let height: CGFloat = 22
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let arrowFont = NSFont.systemFont(ofSize: 6.5, weight: .black)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func row(_ arrow: String, _ text: String, y: CGFloat, active: Bool) {
                let alpha: CGFloat = active ? 1.0 : 0.5
                let color = NSColor.black.withAlphaComponent(alpha)
                let arrowStr = NSAttributedString(string: arrow, attributes: [.font: arrowFont, .foregroundColor: color])
                arrowStr.draw(at: NSPoint(x: badgeWidth + 1, y: y + 1.5))
                let valueStr = NSAttributedString(string: text, attributes: [.font: valueFont, .foregroundColor: color])
                let size = valueStr.size()
                valueStr.draw(at: NSPoint(x: width - size.width - 1, y: y))
            }
            if let badge = awakeBadge {
                // Keep-awake indicator: sun on top, remaining time below.
                let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let s = sun.size
                    sun.draw(in: NSRect(x: (badgeWidth - 4 - s.width) / 2, y: 11.5, width: s.width, height: s.height))
                }
                let badgeStr = NSAttributedString(string: badge, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold),
                    .foregroundColor: NSColor.black])
                let bs = badgeStr.size()
                badgeStr.draw(at: NSPoint(x: (badgeWidth - 4 - bs.width) / 2, y: 0.5))
            }
            row("▲", up, y: 10.5, active: upActive)
            row("▼", down, y: 0.5, active: downActive)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Popover size

/// The popover is one fixed size for every tab, so it never grows or shrinks while you click around.
enum PopoverMetrics {
    static let width: CGFloat = 390
    static let height: CGFloat = 560
}

// MARK: - Popover UI state

/// Holds the popover's view state. Used instead of SwiftUI's @State, which on newer
/// SDKs is a macro that needs Xcode's plugins (not included in the command line tools).
@MainActor
final class UIState: ObservableObject {
    @Published var tab: PopoverView.Tab = .live
    @Published var loginEnabled = LoginItem.isEnabled
    // Awake tab
    @Published var untilTime = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @Published var awakeSelected: String?
    // Friends tab
    @Published var joinCode = ""
    @Published var relayDraft = ""
    @Published var editingRelay = false
    @Published var copied = false
    @Published var messageDraft = ""
    @Published var messageTarget: String?
    /// Set by the app: closes the panel (used by the ✕ button).
    var closePanel: (() -> Void)?
}

// MARK: - Flat controls

/// Driftline's own button look. Newer macOS versions make standard buttons briefly swell
/// when clicked; this style stays perfectly still and just dims slightly while pressed.
struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .driftDown
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 11.5, weight: .semibold))
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 8 : 4)
            .frame(minHeight: large ? 32 : 22)
            .background(
                RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                    .fill(prominent ? tint : Color.primary.opacity(0.09))
            )
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
