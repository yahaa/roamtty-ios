import SwiftUI
import RoamttyCore

/// Android `drawGhost`, `ToolboxPet` and `ItermuxLogo`: the toolbox ghost drawn live so it can bob,
/// sway, ripple its hem, blink, wave the wrench, and hold a curved telephone handset during `/voice`.
/// Everything is drawn on Android's grids (26 units for the pet, 72 for the logo) so both apps stay in sync.
typealias GhostPose = GhostVoicePose

private enum GhostInk {
    static let body = Color(red: 0xF8 / 255, green: 0xF7 / 255, blue: 0xFF / 255)
    static let ink = Color(red: 0x3B / 255, green: 0x35 / 255, blue: 0x50 / 255)
    static let blush = Color(red: 0xFF / 255, green: 0x9E / 255, blue: 0xB5 / 255)
    static let metal = Color(red: 0xD9 / 255, green: 0xDE / 255, blue: 0xE8 / 255)
    static let keyboard = Color(red: 0xED / 255, green: 0xEB / 255, blue: 0xF5 / 255)
    static let badgeFill = Color(red: 0x2E / 255, green: 0x31 / 255, blue: 0x33 / 255)
    static let badgeStroke = Color(red: 0x3B / 255, green: 0x35 / 255, blue: 0x50 / 255)
    static let badgeInk = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xEA / 255)
}

