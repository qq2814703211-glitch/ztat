// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ZtatCore

/// Embedded PowerGuard panel hosted inside ztat's unified Liquid Glass menu bar hub (356pt width).
public struct PowerGuardPanelView: View {
    @ObservedObject private var coordinator: PowerGuardCoordinator
    @ObservedObject private var l10n = ZtatLocalizationStore.shared
    @State private var showOptions: Bool = false
    @State private var showLogs: Bool = false

    public init(coordinator: PowerGuardCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let _ = l10n.revision
        VStack(spacing: 10) {
            if coordinator.needsManualSleepRecovery {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(ZtatL10n.tr("上次退出未恢复合盖休眠", "Unclean exit left sleep disabled"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 4)
                    Button(ZtatL10n.tr("立即恢复", "Restore")) {
                        coordinator.disableAll()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(cardBackground(highlighted: true, accent: .orange))
            }
            heroCard
            durationRow
            quickActionsRow
            telemetryGrid
            optionsDisclosure
            logsDisclosure

            if let toast = coordinator.toastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.88))
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: coordinator.toastMessage)
        .animation(.easeInOut(duration: 0.18), value: showOptions)
        .animation(.easeInOut(duration: 0.18), value: showLogs)
        .onAppear {
            coordinator.setPanelVisible(true)
        }
        .onDisappear {
            coordinator.setPanelVisible(false)
        }
    }

    // MARK: - Hero Remote-Ready Card

