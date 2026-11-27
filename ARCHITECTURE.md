# `ztat` 系统架构与去重优化设计

`ztat` 是一款基于 `vorssaint-utils` 深度二次开发、整合 `status-trio`、`exelban/stats`、`Ebullioscopic/Atoll`（原生灵动岛 `ZtatIsland`）以及洁净室重构的 `ZtatPowerGuard`（吸收 `budhold` 核心交互理念）的统一 macOS 原生菜单栏工具箱。

---

## 1. 模块依赖拓扑

```text
                        ┌──────────────────────────────────────────────┐
                        │               Sources/ZtatApp                │
                        │      统一入口 · Liquid Glass 中心面板        │
                        │      统一设置窗口 · ztat 品牌与签名          │
                        └──┬─────────┬──────────┬──────────┬────────┬──┘
                           │         │          │          │        │
        ┌──────────────────▼┐ ┌──────▼─────┐ ┌──▼──────┐ ┌─▼──────┐ ┌▼────────────────┐
        │ ZtatStatusTrio    │ │ ZtatStats  │ │ Ztat    │ │ Ztat   │ │ ZtatVorssaint   │
        │ (Swift 6)         │ │ (Swift 5)  │ │ Power   │ │ Island │ │ (Swift 5.9)     │
        │ 唯一主菜单栏图标   │ │ 硬件监控   │ │ Guard   │ │ (Atoll)│ │ 去重全能工具箱  │
        │ 原生毛玻璃弹层     │ │ 菜单栏指标 │ │ (Swift6)│ │ 灵动岛 │ │ 混音/窗口/键鼠等│
        │ Wi-Fi/BT/音频/电  │ │ 纯SPM无DB  │ │ 保活黑屏│ │ 锁屏等 │ │ 无独立菜单栏图标│
        └────────┬──────────┘ └──────┬─────┘ └──┬──────┘ └─┬──────┘ └────────┬────────┘
                 │                   │          │          │                 │
                 └───────────────────┴──────────┴────┬─────┴─────────────────┘
                                                     ▼
                                            ┌────────────────┐
                                            │    ZtatCore    │
                                            │ 身份/事件总线   │
                                            │ 共享剪贴板轮询  │
                                            │ 保活桥接协议    │
                                            └────────────────┘

Companion CLI: Packages/ZtatPowerGuard/Sources/ZtatPowerGuardCLI (ztat-hold) ──▶ ZtatPowerGuard
```

---

## 2. 功能去重与替换矩阵

