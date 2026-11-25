//
//  AppSettings.swift
//  ZtatStatsHost
//
//  Created by Serhiy Mytrovtsiy on 15/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//
//  ZTAT-PATCH: Adapted Stats ApplicationSettings for pure SwiftPM inside ztat.
//  Removed Updater/Sparkle, cloud MQTT SystemStats, WidgetKit TeamId suite,
//  privileged SMCHelper daemon uninstall, and Bundle/NSImage force-unwraps.
//

import Cocoa
import StatsKit
import ZtatCore

class ApplicationSettings: NSStackView {
    private var temperatureUnitsValue: String {
        get { Store.shared.string(key: "temperature_units", defaultValue: "system") }
        set { Store.shared.set(key: "temperature_units", value: newValue) }
    }

    private var combinedModulesState: Bool {
        get { Store.shared.bool(key: "CombinedModules", defaultValue: false) }
        set { Store.shared.set(key: "CombinedModules", value: newValue) }
    }
    private var combinedModulesSpacing: String {
        get { Store.shared.string(key: "CombinedModules_spacing", defaultValue: "none") }
        set { Store.shared.set(key: "CombinedModules_spacing", value: newValue) }
    }
    private var combinedModulesSeparator: Bool {
        get { Store.shared.bool(key: "CombinedModules_separator", defaultValue: false) }
        set { Store.shared.set(key: "CombinedModules_separator", value: newValue) }
    }
    private var combinedModulesPopup: Bool {
        get { Store.shared.bool(key: "CombinedModules_popup", defaultValue: true) }
        set { Store.shared.set(key: "CombinedModules_popup", value: newValue) }
    }
    private var combinedModulesAlternateDetails: Bool {
        get { Store.shared.bool(key: "CombinedModules_alternateDetails", defaultValue: true) }
        set { Store.shared.set(key: "CombinedModules_alternateDetails", value: newValue) }
    }
    private var combinedModulesModifierKeys: [UInt16] {
        get { Store.shared.array(key: "CombinedModules_modifierKeys", defaultValue: [58]) as? [UInt16] ?? [58] }
        set { Store.shared.set(key: "CombinedModules_modifierKeys", value: newValue) }
    }

    private var keepMenuBarPosition: Bool {
        get { Store.shared.bool(key: "keep_menubar_positions", defaultValue: false) }
        set { Store.shared.set(key: "keep_menubar_positions", value: newValue) }
    }

    private var combinedModulesView: PreferencesSection?
    private let moduleSelector: ModuleSelectorView = ModuleSelectorView()

    private var CPUeButton: NSButton?
    private var CPUpButton: NSButton?
    private var CPUsButton: NSButton?
    private var GPUButton: NSButton?

