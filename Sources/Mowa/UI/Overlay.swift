import AppKit
import SwiftUI
import MowaCore

/// The small floating pill at the bottom of the screen while Mowa listens or works.
@MainActor
final class OverlayController {
    private let state: AppState
    private let onStop: () -> Void
    private let onCancel: () -> Void
    private var panel: NSPanel?
    private var errorMessage: String?
    private var hideWork: DispatchWorkItem?

    init(state: AppState, onStop: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.state = state
        self.onStop = onStop
        self.onCancel = onCancel
    }

    func show() {
        hideWork?.cancel()
        errorMessage = nil
        guard AppSettings.shared.showOverlay else { return }
        // A fresh panel every time: a reused borderless panel sometimes came back
        // ordered-in but undrawn (seen on macOS 26 with an external display).
        panel?.orderOut(nil)
        state.pillShown = false
        let panel = makePanel()
        self.panel = panel
        setContent(panel)
        position(panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        // Grow in from a point on the next frame (the panel is on screen, pill still collapsed).
        DispatchQueue.main.async { [weak self] in self?.state.pillShown = true }
        updateMouseHandling()
        let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: " ")
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let windowScreen = Self.screenOfFrontmostWindow().map { NSStringFromRect($0.frame) } ?? "none"
        Log.info("Overlay: show at \(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) app=\(app) appWindowScreen=\(windowScreen) mouse=\(NSStringFromPoint(NSEvent.mouseLocation)) screens=\(screens)")
    }

    func update() {
        updateMouseHandling()
    }

    /// Shrinks the pill into a point and fades it (same motion as it grew in, reversed), then
    /// takes the panel off screen.
    func hide() {
        guard errorMessage == nil, let panel else { return }
        state.pillShown = false
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, !self.state.pillShown else { return }
            panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDuration, execute: work)
    }

    func flashError(_ message: String) {
        flash(message, symbol: "exclamationmark.triangle.fill", color: .yellow)
    }

    /// Short notice that doesn't interrupt (e.g. "Learned: малый → малой").
    func flashInfo(_ message: String) {
        guard case .idle = state.phase else { return }
        flash(message, symbol: "sparkles", color: MowaColors.accent)
    }

    /// Error / info notices grow out of a point and shrink back like the dictation pill. If the
    /// dictation pill is on screen (or still shrinking away), it finishes shrinking first, so the
    /// notice never replaces it abruptly.
    private func flash(_ message: String, symbol: String, color: Color) {
        hideWork?.cancel()
        errorMessage = message
        let present = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let panel = self.panel ?? self.makePanel()
            self.panel = panel
            self.state.pillShown = false
            panel.contentView = NSHostingView(rootView: ErrorPill(state: self.state, message: message,
                                                                  symbol: symbol, color: color))
            panel.setContentSize(panel.contentView!.fittingSize)
            self.position(panel)
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in self?.state.pillShown = true }
            let shrink = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.state.pillShown = false
                let out = DispatchWorkItem { [weak self] in
                    self?.errorMessage = nil
                    self?.panel?.orderOut(nil)
                }
                self.hideWork = out
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDuration, execute: out)
            }
            self.hideWork = shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: shrink)
        }
        if let panel, panel.isVisible {
            state.pillShown = false
            hideWork = present
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDuration, execute: present)
        } else {
            present.perform()
        }
    }

    /// The pill's shrink-and-fade (OverlayPill / ErrorPill: easeIn 0.14 s) plus a little margin.
    static let hideDuration: TimeInterval = 0.17

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Above full-screen apps and every normal window.
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        return panel
    }

    private func setContent(_ panel: NSPanel) {
        let view = OverlayPill(state: state, onStop: onStop, onCancel: onCancel)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        panel.contentView = host
        panel.setContentSize(NSSize(width: 260, height: 52))
    }

    private func position(_ panel: NSPanel) {
        // Show it on the screen the user is typing on: the screen of the
        // frontmost app's window, falling back to the screen with the mouse.
        let screen = Self.screenOfFrontmostWindow()
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
    }

    /// Screen holding the largest part of the frontmost app's frontmost normal window.
    private static func screenOfFrontmostWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict), cg.width > 50, cg.height > 50 else { continue }
            // CG window bounds use a top-left origin on the primary screen; Cocoa uses bottom-left.
            let rect = NSRect(x: cg.minX, y: primary.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
            return NSScreen.screens.max { a, b in
                a.frame.intersection(rect).width * a.frame.intersection(rect).height
                    < b.frame.intersection(rect).width * b.frame.intersection(rect).height
            }
        }
        return nil
    }

    /// The pill has nothing to click: clicks always pass through to the app underneath.
    private func updateMouseHandling() {
        panel?.ignoresMouseEvents = true
    }
}