| 功能域 | 原 Vorssaint 实现 | `ztat` 最终采用方案 | 菜单栏展示方式 |
|---|---|---|---|
| **主菜单栏图标与基础状态**（Wi-Fi/电池/音量/蓝牙/AirPods ANC/输入法/DDC外接音亮） | Vorssaint 品牌图标 + 基础电量/音频/输入法提示 | **替换为 `ZtatStatusTrio`**（三槽位自适应图标 + Liquid Glass 弹层 + 完整 AirPods/FreeBuds/DDC 控制） | **保留为 `ztat` 唯一主菜单栏图标** |
| **硬件性能监控**（CPU/GPU/RAM/Disk/Net/Battery/Sensors/Fans/BT/Clock） | Vorssaint `.monitor` 组（8 项 + `SystemMonitor` + `FanControlHelper` + 15 个菜单栏指标项） | **完全替换为 `ZtatStats`**（纯 SPM 移植版 `exelban/stats`，9 大模块 + 14 种可视化控件 + Combined 模式） | **仅按用户开关在菜单栏显示 Stats 指标** |
| **防休眠 / 合盖不休眠 / 熄屏挂机** | Vorssaint `KeepAwakeManager` + `LidDisplayDimmer` | **融合升级为 `ZtatPowerGuard`**（Vorssaint 安全底座 + BudHold 式一键远控保活、物理 0% 熄屏挂机、帧缓冲唤醒、实时诊断网格、日志与 `ztat-hold` CLI） | **无独立菜单栏图标**，内嵌于 `ztat` 统一面板「保活」页及顶栏快捷胶囊 |
| **逐应用音量混音 (>100%) / 音频优先级 / 麦克风静音 / Music 拦截** | Vorssaint `.sound` | **保留 `ZtatVorssaint`**（与 Status Trio 的系统音量互补） | 内嵌于统一面板「工具箱」页（静音徽标可选） |
| **窗口布局 / App Switcher / Dock 预览与点击 / 防误退 `⌘Q`/`⌘W`** | Vorssaint `.windowsDock` | **保留 `ZtatVorssaint`** | 内嵌于统一面板「工具箱」页 |
| **键鼠增强（平滑滚动/侧键/中键/SuperKey/文本片段/防抖）** | Vorssaint `.mouseKeyboard` | **保留 `ZtatVorssaint`** | 内嵌于统一面板「工具箱」页 |
| **剪贴板历史 / 纯文本粘贴 / 文件搁板 / Finder 增强 / URL 清理 / DMG 安装器** | Vorssaint `.clipboardFiles` | **保留 `ZtatVorssaint`**（合并重复剪贴板定时器） | 内嵌于统一面板「工具箱」页（剪贴板预览条默认关闭，可特别开启） |
| **灵动岛 Dynamic Island（媒体/歌词/实时活动/锁屏小组件/下拉终端/计时器/暂存架/蓝牙 HUD/待机动画）** | Vorssaint `.dynamicIsland`（13 个 `notch*` 特性） | **完全替换为 `ZtatIsland`**（纯 SPM 移植版 `Ebullioscopic/Atoll`，独立配置套件 `dev.ztat.app.island`，保活桥接 `ZtatPowerGuard`，锁屏小组件与全功能设置原生内嵌） | 仅屏幕刘海/锁屏交互，无额外菜单栏图标；可在统一面板与设置中控制 |
| **截屏标注 / 录屏+GIF / OCR / 取色器 / 媒体工具 / 命令栏 / 轮盘菜单 / 清洁模式** | Vorssaint `.tools` | **保留 `ZtatVorssaint`** | 内嵌于统一面板「工具箱」页 |
| **应用更新 / 定时垃圾清理 / Homebrew / 端口管理 / 进程查杀** | Vorssaint `.tools` | **保留 `ZtatVorssaint`**（与 `ZtatCleaner` 深度卸载互补） | 内嵌于统一面板「工具箱」页 |
| **应用深度卸载 / 孤立残留 / Mach-O 架构瘦身 / 语言包裁剪 / 开发环境 / PKG / 插件 / 后台服务 / 文件搜索 / 废纸篓哨兵** | Vorssaint 基础 `.uninstaller`（单应用拖放） | **完全替换为 `ZtatCleaner`**（洁净室重构，吸收 `Pearcleaner` 全套工作流，独立配置套件 `dev.ztat.app.cleaner`，CommandBar/工具箱/Finder Services/`ztat://` 原生桥接） | **无独立菜单栏图标**，内嵌于统一设置侧栏「应用清理与卸载」及菜单栏右键快捷入口 |
| **XDR 额外亮度 / 休眠断蓝牙** | Vorssaint `extraBrightness`, `bluetoothSleep` | **保留 `ZtatVorssaint`** | 内嵌于统一面板「工具箱」页 |

---

## 3. 菜单栏统一交互契约

- **常态菜单栏**：只显示两类元素：
  1. **Status Trio 统一三合一状态图标**（归属 `ztat` 主入口，支持点击展开统一面板、右键快捷操作、悬停展开、全局快捷键）
  2. **Stats 硬件监控指标**（支持单模块、多控件或 Combined 合并模式，零启用时菜单栏零额外占位）
- **左键点击 `ztat` 主图标** → 打开原生 Liquid Glass 无箭头统一面板（`AnchoredStatusPanel`，宽度 356pt，120Hz 平滑高度过渡，关闭 5 秒后自动回收 SwiftUI 视图树），顶部 4 个分段标签一键切换：
  1. **状态**（Status Trio 完整状态与控制 + 顶栏 `PowerGuard` 快捷状态胶囊）
  2. **保活**（`ZtatPowerGuard`：一键合盖+关屏不休眠、物理 0% 熄屏挂机、定时预设、2×2 实时硬件诊断、免密 `pmset` 配置、自动化策略与活动日志）
  3. **工具箱**（`ZtatVorssaint` 精选功能面板：混音器、快捷控制、实用工具、快捷开关、XDR 亮度、壁纸等）
  4. **监控**（`ZtatStats` 快捷控制台：一键开关 9 个监控模块、切换合并视图、暂停/恢复采集、打开完整监控设置）
