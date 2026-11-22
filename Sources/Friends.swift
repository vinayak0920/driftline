import Foundation
import AppKit

// MARK: - Model

enum BuddyKind: String, CaseIterable, Identifiable {
    case mochi, pebble, ghosty, bean
    var id: String { rawValue }
    var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

enum BuddyGesture: String, CaseIterable, Identifiable {
    case wave, heart, thumbs, laugh, highfive, dance, sleepy, coffee, poke
    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .wave: return "👋"
        case .heart: return "❤️"
        case .thumbs: return "👍"
        case .laugh: return "😂"
        case .highfive: return "✋"
        case .dance: return "🕺"
        case .sleepy: return "😴"
        case .coffee: return "☕️"
        case .poke: return "👀"
        }
    }

    var label: String {
        switch self {
        case .wave: return "Hi!"
        case .heart: return "Love it"
        case .thumbs: return "Nice"
        case .laugh: return "Haha"
        case .highfive: return "High five"
        case .dance: return "Party"
        case .sleepy: return "Sleepy"
        case .coffee: return "Break?"
        case .poke: return "You there?"
        }
    }
}

struct Peer: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: BuddyKind
    var color: Int
    var online: Bool
    var gesture: BuddyGesture?
    var gestureAt: Date = .distantPast
}

// MARK: - Controller

/// Talks to the Driftline relay (a Cloudflare Worker) over one WebSocket.
@MainActor
final class FriendsController: ObservableObject {
    enum Status: Equatable {
        case notSetUp, idle, connecting, connected
        case reconnecting(String)
    }

    static let relayKey = "friendsRelayURL"
    static let roomKey = "friendsRoom"
    static let nameKey = "friendsName"
    static let kindKey = "friendsKind"
    static let colorKey = "friendsColor"
    static let idKey = "friendsDeviceID"
    static let showBuddiesKey = "friendsShowBuddies"
    static let soundKey = "friendsSound"

    @Published private(set) var status: Status = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var roomCode: String?
    @Published private(set) var myGesture: BuddyGesture?
    @Published private(set) var myGestureAt: Date = .distantPast
    @Published var lastError: String?

