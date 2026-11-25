import SwiftUI
import AppKit

enum BuddyPalette {
    static let colors: [Color] = [
        Color(red: 0.47, green: 0.80, blue: 0.98), // sky
        Color(red: 0.99, green: 0.62, blue: 0.71), // blush
        Color(red: 0.60, green: 0.88, blue: 0.55), // mint
        Color(red: 1.00, green: 0.80, blue: 0.40), // honey
        Color(red: 0.75, green: 0.63, blue: 0.98), // lilac
        Color(red: 1.00, green: 0.58, blue: 0.42), // apricot
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

/// How long a gesture animation plays.
let gestureDuration: TimeInterval = 3.6

// MARK: - Character

/// An original, fully code-drawn character that animates each gesture.
struct BuddyView: View {
    let kind: BuddyKind
    let colorIndex: Int
    var gesture: BuddyGesture?
    var gestureAt: Date = .distantPast
    var online: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, now: timeline.date)
            }
        }
        .opacity(online ? 1 : 0.55)
        .saturation(online ? 1 : 0.35)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let s = min(size.width, size.height)
        let t = now.timeIntervalSinceReferenceDate
        let since = now.timeIntervalSince(gestureAt)
        let active: BuddyGesture? = (since >= 0 && since < gestureDuration) ? gesture : nil
        let g = since // seconds into the gesture
        let fade = active == nil ? 0 : min(1, g * 4) * min(1, (gestureDuration - g) * 3) // ease in/out

        let base = BuddyPalette.color(colorIndex)
        let ink = Color(red: 0.13, green: 0.12, blue: 0.16)

        // Body motion
        var bob = sin(t * 2.2) * s * 0.012            // breathing
        var tilt = 0.0
        var squash = 1.0 + sin(t * 2.2) * 0.015
        switch active {
        case .laugh?:
            bob += -abs(sin(g * 14)) * s * 0.05 * fade
            tilt = sin(g * 28) * 0.05 * fade
        case .dance?:
            tilt = sin(g * 8) * 0.22 * fade
            bob += -abs(sin(g * 8)) * s * 0.06 * fade
        case .highfive?:
            bob += -max(0, sin(g * 5)) * s * 0.09 * fade
        case .heart?:
            squash += sin(g * 9) * 0.035 * fade
        case .sleepy?:
            tilt = 0.12 * fade
            bob += s * 0.015 * fade
        case .poke?:
            tilt = sin(g * 3) * 0.08 * fade
        default:
            break
        }
        if !online { tilt = 0.1; bob = s * 0.01 }

        let cx = size.width / 2
        let groundY = size.height * 0.94
        let bodyW = s * (kind == .bean ? 0.48 : 0.70)
        let bodyH = s * (kind == .bean ? 0.70 : 0.60) * squash
        let bodyRect = CGRect(x: cx - bodyW / 2, y: groundY - bodyH + bob - s * 0.02, width: bodyW, height: bodyH)

        // Ground shadow
        let shadowW = bodyW * (1.0 - min(0, bob) / s * 2)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - shadowW / 2, y: groundY - s * 0.035, width: shadowW, height: s * 0.06)),
                 with: .color(.black.opacity(0.18)))

        var layer = ctx
        layer.translateBy(x: cx, y: bodyRect.maxY)
        layer.rotate(by: .radians(tilt))
        layer.translateBy(x: -cx, y: -bodyRect.maxY)

        // Arms (drawn first so they tuck behind the body)
        let (leftAngle, rightAngle) = armAngles(active, g: g, fade: fade, t: t)
        let armL = s * 0.2, armW = s * 0.085
        let shoulderY = bodyRect.minY + bodyRect.height * 0.55
        drawArm(&layer, at: CGPoint(x: bodyRect.minX + bodyW * 0.1, y: shoulderY), angle: leftAngle,
                length: armL, width: armW, color: base.darker(0.08), ink: ink)
        drawArm(&layer, at: CGPoint(x: bodyRect.maxX - bodyW * 0.1, y: shoulderY), angle: rightAngle,
                length: armL, width: armW, color: base.darker(0.08), ink: ink)

        // Body
        let bodyPath = shape(for: kind, in: bodyRect, t: t)
        layer.fill(bodyPath, with: .linearGradient(Gradient(colors: [base.lighter(0.18), base]),
                                                  startPoint: CGPoint(x: cx, y: bodyRect.minY),
                                                  endPoint: CGPoint(x: cx, y: bodyRect.maxY)))
        layer.stroke(bodyPath, with: .color(ink.opacity(0.85)), lineWidth: max(1.2, s * 0.018))

        // Extras per character
        switch kind {
        case .pebble:
            let stem = CGPoint(x: cx, y: bodyRect.minY)
            var leaf = Path()
            leaf.move(to: stem)
            leaf.addQuadCurve(to: CGPoint(x: stem.x + s * 0.1, y: stem.y - s * 0.1), control: CGPoint(x: stem.x + s * 0.1, y: stem.y))
            leaf.addQuadCurve(to: stem, control: CGPoint(x: stem.x, y: stem.y - s * 0.1))
            var leaf2 = Path()
            leaf2.move(to: stem)
            leaf2.addQuadCurve(to: CGPoint(x: stem.x - s * 0.08, y: stem.y - s * 0.08), control: CGPoint(x: stem.x - s * 0.08, y: stem.y))
            leaf2.addQuadCurve(to: stem, control: CGPoint(x: stem.x, y: stem.y - s * 0.08))
            layer.fill(leaf, with: .color(Color(red: 0.36, green: 0.75, blue: 0.40)))
            layer.fill(leaf2, with: .color(Color(red: 0.45, green: 0.82, blue: 0.48)))
        case .bean:
            let top = CGPoint(x: cx, y: bodyRect.minY)
            let sway = sin(t * 3) * s * 0.03
            var antenna = Path()
            antenna.move(to: top)
            antenna.addQuadCurve(to: CGPoint(x: top.x + sway, y: top.y - s * 0.12), control: CGPoint(x: top.x - s * 0.03, y: top.y - s * 0.06))
            layer.stroke(antenna, with: .color(ink.opacity(0.85)), lineWidth: max(1.2, s * 0.018))
            let ball = s * 0.06
            layer.fill(Path(ellipseIn: CGRect(x: top.x + sway - ball / 2, y: top.y - s * 0.12 - ball / 2, width: ball, height: ball)),
                      with: .color(Color.driftAwake))
        default:
            break
        }

        // Face
        let faceY = bodyRect.minY + bodyRect.height * (kind == .bean ? 0.36 : 0.42)
        let eyeGap = bodyW * (kind == .bean ? 0.2 : 0.17)
        let eyeR = s * 0.038
        let happy = [BuddyGesture.heart, .laugh, .dance, .highfive, .thumbs].contains(active ?? .poke) && active != nil
        let closed = active == .sleepy || !online
        let blink = (t.truncatingRemainder(dividingBy: 4.3)) < 0.12

        for dir in [-1.0, 1.0] {
            let ex = cx + dir * eyeGap
            if closed {
                var p = Path()
                p.move(to: CGPoint(x: ex - eyeR, y: faceY))
                p.addQuadCurve(to: CGPoint(x: ex + eyeR, y: faceY), control: CGPoint(x: ex, y: faceY + eyeR * 0.9))
                layer.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.3, s * 0.02), lineCap: .round))
            } else if happy {
                var p = Path()
                p.move(to: CGPoint(x: ex - eyeR, y: faceY + eyeR * 0.3))
                p.addQuadCurve(to: CGPoint(x: ex + eyeR, y: faceY + eyeR * 0.3), control: CGPoint(x: ex, y: faceY - eyeR * 1.4))
                layer.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.3, s * 0.022), lineCap: .round))
            } else {
                let h = blink ? eyeR * 0.3 : eyeR * 2.1
                let look = active == .poke ? sin(g * 4) * eyeR * 0.6 : 0
                layer.fill(Path(ellipseIn: CGRect(x: ex - eyeR + look, y: faceY - h / 2, width: eyeR * 2, height: h)), with: .color(ink))
                if !blink {
                    layer.fill(Path(ellipseIn: CGRect(x: ex - eyeR * 0.2 + look, y: faceY - h / 2 + eyeR * 0.35,
                                                     width: eyeR * 0.75, height: eyeR * 0.75)), with: .color(.white))
                }
            }
            // Cheeks
            let cheek = s * 0.05
            layer.fill(Path(ellipseIn: CGRect(x: ex + dir * eyeR * 1.2 - cheek / 2, y: faceY + eyeR * 1.5, width: cheek, height: cheek * 0.6)),
                      with: .color(Color(red: 1, green: 0.45, blue: 0.5).opacity(0.45)))
        }

        // Mouth
        let my = faceY + eyeR * 2.3
        let mw = s * 0.07
        var mouth = Path()
        switch active {
        case .laugh?, .highfive?, .dance?:
            mouth.move(to: CGPoint(x: cx - mw, y: my - mw * 0.2))
            mouth.addQuadCurve(to: CGPoint(x: cx + mw, y: my - mw * 0.2), control: CGPoint(x: cx, y: my + mw * 1.6))
            mouth.closeSubpath()
            layer.fill(mouth, with: .color(Color(red: 0.55, green: 0.15, blue: 0.2)))
            layer.stroke(mouth, with: .color(ink), lineWidth: max(1, s * 0.015))
        case .poke?, .sleepy?:
            let r = s * 0.025
            layer.fill(Path(ellipseIn: CGRect(x: cx - r, y: my - r * 0.5, width: r * 2, height: r * 2.2)), with: .color(ink))
        default:
            mouth.move(to: CGPoint(x: cx - mw * 0.7, y: my))
            mouth.addQuadCurve(to: CGPoint(x: cx + mw * 0.7, y: my), control: CGPoint(x: cx, y: my + mw * 0.8))
            layer.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: max(1.3, s * 0.02), lineCap: .round))
        }

        // Props and particles (unrotated layer)
        if let active {
            switch active {
            case .heart:
                for i in 0..<3 {
                    let p = (g * 0.6 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                    let x = cx + CGFloat(sin(Double(i) * 2.1 + g * 2)) * s * 0.25
                    let y = bodyRect.minY - CGFloat(p) * s * 0.35
                    ctx.opacity = (1 - p) * fade
                    ctx.draw(Text("❤️").font(.system(size: s * 0.13)), at: CGPoint(x: x, y: y))
                }
                ctx.opacity = 1
            case .sleepy:
                drawZzz(&ctx, origin: CGPoint(x: bodyRect.maxX, y: bodyRect.minY), s: s, t: g, alpha: fade)
            case .coffee:
                let hand = armTip(CGPoint(x: bodyRect.maxX - bodyW * 0.1, y: shoulderY), angle: rightAngle, length: armL)
                ctx.draw(Text("☕️").font(.system(size: s * 0.16)), at: CGPoint(x: hand.x + s * 0.03, y: hand.y - s * 0.03))
            case .thumbs:
                let hand = armTip(CGPoint(x: bodyRect.maxX - bodyW * 0.1, y: shoulderY), angle: rightAngle, length: armL)
                ctx.opacity = fade
                ctx.draw(Text("👍").font(.system(size: s * 0.15)), at: CGPoint(x: hand.x + s * 0.02, y: hand.y - s * 0.05))
                ctx.opacity = 1
            default:
                break
            }
        } else if !online {
            drawZzz(&ctx, origin: CGPoint(x: bodyRect.maxX, y: bodyRect.minY), s: s, t: t, alpha: 0.8)
        }
    }

    // MARK: Parts

    private func shape(for kind: BuddyKind, in r: CGRect, t: Double) -> Path {
        switch kind {
        case .mochi:
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.18))
            p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control1: CGPoint(x: r.minX, y: r.minY + r.height * 0.25),
                       control2: CGPoint(x: r.minX + r.width * 0.2, y: r.minY))
            p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.18),
                       control1: CGPoint(x: r.maxX - r.width * 0.2, y: r.minY),
                       control2: CGPoint(x: r.maxX, y: r.minY + r.height * 0.25))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.18), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.12))
            p.closeSubpath()
            return p
        case .pebble:
            return Path(roundedRect: r, cornerSize: CGSize(width: r.width * 0.32, height: r.height * 0.38), style: .continuous)
        case .ghosty:
            var p = Path()
            let skirtTop = r.maxY - r.height * 0.15
            p.move(to: CGPoint(x: r.minX, y: skirtTop))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.width / 2))
            p.addArc(center: CGPoint(x: r.midX, y: r.minY + r.width / 2), radius: r.width / 2,
                     startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: skirtTop))
            let waves = 4
            let w = r.width / CGFloat(waves)
            let phase = sin(t * 4) * r.height * 0.04
            for i in 0..<waves {
                let x0 = r.maxX - CGFloat(i) * w
                p.addQuadCurve(to: CGPoint(x: x0 - w, y: skirtTop),
                               control: CGPoint(x: x0 - w / 2, y: r.maxY + (i % 2 == 0 ? phase : -phase)))
            }
            p.closeSubpath()
            return p
        case .bean:
            return Path(roundedRect: r, cornerRadius: r.width / 2, style: .continuous)
        }
    }

    /// Angles in radians; 0 = hanging down. Negative right / positive left raise outward.
    private func armAngles(_ g: BuddyGesture?, g t0: Double, fade: Double, t: Double) -> (Double, Double) {
        let idle = sin(t * 2.2) * 0.08
        var left = 0.35 + idle
        var right = -0.35 - idle
        guard let g else { return (left, right) }
        let deg = Double.pi / 180
        func blend(_ a: Double, _ b: Double) -> Double { a + (b - a) * fade }
        switch g {
        case .wave:
            right = blend(right, -140 * deg + sin(t0 * 12) * 28 * deg)
        case .highfive:
            right = blend(right, -165 * deg)
        case .thumbs, .coffee:
            right = blend(right, -115 * deg)
        case .heart:
            left = blend(left, 150 * deg); right = blend(right, -150 * deg)
        case .dance:
            left = blend(left, (120 + sin(t0 * 8) * 40) * deg)
            right = blend(right, -(120 - sin(t0 * 8) * 40) * deg)
        case .laugh:
            left = blend(left, (40 + sin(t0 * 20) * 15) * deg)
            right = blend(right, -(40 + sin(t0 * 20) * 15) * deg)
        case .sleepy:
            left = blend(left, 10 * deg); right = blend(right, -10 * deg)
        case .poke:
            right = blend(right, -95 * deg + sin(t0 * 10) * 10 * deg)
        }
        return (left, right)
    }

    private func armTip(_ shoulder: CGPoint, angle: Double, length: CGFloat) -> CGPoint {
        CGPoint(x: shoulder.x - CGFloat(sin(angle)) * length, y: shoulder.y + CGFloat(cos(angle)) * length)
    }

    private func drawArm(_ ctx: inout GraphicsContext, at shoulder: CGPoint, angle: Double,
                         length: CGFloat, width: CGFloat, color: Color, ink: Color) {
        let arm = Path(roundedRect: CGRect(x: -width / 2, y: 0, width: width, height: length), cornerRadius: width / 2)
            .applying(CGAffineTransform(rotationAngle: CGFloat(angle)))
            .applying(CGAffineTransform(translationX: shoulder.x, y: shoulder.y))
        ctx.fill(arm, with: .color(color))
        ctx.stroke(arm, with: .color(ink.opacity(0.85)), lineWidth: max(1, width * 0.18))
    }

    private func drawZzz(_ ctx: inout GraphicsContext, origin: CGPoint, s: CGFloat, t: Double, alpha: Double) {
        for i in 0..<3 {
            let p = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            ctx.opacity = (1 - p) * alpha
            ctx.draw(Text("z").font(.system(size: s * (0.08 + CGFloat(p) * 0.08), weight: .heavy, design: .rounded))
                        .foregroundColor(.secondary),
                     at: CGPoint(x: origin.x + CGFloat(p) * s * 0.12, y: origin.y - CGFloat(p) * s * 0.25))
        }
        ctx.opacity = 1
    }
}