- **特别开启项**：仅当用户在设置中显式开启（例如剪贴板菜单栏实时预览），才额外创建对应辅助项；`budhold` 与 `vorssaint` 品牌菜单栏图标永不显示。

---

## 4. 系统级性能优化台账

### Status Trio 渲染与事件优化 (`Packages/ZtatStatusTrio`)
1. **消除 `StatusIconRenderer.image` 双重光栅化与重绘开销**：模板图标预光栅化为 `NSImage(cgImage:)` 并设置 `isTemplate = true`，取消绘制回调里每次 Space 切换/重绘时的二次 2× 超采样光栅化（减少 50%+ 渲染负载）。
2. **消除 `StatusBarChargingFrameCache` 主线程 36 帧卡顿**：改为 `[CGImage?]` 懒加载按帧缓存，每 50ms tick 仅渲染当前缺失帧，彻底消除充电电量每次 +1% 时的主线程 72 次 `CGContext` 分配抖动。
3. **复用 `CGContext` 缓冲池 + 外向内边缘扫描**：`StatusIconRenderer` 复用暂存位图上下文（并在内存压力回调中释放）；光学墨迹居中扫描从左右边界向内遇墨即停。
4. **悬停模式全局 `.mouseMoved` 边界预过滤**：在事件回调阶段先用缓存的菜单栏高度带做快速拒绝，空闲桌面移动鼠标时降低 >95% CPU 唤醒。
5. **`DockVisibilityMonitor` 移出主线程**：当系统未开启 Dock 自动隐藏时直接跳过轮询；开启时将 `CGWindowListCopyWindowInfo` 移至后台工具队列。
6. **修复 `AirPodsSystemControls` 重复实例化 `Localization()`**，并彻底移除 `Sparkle` 与上游遥测心跳。

### Stats 纯 SPM 与采集优化 (`Packages/ZtatStats`)
7. **移除 LevelDB 静态库与 60s `fsync` 后台定时器**：替换为纯 Swift 轻量持久化存储 `StatsStoreCache`（仅在网络累计流量变动/退出时原子落盘），消除多 MB 内存占用与后台 SSD 写入。
8. **消除持续后台进程 fork**：将 `CPU/AverageLoadReader` 每 15 秒 fork `/usr/bin/uptime` 替换为纳秒级 POSIX `getloadavg()`；为 `Net/ConnectivityReader`（原每秒 ICMP/HTTP）和 `Disk/SMARTReader` 增加可见性/启用门控。
9. **延迟异步化 `SystemKit` 硬件发现**：取消启动路径同步 fork `system_profiler` 和 `diskutil`。
10. **量化 `Mini` 控件重绘比较**：按格式化后的整数百分比/展示值去重，消除浮点数尾数抖动导致的无效 `needsDisplay`。
11. **去重编译与完全隔离**：`SMC/smc.swift` 仅在 `StatsKit` 编译 1 次（原版编译 4 次）；合并 3 份重复 `IOReport` 桥接头文件为单一 `CStatsHardware`；`Store` 隔离至独立 `UserDefaults(suiteName: "dev.ztat.app.stats")`，杜绝 `reset()` 误清主应用配置；启用 `suppressStatusBarTilingConstraintUpdates()` 消除 macOS 26/27 WindowServer 约束刷屏日志。
12. **零空闲启动**：默认不创建 `AppIcon` 兜底图标、不自动弹出设置窗口。

### ZtatPowerGuard 引擎优化 (`Packages/ZtatPowerGuard`)
13. **纯事件驱动零空闲轮询**：使用 `IOServiceAddInterestNotification` (`IOPMrootDomain`) + `IOPSNotificationCreateRunLoopSource` + `NSWorkspace` 通知，彻底消除原版 BudHold 每 2.5 秒在主线程 fork `sudo -n pmset` 并重建整棵菜单树的性能黑洞。
14. **零泄漏断言与崩溃安全恢复**：复用并正确释放 `IOPMAssertionDeclareUserActivity` ID；不再派生易成孤儿进程的 `caffeinate`；落盘记录 `disablesleep` 归属与熄屏前亮度，崩溃重启后自动恢复；采用 `#uid` 最小权限 sudoers（仅放行 `disablesleep 0/1`）+ `visudo -cf` 校验；低电量/到期时调用 `IOPMSleepSystem` 重试确保合盖真休眠；内建屏精确锁定（`CGDisplayIsBuiltin`）+ 三层亮度 API 降级 + Carbon 热键/亮度键无障碍免授权恢复。

