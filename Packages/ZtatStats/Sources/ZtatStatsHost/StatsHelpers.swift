//
//  StatsHelpers.swift
//  ZtatStatsHost
//
//  ZTAT-PATCH: Replaced upstream Stats/helpers.swift AppDelegate extension (which pulled in
//  Updater/SetupWindow/SupportWindow/AppIcon) with a minimal macOS 26/27 status bar compatibility
//  helper and internal module list accessor owned by ZtatStatsHost.
//

import AppKit
import ObjectiveC
import StatsKit

/// Internal reference to the active Stats modules managed by `ZtatStatsHost.shared`.
/// Kept internal so upstream-ported `SettingsWindow`, `CombinedView`, and `ApplicationSettings`
/// access the single source of truth without global mutable startup state.
internal var modules: [Module] = []

/// Workaround for the WindowServer "Invalid window" log spam on macOS Tahoe (26/27).
/// Overrides `-[NSStatusBarWindow _needsTilingConstraintUpdate]` to return `false`
/// (a status bar window can never be tiled) while leaving all other windows untouched.
internal enum ZtatStatsStatusBarWorkaround {
    private static var applied = false

    static func suppressStatusBarTilingConstraintUpdates() {
        guard !applied else { return }
        applied = true
        guard #available(macOS 26.0, *) else { return }
        let selector = NSSelectorFromString("_needsTilingConstraintUpdate")
        guard let cls = NSClassFromString("NSStatusBarWindow"),
              let method = class_getInstanceMethod(cls, selector) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
}