    @Published var myName: String {
        didSet { UserDefaults.standard.set(myName, forKey: Self.nameKey); scheduleProfileUpdate() }
    }
    @Published var myKind: BuddyKind {
        didSet { UserDefaults.standard.set(myKind.rawValue, forKey: Self.kindKey); scheduleProfileUpdate() }
    }
    @Published var myColor: Int {
        didSet { UserDefaults.standard.set(myColor, forKey: Self.colorKey); scheduleProfileUpdate() }
    }
    @Published var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: Self.relayKey); refreshStatus() }
    }

    /// Called whenever a friend sends a gesture.
    var onGesture: ((Peer, BuddyGesture) -> Void)?

    let myId: String
    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pingTimer: Timer?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Self.showBuddiesKey: true, Self.soundKey: true])

        if let existing = d.string(forKey: Self.idKey) {
            myId = existing
        } else {
            myId = UUID().uuidString
            d.set(myId, forKey: Self.idKey)
        }
        myName = d.string(forKey: Self.nameKey) ?? NSFullUserName().components(separatedBy: " ").first ?? "Me"
        myKind = BuddyKind(rawValue: d.string(forKey: Self.kindKey) ?? "") ?? .mochi
        myColor = d.object(forKey: Self.colorKey) as? Int ?? Int.random(in: 0..<BuddyPalette.colors.count)
        // A relay URL baked in at build time (RELAY_URL=… ./build.sh) is used until the user sets one.
        relayURL = d.string(forKey: Self.relayKey)
            ?? (Bundle.main.object(forInfoDictionaryKey: "DriftlineRelayURL") as? String ?? "")
        roomCode = d.string(forKey: Self.roomKey)

        refreshStatus()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectNow() }
        }
    }

    var isSetUp: Bool { websocketBase != nil }

    // MARK: Rooms

    func start() {
        if roomCode != nil { connect() }
    }

    func createRoom() {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O/1/I mix-ups
        let code = String((0..<6).map { _ in alphabet.randomElement()! })
        enter(code)
    }

    /// Returns false if the code isn't valid.
    @discardableResult
    func join(_ raw: String) -> Bool {
        let code = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 6, code.allSatisfy({ $0.isASCII }) else {
            lastError = "Room codes have 6 letters or numbers."
            return false
        }
        enter(code)
        return true
    }

    func leave() {
        roomCode = nil
        UserDefaults.standard.removeObject(forKey: Self.roomKey)
        disconnect()
        peers = []
        refreshStatus()
    }

    private func enter(_ code: String) {
        lastError = nil
        roomCode = code
        UserDefaults.standard.set(code, forKey: Self.roomKey)
        peers = []
        connect()
    }

    // MARK: Sending

    func send(_ gesture: BuddyGesture, to peerId: String? = nil) {
        myGesture = gesture
        myGestureAt = Date()
        var payload: [String: Any] = ["type": "gesture", "gesture": gesture.rawValue]
        if let peerId { payload["to"] = peerId }
        sendJSON(payload)
    }

    private func scheduleProfileUpdate() {
        profileTask?.cancel()
        profileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.sendJSON(["type": "profile", "name": self.myName,
                           "character": self.myKind.rawValue, "color": self.myColor])
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let socket, status == .connected,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Connection

    private var websocketBase: URL? {
        var raw = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw), comps.host != nil else { return nil }
        comps.scheme = (comps.scheme == "http" || comps.scheme == "ws") ? "ws" : "wss"
        comps.path = ""
        comps.query = nil
        return comps.url
    }

    private func connect() {
        disconnect()
        guard let base = websocketBase, let code = roomCode else { refreshStatus(); return }

        var comps = URLComponents(url: base.appendingPathComponent("room/\(code)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "id", value: myId),
            URLQueryItem(name: "name", value: myName),
            URLQueryItem(name: "character", value: myKind.rawValue),
            URLQueryItem(name: "color", value: String(myColor)),
        ]
        guard let url = comps.url else { return }

        status = .connecting
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)

        // Protocol-level pings keep the connection alive and are free on Cloudflare.
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.socket?.sendPing { error in
                    if error != nil { Task { @MainActor in self?.connectionLost(task) } }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func reconnectNow() {
        guard roomCode != nil else { return }
        reconnectAttempt = 0
        connect()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                case .failure:
                    self.connectionLost(task)
                }
            }
        }
    }

    private func connectionLost(_ task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        socket = nil
        pingTimer?.invalidate()
        pingTimer = nil
        for i in peers.indices { peers[i].online = false }
        guard roomCode != nil else { refreshStatus(); return }

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30)
        status = .reconnecting("Reconnecting in \(Int(delay))s…")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func refreshStatus() {
        if !isSetUp { status = .notSetUp }
        else if socket == nil { status = .idle }
    }

    // MARK: Incoming

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        switch type {
        case "roster":
            status = .connected
            reconnectAttempt = 0
            let list = (msg["peers"] as? [[String: Any]] ?? []).compactMap(Self.peer(from:))
            // Keep friends we've seen this session (shown asleep) and mark who's online.
            var merged = peers.map { p -> Peer in var p = p; p.online = false; return p }
            for p in list { upsert(p, into: &merged) }
            peers = merged

        case "join":
            if let dict = msg["peer"] as? [String: Any], let p = Self.peer(from: dict) {
                var list = peers
                upsert(p, into: &list)
                peers = list
            }

        case "leave":
            if let id = msg["id"] as? String, let i = peers.firstIndex(where: { $0.id == id }) {
                peers[i].online = false
            }

        case "gesture":
            guard let from = msg["from"] as? String,
                  let g = BuddyGesture(rawValue: msg["gesture"] as? String ?? ""),
                  let i = peers.firstIndex(where: { $0.id == from }) else { return }
            if let to = msg["to"] as? String, to != myId { return } // aimed at someone else
            peers[i].gesture = g
            peers[i].gestureAt = Date()
            peers[i].online = true
            onGesture?(peers[i], g)

        default:
            break
        }
    }

    private func upsert(_ p: Peer, into list: inout [Peer]) {
        if let i = list.firstIndex(where: { $0.id == p.id }) {
            list[i].name = p.name
            list[i].kind = p.kind
            list[i].color = p.color
            list[i].online = true
        } else {
            list.append(p)
        }
    }

    private static func peer(from dict: [String: Any]) -> Peer? {
        guard let id = dict["id"] as? String else { return nil }
        return Peer(id: id,
                    name: dict["name"] as? String ?? "Friend",
                    kind: BuddyKind(rawValue: dict["character"] as? String ?? "") ?? .mochi,
                    color: dict["color"] as? Int ?? 0,
                    online: true)
    }
}