    private var CPUeTest: CPUStressTest = CPUStressTest(type: .efficiency)
    private var CPUpTest: CPUStressTest = CPUStressTest(type: .performance)
    private var CPUsTest: CPUStressTest = CPUStressTest(type: .super)
    private var GPUTest: GPUStressTest? = GPUStressTest()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Settings.width, height: Constants.Settings.height))
        self.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = ScrollableStackView(orientation: .vertical)
        scrollView.stackView.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        scrollView.stackView.spacing = Constants.Settings.margin

        scrollView.stackView.addArrangedSubview(self.informationView())

        scrollView.stackView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Temperature"), component: self.selectView(
                action: #selector(self.toggleTemperatureUnits),
                items: TemperatureUnits,
                selected: self.temperatureUnitsValue
            )),
            PreferencesRow(localizedString("Keep the menubar items position"), component: self.switchView(
                action: #selector(self.toggleMenuBarPosition),
                state: self.keepMenuBarPosition
            ))
        ]))

        self.combinedModulesView = PreferencesSection([
            PreferencesRow(localizedString("Combined modules"), component: self.switchView(
                action: #selector(self.toggleCombinedModules),
                state: self.combinedModulesState
            )),
            PreferencesRow(localizedString("Menu bar"), component: self.selectView(
                action: #selector(self.toggleCombinedModulesWidget),
                items: CombinedModulesWidget.all,
                selected: CombinedModulesWidget.current.rawValue
            )),
            PreferencesRow(component: self.moduleSelector),
            PreferencesRow(localizedString("Spacing"), component: self.selectView(
                action: #selector(self.toggleCombinedModulesSpacing),
                items: CombinedModulesSpacings,
                selected: self.combinedModulesSpacing
            )),
            PreferencesRow(localizedString("Separator"), component: self.switchView(
                action: #selector(self.toggleCombinedModulesSeparator),
                state: self.combinedModulesSeparator
            )),
            PreferencesRow(localizedString("Combined details"), component: self.switchView(
                action: #selector(self.toggleCombinedModulesPopup),
                state: self.combinedModulesPopup
            )),
            PreferencesRow(localizedString("Alternate details on click"), component: self.switchView(
                action: #selector(self.toggleCombinedModulesAlternateDetails),
                state: self.combinedModulesAlternateDetails
            )),
            PreferencesRow(localizedString("Keyboard shortcut"), localizedString("Hold Option or Shift, or both."), component: KeyboardShartcutView(
                callback: self.setCombinedModulesModifierKeys,
                value: self.combinedModulesModifierKeys,
                modifierKeys: [58, 60]
            ))
        ])
        scrollView.stackView.addArrangedSubview(self.combinedModulesView!)
        self.updateCombinedModulesSettings()

        scrollView.stackView.addArrangedSubview(PreferencesSection(title: localizedString("Settings"), [
            PreferencesRow(
                localizedString("Export settings"),
                component: self.buttonView(#selector(self.exportSettings), text: localizedString("Save"))
            ),
            PreferencesRow(
                localizedString("Import settings"),
                component: self.buttonView(#selector(self.importSettings), text: localizedString("Choose file"))
            ),
            PreferencesRow(
                localizedString("Reset settings"),
                component: self.buttonView(#selector(self.resetSettings), text: localizedString("Reset"))
            )
        ]))

        self.addArrangedSubview(scrollView)

        let CPUeButton = self.buttonView(#selector(self.toggleCPUeStressTest), text: localizedString("Run"))
        let CPUpButton = self.buttonView(#selector(self.toggleCPUpStressTest), text: localizedString("Run"))
        let CPUsButton = self.buttonView(#selector(self.toggleCPUsStressTest), text: localizedString("Run"))
        let GPUButton = self.buttonView(#selector(self.toggleGPUStressTest), text: localizedString("Run"))

        self.CPUeButton = CPUeButton
        self.CPUpButton = CPUpButton
        self.CPUsButton = CPUsButton
        self.GPUButton = GPUButton

        let cpu = SystemKit.shared.device.info.cpu
        var tests: [PreferencesRow] = []
        if (cpu?.eCores ?? 0) > 0 {
            tests.append(PreferencesRow(localizedString("Efficiency cores"), component: CPUeButton))
        }
        if (cpu?.pCores ?? 1) > 0 {
            tests.append(PreferencesRow(localizedString("Performance cores"), component: CPUpButton))
        }
        if (cpu?.sCores ?? 0) > 0 {
            tests.append(PreferencesRow(localizedString("Super cores"), component: CPUsButton))
        }
        if self.GPUTest != nil {
            tests.append(PreferencesRow(localizedString("GPU"), component: GPUButton))
        }

        #if arch(arm64)
        if !tests.isEmpty {
            scrollView.stackView.addArrangedSubview(PreferencesSection(title: localizedString("Stress tests"), tests))
        }
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    internal func viewWillAppear() {
        self.updateCombinedModulesSettings()
    }

    private func informationView() -> NSView {
        let view = NSStackView()
        view.heightAnchor.constraint(equalToConstant: 140).isActive = true
        view.orientation = .vertical
        view.distribution = .fill
        view.alignment = .centerY
        view.spacing = 0

        let container: NSGridView = NSGridView()
        container.heightAnchor.constraint(equalToConstant: 120).isActive = true
        container.rowSpacing = 4
        container.yPlacement = .center
        container.xPlacement = .center

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let iconImage = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "ztat Stats")?
            .withSymbolConfiguration(symbolConfig) ?? NSImage(size: NSSize(width: 48, height: 48))
        let iconView = NSImageView(image: iconImage)
        iconView.contentTintColor = .controlAccentColor

        let statsName: NSTextField = TextView(frame: NSRect(x: 0, y: 0, width: view.frame.width, height: 22))
        statsName.alignment = .center
        statsName.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        statsName.stringValue = "ztat Stats"
        statsName.isSelectable = true

        let versionNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ZtatBrand.version
        let buildNumber = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ZtatBrand.buildNumber

        let statsVersion: NSTextField = TextView(frame: NSRect(x: 0, y: 0, width: view.frame.width, height: 16))
        statsVersion.alignment = .center
        statsVersion.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statsVersion.stringValue = "\(localizedString("Version")) \(versionNumber)"
        statsVersion.isSelectable = true
        statsVersion.toolTip = "\(localizedString("Build number")) \(buildNumber)"

        container.addRow(with: [iconView])
        container.addRow(with: [statsName])
        container.addRow(with: [statsVersion])

        container.row(at: 1).height = 22
        container.row(at: 2).height = 20

        view.addArrangedSubview(container)

        return view
    }

    // MARK: - actions

    @objc private func toggleTemperatureUnits(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.temperatureUnitsValue = key
    }

    @objc private func toggleCombinedModules(_ sender: NSButton) {
        self.combinedModulesState = sender.state == NSControl.StateValue.on
        self.updateCombinedModulesSettings()
        NotificationCenter.default.post(name: .toggleOneView, object: nil, userInfo: nil)
    }

    private func updateCombinedModulesSettings() {
        self.combinedModulesView?.setRowVisibility(1, newState: self.combinedModulesState)
        self.combinedModulesView?.setRowVisibility(2, newState: self.combinedModulesState && CombinedModulesWidget.current != .icon)
        for row in 3...6 {
            self.combinedModulesView?.setRowVisibility(row, newState: self.combinedModulesState && CombinedModulesWidget.current == .widgets)
        }
        self.combinedModulesView?.setRowVisibility(7, newState: self.combinedModulesState && CombinedModulesWidget.current == .widgets && self.combinedModulesAlternateDetails)
    }

    @objc private func toggleCombinedModulesWidget(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let widget = CombinedModulesWidget(rawValue: key) else { return }
        CombinedModulesWidget.current = widget
        self.updateCombinedModulesSettings()
        NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
    }

    @objc private func toggleCombinedModulesSpacing(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.combinedModulesSpacing = key
        NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
    }

    @objc private func toggleCombinedModulesSeparator(_ sender: NSButton) {
        self.combinedModulesSeparator = sender.state == NSControl.StateValue.on
        NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: nil)
    }

    @objc private func toggleCombinedModulesPopup(_ sender: NSButton) {
        self.combinedModulesPopup = sender.state == NSControl.StateValue.on
        NotificationCenter.default.post(name: .combinedModulesPopup, object: nil, userInfo: nil)
    }

    @objc private func toggleCombinedModulesAlternateDetails(_ sender: NSButton) {
        self.combinedModulesAlternateDetails = sender.state == NSControl.StateValue.on
        self.updateCombinedModulesSettings()
    }

    private func setCombinedModulesModifierKeys(_ binding: [UInt16]) {
        self.combinedModulesModifierKeys = binding
    }

    @objc private func toggleMenuBarPosition(_ sender: NSButton) {
        self.keepMenuBarPosition = sender.state == NSControl.StateValue.on
    }

    @objc private func importSettings() {
        let panel = NSOpenPanel()
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.modalPanelWindow)))
        panel.begin { result in
            guard result.rawValue == NSApplication.ModalResponse.OK.rawValue else { return }
            if let url = panel.url {
                Store.shared.import(from: url)
                Task { @MainActor in
                    ZtatStatsHost.shared.refreshSummaries()
                }
            }
        }
    }

    @objc private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ztat-stats.plist"
        panel.showsTagField = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.modalPanelWindow)))
        panel.begin { result in
            guard result.rawValue == NSApplication.ModalResponse.OK.rawValue else { return }
            if let url = panel.url {
                Store.shared.export(to: url)
            }
        }
    }

    @objc private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = localizedString("Reset settings")
        alert.informativeText = localizedString("Reset settings text")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedString("Yes"))
        alert.addButton(withTitle: localizedString("No"))

        if alert.runModal() == .alertFirstButtonReturn {
            // ZTAT-PATCH: Reset isolated Stats preferences via ZtatStatsHost without killing host app
            Task { @MainActor in
                ZtatStatsHost.shared.resetAllStatsPreferences()
            }
        }
    }

    @objc private func toggleCPUeStressTest() {
        if self.CPUeTest.isRunning {
            self.CPUeTest.stop()
            self.CPUeButton?.title = localizedString("Run")
        } else {
            self.CPUeTest.start()
            self.CPUeButton?.title = localizedString("Stop")
        }
    }

    @objc private func toggleCPUpStressTest() {
        if self.CPUpTest.isRunning {
            self.CPUpTest.stop()
            self.CPUpButton?.title = localizedString("Run")
        } else {
            self.CPUpTest.start()
            self.CPUpButton?.title = localizedString("Stop")
        }
    }

    @objc private func toggleCPUsStressTest() {
        if self.CPUsTest.isRunning {
            self.CPUsTest.stop()
            self.CPUsButton?.title = localizedString("Run")
        } else {
            self.CPUsTest.start()
            self.CPUsButton?.title = localizedString("Stop")
        }
    }

    @objc private func toggleGPUStressTest() {
        guard let test = self.GPUTest else { return }

        if test.isRunning {
            test.stop()
            self.GPUButton?.title = localizedString("Run")
        } else {
            test.start()
            self.GPUButton?.title = localizedString("Stop")
        }
    }
}

