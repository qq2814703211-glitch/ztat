# `ztat` 上游同步与二次开发规范 (Upstream Sync & Maintenance Handbook)

本文档定义 `ztat` 仓库如何**长期追踪、比对、同步四个上游项目更新**，以及如何**低冲突地新增需求或替换功能**。

---

## 1. 核心设计原则：分层隔离，永不混写

为了避免四路合并灾难，`ztat` 强制采用 **「上游模块层 + 适配胶水层 + 宿主壳层」** 三层隔离：

```text
Sources/ZtatApp/              ← 100% ztat 自有代码（主入口、统一面板、统一设置、品牌图标）
Packages/ZtatCore/            ← 100% ztat 自有基础库（事件总线、统一剪贴板轮询、身份常量、本地化桥）
Packages/ZtatPowerGuard/      ← 100% ztat 洁净室保活引擎与 ztat-hold CLI（融合 BudHold 交互理念 + Vorssaint 安全底座）
───────────────────────────────────────────────────────────────────────────────
Packages/ZtatStatusTrio/      ← 上游 status-trio 隔离模块（仅包含最小化补丁，注释标记 // ZTAT-PATCH:）
Packages/ZtatStats/           ← 上游 exelban/stats 纯 SPM 移植模块（注释标记 // ZTAT-PATCH:）
Packages/ZtatVorssaint/       ← 上游 vorssaint-utils 去重后模块（注释标记 // ZTAT-PATCH:）
```

### 黄金纪律（强制遵守）
1. **所有对上游文件的改动，必须在改动点上方添加 `// ZTAT-PATCH: <简述>` 注释**，并在 `upstreams.lock.json` 的 `ztatPatches` 列表中登记。同步上游前，一条 `rg "ZTAT-PATCH"` 即可精准定位所有本地改动。
2. **绝不直接把 `ztat` 的新业务塞进上游文件**：新增 UI、面板标签、跨模块联动一律写在 `Sources/ZtatApp/`、`Packages/ZtatCore/` 或各模块的 `*ZtatHost.swift` 独立适配文件中。
3. **跨模块通信走 `Packages/ZtatCore/` 协议与事件总线**：例如 Dynamic Island 联动保活开关，只依赖 `ZtatCore.PowerGuardBridge`，不让 `ZtatVorssaint` 直接耦合 `ZtatPowerGuard` 或 `ZtatStatusTrio` 内部实现。
4. **菜单栏铁律（Menu Bar Contract）**：
   - 仅 `ZtatStatusTrio` 拥有主 `NSStatusItem`（统一三合一状态图标，左键打开 `ztat` 统一面板）。
   - 仅 `ZtatStats` 拥有硬件监控指标 `NSStatusItem`（按用户开关显示，默认不展示多余图标）。
   - 其他任何模块（`ZtatPowerGuard`、`ZtatVorssaint` 及未来新模块）**默认禁止创建独立 `NSStatusItem`**，除非用户显式开启了"特别开启的独立菜单栏项"（如剪贴板实时预览）。
5. **命名空间铁律（Zero Collision Contract）**：
   - `ZtatStats` 的 `UserDefaults` 强制隔离在 `dev.ztat.app.stats`，所有 `NSStatusItem.autosaveName` 加 `ztat.stats.` 前缀，所有 `Notification.Name` 加 `ztat.stats.` 前缀。
   - `ZtatStatusTrio`、`ZtatVorssaint`、`ZtatPowerGuard` 各自独立为 SwiftPM target，所有 `internal` 符号天然隔离，对外仅暴露 `*Host` 门面。
6. **严禁引入闭源/无证代码**：`budhold` 仓库未提供开源 LICENSE，仅作功能与体验参考（`integrationMode: "clean-room-feature-reference"`），同步其新点子时须采用洁净室重写，禁止直接拷贝源码文件。

---

## 2. 上游锁文件：`upstreams.lock.json`

`upstreams.lock.json` 是 `ztat` 与四个上游同步状态的**唯一真相源**，记录：
- `url` / `branch` / `commit`（已同步的精确 SHA）/ `describe`（标签偏移）
- `license` 与 `integrationMode`
- `targetPath`（在 `ztat` 中的落盘位置）
- `excludedFeatures` / `excludedComponents`（被替代或裁掉的功能清单）
- `ztatPatches`（本仓库施加的性能优化与集成补丁摘要）

本地上游克隆缓存存放在 `.gitignore` 忽略的 `upstreams/<name>/` 中，绝不提交进 `ztat` 主仓库，保持主仓库历史清爽。

---

## 3. 日常同步上游更新的标准流程 (SOP)