extension Color {
    func lighter(_ amount: Double) -> Color { mix(with: .white, amount) }
    func darker(_ amount: Double) -> Color { mix(with: .black, amount) }

    private func mix(with other: NSColor, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = other.usingColorSpace(.sRGB) ?? .gray
        return Color(red: Double(a.redComponent + (b.redComponent - a.redComponent) * amount),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * amount),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * amount))
    }
}

// MARK: - Desktop stage

/// Friends sitting together on your desktop.
/// Drag to move, click to wave, double-click to reply, right-click for gestures.
struct BuddyStage: View {
    @ObservedObject var friends: FriendsController
    @AppStorage(FriendsController.opacityKey) private var characterOpacity = 1.0

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(friends.peers) { peer in
                BuddySeat(peer: peer, characterOpacity: characterOpacity)
                    .onTapGesture(count: 2) { friends.requestReply(to: peer) }
                    .onTapGesture { friends.send(.wave, to: peer.id) }
                    .contextMenu {
                        Button("💬  Reply to \(peer.name)…") { friends.requestReply(to: peer) }
                        Divider()
                        ForEach(BuddyGesture.allCases) { g in
                            Button("\(g.emoji)  \(g.label)") { friends.send(g, to: peer.id) }
                        }
                    }
                    .help("\(peer.name): click to wave, double-click to reply, right-click for more")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

struct BuddySeat: View {
    let peer: Peer
    var characterOpacity: Double = 1

    var body: some View {
        VStack(spacing: 4) {
            // Bubble area: the newest of a typed message or a gesture.
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                bubble(at: tl.date)
                    .frame(width: 150, height: 84, alignment: .bottom)
            }

            BuddyView(kind: peer.kind, colorIndex: peer.color, gesture: peer.gesture,
                      gestureAt: peer.gestureAt, online: peer.online)
                .frame(width: 92, height: 92)
                .opacity(characterOpacity)

            Text(peer.name)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(peer.online ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                        .offset(x: -8)
                }
        }
        .frame(width: 150)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func bubble(at now: Date) -> some View {
        let messageAge = now.timeIntervalSince(peer.messageAt)
        let gestureAge = now.timeIntervalSince(peer.gestureAt)
        let showMessage = peer.message != nil && messageAge >= 0
            && messageAge < messageDuration(peer.message ?? "")
        let showGesture = peer.gesture != nil && gestureAge >= 0 && gestureAge < gestureDuration + 0.6

        if showMessage, (!showGesture || peer.messageAt >= peer.gestureAt), let text = peer.message {
            GlassBubble(text: text, multiline: true)
                .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
                .id(peer.messageAt)
        } else if showGesture, let g = peer.gesture {
            GlassBubble(text: "\(g.emoji) \(g.label)")
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                .id(peer.gestureAt)
        }
    }
}

/// Apple-style frosted glass: translucent material, a bright top edge and a soft shadow.
enum GlassEdge {
    static let gradient = LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.08)],
                                         startPoint: .top, endPoint: .bottom)
}

