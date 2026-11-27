// SPDX-License-Identifier: GPL-3.0-or-later
// ZTAT-PATCH: Dedicated native borderless floating popover panel for the Vitals Dashboard.
// Hosts VitalsDashboardView directly with proper sizingOptions, clean click-outside dismissal,
// and reference-counted zero-idle telemetry activation.

import AppKit
import SwiftUI
import ZtatCore

@MainActor
public final class VitalsPopoverWindow: NSPanel, NSWindowDelegate {
    public static let shared = VitalsPopoverWindow()

    private static let defaultPopoverSize = NSSize(width: 520, height: 660)
    private static let consumerID = "vitals.menubar.popover"

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private weak var lastAnchorWindow: NSWindow?
    private let hostingController: NSHostingController<VitalsDashboardView>

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    private init() {
        let view = VitalsDashboardView(model: VitalsDashboardModel.shared)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        self.hostingController = host

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultPopoverSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        self.contentViewController = hostingController
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.delegate = self
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.animationBehavior = .utilityWindow
        self.level = .statusBar
        self.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
    }

    public override func close() {
        dismiss()
    }

    public func windowDidResignKey(_ notification: Notification) {
        if let anchor = lastAnchorWindow,
           let event = NSApp.currentEvent,
           (event.type == .leftMouseDown || event.type == .rightMouseDown),
           (event.window === anchor || anchor.frame.contains(NSEvent.mouseLocation)) {
            return
        }
        dismiss()
    }

    public func toggle(relativeTo anchorWindow: NSWindow?, targetPane: VitalsPane = .overview) {
        if self.isVisible {
            let sameAnchor = (anchorWindow == nil || lastAnchorWindow === anchorWindow)
            if !sameAnchor {
                // Moved click to another Stats menu bar item: re-anchor & switch pane seamlessly
                show(relativeTo: anchorWindow, targetPane: targetPane)
            } else if targetPane != .overview && VitalsDashboardModel.shared.activePane != targetPane {
                VitalsDashboardModel.shared.activePane = targetPane
            } else {
                dismiss()
            }
        } else {
            show(relativeTo: anchorWindow, targetPane: targetPane)
        }
    }

    public func show(relativeTo anchorWindow: NSWindow?, targetPane: VitalsPane = .overview) {
        let model = VitalsDashboardModel.shared
        model.activePane = targetPane
        model.beginConsumer(Self.consumerID)
        self.lastAnchorWindow = anchorWindow

        let width = Self.defaultPopoverSize.width
        let screen: NSScreen?
        if let anchor = anchorWindow {
            let anchorFrame = anchor.frame
            screen = anchor.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        } else {
            screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }

        // Clamp height cleanly for scaled 13" screens so top header never clips above menu bar
        let maxAvailHeight = screen.map { max(420, $0.visibleFrame.height - 16) } ?? Self.defaultPopoverSize.height
        let height = min(Self.defaultPopoverSize.height, maxAvailHeight)
        self.setContentSize(NSSize(width: width, height: height))

        let targetFrame: NSRect
        if let anchor = anchorWindow {
            let anchorFrame = anchor.frame
            var x = anchorFrame.midX - (width / 2.0)
            var y = anchorFrame.minY - height - 6.0
            if let screen {
                x = min(screen.visibleFrame.maxX - width - 8, max(screen.visibleFrame.minX + 8, x))
                y = max(screen.visibleFrame.minY + 8, min(screen.visibleFrame.maxY - height - 4, y))
            }
            targetFrame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
        } else if let screen {
            let x = min(screen.visibleFrame.maxX - width - 10, max(screen.visibleFrame.minX + 10, NSEvent.mouseLocation.x - width / 2))
            let y = max(screen.visibleFrame.minY + 10, screen.visibleFrame.maxY - height - 8)
            targetFrame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
        } else {
            targetFrame = NSRect(x: 200, y: 200, width: width, height: height)
        }

        self.setFrame(targetFrame, display: true)
        self.orderFrontRegardless()
        self.makeKey()
        installDismissMonitors()
    }

    public func dismiss() {
        guard self.isVisible || globalEventMonitor != nil || localEventMonitor != nil || !lifecycleObservers.isEmpty || workspaceObserver != nil else {
            lastAnchorWindow = nil
            return
        }
        self.orderOut(nil)
        removeDismissMonitors()
        lastAnchorWindow = nil
        VitalsDashboardModel.shared.endConsumer(Self.consumerID)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let anchor = self.lastAnchorWindow, anchor.frame.contains(NSEvent.mouseLocation) {
                    return
                }
                self.dismiss()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { // ESC — only when this popover is target window
                if event.window === self {
                    MainActor.assumeIsolated { self.dismiss() }
                    return nil
                }
                return event
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                // Only skip dismissal when clicking inside this popover or its own anchor status bar item;
                // clicking any other ztat window (including StatusTrio Hub icon) dismisses cleanly.
                if let win = event.window, win !== self, win !== self.lastAnchorWindow {
                    MainActor.assumeIsolated { self.dismiss() }
                }
            }
            return event
        }

        let nc = NotificationCenter.default
        lifecycleObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        })
        lifecycleObservers.append(nc.addObserver(forName: .ztatHubPanelVisibilityDidChange, object: nil, queue: .main) { [weak self] note in
            let visible = (note.userInfo?["visible"] as? Bool) ?? (note.object as? Bool) ?? false
            if visible {
                Task { @MainActor [weak self] in self?.dismiss() }
            }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    private func removeDismissMonitors() {
        if let g = globalEventMonitor {
            NSEvent.removeMonitor(g)
            globalEventMonitor = nil
        }
        if let l = localEventMonitor {
            NSEvent.removeMonitor(l)
            localEventMonitor = nil
        }
        for obs in lifecycleObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        lifecycleObservers.removeAll()
        if let ws = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(ws)
            workspaceObserver = nil
        }
    }
}
