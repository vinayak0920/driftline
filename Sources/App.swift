import AppKit
import SwiftUI
import Combine

@main
enum DriftlineMain {
    @MainActor
    static func main() {
        Prefs.registerDefaults()
        AwakeController.registerDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = NetworkMonitor()
    private let tester = SpeedTester()
    private let awake = AwakeController()
    private let friends = FriendsController()
    private let ui = UIState()
    private let mixer = AppVolumeMixer()
    private let updater = Updater()
    private var buddyPanel: BuddyPanelController!
    private var friendsObserver: AnyCancellable?
    private var flash: (emoji: String, until: Date)?
    private var awakeObserver: AnyCancellable?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        let hosting = NSHostingController(rootView: PopoverView(monitor: monitor, tester: tester, awake: awake, friends: friends, mixer: mixer, updater: updater, ui: ui))
        // Fixed size: the popover never resizes when you switch tabs or a banner appears.
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: PopoverMetrics.width, height: PopoverMetrics.height)
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)
        popover.behavior = .transient
        popover.animates = false  // no zoom-in "pop": the panel appears at its final size

        monitor.onTick = { [weak self] in
            guard let self else { return }
            self.awake.observeTraffic(bytesPerSecond: self.monitor.down)
            self.updateStatusItem()
        }
        buddyPanel = BuddyPanelController(friends: friends)
        friendsObserver = friends.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.buddyPanel.refresh() }
        }
        friends.onGesture = { [weak self] peer, gesture in
            guard let self else { return }
            self.flash = (gesture.emoji, Date().addingTimeInterval(4))
            self.updateStatusItem()
            if UserDefaults.standard.bool(forKey: FriendsController.soundKey) {
                NSSound(named: NSSound.Name("Pop"))?.play()
            }
        }
        friends.onMessage = { [weak self] peer, _ in
            guard let self else { return }
            self.flash = ("💬", Date().addingTimeInterval(5))
            self.updateStatusItem()
            if UserDefaults.standard.bool(forKey: FriendsController.soundKey) {
                NSSound(named: NSSound.Name("Tink"))?.play()
            }
        }
        friends.onRequestReply = { [weak self] peer in
            guard let self else { return }
            self.ui.tab = .friends
            self.ui.messageTarget = peer.id
            self.showPopover()
        }
        friends.start()
        mixer.start()
        updater.start()
        buddyPanel.refresh()

        awakeObserver = awake.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        monitor.start()
        updateStatusItem()

        // Redraw immediately when the user changes units or style.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.buddyPanel.refresh()
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard statusItem.button != nil else { return }
        // Right-click the menu bar item = quick Keep Awake on/off.
        if NSApp.currentEvent?.type == .rightMouseUp {
            awake.toggleIndefinite()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let bits = Prefs.useBits
        let down = RateFormat.short(monitor.down, bits: bits)
        let up = RateFormat.short(monitor.up, bits: bits)
        let idleThreshold = 1_000.0 // < 1 KB/s reads as idle
        let showBadge = UserDefaults.standard.bool(forKey: AwakeController.showIndicatorKey)
        let badge = showBadge ? awake.menuBarBadge : nil

        switch Prefs.menuStyle {
        case .stacked:
            button.attributedTitle = NSAttributedString(string: "")
            button.image = StatusRenderer.stacked(
                down: down, up: up,
                downActive: monitor.down >= idleThreshold,
                upActive: monitor.up >= idleThreshold,
                awakeBadge: badge)
            button.imagePosition = .imageOnly
            statusItem.length = badge == nil ? 76 : 100

        case .inline, .downOnly:
            button.image = nil
            button.imagePosition = .noImage
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            var text: String
            var length: CGFloat
            if Prefs.menuStyle == .inline {
                text = "↓ \(pad(down))  ↑ \(pad(up))"
                length = 172
            } else {
                text = "↓ \(pad(down))"
                length = 90
            }
            if let badge {
                text = "☀︎ \(badge)  " + text
                length += 52
            }
            statusItem.length = length
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        }

        // A friend's gesture briefly shows its emoji in the menu bar.
        if let f = flash, f.until > Date() {
            if button.image != nil {
                button.title = f.emoji
                button.imagePosition = .imageTrailing
            } else {
                button.attributedTitle = NSAttributedString(
                    string: "\(f.emoji) " + button.attributedTitle.string,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
            }
            statusItem.length += 24
        } else {
            flash = nil
        }

        button.toolTip = "Driftline — ↓ \(down)  ↑ \(up)\nRight-click to toggle Keep Awake"
    }

    /// Fixed-width text so the menu bar doesn't jiggle as numbers change.
    private func pad(_ s: String) -> String {
        s.count >= 9 ? s : String(repeating: " ", count: 9 - s.count) + s
    }
}