private class ModuleSelectorView: NSStackView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Constants.Widget.height + (Constants.Settings.margin*2)))

        self.translatesAutoresizingMaskIntoConstraints = false
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Settings.margin,
            left: Constants.Settings.margin,
            bottom: Constants.Settings.margin,
            right: Constants.Settings.margin
        )
        self.spacing = Constants.Settings.margin

        let background: NSVisualEffectView = {
            let view = NSVisualEffectView(frame: NSRect.zero)
            view.blendingMode = .withinWindow
            view.material = .contentBackground
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = 5
            return view
        }()

        var w = self.spacing
        modules.filter({ $0.available }).sorted(by: { $0.combinedPosition < $1.combinedPosition }).forEach { (m: Module) in
            let v = ModulePreview(id: m.name, icon: m.config.icon)
            self.addArrangedSubview(v)
            w += v.frame.width + self.spacing
        }

        if w < 20 {
            w = 20
        }

        self.addSubview(background, positioned: .below, relativeTo: .none)

        self.setFrameSize(NSSize(width: w, height: self.frame.height))
        background.setFrameSize(NSSize(width: w, height: self.frame.height))

        self.widthAnchor.constraint(equalToConstant: w).isActive = true
        self.heightAnchor.constraint(equalToConstant: self.frame.height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        let location = self.convert(event.locationInWindow, from: nil)
        guard let targetIdx = self.views.firstIndex(where: { $0.hitTest(location) != nil }),
              let window = self.window, self.views[targetIdx].identifier != nil else {
            super.mouseDragged(with: event)
            return
        }

        let view = self.views[targetIdx]
        let copy = ViewCopy(view)
        copy.zPosition = 2
        copy.transform = CATransform3DMakeScale(0.9, 0.9, 1)

        view.subviews.forEach({ $0.isHidden = true })
        self.layer?.addSublayer(copy)

        defer {
            copy.removeFromSuperlayer()
            view.subviews.forEach({ $0.isHidden = false })
        }

        var newIdx = -1
        let originCenter = view.frame.midX
        let originX = view.frame.origin.x
        let p0 = self.convert(event.locationInWindow, from: nil).x

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: 1e6, mode: .eventTracking) { event, stop in
            guard let event = event else {
                stop.pointee = true
                return
            }

            if event.type == .leftMouseDragged {
                let p1 = self.convert(event.locationInWindow, from: nil).x
                let diff = p1 - p0

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                copy.frame.origin.x = originX + diff
                CATransaction.commit()

                let reordered = self.views.map {
                    (view: $0, x: $0 !== view ? $0.frame.midX : originCenter + diff)
                }.sorted { $0.x < $1.x }.map { $0.view }

                guard let nextIndex = reordered.firstIndex(of: view),
                      let prevIndex = self.views.firstIndex(of: view) else {
                    stop.pointee = true
                    return
                }

                if nextIndex != prevIndex {
                    newIdx = nextIndex
                    view.removeFromSuperviewWithoutNeedingDisplay()
                    self.insertArrangedSubview(view, at: newIdx)
                    self.layoutSubtreeIfNeeded()

                    for (i, v) in self.views(in: .leading).compactMap({ $0 as? ModulePreview }).enumerated() {
                        if let m = modules.first(where: { $0.name == v.identifier?.rawValue }) {
                            m.combinedPosition = i
                        }
                    }
                }
            } else {
                if newIdx != -1, let view = self.views[newIdx] as? ModulePreview, let id = view.identifier?.rawValue {
                    NotificationCenter.default.post(name: .moduleRearrange, object: nil, userInfo: ["id": id])
                }
                view.mouseUp(with: event)
                stop.pointee = true
            }
        }
    }
}