private struct OverlayPill: View {
    @ObservedObject var state: AppState
    let onStop: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var palette: PillPalette { PillPalette(scheme) }

    /// Where the hands-free side items sit, in the fixed panel space (see `sideItems`).
    @State private var sideCenters: [SideItem: CGPoint] = [:]
    /// The pill's size, followed with the pill's own animation, so the side items can be cut off
    /// at the pill's edge (they never show outside the background).
    @State private var pillSize: CGSize = .zero

    var body: some View {
        pill
            // A fixed-size space (the whole panel) around the pill: the side items are drawn here,
            // so they stay put while the pill shrinks under them and can slide straight outwards.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                sideItems
                    .mask {
                        Capsule().frame(width: pillSize.width, height: pillSize.height)
                    }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(SideItemCenters.self) { centers in
                // Keep the last known places after the placeholders are gone (they leave first).
                sideCenters.merge(centers) { $1 }
            }
            .onPreferenceChange(PillSizeKey.self) { size in
                // Same clock as the pill itself (see the phase animation below).
                withAnimation(state.processingSince != nil ? VoiceIndicator.windAnimation
                                                           : .spring(response: 0.35, dampingFraction: 0.85)) {
                    pillSize = size
                }
            }
            // Appears by growing out of a point and floating up a little; disappears the same way
            // in reverse (shrinks into a point, sinks and fades).
            .scaleEffect(state.pillShown ? 1 : 0.02)
            .offset(y: state.pillShown ? 0 : 10)
            .opacity(state.pillShown ? 1 : 0)
            .animation(state.pillShown ? .spring(response: 0.25, dampingFraction: 0.8) : .easeIn(duration: 0.14),
                       value: state.pillShown)
            // On key release the whole pill closes into a circle on the same clock as the line
            // winding up inside it (VoiceIndicator), so the reel never runs outside the pill.
            .animation(state.processingSince != nil ? VoiceIndicator.windAnimation
                                                    : .spring(response: 0.35, dampingFraction: 0.85),
                       value: state.phase)
    }

    private static let space = "overlayPanel"