struct GlassBubble: View {
    let text: String
    var multiline = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(multiline ? 4 : 1)
            .fixedSize(horizontal: !multiline, vertical: true)
            .frame(maxWidth: multiline ? 144 : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Kept for the popover preview of your own character.
struct SpeechBubble: View {
    let text: String
    var body: some View { GlassBubble(text: text, multiline: true) }
}

// MARK: - Floating panel

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A transparent, always-on-top window where friends' characters sit.
@MainActor
final class BuddyPanelController {
    private let panel: NSPanel
    private let friends: FriendsController
    private let seatWidth: CGFloat = 150
    private let height: CGFloat = 220

    init(friends: FriendsController) {
        self.friends = friends
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = DraggableHostingView(rootView: BuddyStage(friends: friends))

        if !panel.setFrameUsingName("DriftlineBuddies"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - 160, y: v.minY + 8))
        }
        panel.setFrameAutosaveName("DriftlineBuddies")
    }

    func refresh() {
        let show = UserDefaults.standard.bool(forKey: FriendsController.showBuddiesKey)
        let count = friends.peers.count
        guard show, friends.roomCode != nil, count > 0 else {
            panel.orderOut(nil)
            return
        }
        // Grow leftwards so the right edge stays put.
        let width = CGFloat(count) * seatWidth + 16
        var frame = panel.frame
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            frame.origin.x += frame.width - width
            frame.size = NSSize(width: width, height: height)
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