### Vorssaint 精简与内存/CPU 优化 (`Packages/ZtatVorssaint`)
15. **彻底裁剪重叠重型模块**：移除 `.monitor` 全部 8 个监控特性、`.dynamicIsland` 全部 13 个 `notch*` 特性、`SMCClient`、`FanControlHelper` root daemon、`MaxCapacityProbe`、`PeripheralBatterySampler`、`MenuBarRenderer` 与 15 个独立菜单栏指标项，大幅缩减二进制体积与常驻内存。
16. **延迟加载与事件收敛**：维护已启动服务登记表，消除 `applicationWillTerminate` 退出时凭空构造 22 个未启用单例；移除启动时急加载的 `MenuPanelView`；通过 `ZtatCore.SharedPasteboardMonitor` 合并 `ClipboardHistoryService` 与 `URLCleanerService` 重复的 0.8s 剪贴板定时器；节流 `Permissions.swift` 的全局 `UserDefaults.didChangeNotification` 扫描。

### ZtatIsland 原生灵动岛引擎与性能优化 (`Packages/ZtatIsland`)
17. **纯 Apple CLT / SwiftPM 移植与零冲突隔离**：独立 `CAudioBridge` ObjC++/C++20 频谱引擎、锁定 `SwiftTerm 1.10.0`（绕过 Xcode-only `xcrun metal` 阻塞）、源码编译 `lottie-ios` + 轻量 `LottieUIShim`、内联 `SkyLightOperator`/`OrderedSet`/`ZtatFullscreenDetector` 垫片、将 `Localizable.xcstrings`（1,603 词条/19 语种）无损转为 `.lproj` 表，并将 359 项 `Defaults.Keys` 隔离至独立套件 `dev.ztat.app.island`。
18. **空闲事件与子进程彻底收敛**：消除 `BluetoothAudioManager` 的全系统通配符 `DistributedNotificationCenter(name: nil)` 与无条件 3s 轮询；修复 `DownloadManager` 丢失的 Combine 订阅；延迟初始化日历/天气/内嵌监控/系统计时器/勿扰监听；修复 `AudioTap` 30Hz 定时器强引用；停止空闲状态 1Hz 悬停轮询；`stop()` 时同步恢复 `OSDUIHelper` 并精准终止所有子进程（`mediaremote-adapter.pl` / `log stream`），杜绝孤儿进程与系统 OSD 冻结。
19. **修复 Stats 菜单栏高度对齐**：将 `StatsKit/constants.swift` 的 `Constants.Widget.height` 从 `NSApp.mainMenu?.menuBarHeight`（刘海屏 33pt）修正为 `NSStatusBar.system.thickness`（22pt），解决加入标准主菜单后状态栏监控顶部拉高、底部裁切的问题。

### ZtatCleaner 原生应用卸载与深度清理套件 (`Packages/ZtatCleaner`)
20. **零空闲进程内哨兵与纯公开 API 架构**：废纸篓哨兵（`TrashSentinelMonitor`）采用进程内 CoreServices `FSEventStream` 且默认关闭（零空闲 CPU/内存开销，无需额外常驻 LaunchAgent）；PKG 收据管理器采用公开 `/var/db/receipts` + `/usr/bin/lsbom` 解析（零私有框架链接）；架构瘦身采用纯 Swift Mach-O 32/64 位 FAT 解析与原子切片替换（无需 Xcode `lipo`）。
21. **多层路径安全围栏与可逆废纸篓打包**：`SafePathGuard` 硬拦截全部系统根目录、用户主目录、核心 Library 根目录、`ztat` 应用本体、用户配置的扫描根目录以及 `.git` 源码仓库；全部清理操作打包移入带时间戳的废纸篓目录并保留最近 10 次可一键还原的持久化历史记录；`CleanerSettingsStore` 严格隔离于 `dev.ztat.app.cleaner`。
