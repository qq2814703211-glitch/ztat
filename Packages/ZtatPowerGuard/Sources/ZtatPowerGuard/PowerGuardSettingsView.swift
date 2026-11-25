// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ZtatCore

/// Settings pane for ZtatPowerGuard inside ztat's unified Settings window.
public struct PowerGuardSettingsView: View {
    @ObservedObject private var coordinator: PowerGuardCoordinator

    public init(coordinator: PowerGuardCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Form {
            Section(ZtatL10n.tr("保活与合盖守护", "Keep-Awake & Clamshell Guard")) {
                Picker(ZtatL10n.tr("默认保活时长", "Default Duration"), selection: $coordinator.selectedDuration) {
                    ForEach(PowerGuardDuration.allCases) { dur in
                        Text(dur.displayTitle).tag(dur)
                    }
                }

                Toggle(ZtatL10n.tr("保持远程桌面显存唤醒 (Framebuffer Guard)", "Keep Framebuffer Awake for Remote Desktop"), isOn: $coordinator.keepFramebufferAwake)
                Toggle(ZtatL10n.tr("合盖时自动关闭内建背光 (0%)", "Auto-Dim Built-in Display on Lid Close"), isOn: $coordinator.autoDimOnLidClose)
                Toggle(ZtatL10n.tr("仅保活系统时允许屏幕空闲关闭", "Allow Display Sleep During Idle Keep-Awake"), isOn: $coordinator.allowDisplaySleep)
                Toggle(ZtatL10n.tr("退出 ztat 时恢复系统默认休眠策略", "Restore Default Sleep Policy on Quit"), isOn: $coordinator.restoreSleepOnQuit)
            }

            Section(ZtatL10n.tr("低电量安全熔断", "Low-Battery Safety Cutoff")) {
                Toggle(ZtatL10n.tr("使用电池且低于阈值时自动停止保活", "Automatically Disable Guard Below Battery Threshold"), isOn: $coordinator.lowBatteryAutoRestore)
                if coordinator.lowBatteryAutoRestore {
                    Stepper(
                        ZtatL10n.tr("低电量阈值：\(coordinator.lowBatteryThreshold)%", "Battery Cutoff: \(coordinator.lowBatteryThreshold)%"),
                        value: $coordinator.lowBatteryThreshold,
                        in: 10...50,
                        step: 5
                    )
                }
            }

            Section(ZtatL10n.tr("物理熄屏快捷恢复", "Physical Blackout Recovery")) {
                LabeledContent(ZtatL10n.tr("全局快捷键", "Global Hotkey"), value: "⌘⌥B")
                LabeledContent(ZtatL10n.tr("紧急恢复键", "Emergency Restore"), value: ZtatL10n.tr("Esc / 键盘亮度增键 (F2)", "Esc / Brightness Up (F2)"))
                Text(ZtatL10n.tr(
                    "物理熄屏仅将内建屏幕背光归零，不会断电或挂起 GPU；若程序异常退出，下次启动会自动恢复上次保存的亮度。",
                    "Physical blackout only sets the built-in panel backlight to 0% without sleeping the GPU. Saved brightness is automatically recovered after any unclean exit."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(ZtatL10n.tr("最小权限免密授权与 CLI", "Least-Privilege Sudoers & CLI")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZtatL10n.tr("免密 pmset 规则", "Passwordless pmset Rule"))
                        Text(coordinator.telemetry.isPasswordlessSudoReady
                             ? ZtatL10n.tr("已安装于 \(ClamshellSudoEngine.sudoersPath)", "Installed at \(ClamshellSudoEngine.sudoersPath)")
                             : ZtatL10n.tr("未安装（切换合盖锁时会弹出系统认证框）", "Not installed (macOS authentication prompt required)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(coordinator.telemetry.isPasswordlessSudoReady
                           ? ZtatL10n.tr("移除规则", "Remove")
                           : ZtatL10n.tr("配置免密", "Install")) {
                        coordinator.togglePasswordlessSudo()
                    }
                    .disabled(coordinator.isBusy)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(ZtatL10n.tr("命令行工具 (ztat-hold)", "Command-Line Tool (ztat-hold)"))
                        .font(.subheadline.weight(.medium))
                    Text("ztat-hold status | on [--daemon] | off | blackout on|off | wake")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.refreshTelemetry()
        }
    }
}