    private var pill: some View {
        HStack(spacing: 10) {
            // One indicator view for both phases (same place in the hierarchy), so on key release
            // the waveform itself rolls up into the spinner instead of being swapped for another view.
            // Always present (also while the pill shrinks away after processing, phase idle).
            VoiceIndicator(state: state)
            if case .processing(let message) = state.phase, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
        }
        // Spinner alone: 12 + 16 + 12 = 40 = the pill's height, so the pill becomes a circle.
        .padding(.horizontal, isSpinnerOnly ? 12 : 14)
        .frame(height: 40)
        .background(
            Capsule().fill(palette.background)
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        )
        // Nothing inside (the winding line, the spinning dots) may ever show outside the pill.
        .clipShape(Capsule())
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PillSizeKey.self, value: proxy.size)
        })
        .shadow(color: .black.opacity(palette.shadowOpacity), radius: 8, y: 3)
    }

    private var wandIcon: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondaryText)
    }

    /// The command-mode icon (left of the line). When the recording ends it slides out to the
    /// left and fades, cut off at the pill's edge as it closes into the spinner. Hands-free
    /// (long) dictation has no buttons: it differs from push-to-talk only by a wider line.
    @ViewBuilder private var sideItems: some View {
        ZStack {
            // (The command-mode wand icon lived here; Shift + key command mode was removed 2026-10-21.)
            EmptyView()
        }
    }

    /// In: after the pill has widened, from `dx` outside. Out: straight to `dx` outside, fading.
    private static func slide(_ dx: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: dx).combined(with: .opacity).animation(.easeOut(duration: 0.2).delay(0.12)),
            removal: .offset(x: dx).combined(with: .opacity).animation(.easeOut(duration: 0.22)))
    }

    private func isRecording(handsFree: Bool) -> Bool {
        if case .recording(let h) = state.phase { return h == handsFree }
        return false
    }

    private var isSpinnerOnly: Bool {
        if case .processing(let message) = state.phase { return message.isEmpty }
        // Still a spinner while it shrinks away after processing.
        if state.phase == .idle { return state.processingSince != nil }
        return false
    }
}

/// The coral voice indicator. While recording: thin bars flowing right → left (newest on the
/// right), placed by timestamp on every display frame. On key release the same bars roll up into
/// the spinner: they stop flowing, bend onto a circle and keep turning as a comet-like arc. Drawn
/// in one Canvas so every bar travels continuously from its place in the line to its place in
/// the ring.
private struct VoiceIndicator: View {
    @ObservedObject var state: AppState
    @Environment(\.displayScale) private var displayScale

    // Thin bars on whole points (2 pt bar + 2 pt gap) so they stay crisp lines.
    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 2
    private let height: CGFloat = 22
    private let spinnerRadius: CGFloat = 7
    private let secondsPerTurn: TimeInterval = 0.9

    /// Long (hands-free) dictation: a wider line — the only visual difference from push-to-talk.
    private var lineWidth: CGFloat { state.lastRecordingHandsFree ? 104 : 56 }