private class ModulePreview: NSStackView {
    private let imageView: NSImageView

    fileprivate init(id: String, icon: NSImage?) {
        self.imageView = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: Constants.Widget.height, height: Constants.Widget.height)))

        let size: CGSize = CGSize(width: Constants.Widget.height + (Constants.Widget.spacing * 2), height: Constants.Widget.height)
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))

        self.wantsLayer = true
        self.layer?.cornerRadius = 2
        self.layer?.borderColor = NSColor(red: 221/255, green: 221/255, blue: 221/255, alpha: 1).cgColor
        self.layer?.borderWidth = 1
        self.layer?.backgroundColor = NSColor.white.cgColor

        self.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
        self.setAccessibilityElement(true)
        self.toolTip = id

        self.orientation = .vertical
        self.distribution = .fill
        self.alignment = .centerY
        self.spacing = 0

        self.imageView.image = icon
        self.imageView.contentTintColor = self.isDarkMode ? .textBackgroundColor : .textColor

        self.addArrangedSubview(self.imageView)

        self.addTrackingArea(NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
            owner: self,
            userInfo: nil
        ))

        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: size.width),
            self.heightAnchor.constraint(equalToConstant: size.height)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.imageView.contentTintColor = self.isDarkMode ? .textBackgroundColor : .textColor
    }

    override func mouseEntered(with: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with: NSEvent) {
        NSCursor.arrow.set()
    }
}
