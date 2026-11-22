import SwiftUI
import AppKit

struct FriendsSection: View {
    @ObservedObject var friends: FriendsController
    @AppStorage(FriendsController.showBuddiesKey) private var showBuddies = true
    @AppStorage(FriendsController.soundKey) private var playSound = true
    @ObservedObject var ui: UIState

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                if !friends.isSetUp || ui.editingRelay {
                    relaySetup
                } else {
                    profileCard
                    roomCard
                    if friends.roomCode != nil {
                        gestures
                        friendList
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Show friends on my desktop", isOn: $showBuddies)
                        Toggle("Play a sound when a gesture arrives", isOn: $playSound)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    Button("Change relay server…") {
                        ui.relayDraft = friends.relayURL
                        ui.editingRelay = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
        }
    }

    // MARK: Relay setup

    private var relaySetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 20)).foregroundStyle(Color.driftDown)
                Text("Connect your relay").font(.system(size: 14, weight: .bold, design: .rounded))
            }
            Text("Friends links Macs through your own free Cloudflare Worker. Deploy the **relay** folder (see the README), then paste the URL it gives you. Your friend uses the same URL.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://driftline-relay.yourname.workers.dev", text: $ui.relayDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            HStack {
                if ui.editingRelay {
                    Button("Cancel") { ui.editingRelay = false }
                }
                Spacer()
                Button("Save") {
                    friends.relayURL = ui.relayDraft
                    ui.editingRelay = false
                    friends.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(.driftDown)
                .disabled(ui.relayDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .onAppear { if ui.relayDraft.isEmpty { ui.relayDraft = friends.relayURL } }
    }

    // MARK: You

    private var profileCard: some View {
        HStack(alignment: .top, spacing: 10) {
            BuddyView(kind: friends.myKind, colorIndex: friends.myColor,
                      gesture: friends.myGesture, gestureAt: friends.myGestureAt)
                .frame(width: 62, height: 62)
                .onTapGesture { friends.send(.wave) }
                .help("This is you. Click to wave.")

            VStack(alignment: .leading, spacing: 6) {
                TextField("Your name", text: $friends.myName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                HStack(spacing: 4) {
                    ForEach(BuddyKind.allCases) { kind in
                        Button(kind.displayName) { friends.myKind = kind }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(friends.myKind == kind
                                                       ? BuddyPalette.color(friends.myColor).opacity(0.85)
                                                       : Color.primary.opacity(0.07)))
                            .foregroundStyle(friends.myKind == kind ? Color.black : Color.primary)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(BuddyPalette.colors.indices, id: \.self) { i in
                        Circle()
                            .fill(BuddyPalette.colors[i])
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(friends.myColor == i ? 0.8 : 0), lineWidth: 2))
                            .onTapGesture { friends.myColor = i }
                    }
                }
            }
        }
    }

    // MARK: Room

    private var roomCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = friends.roomCode {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatted(code))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        ui.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
                    } label: {
                        Image(systemName: ui.copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy room code")
                    Button("Leave") { friends.leave() }
                        .controlSize(.small)
                }
            } else {
                Text("ROOM")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Create a room") { friends.createRoom() }
                        .buttonStyle(.borderedProminent)
                        .tint(.driftDown)
                    Text("or").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("CODE", text: $ui.joinCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                        .onSubmit { if friends.join(ui.joinCode) { ui.joinCode = "" } }
                    Button("Join") { if friends.join(ui.joinCode) { ui.joinCode = "" } }
                        .disabled(ui.joinCode.count < 6)
                }
                if let error = friends.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var statusText: String {
        switch friends.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let s): return s
        case .idle: return "Offline"
        case .notSetUp: return "No relay"
        }
    }

    private var statusColor: Color {
        switch friends.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        default: return .red
        }
    }

    private func formatted(_ code: String) -> String {
        "\(code.prefix(3))-\(code.suffix(3))"
    }

    // MARK: Gestures

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEND A GESTURE")
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                ForEach(BuddyGesture.allCases) { g in
                    Button { friends.send(g) } label: {
                        VStack(spacing: 1) {
                            Text(g.emoji).font(.system(size: 17))
                            Text(g.label).font(.system(size: 8.5, weight: .medium)).lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(friends.status != .connected)
                }
            }
        }
    }

    // MARK: Friends

    private var friendList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if friends.peers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a friend. Send them the code **\(formatted(friends.roomCode ?? ""))**.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(friends.peers) { peer in
                    HStack(spacing: 8) {
                        BuddyView(kind: peer.kind, colorIndex: peer.color, gesture: peer.gesture,
                                  gestureAt: peer.gestureAt, online: peer.online)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(peer.name).font(.system(size: 11.5, weight: .semibold))
                            Text(peer.online ? "Online" : "Away")
                                .font(.system(size: 9.5))
                                .foregroundStyle(peer.online ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(BuddyGesture.allCases) { g in
                                Button("\(g.emoji)  \(g.label)") { friends.send(g, to: peer.id) }
                            }
                        } label: {
                            Text("👋")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Send just to \(peer.name)")
                    }
                }
            }
        }
    }
}