    var body: some View {
        // Layout size: the waveform's width while recording, 16 pt (spinner) while processing,
        // so the pill shrinks to a circle. The drawing itself sits on a fixed-size canvas on top.
        let processing = state.processingSince != nil
        Color.clear
            .frame(width: processing ? 16 : lineWidth, height: processing ? 16 : height)
            .overlay {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(in: &context, size: size, now: timeline.date)
                    }
                }
                .frame(width: lineWidth, height: height)
                .allowsHitTesting(false)
            }
    }

    // Release animation, all measured from the moment the key was let go:
    // 1. the bars shrink back to dots (0 → shrinkDuration);
    // 2. the dotted line keeps running left, as it did while recording, and its LEFT end curls
    //    up into a coil (it runs along the coil's bottom and up its left side — clockwise).
    //    The coil travels in with the pill's left edge as the pill closes into a circle, and the
    //    rest of the line is reeled in after it (windStart → windStart + windDuration);
    // 3. the coil keeps turning: that is the spinner — the same dots, never swapped out. Its
    //    speed eases from the line's running speed to the spinner's, without a jolt.
    private let shrinkDuration: TimeInterval = 0.14
    static let windStart: TimeInterval = 0.04
    static let windDuration: TimeInterval = 0.42
    /// The pill's own shrink to a circle uses this, so it closes exactly as the coil arrives.
    /// (A smoothstep-shaped curve, matching `smoothstep` used for the drawing.)
    static let windAnimation = Animation.timingCurve(0.45, 0, 0.55, 1, duration: windDuration).delay(windStart)
    private let ringDots = 8

    private static func smoothstep(_ x: Double) -> CGFloat {
        let c = min(1, max(0, x))
        return CGFloat(c * c * (3 - 2 * c))
    }

    /// ∫ smoothstep from 0 to x (x in 0…1, linear after): x³ − x⁴/2.
    private static func smoothstepIntegral(_ x: Double) -> CGFloat {
        if x <= 0 { return 0 }
        if x >= 1 { return CGFloat(0.5 + (x - 1)) }
        return CGFloat(x * x * x - x * x * x * x / 2)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let samples = state.levelSamples
        let step = barWidth + spacing
        let pixel = 1 / max(1, displayScale)
        let releasedAt = state.processingSince
        // The recorded line stops at release; from there on its motion is the wind-up's.
        let lineTime = releasedAt.map { min(now, $0) } ?? now
        let elapsed = releasedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let shrink = Self.smoothstep(elapsed / shrinkDuration)
        let windX = (elapsed - Self.windStart) / Self.windDuration
        let wind = Self.smoothstep(windX)

        struct Bar { let x: CGFloat; let h: CGFloat; let alpha: CGFloat }
        var bars: [Bar] = []   // newest first, x = left edge in the line
        let right = size.width - barWidth
        for sample in samples.reversed() {
            let age = lineTime.timeIntervalSince(sample.time)
            let rawX = right - CGFloat(age / AppState.sampleInterval) * step
            if rawX < -barWidth { break }
            if rawX > size.width { continue }
            // Whole pixels while the line flows (crisp); free positions while it winds (smooth).
            let x = releasedAt == nil ? (rawX / pixel).rounded() * pixel : rawX
            // Bar height from the shared meter (MowaCore/LevelMeter, unit-tested).
            // A mic heard before is drawn like the MacBook mic (its learnt loudness, not live auto gain).
            let v = CGFloat(state.micSpeechDB.map { LevelMeter.barFraction(sample.value, micSpeechDB: $0) }
                            ?? LevelMeter.barFraction(sample.value))
            let h = max(2, min(1, v) * size.height)
            // Soft edges: fade in on the right 20 %, out on the left 25 %.
            let cx = x + barWidth / 2
            let alpha = min(1, max(0, cx / (size.width * 0.25))) * min(1, max(0, (size.width - cx) / (size.width * 0.2)))
            bars.append(Bar(x: x, h: h, alpha: alpha))
        }
        guard let oldest = bars.last, let newest = bars.first else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = spinnerRadius - 1                   // dots on a 6 pt circle
        let gap = 2 * CGFloat.pi / CGFloat(ringDots)     // one line step = one coil slot
        // The coil starts right above the line's left end and travels to the middle.
        let startX = oldest.x + barWidth / 2
        let coil = CGPoint(x: startX + (center.x - startX) * wind,
                           y: center.y - radius * (1 - wind))
        let lineY = coil.y + radius                      // the line runs along the coil's bottom
        // How much of the line has run into the coil. Its speed goes from the recording's
        // (a step per sample) to the spinner's; on top, the rest of the line is reeled in by the
        // end of the wind.
        let flowSpeed = step / CGFloat(AppState.sampleInterval)
        let spinSpeed = CGFloat(ringDots) * step / CGFloat(secondsPerTurn)
        let duration = CGFloat(Self.windDuration)
        func ran(_ t: TimeInterval) -> CGFloat {          // distance run in t seconds
            return flowSpeed * CGFloat(t) + (spinSpeed - flowSpeed)
                * duration * Self.smoothstepIntegral((t - Self.windStart) / Self.windDuration)
        }
        let lineLength = newest.x - oldest.x + step
        let ranByEnd = ran(Self.windStart + Self.windDuration)
        let reeled = releasedAt == nil ? 0 : ran(elapsed) + max(0, lineLength - ranByEnd) * wind

        for (index, bar) in bars.enumerated() {
            let q = bar.x + barWidth / 2 - startX          // distance from the line's left end
            let onCoil = reeled - q                       // > 0: this far around the coil
            var p: CGPoint
            var alpha: CGFloat
            var length = bar.h + (2 - bar.h) * shrink
            if onCoil > 0 {
                // From the bottom, clockwise: bottom → left → top → right.
                let angle = CGFloat.pi / 2 + onCoil / step * gap
                p = CGPoint(x: coil.x + radius * cos(angle), y: coil.y + radius * sin(angle))
                let landed = min(1, onCoil / (2 * step))
                // The newest `ringDots` dots run in last and make the spinner: the one furthest
                // round (index ringDots-1) leads at full strength, the newest trails faintest.
                // Older dots came round first; they fade before the spinner's dots reach them.
                let ringAlpha: CGFloat
                if index < ringDots {
                    ringAlpha = 0.2 + 0.8 * CGFloat(index) / CGFloat(ringDots - 1)
                } else {
                    ringAlpha = max(0, 1 - onCoil / (CGFloat(ringDots - 2) * step))
                }
                alpha = bar.alpha + (ringAlpha - bar.alpha) * landed
                length = 2 + (length - 2) * (1 - landed)
            } else {
                p = CGPoint(x: coil.x + q - reeled, y: lineY)   // still running along the line
                alpha = bar.alpha
            }
            if alpha <= 0.01 { continue }

            var c = context
            c.opacity = Double(alpha)
            let rect = CGRect(x: p.x - barWidth / 2, y: p.y - length / 2, width: barWidth, height: length)
            c.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(MowaColors.accent))
        }
    }
}