extension GraphicsContext {
    fileprivate mutating func rotate(_ degrees: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y); rotate(by: .degrees(degrees)); translateBy(x: -pivot.x, y: -pivot.y)
    }
    fileprivate mutating func scale(x: Double, y: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y); scaleBy(x: x, y: y); translateBy(x: -pivot.x, y: -pivot.y)
    }

    /// Breathing voice aura & expanding pulse ring drawn behind the ghost during active calls.
    /// Stays green while network is stable and shifts to amber only when unstable/reconnecting.
    fileprivate func drawVoiceAura(voice: GhostVoiceState, networkUnstable: Bool, pose: GhostPose, lift: Double) {
        guard voice.showsAura else { return }
        let color: Color = GhostVoiceTone.forCall(state: voice, networkUnstable: networkUnstable) == .unstable ? Palette.warning : Palette.success
        let cy = 12.6 - lift * 0.6
        let baseR = 9.2 + pose.level * 2.4
        let center = CGPoint(x: 12, y: cy)
        let gradient = Gradient(colors: [color.opacity(0.22 + pose.level * 0.14), color.opacity(0)])
        fill(circle(center, baseR + 2.6), with: .radialGradient(gradient, center: center, startRadius: 4, endRadius: baseR + 2.6))
        if let p = pose.pulseProgress {
            let ringR = 8.4 + p * (4.4 + pose.level * 1.8)
            let alpha = (1 - p) * (voice == .connecting ? 0.5 : 0.45)
            stroke(circle(center, ringR), with: .color(color.opacity(alpha)), lineWidth: 0.85)
        }
    }

    /// The wrench behind the right paw, swinging around its grip.
    private func drawWrench(accent: Color, wave: Double, grip: CGPoint) {
        var wrench = self
        wrench.rotate(wave, around: grip)
        let handle = Path { $0.move(to: grip); $0.addLine(to: CGPoint(x: 22.4, y: 7.6)) }
        wrench.stroke(handle, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
        wrench.stroke(handle, with: .color(accent), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        let head = Path { $0.addArc(center: CGPoint(x: 23.2, y: 5.4), radius: 2.1, startAngle: .degrees(-22), endAngle: .degrees(248), clockwise: false) }
        wrench.stroke(head, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        wrench.stroke(head, with: .color(GhostInk.metal), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    /// The little keyboard the left paw holds in front of the body when idle.
    private func drawKeyboard(accent: Color, wave: Double, paw: CGPoint) {
        var board = self
        board.rotate(-10 + wave / 8, around: paw)
        let left = paw.x - 2.2, top = paw.y + 0.2
        board.fill(rounded(left, top, 7.2, 4.4, 0.9), with: .color(GhostInk.keyboard))
        board.stroke(rounded(left, top, 7.2, 4.4, 0.9), with: .color(GhostInk.ink), lineWidth: 1.1)
        for row in 0..<2 {
            for col in 0..<4 {
                board.fill(rounded(left + 0.8 + Double(col) * 1.45, top + 0.75 + Double(row) * 1.25, 0.95, 0.8, 0.25), with: .color(accent))
            }
        }
        board.fill(rounded(left + 1.9, top + 3.25, 3.2, 0.6, 0.3), with: .color(accent))
    }

    /// Classic retro curved telephone handset + coiled cord + optional sound-wave arcs (exact 26x26 coordinates).
    private func drawHandset(voice: GhostVoiceState, networkUnstable: Bool, pose: GhostPose) {
        let phoneColor: Color = GhostVoiceTone.forCall(state: voice, networkUnstable: networkUnstable) == .unstable ? Palette.warning : Palette.success
        let pawPivot = CGPoint(x: 3.3, y: 12.3)
        var handset = self
        handset.rotate(pose.ringJiggle, around: pawPivot)

        // Subtle coiled cord curling from mouthpiece down.
        let cord = Path { p in
            p.move(to: CGPoint(x: 5.6, y: 16.0))
            p.addCurve(to: CGPoint(x: 4.4, y: 19.6), control1: CGPoint(x: 4.2, y: 17.5), control2: CGPoint(x: 6.2, y: 18.4))
        }
        handset.stroke(cord, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))

        // Curved spine from earpiece (top-left) around cheek to mouthpiece (bottom-right).
        let spine = Path { p in
            p.move(to: CGPoint(x: 4.8, y: 8.2))
            p.addQuadCurve(to: CGPoint(x: 5.7, y: 15.6), control: CGPoint(x: 1.1, y: 12.1))
        }
        handset.stroke(spine, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        handset.stroke(spine, with: .color(phoneColor), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))

        // Earpiece and mouthpiece caps.
        for (cx, cy, angle) in [(5.1, 8.2, -32.0), (5.8, 15.5, 30.0)] {
            var cap = handset
            cap.translateBy(x: cx, y: cy)
            cap.rotate(by: .degrees(angle))
            let rect = rounded(-1.7, -1.25, 3.4, 2.5, 1.15)
            cap.fill(rect, with: .color(phoneColor))
            cap.stroke(rect, with: .color(GhostInk.ink), lineWidth: 1.1)
        }

        // Sound waves radiating near earpiece while speaking or connecting.
        if voice.showsSoundWaves {
            let waveColor = phoneColor
            let style = StrokeStyle(lineWidth: 1.05, lineCap: .round)
            let arc1 = Path { $0.addArc(center: CGPoint(x: 3.5, y: 7.4), radius: 2.6, startAngle: .degrees(165), endAngle: .degrees(240), clockwise: false) }
            let arc2 = Path { $0.addArc(center: CGPoint(x: 3.5, y: 7.4), radius: 4.3, startAngle: .degrees(168), endAngle: .degrees(238), clockwise: false) }
            handset.stroke(arc1, with: .color(waveColor.opacity(pose.waveAlpha1)), style: style)
            handset.stroke(arc2, with: .color(waveColor.opacity(pose.waveAlpha2)), style: style)
        }

        // Left paw gripping the middle of the handset.
        let pawStyle = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
        handset.fill(circle(CGPoint(x: 2.7, y: 12.2), 1.65), with: .color(GhostInk.body))
        handset.stroke(circle(CGPoint(x: 2.7, y: 12.2), 1.65), with: .color(GhostInk.ink), style: pawStyle)
    }

    /// Neutral dark mute badge pinned cleanly at bottom-right when muted.
    fileprivate func drawMuteBadge() {
        let bx = 21.5, by = 20.5
        let badge = circle(CGPoint(x: bx, y: by), 3.6)
        fill(badge, with: .color(GhostInk.badgeFill))
        stroke(badge, with: .color(GhostInk.badgeStroke), lineWidth: 1.1)
        let slash = Path { p in
            p.move(to: CGPoint(x: bx, y: by - 1.5))
            p.addLine(to: CGPoint(x: bx, y: by + 0.5))
            p.move(to: CGPoint(x: bx - 1.5, y: by - 1.5))
            p.addLine(to: CGPoint(x: bx + 1.5, y: by + 1.5))
        }
        stroke(slash, with: .color(GhostInk.badgeInk), style: StrokeStyle(lineWidth: 1.05, lineCap: .round))
    }

    private func drawFace(voice: GhostVoiceState, pose: GhostPose) {
        for x in [9.2, 14.8] {
            var eye = self
            eye.scale(x: 1, y: pose.eyes, around: CGPoint(x: x, y: 11.2))
            eye.fill(oval(x - 1.1, 9.6, 2.2, 3.2), with: .color(GhostInk.ink))
            eye.fill(circle(CGPoint(x: x + 0.35, y: 10.4), 0.45), with: .color(.white))
        }
        fill(oval(6.4, 13, 2.4, 1.3), with: .color(GhostInk.blush.opacity(0.6)))
        fill(oval(15.2, 13, 2.4, 1.3), with: .color(GhostInk.blush.opacity(0.6)))
        switch voice {
        case .speaking:
            let mw = 0.85 + pose.level * 0.3
            let mh = 0.85 + pose.level * 1.15
            fill(oval(12 - mw, 14.6 - mh, mw * 2, mh * 2), with: .color(GhostInk.ink))
        case .muted:
            let flat = Path { $0.move(to: CGPoint(x: 11.1, y: 14.6)); $0.addLine(to: CGPoint(x: 12.9, y: 14.6)) }
            stroke(flat, with: .color(GhostInk.ink), style: StrokeStyle(lineWidth: 1.05, lineCap: .round))
        case .idle, .connecting, .listening:
            fill(oval(11.2, 13.6, 1.6, 1.8), with: .color(GhostInk.ink))
        }
    }

    /// The ghost on its 26-unit grid, holding a keyboard (idle) or lifted telephone handset (call) and a wrench.
    func drawGhost(accent: Color, pose: GhostPose, voice: GhostVoiceState = .idle, networkUnstable: Bool = false) {
        let line = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        let grip = CGPoint(x: 19.6, y: 14.2)
        drawWrench(accent: accent, wave: pose.wave, grip: grip)
        let body = Path { path in
            path.move(to: CGPoint(x: 4, y: 20.4))
            path.addLine(to: CGPoint(x: 4, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 4, y: 6.2), control2: CGPoint(x: 7.6, y: 3))
            path.addCurve(to: CGPoint(x: 20, y: 11), control1: CGPoint(x: 16.4, y: 3), control2: CGPoint(x: 20, y: 6.2))
            path.addLine(to: CGPoint(x: 20, y: 20.4))
            for i in 1...24 {
                let t = Double(i) / 24
                path.addLine(to: CGPoint(x: 20 - 16 * t, y: 20.4 + 1.3 * sin(t * 6 * .pi + pose.hem)))
            }
            path.closeSubpath()
        }
        fill(body, with: .color(GhostInk.body))
        stroke(body, with: .color(GhostInk.ink), style: line)
        drawFace(voice: voice, pose: pose)
        if !voice.isCall {
            let paw = CGPoint(x: 3.9, y: 14.6 - pose.wave / 40)
            drawKeyboard(accent: accent, wave: pose.wave, paw: paw)
            for (center, radius) in [(paw, 1.7), (grip, 1.8)] {
                fill(circle(center, radius), with: .color(GhostInk.body))
                stroke(circle(center, radius), with: .color(GhostInk.ink), style: line)
            }
        } else {
            drawHandset(voice: voice, networkUnstable: networkUnstable, pose: pose)
            fill(circle(grip, 1.8), with: .color(GhostInk.body))
            stroke(circle(grip, 1.8), with: .color(GhostInk.ink), style: line)
        }
    }
}

/// Android `ToolboxPet`'s picture: bobs over its shadow, sways, ripples its hem, blinks,
/// and swaps its keyboard for a lifted telephone handset during active `/voice` calls.
struct ToolboxPetArt: View {
    var animated = true
    var voiceState: GhostVoiceState = .idle
    var networkUnstable = false
    @State private var appeared = Date()

    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let pose = GhostVoicePose.at(context.date.timeIntervalSinceReferenceDate, voice: voiceState, reduceMotion: !animated)
            let hop = animated ? Self.hop(context.date.timeIntervalSince(appeared)) : 0
            Canvas { canvas, size in
                var grid = canvas
                let isCall = voiceState.isCall
                let unit = min(size.width, size.height) / (isCall ? 30 : 26)
                grid.scaleBy(x: unit, y: unit)
                if isCall { grid.translateBy(x: 2, y: 2) }
                let lift = pose.float * 1.6 + hop * (isCall ? 3.4 : 4.0)
                grid.drawVoiceAura(voice: voiceState, networkUnstable: networkUnstable, pose: pose, lift: lift)
                let shadow = 1 - lift / 9
                grid.fill(
                    Path(ellipseIn: CGRect(x: 12 - 5 * shadow, y: isCall ? 23.55 : 23.6, width: 10 * shadow, height: isCall ? 1.7 : 1.6)),
                    with: .color(.black.opacity((isCall ? 0.26 : 0.22) * shadow))
                )
                var bodyCtx = grid
                bodyCtx.translateBy(x: 0, y: 0.4 - lift)
                bodyCtx.rotate(pose.sway, around: CGPoint(x: 12, y: 21))
                bodyCtx.drawGhost(accent: Palette.accent, pose: pose, voice: voiceState, networkUnstable: networkUnstable)
                if voiceState.showsMuteBadge { grid.drawMuteBadge() }
            }
        }
        .onAppear { appeared = Date() }
        .onChange(of: voiceState.isCall) { _ in appeared = Date() }
        .accessibilityHidden(true)
    }

    /// Android's pop-in: up over 180 ms, then a loose spring back to rest.
    private static func hop(_ elapsed: TimeInterval) -> Double {
        guard elapsed >= 0 else { return 0 }
        if elapsed < 0.18 { return GhostVoicePose.fastOutSlowIn(elapsed / 0.18) }
        let t = elapsed - 0.18
        return t > 2 ? 0 : exp(-7.4 * t) * cos(20 * t)
    }
}

/// Android `ItermuxLogo`: the launcher icon drawn live.
struct RoamttyLogoArt: View {
    var animated = false
    private static let terminal = Color(red: 0x25 / 255, green: 0x27 / 255, blue: 0x28 / 255)
    private static let text = Color(red: 0xF3 / 255, green: 0xF0 / 255, blue: 0xEA / 255)
    private static let accent = Color(red: 0xEF / 255, green: 0xA7 / 255, blue: 0x83 / 255)
    var body: some View {
        TimelineView(.animation(paused: !animated)) { context in
            let pose = GhostVoicePose.at(context.date.timeIntervalSinceReferenceDate, voice: .idle, reduceMotion: !animated)
            Canvas { canvas, size in
                var icon = canvas
                let unit = min(size.width, size.height) / 72
                icon.scaleBy(x: unit, y: unit)
                icon.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 72, height: 72), cornerRadius: 19), with: .color(Self.terminal))
                for (x1, x2, y) in [(12.0, 26.0, 9.0), (7, 19, 16), (52, 62, 16), (6, 14, 23)] {
                    icon.stroke(Path { $0.move(to: CGPoint(x: x1, y: y)); $0.addLine(to: CGPoint(x: x2, y: y)) },
                                with: .color(Self.text.opacity(0.1)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
                let prompt = Path { $0.move(to: CGPoint(x: 28, y: 58)); $0.addLine(to: CGPoint(x: 33, y: 62.5)); $0.addLine(to: CGPoint(x: 28, y: 67)) }
                icon.stroke(prompt, with: .color(Self.accent), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                icon.fill(Path(roundedRect: CGRect(x: 37, y: 57.5, width: 6, height: 10), cornerRadius: 1), with: .color(Self.accent.opacity(0.85 * pose.cursor)))
                icon.translateBy(x: 12.375, y: 7.5)
                icon.scaleBy(x: 1.75, y: 1.75)
                let lift = pose.float * 1.6, shadow = 1 - lift / 9
                icon.fill(Path(ellipseIn: CGRect(x: 12 - 5 * shadow, y: 23.6, width: 10 * shadow, height: 1.6)), with: .color(.black.opacity(0.35 * shadow)))
                icon.translateBy(x: 0, y: 0.4 - lift)
                icon.drawGhost(accent: Self.accent, pose: pose, voice: .idle)
            }
        }
    }
}

private func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path { Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)) }
private func circle(_ c: CGPoint, _ r: Double) -> Path { oval(c.x - r, c.y - r, 2 * r, 2 * r) }
private func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
}