    private var heroCard: some View {
        let active = coordinator.isAnyGuardActive
        let accent: Color = coordinator.isBlackoutActive
            ? .indigo
            : (coordinator.isClamshellLocked ? .orange : (active ? .green : .secondary))

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(active ? accent.opacity(0.22) : Color.primary.opacity(0.08))
                        .frame(width: 34, height: 34)
                    Image(systemName: heroIconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(active ? accent : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.currentSnapshot.summaryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let exp = coordinator.expirationDate {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let rem = max(0, Int(exp.timeIntervalSince(ctx.date)))
                            Text(ZtatL10n.tr("剩余 \(formatCountdown(rem))", "Remaining \(formatCountdown(rem))"))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(accent)
                        }
                    } else {
                        Text(active
                             ? ZtatL10n.tr("持续保活中 · 远程桌面与合盖就绪", "Active · Remote & Clamshell Ready")
                             : ZtatL10n.tr("一键开启合盖不休眠与远程保活", "One-click Remote-Ready Keep-Awake"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    coordinator.toggleRemoteReadyMode()
                } label: {
                    if coordinator.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 58, height: 26)
                    } else {
                        Text(active ? ZtatL10n.tr("全部停止", "Stop") : ZtatL10n.tr("一键保活", "Guard"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(active ? .white : .white)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(active ? Color.red.opacity(0.85) : Color.accentColor)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isBusy)
            }

            if coordinator.expirationDate != nil {
                HStack(spacing: 6) {
                    Text(ZtatL10n.tr("延长定时:", "Extend:"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    extendChip("+15m", seconds: 900)
                    extendChip("+1h", seconds: 3600)
                    extendChip("∞", seconds: nil)
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(cardBackground(highlighted: active, accent: accent))
    }

    private var heroIconName: String {
        if coordinator.isBlackoutActive { return "moon.stars.fill" }
        if coordinator.isClamshellLocked { return "laptopcomputer.slash" }
        if coordinator.isIdleKeepAwakeActive { return "bolt.shield.fill" }
        return "shield"
    }

    private func extendChip(_ label: String, seconds: TimeInterval?) -> some View {
        Button {
            if let seconds {
                coordinator.extendSession(by: seconds)
            } else {
                coordinator.setDuration(.infinite)
            }
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Duration Chips

    private var durationRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(ZtatL10n.tr("保活时长", "Duration"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    coordinator.toggleIdleKeepAwake()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: coordinator.isIdleKeepAwakeActive ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10.5))
                        Text(ZtatL10n.tr("仅防空闲休眠", "Idle Awake Only"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(coordinator.isIdleKeepAwakeActive ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                ForEach(PowerGuardDuration.allCases) { dur in
                    let selected = coordinator.selectedDuration == dur
                    Button {
                        coordinator.setDuration(dur)
                    } label: {
                        Text(dur.shortTitle)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? .white : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(cardBackground(highlighted: false, accent: .accentColor))
    }

    // MARK: - Clamshell & Blackout Quick Actions

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            actionTile(
                icon: coordinator.isClamshellLocked ? "lock.laptopcomputer" : "laptopcomputer",
                title: ZtatL10n.tr("合盖不休眠", "Clamshell Lock"),
                subtitle: coordinator.isClamshellLocked
                    ? ZtatL10n.tr("内核已锁定", "Kernel Locked")
                    : (coordinator.telemetry.isPasswordlessSudoReady
                       ? ZtatL10n.tr("免密就绪", "Ready (No PW)")
                       : ZtatL10n.tr("需管理员授权", "Admin Prompt")),
                isActive: coordinator.isClamshellLocked,
                accent: .orange,
                disabled: coordinator.isBusy
            ) {
                coordinator.toggleClamshellLock()
            }

            let brText = coordinator.telemetry.builtInBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            actionTile(
                icon: coordinator.isBlackoutActive ? "sun.min.fill" : "display",
                title: ZtatL10n.tr("物理熄屏 0%", "Blackout 0%"),
                subtitle: coordinator.isBlackoutActive
                    ? ZtatL10n.tr("按 Esc / ⌘⌥B 恢复", "Esc / ⌘⌥B to wake")
                    : ZtatL10n.tr("当前背光 \(brText)", "Backlight \(brText)"),
                isActive: coordinator.isBlackoutActive,
                accent: .indigo,
                disabled: false
            ) {
                coordinator.toggleBlackoutMode()
            }
        }
    }

    private func actionTile(
        icon: String,
        title: String,
        subtitle: String,
        isActive: Bool,
        accent: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? accent : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? accent : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(highlighted: isActive, accent: accent))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - 2x2 Live Hardware Telemetry

    private var telemetryGrid: some View {
        let t = coordinator.telemetry
        let brStr = t.builtInBrightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "N/A"
        let powerValue: String = {
            if let pct = t.batteryPercentage {
                return "\(pct)% · \(t.isOnACPower ? (t.isCharging ? ZtatL10n.tr("充电", "Chg") : "AC") : ZtatL10n.tr("电池", "Bat"))"
            }
            return ZtatL10n.tr("桌面交流电", "AC Desktop")
        }()

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            telemetryCell(
                icon: t.lidClosed ? "macbook.gen2" : "laptopcomputer",
                label: ZtatL10n.tr("盒盖状态", "Lid Sensor"),
                value: t.lidClosed ? ZtatL10n.tr("已合盖", "Closed") : ZtatL10n.tr("已打开", "Open"),
                tint: t.lidClosed ? .orange : .secondary
            )
            telemetryCell(
                icon: "cpu",
                label: ZtatL10n.tr("内核休眠锁", "Kernel Sleep"),
                value: t.sleepDisabledKernel ? "disablesleep 1" : ZtatL10n.tr("系统默认", "Default"),
                tint: t.sleepDisabledKernel ? .green : .secondary
            )
            telemetryCell(
                icon: t.displayAsleep ? "moon.zzz.fill" : "sun.max.fill",
                label: ZtatL10n.tr("显示与背光", "Display / BL"),
                value: "\(t.displayAsleep ? ZtatL10n.tr("睡眠", "Sleep") : ZtatL10n.tr("亮屏", "Awake")) · \(brStr)",
                tint: coordinator.isBlackoutActive ? .indigo : .secondary
            )
            telemetryCell(
                icon: t.isOnACPower ? "bolt.fill" : "battery.50",
                label: ZtatL10n.tr("电源与电池", "Power"),
                value: powerValue,
                tint: (!t.isOnACPower && (t.batteryPercentage ?? 100) <= coordinator.lowBatteryThreshold) ? .red : .secondary
            )
        }
    }

    private func telemetryCell(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(cardBackground(highlighted: false, accent: .accentColor))
    }

    // MARK: - Guard Options & Passwordless Sudo

    private var optionsDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                showOptions.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(ZtatL10n.tr("守护策略与免密授权", "Guard Policy & Sudoers"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    if coordinator.telemetry.isPasswordlessSudoReady {
                        Text(ZtatL10n.tr("免密已就绪", "No-PW"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showOptions {
                Divider().opacity(0.35).padding(.horizontal, 10)
                VStack(spacing: 7) {
                    optionToggle(ZtatL10n.tr("保持远程显存唤醒", "Keep Framebuffer Awake"), isOn: $coordinator.keepFramebufferAwake)
                    optionToggle(ZtatL10n.tr("合盖时自动 0% 背光", "Auto-Dim Built-in on Lid Close"), isOn: $coordinator.autoDimOnLidClose)
                    optionToggle(ZtatL10n.tr("允许仅屏幕空闲关闭", "Allow Display Idle Sleep"), isOn: $coordinator.allowDisplaySleep)
                    optionToggle(ZtatL10n.tr("退出 ztat 时恢复系统默认休眠", "Restore Sleep on Quit"), isOn: $coordinator.restoreSleepOnQuit)

                    HStack {
                        Toggle(ZtatL10n.tr("低电量自动断开保活", "Low-Battery Cutoff"), isOn: $coordinator.lowBatteryAutoRestore)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11))
                        Spacer()
                        if coordinator.lowBatteryAutoRestore {
                            Stepper("\(coordinator.lowBatteryThreshold)%", value: $coordinator.lowBatteryThreshold, in: 10...50, step: 5)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .controlSize(.mini)
                                .fixedSize()
                        }
                    }

                    Divider().opacity(0.25)

                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ZtatL10n.tr("最小权限免密 pmset (#uid)", "Least-Privilege pmset (#uid)"))
                                .font(.system(size: 11, weight: .medium))
                            Text(coordinator.telemetry.isPasswordlessSudoReady
                                 ? ZtatL10n.tr("已配置 /etc/sudoers.d/ztat-powerguard", "Configured at /etc/sudoers.d/ztat-powerguard")
                                 : ZtatL10n.tr("仅放行 disablesleep 0/1，免弹窗切换", "Allows only disablesleep 0/1 without prompts"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            coordinator.togglePasswordlessSudo()
                        } label: {
                            Text(coordinator.telemetry.isPasswordlessSudoReady
                                 ? ZtatL10n.tr("移除", "Remove")
                                 : ZtatL10n.tr("配置", "Setup"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(
                                        coordinator.telemetry.isPasswordlessSudoReady
                                            ? Color.red.opacity(0.15)
                                            : Color.accentColor.opacity(0.18)
                                    )
                                )
                                .foregroundStyle(coordinator.telemetry.isPasswordlessSudoReady ? .red : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.isBusy)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(cardBackground(highlighted: false, accent: .accentColor))
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Activity Logs

    private var logsDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                showLogs.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(ZtatL10n.tr("运行日志 (\(coordinator.logs.count))", "Activity Log (\(coordinator.logs.count))"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    if showLogs && !coordinator.logs.isEmpty {
                        Button(ZtatL10n.tr("清空", "Clear")) {
                            coordinator.clearLogs()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                    }
                    Image(systemName: showLogs ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showLogs {
                Divider().opacity(0.35).padding(.horizontal, 10)
                if coordinator.logs.isEmpty {
                    Text(ZtatL10n.tr("暂无事件记录", "No events recorded"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.logs.prefix(12)) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(entry.formattedTime)
                                    .font(.system(size: 9.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(entry.isWarning ? .orange : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(cardBackground(highlighted: false, accent: .accentColor))
    }

    // MARK: - Helpers

    private func cardBackground(highlighted: Bool, accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlighted ? accent.opacity(0.11) : Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(highlighted ? accent.opacity(0.32) : Color.primary.opacity(0.07), lineWidth: 0.8)
            )
    }

    private func formatCountdown(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
