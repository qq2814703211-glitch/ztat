import AppKit
import ZtatCore

@MainActor
enum StatusMenuBuilder {
    static func makeMenu(
        version: String,
        settingsTarget: AnyObject?,
        settingsAction: Selector?,
        localization: Localization,
        updateTarget: AnyObject? = nil,
        updateAction: Selector? = nil,
        // ZTAT-PATCH: Support injecting host context menu items (e.g. PowerGuard, Stats, Toolbox) and ztat branding.
        extraItems: [NSMenuItem] = []
    ) -> NSMenu {
        let menu = NSMenu()
        menu.userInterfaceLayoutDirection =
            localization.resolvedLanguage.nsLayoutDirection

        let versionItem = NSMenuItem(
            title: "\(ZtatBrand.appName) \(version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        if !extraItems.isEmpty {
            menu.addItem(.separator())
            for item in extraItems {
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if let updateAction {
            let updateItem = NSMenuItem(
                title: localization.string(.menuCheckForUpdates),
                action: updateAction,
                keyEquivalent: ""
            )
            updateItem.target = updateTarget
            menu.addItem(updateItem)
        }

        let settingsItem = NSMenuItem(
            title: localization.string(.menuSettings),
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.target = settingsTarget
        settingsItem.isEnabled = settingsAction != nil
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitTitle = localization.resolvedLanguage.isChinese
            ? "退出 \(ZtatBrand.appName)"
            : "Quit \(ZtatBrand.appName)"
        let quitItem = NSMenuItem(
            title: quitTitle,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)

        return menu
    }
}
