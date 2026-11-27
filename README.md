# ztat

一款面向 Apple Silicon macOS 的统一、精致、高性能原生工具箱与系统状态中心。

`ztat` 基于 **Vorssaint** 二次开发，按「每个领域只保留最精致的专精实现」原则，将多款顶级 macOS 效率与系统工具深度原生融合、彻底去重并做系统级性能优化：

- **统一主菜单栏图标与基础状态** ← [`status-trio`](https://github.com/lingyired/status-trio)（三合一自适应图标 + 原生 Liquid Glass 弹层 + Wi-Fi / 蓝牙 & AirPods ANC / 电池与充电上限 / 音频设备 / 输入法 / DDC 显示控制）
- **硬件性能监控、Vitals 概览弹层与全功能任务管理器** ← [`exelban/stats`](https://github.com/exelban/stats) + 洁净室 `VitalsDashboard` / `ZtatTaskManager`（纯 SwiftPM 无 Xcode 移植，保留 Stats 多参数菜单栏可视化，点击直达原生 Vitals 风格硬件全景弹层，内置可替代 macOS 活动监视器的完整任务管理器与全局快捷键 `⌃⇧⎋`）
- **应用深度卸载与系统清理套件** ← `ZtatCleaner`（洁净室吸收 [`Pearcleaner`](https://github.com/alienator88/Pearcleaner) 全套核心工作流并替换 Vorssaint 基础卸载器：13 分类应用卸载与一键重置数据、22 路径孤立残留扫描与关联、纯 Swift Mach-O 32/64 位架构瘦身与语言包裁剪、26 项开发环境缓存/IDE 孤立工作区/Pip 管理、公开 API PKG 收据/18 类插件/Launchd 后台服务管理、7 条件深度文件搜索、废纸篓可逆还原历史、零空闲废纸篓哨兵、Finder 右键服务与 `ztat://` 深度链接）
- **原生灵动岛与锁屏小组件** ← [`Ebullioscopic/Atoll`](https://github.com/Ebullioscopic/Atoll)（纯 SwiftPM 无 Xcode 移植为 `ZtatIsland`，完整替换 Vorssaint 灵动岛：媒体播放/实时频谱与歌词、锁屏实时活动/天气/计时器、下拉终端、文件暂存架、日历、蓝牙/电量/亮度/音量 HUD、待机动画，原生融入统一设置与控制中心）
- **远控保活与物理熄屏挂机** ← `ZtatPowerGuard`（洁净室融合 [`budhold`](https://github.com/budwk/budhold) 体验与 Vorssaint 事件驱动安全引擎：一键合盖+关屏不休眠、物理 0% 熄屏挂机、帧缓冲防黑屏、低电量自动恢复休眠、`ztat-hold` CLI）
- **全能 macOS 效率工具箱** ← [`vorssaint-utils`](https://github.com/vorssaint/vorssaint-utils)（去重后保留全部独有精华：逐应用音量混音器 >100%、窗口布局/App Switcher/Dock 预览、防误退 `⌘Q`/`⌘W`、键鼠增强与 SuperKey、剪贴板历史/文件搁板/文本片段、截屏（预览弹窗默认关闭可开关）/录屏 GIF/OCR/取色器、定时垃圾清理/Homebrew/应用更新/端口管理、XDR 额外亮度等）

## 菜单栏设计

- **常态菜单栏极其克制**：仅展示 **Status Trio 三合一统一状态图标**（归属 `ztat`）与用户启用的 **Stats 硬件监控指标**。
- **零多余常驻图标**：不展示 Vorssaint、BudHold、Atoll 与 Pearcleaner 的独立菜单栏图标，全部收敛至点击 `ztat` 主图标后展开的原生 Liquid Glass 统一控制中心（`状态` / `保活` / `工具箱` / `监控` 四页无缝切换）与单侧栏统一设置窗口。

## 构建与安装（仅需 Xcode Command Line Tools，无需安装 Xcode.app）

```bash
# 编译 Release 并组装 dist/ztat.app 与 dist/ztat-hold
./scripts/build.sh

# 编译、本地签名并安装至 /Applications/ztat.app（同时支持 --dev 开发隔离版）
./scripts/build.sh --install

# 运行完整编译、单元测试与打包验证
./scripts/verify.sh
```

## 上游同步与维护

完整规范见 [UPSTREAM_SYNC.md](UPSTREAM_SYNC.md) 与 [ARCHITECTURE.md](ARCHITECTURE.md)：

```bash
./scripts/sync-upstream.sh fetch         # 拉取 5 个上游最新提交
./scripts/sync-upstream.sh status        # 查看当前锁定的 SHA 与落后提交数
./scripts/sync-upstream.sh diff stats    # 审阅某上游变更内容
./scripts/sync-upstream.sh patches       # 列出全部 ZTAT-PATCH 本地补丁点
./scripts/sync-upstream.sh lock stats    # 验证通过后更新 upstreams.lock.json
```

## 许可证

遵循 **GPL-3.0-or-later**（详见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。
