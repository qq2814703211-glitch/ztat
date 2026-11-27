//
//  CombinedView.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 09/01/2023
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//
//  ZTAT-PATCH: Clean native menu bar fusion — retains Stats multi-metric bar while
//  routing clicks directly to the Vitals unified popover (or classic module popup on ⌥-click),
//  with zero global mouse-event hijacking and right-click context menu.
//

import Cocoa
import StatsKit
import ZtatCore

internal class CombinedView: NSObject {
    private var menuBarItem: NSStatusItem? = nil
    private var view: NSView = CombinedClickThroughContainerView(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height))
    private let summary: CombinedSummaryWidget = CombinedSummaryWidget()

    private var status: Bool {
        Store.shared.bool(key: "CombinedModules", defaultValue: false) && !Store.shared.bool(key: "pause", defaultValue: false)
    }
    private var spacing: CGFloat {
        CGFloat(Int(Store.shared.string(key: "CombinedModules_spacing", defaultValue: "")) ?? 0)
    }
    private var separator: Bool {
        Store.shared.bool(key: "CombinedModules_separator", defaultValue: false)
    }
    private var vitalsPopoverDefault: Bool {
        Store.shared.bool(key: "VitalsUnifiedPopover", defaultValue: true)
    }

    private var activeModules: [Module] {
        modules.filter({ $0.enabled }).sorted(by: { $0.combinedPosition < $1.combinedPosition })
    }

    override init() {
        super.init()

        modules.forEach { (m: Module) in
            m.menuBar.callback = { [weak self] in
                if let s = self?.status, s {
                    DispatchQueue.main.async {
                        self?.recalculate()
                    }
                }
            }
            m.summaryCallback = { [weak self] module, value in
                guard let self else { return }
                self.summary.setValue(for: module, with: value)
                guard self.status, CombinedModulesWidget.current.isSummaryWidget else { return }
                self.updateSummary()
            }
        }

        // ZTAT-PATCH: Strict zero-idle rule — only create CombinedModules status item when at least 1 module is active
        if self.status && !self.activeModules.isEmpty {
            self.enable()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.listenForStateChange), name: .toggleOneView, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.listenForStateChange), name: .pause, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.listenForModuleRearrange), name: .moduleRearrange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .toggleOneView, object: nil)
        NotificationCenter.default.removeObserver(self, name: .pause, object: nil)
        NotificationCenter.default.removeObserver(self, name: .moduleRearrange, object: nil)
    }

    public func syncVisibility() {
        if self.status && !self.activeModules.isEmpty {
            if self.menuBarItem == nil {
                self.enable()
            } else {
                self.recalculate()
            }
        } else {
            self.disable()
        }
    }

    public func enable() {
        guard self.status, !self.activeModules.isEmpty else {
            self.disable()
            return
        }
        guard self.menuBarItem == nil else { return }

        self.menuBarItem = NSStatusBar.system.statusItem(withLength: 0)
        DispatchQueue.main.async {
            self.menuBarItem?.autosaveName = "ztat.stats.CombinedModules"
        }
        self.menuBarItem?.button?.addSubview(self.view)
        self.menuBarItem?.button?.image = NSImage()
        self.menuBarItem?.button?.toolTip = ZtatL10n.tr("ztat 硬件监控（点击打开概览，⌥+点击经典弹窗，右键更多）", "ztat Hardware Monitor (Click for Vitals, ⌥+Click for classic popup)")

        self.menuBarItem?.button?.target = self
        self.menuBarItem?.button?.action = #selector(self.handleClick)
        self.menuBarItem?.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])

        DispatchQueue.main.async {
            self.recalculate()
        }
    }

    public func disable() {
        Task { @MainActor in
            VitalsPopoverWindow.shared.dismiss()
        }
        if let item = self.menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        self.menuBarItem = nil
    }

    private func recalculate() {
        guard self.status, !self.activeModules.isEmpty else {
            self.disable()
            return
        }
        guard self.menuBarItem != nil else { return }
        self.view.subviews.forEach { $0.removeFromSuperview() }

        if CombinedModulesWidget.current.isSummaryWidget {
            self.updateSummary()
            return
        }

        if CombinedModulesWidget.current == .icon {
            self.view.addSubview(AppIcon())
            self.view.setFrameSize(NSSize(width: AppIcon.size.width, height: self.view.frame.height))
            self.menuBarItem?.length = AppIcon.size.width
            return
        }

        let visibleModules = self.activeModules.filter { !$0.menuBar.activeWidgets.isEmpty }
        guard !visibleModules.isEmpty else {
            self.view.addSubview(AppIcon())
            self.view.setFrameSize(NSSize(width: AppIcon.size.width, height: self.view.frame.height))
            self.menuBarItem?.length = AppIcon.size.width
            return
        }
        var w: CGFloat = 0
        visibleModules.enumerated().forEach { (i, m) in
            if i != 0 {
                w += self.spacing
                if self.separator {
                    self.view.addSubview(SeparatorLineView(frame: NSRect(x: w, y: 3, width: 1, height: Constants.Widget.height - 6)))
                    w += 3 + self.spacing
                }
            }
            self.view.addSubview(m.menuBar.view)
            m.menuBar.view.setFrameOrigin(NSPoint(x: w, y: 0))
            w += m.menuBar.view.frame.width
        }
        self.view.setFrameSize(NSSize(width: w, height: self.view.frame.height))
        self.menuBarItem?.length = w
    }

    private func updateSummary() {
        guard self.menuBarItem != nil else { return }
        let list = self.activeModules.filter { $0.config.hasSummary }

        if list.isEmpty {
            self.view.subviews.forEach { $0.removeFromSuperview() }
            self.view.addSubview(AppIcon())
            self.view.setFrameSize(NSSize(width: AppIcon.size.width, height: self.view.frame.height))
            self.menuBarItem?.length = AppIcon.size.width
            return
        }

        if self.summary.superview == nil {
            self.view.subviews.forEach { $0.removeFromSuperview() }
            self.view.addSubview(self.summary)
        }

        self.summary.update(list)
        self.view.setFrameSize(self.summary.frame.size)
        self.menuBarItem?.length = self.summary.frame.width
        self.menuBarItem?.button?.toolTip = self.summary.toolTip
        self.menuBarItem?.button?.setAccessibilityLabel(self.summary.toolTip)
    }

    @objc private func handleClick() {
        guard let button = self.menuBarItem?.button, let window = button.window else { return }
        let event = NSApp.currentEvent

        // Right-click opens quick actions context menu (dismissing Vitals popover first so they never overlap)
        if event?.type == .rightMouseDown || (event?.modifierFlags.contains(.control) == true) {
            MainActor.assumeIsolated {
                VitalsPopoverWindow.shared.dismiss()
            }
            showContextMenu(from: button)
            return
        }

        let location = self.view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let visibleModules = self.activeModules.filter { !$0.menuBar.activeWidgets.isEmpty }
        let hitModule: Module?
        if CombinedModulesWidget.current == .widgets {
            hitModule = visibleModules.last(where: {
                $0.menuBar.view.frame.minX <= location.x && location.x <= ($0.menuBar.view.frame.maxX + 4)
            })
        } else {
            hitModule = nil
        }

        let optionHeld = event?.modifierFlags.contains(.option) == true
        let isClockHit = (hitModule?.moduleType == .clock)
        let openClassic = isClockHit || (vitalsPopoverDefault ? optionHeld : !optionHeld)

        if openClassic, let module = (hitModule ?? visibleModules.first ?? activeModules.first) {
            MainActor.assumeIsolated {
                VitalsPopoverWindow.shared.dismiss()
            }
            let centerX = hitModule != nil ? module.menuBar.view.frame.midX : (self.view.frame.width / 2.0)
            NotificationCenter.default.post(name: .togglePopup, object: nil, userInfo: [
                "module": module.name,
                "origin": window.frame.origin,
                "center": centerX,
                "forceClassic": true
            ])
            return
        }

        let targetPane: VitalsPane = hitModule.map { VitalsPane.fromStatsModuleName($0.name) } ?? .overview
        MainActor.assumeIsolated {
            VitalsPopoverWindow.shared.toggle(relativeTo: window, targetPane: targetPane)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let overviewItem = NSMenuItem(
            title: ZtatL10n.tr("打开 Vitals 系统概览", "Open Vitals Overview"),
            action: #selector(openOverviewFromMenu),
            keyEquivalent: ""
        )
        overviewItem.target = self
        menu.addItem(overviewItem)

        let taskMgrItem = NSMenuItem(
            title: ZtatL10n.tr("打开任务管理器", "Open Task Manager"),
            action: #selector(openTaskManagerFromMenu),
            keyEquivalent: ""
        )
        taskMgrItem.target = self
        menu.addItem(taskMgrItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: ZtatL10n.tr("硬件监控设置…", "Hardware Monitor Settings…"),
            action: #selector(openStatsSettingsFromMenu),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openOverviewFromMenu() {
        guard let window = self.menuBarItem?.button?.window else { return }
        MainActor.assumeIsolated {
            VitalsPopoverWindow.shared.show(relativeTo: window, targetPane: .overview)
        }
    }

    @objc private func openTaskManagerFromMenu() {
        MainActor.assumeIsolated {
            VitalsPopoverWindow.shared.dismiss()
            NotificationCenter.default.post(name: .ztatOpenTaskManager, object: nil)
        }
    }

    @objc private func openStatsSettingsFromMenu() {
        MainActor.assumeIsolated {
            VitalsPopoverWindow.shared.dismiss()
            NotificationCenter.default.post(name: .ztatOpenSettings, object: ZtatSettingsRoute.stats(target: "overview"))
        }
    }

    @objc private func listenForStateChange(_ notification: Notification) {
        guard notification.userInfo?["module"] == nil else { return }
        if Thread.isMainThread {
            self.syncVisibility()
        } else {
            DispatchQueue.main.async { [weak self] in self?.syncVisibility() }
        }
    }

    @objc private func listenForModuleRearrange() {
        if Thread.isMainThread {
            self.recalculate()
        } else {
            DispatchQueue.main.async { [weak self] in self?.recalculate() }
        }
    }
}

private class CombinedSummaryWidget: NSView {
    private var values: [(ModuleType, Double?)] = []

    private var color: NSColor { self.isDarkMode ? .white : .black }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch CombinedModulesWidget.current {
        case .rings: self.drawRings()
        case .dial: self.drawDial()
        default: self.drawBars()
        }
    }

    private func color(for value: Double?, moduleType: ModuleType) -> NSColor {
        guard let value else { return self.color }
        return (moduleType == .battery ? value < 0.1 : value > 0.9) ? .systemRed : self.color
    }

    private func drawBars() {
        let height: CGFloat = min(16, self.bounds.height - 4)
        let width = CGFloat(self.values.count) * 6 - 2
        let origin = ((self.bounds.width - width) / 2).rounded()
        let y = ((self.bounds.height - height) / 2).rounded()

        for (i, (module, value)) in self.values.enumerated() {
            let color = self.color(for: value, moduleType: module)
            let rect = NSRect(x: origin + CGFloat(i) * 6, y: y, width: 4, height: height)
            let track = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            color.withAlphaComponent(0.25).setFill()
            track.fill()

            if let value, value > 0 {
                let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height * CGFloat(value))
                NSGraphicsContext.saveGraphicsState()
                track.addClip()
                color.setFill()
                NSBezierPath(rect: fill).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawRings() {
        guard !self.values.isEmpty else { return }
        let diameter = min(20, self.bounds.height - 2)
        let spacing = min(3, diameter / (CGFloat(self.values.count) * 2))
        let lineWidth = spacing - 0.5
        let center = NSPoint(x: self.bounds.midX, y: self.bounds.midY)

        for (i, (module, value)) in self.values.enumerated() {
            let color = self.color(for: value, moduleType: module)
            let radius = (diameter - lineWidth) / 2 - CGFloat(i) * spacing
            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if let value, value > 0 {
                color.setStroke()
                if value == 1 {
                    track.stroke()
                } else {
                    let fill = NSBezierPath()
                    fill.lineWidth = lineWidth
                    fill.lineCapStyle = .round
                    fill.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(value) * 360, clockwise: true)
                    fill.stroke()
                }
            }
        }
    }

    private func drawDial() {
        guard !self.values.isEmpty else { return }
        let lineWidth: CGFloat = 2.5
        let radius = (min(20, self.bounds.height - 2) - lineWidth) / 2
        let center = NSPoint(x: self.bounds.midX, y: self.bounds.midY)
        let segment = 360 / CGFloat(self.values.count)
        let gap: CGFloat = self.values.count > 1 ? 32 : 0

        for (i, (module, value)) in self.values.enumerated() {
            let color = self.color(for: value, moduleType: module)
            let start = 90 - CGFloat(i) * segment - gap / 2
            let length = segment - gap
            let track = NSBezierPath()
            track.lineWidth = lineWidth
            track.lineCapStyle = .round
            track.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - length, clockwise: true)
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if let value, value > 0 {
                let fill = NSBezierPath()
                fill.lineWidth = lineWidth
                fill.lineCapStyle = .round
                fill.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - length * CGFloat(value), clockwise: true)
                color.setStroke()
                fill.stroke()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    fileprivate func setValue(for module: ModuleType, with value: Double?) {
        let value = value.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        if let index = self.values.firstIndex(where: { $0.0 == module }) {
            self.values[index].1 = value
        } else {
            self.values.append((module, value))
        }
    }

    fileprivate func update(_ list: [Module]) {
        self.values = list.map { module in
            (module.moduleType, self.values.first(where: { $0.0 == module.moduleType })?.1)
        }
        let width: CGFloat = CombinedModulesWidget.current == .bars ? max(22, CGFloat(self.values.count) * 6 + 2) : 22
        self.setFrameSize(NSSize(width: width, height: Constants.Widget.height))
        self.toolTip = list.map { module in
            let value = self.values.first(where: { $0.0 == module.moduleType })?.1.map { "\(Int($0 * 100))%" } ?? localizedString("Unknown")
            return "\(localizedString(module.name)): \(value)"
        }.joined(separator: "\n")
        self.needsDisplay = true
    }
}

private final class CombinedClickThroughContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private class SeparatorLineView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = (self.isDarkMode ? NSColor.white : NSColor.black).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }
}