使用 `scripts/sync-upstream.sh` 一站式完成检查、拉取、差异分析与锁定：

### 步骤 1：检查全部上游是否有新提交
```bash
./scripts/sync-upstream.sh fetch
./scripts/sync-upstream.sh status
```
输出会逐项显示每个上游的：
- 当前锁定 SHA（`upstreams.lock.json`）
- 上游远端最新 SHA（`origin/<branch>`）
- 落后提交数（`commits behind`）

### 步骤 2：审阅目标上游的变更清单与代码 Diff
以同步 `status-trio` 或 `stats` 或 `vorssaint-utils` 为例：
```bash
# 查看自上次同步以来的 commit 摘要与修改文件列表
./scripts/sync-upstream.sh diff status-trio

# 查看本地在目标模块上打过的所有 ZTAT-PATCH 标记点
./scripts/sync-upstream.sh patches status-trio
```

### 步骤 3：应用更新（按上游类型区分）
- **对于 `status-trio` / `stats` / `vorssaint-utils`（代码同步）**：
  1. 切出专用同步分支：`git checkout -b sync/<upstream>-<YYYYMMDD>`
  2. 过滤掉 `excludedFeatures` / `excludedComponents` 中的文件（如 `vorssaint-utils` 的 `Services/SystemMonitor`、`Services/Metrics`、`Services/FanControl`、`KeepAwakeManager`；`stats` 的 `Kit/lldb`、`Modules/Remote`、`*/widget.swift`）。
  3. 使用三路比对或增量同步：
     ```bash
     # 预览文件级新增/修改/删除计划（dry-run）
     ./scripts/sync-upstream.sh plan <name>
     ```
     将非冲突文件同步到对应 `Packages/Ztat*/`，对含 `// ZTAT-PATCH:` 标记的文件做三路合并保留优化与适配钩子。
  4. 如上游新增了与 `Status Trio` / `Stats` / `ZtatPowerGuard` 重叠的新能力，按《去重决策表》决定是屏蔽该重叠项还是保留更优实现。
- **对于 `budhold`（洁净室特性追踪）**：
  1. 仅查看 `./scripts/sync-upstream.sh diff budhold` 的 README/commit 摘要了解新功能点或 macOS 新版本兼容性策略。
  2. 如需吸收新功能，在 `Packages/ZtatPowerGuard` 中独立设计并实现，同时补充单元测试。

### 步骤 4：构建、测试与锁定新 SHA
```bash
# 全量编译 + 单元测试 + dyld weak-import 检查 + .app 打包验证
./scripts/verify.sh

# 验证全绿后更新 upstreams.lock.json 到最新 SHA
./scripts/sync-upstream.sh lock <name>

# 提交同步记录（规范 commit message）
git add -A
git commit -m "sync(<name>): update upstream to <short-sha> (<tag>)"
```

---

## 4. 新增需求或替换功能的开发规范

当你需要提出新需求或修改现有功能时，遵循以下规则：

1. **新增独立小工具 / 跨模块能力**：
   - 核心逻辑放 `Packages/ZtatCore/` 或新建 `Packages/Ztat<Feature>/`。
   - UI 接入 `Sources/ZtatApp/ZtatHubRootView.swift` 的对应标签页，禁止新增独立菜单栏图标。
2. **用更优秀的第 5 款开源软件替换 Vorssaint 某项现有功能**（例如未来替换截屏/剪贴板/窗口管理）：
   - 在 `upstreams.lock.json` 中新增第 5 个 upstream 条目。
   - 在 `Packages/ZtatVorssaint` 的 `excludedFeatures` 中禁用对应 `AppFeature`（并移除/关闭其后台服务）。
   - 在 `Packages/Ztat<NewTool>` 中封装新工具并暴露统一 `*Host` 门面给 `Sources/ZtatApp/`。
3. **性能优化提交规范**：
   - 任何涉及轮询间隔、事件监听、绘制缓存、内存释放的优化，须在 `ARCHITECTURE.md` 的性能优化台账中补充记录，并确保在 `Tests/` 中有对应回归用例。

---

## 5. Git 分支与 Commit 约定

- `main`：始终保持可编译、可打包、测试全绿的稳定状态。
- 分支命名：
  - `sync/<upstream>-<date>`：上游同步分支
  - `feat/<topic>`：新功能/新集成模块
  - `perf/<topic>`：CPU / 内存 / 渲染 / 启动性能优化
  - `fix/<topic>`：缺陷修复
- Commit 前缀：`sync(<upstream>):`、`feat(<module>):`、`perf(<module>):`、`fix(<module>):`、`docs:`、`build:`。
