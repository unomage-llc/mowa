import AppKit
import SwiftUI

/// "Mowa is running" card shown when the app starts. Mowa is menu-bar only (no
/// Dock icon), so without this a user who just opened it sees nothing happen —
/// especially when macOS hides the menu bar icon behind the camera notch.
@MainActor
final class LaunchNotice {
    static let shared = LaunchNotice()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    /// Shows the card under the status item (or at the top of the screen when
    /// the icon is hidden). `force` ignores the "don't show again" setting.
    func show(statusItem: NSStatusItem?, force: Bool = false, title: String? = nil) {
        guard force || AppSettings.shared.showLaunchNotice else { return }
        close()

        let anchor = Self.visibleAnchor(of: statusItem)
        let view = LaunchNoticeView(
            title: title ?? L("Mowa is running"),
            hotkey: AppSettings.shared.hotkey.displayName,
            iconHidden: anchor == nil,
            onOpenSettings: { [weak self] in
                self?.close()
                AppDelegate.shared.showSettings()
            },
            onClose: { [weak self] in self?.close() },
            onHover: { [weak self] hovering in
                if hovering { self?.dismissWork?.cancel() } else { self?.scheduleDismiss(after: 6) }
            })

        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, anchor: anchor))
        panel.orderFrontRegardless()
        self.panel = panel
        Log.info("Launch notice shown (icon \(anchor == nil ? "hidden" : "visible"))")
        scheduleDismiss(after: 12)
    }

    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Screen frame of the status item button, or nil when macOS isn't showing it
    /// (no room in the menu bar, e.g. behind the notch).
    private static func visibleAnchor(of item: NSStatusItem?) -> NSRect? {
        guard let button = item?.button, let window = button.window,
              window.isVisible, window.occlusionState.contains(.visible) else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        // An item squeezed out by the notch can still report a frame inside the
        // notch area; treat anything inside the camera housing as hidden.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.midX > left.maxX, frame.midX < right.minX {
            return nil
        }
        return frame
    }

    private static func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x: CGFloat
        let y = visible.maxY - size.height - 8
        if let a = anchor {
            x = a.midX - size.width / 2
        } else {
            x = visible.midX - size.width / 2
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }
}

private struct LaunchNoticeView: View {
    let title: String
    let hotkey: String
    let iconHidden: Bool
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(LF("Hold %@ to dictate", hotkey))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close"))
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(MowaColors.accent)
                    .frame(width: 16)
                Text(L("Mowa lives in the menu bar. Click the waveform icon at the top of the screen for settings, history and to quit."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            if iconHidden {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(L("Can't see the icon? macOS hides menu bar icons that don't fit next to the camera notch. Quit a few other menu bar apps to make room, or open Mowa again from Applications to get its settings."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Toggle(L("Don't show this again"), isOn: Binding(
                    get: { !settings.showLaunchNotice },
                    set: { settings.showLaunchNotice = !$0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button(L("Open Settings"), action: onOpenSettings)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .onHover(perform: onHover)
    }
}