private enum SideItem: Hashable { case wand }

private struct PillSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SideItemCenters: PreferenceKey {
    static var defaultValue: [SideItem: CGPoint] = [:]
    static func reduce(value: inout [SideItem: CGPoint], nextValue: () -> [SideItem: CGPoint]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Reports this view's centre in the overlay panel's space (OverlayPill.space).
    func reportCenter(_ item: SideItem) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .named("overlayPanel"))
            Color.clear.preference(key: SideItemCenters.self, value: [item: CGPoint(x: frame.midX, y: frame.midY)])
        })
    }
}

private struct PillButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var prominent = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PillPalette(scheme)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(prominent ? Color.black : palette.text)
                .frame(width: 22, height: 22)
                .background(Circle().fill(prominent ? MowaColors.accent : palette.buttonFill))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ErrorPill: View {
    @ObservedObject var state: AppState
    let message: String
    var symbol = "exclamationmark.triangle.fill"
    var color: Color = .yellow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PillPalette(scheme)
        HStack(spacing: 8) {
            // Yellow is unreadable on the light pill: use orange there.
            Image(systemName: symbol).foregroundStyle(scheme == .light && color == .yellow ? Color.orange : color)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(
            Capsule().fill(palette.background)
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        )
        // Same appear / disappear motion as the dictation pill.
        .scaleEffect(state.pillShown ? 1 : 0.02)
        .offset(y: state.pillShown ? 0 : 10)
        .opacity(state.pillShown ? 1 : 0)
        .animation(state.pillShown ? .spring(response: 0.25, dampingFraction: 0.8) : .easeIn(duration: 0.14),
                   value: state.pillShown)
        .padding(6)
    }
}

/// Overlay colours for the Mac's light or dark appearance (follows System Settings → Appearance,
/// switching live).
private struct PillPalette {
    let background: Color
    let border: Color
    let text: Color
    let secondaryText: Color
    let buttonFill: Color
    let shadowOpacity: Double

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            background = Color.black.opacity(0.82)
            border = Color.white.opacity(0.12)
            text = Color.white.opacity(0.9)
            secondaryText = Color.white.opacity(0.85)
            buttonFill = Color.white.opacity(0.18)
            shadowOpacity = 0.25
        } else {
            background = Color.white.opacity(0.94)
            border = Color.black.opacity(0.10)
            text = Color.black.opacity(0.85)
            secondaryText = Color.black.opacity(0.7)
            buttonFill = Color.black.opacity(0.08)
            shadowOpacity = 0.15
        }
    }
}

enum MowaColors {
    /// Warm coral — Mowa's accent.
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.33)
}
