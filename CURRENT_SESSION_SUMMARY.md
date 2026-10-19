# CodexQuotaMenu 当前会话整理

生成时间：2026-10-19 18:20（Asia/Shanghai）

这份文档整理本次会话中关于 Codex 用量菜单栏工具的需求、实现、问题修复、验证结果和当前文件位置。文档不包含认证 token、API Key 或其他敏感凭证，也不包含模型内部推理过程。

## 1. 需求演进

本次会话的需求按时间顺序如下：

1. 制作一个 macOS 菜单栏小工具，监控 Codex 当前的 5 小时额度和周额度。
2. 数据直接从本机 Codex 获取，不重复实现登录、不额外请求另一套服务。
3. 补充应用图标、状态栏图标和相关视觉素材。
4. 刷新时间需要可调：
   - 跟随 Codex（智能）
   - 30 秒
   - 1 分钟
   - 3 分钟
   - 5 分钟
   - 10 分钟
5. 将散落输出整合成一个完整工程目录，并提供标准 Xcode 工程，而不是只有多个压缩包或散落文件。
6. 处理菜单中出现“实时读取失败”的问题。
7. 增强不同 ChatGPT/Codex CLI 安装路径的兼容性。
8. 将整合后的项目移动到 `/Users/dt/Desktop/Sync/Product/` 目录下。
9. 将本次会话内容整理成当前 Markdown 文档。

## 2. 最终功能

### 2.1 额度显示

- 5 小时额度：显示已使用百分比、剩余百分比和预计重置时间。
- 周额度：显示已使用百分比、剩余百分比和预计重置时间。
- 菜单栏状态项显示简要的 5 小时和周额度剩余值。
- 高用量时使用橙色或红色提示。

### 2.2 数据来源

工具直接启动本机的 Codex CLI app-server，并通过 JSON-RPC 读取额度：

```text
codex app-server --stdio
```

协议流程：

1. 发送 `initialize`。
2. 发送 `initialized` 通知。
3. 调用 `account/rateLimits/read`，参数为 `null`。
4. 监听 `account/rateLimits/updated` 通知。
5. 将稀疏通知合并到最新的完整额度快照。

额度窗口映射：

| Codex 字段 | 工具含义 |
| --- | --- |
| `primary`，`windowDurationMins = 300` | 5 小时额度 |
| `secondary`，`windowDurationMins = 10080` | 周额度 |
| `usedPercent` | 已使用百分比 |
| `resetsAt` | Unix 时间戳形式的重置时间 |

工具不会读取或保存 Codex 认证 token，也不要求用户填写 API Key，不会建立第二套 ChatGPT 登录流程。应用运行期间复用一个 app-server 进程。

### 2.3 刷新策略

“跟随 Codex（智能）”模式采用：

- Codex 发出 `account/rateLimits/updated` 通知时立即更新。
- 没有通知时每 30 秒进行一次兜底读取。

用户也可以手动选择 30 秒、1 分钟、3 分钟、5 分钟或 10 分钟。刷新选项会持久化到本机偏好设置。

### 2.4 缓存与启动

- 最近一次成功读取的快照保存到 `UserDefaults`。
- 实时读取失败时继续显示缓存，并明确标记为缓存数据。
- 支持手动刷新。
- 支持“登录时自动启动”。
- 支持“打开 Codex”按钮。

## 3. 实现结构

当前项目是一个标准 macOS Swift 工程，主入口为 `CodexQuotaMenu.xcodeproj`，同时保留 `Package.swift` 作为 Swift Package 入口。

```text
CodexQuotaMenu/
├── CodexQuotaMenu.xcodeproj/
├── CodexQuotaMenu.app/
├── Package.swift
├── project.yml
├── Info.plist
├── README.md
├── Assets/
│   ├── CodexQuotaMenu.xcassets/
│   ├── CodexQuotaMenuIcon-1024.png
│   ├── CodexQuotaMenuIcon-source.png
│   └── CodexQuotaMenuIcon.icns
├── Sources/
│   ├── CodexQuotaCore/
│   │   ├── CodexAppServerClient.swift
│   │   └── QuotaModels.swift
│   └── CodexQuotaMenu/
│       ├── CodexQuotaMenuApp.swift
│       └── QuotaStore.swift
├── Tests/
│   └── CodexQuotaCoreTests/
│       └── QuotaModelsTests.swift
└── scripts/
    └── build_app.sh
```

### 3.1 核心文件

- `Sources/CodexQuotaCore/CodexAppServerClient.swift`
  - 管理 Codex app-server 进程。
  - 负责 JSON-RPC 请求、响应、通知和超时处理。
  - 负责定位本机 Codex CLI。
- `Sources/CodexQuotaCore/QuotaModels.swift`
  - 定义 5 小时和周额度模型。
  - 处理百分比边界保护、重置时间和稀疏更新合并。
- `Sources/CodexQuotaMenu/QuotaStore.swift`
  - 管理刷新任务、缓存、自动刷新开关、刷新频率和登录启动。
- `Sources/CodexQuotaMenu/CodexQuotaMenuApp.swift`
  - 原生 AppKit `NSStatusItem` 菜单栏应用和 SwiftUI 额度面板。
  - 包含额度卡片、状态栏标识、设置和错误状态。
- `Assets/`
  - 包含主图标、状态栏资源和 `.icns` 素材。

## 4. 实时读取失败问题

### 4.1 原因

最初的定位逻辑只检查旧版路径：

```text
/Applications/ChatGPT.app/Contents/Resources/codex
```

当前 ChatGPT 版本实际把 CLI 放到了新的目录结构中：

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
```

因此应用虽然有缓存，但无法定位本机 CLI，界面才会显示“找不到本机 Codex CLI”。

### 4.2 兼容修复

当前定位逻辑支持：

1. `CODEX_CLI_PATH` 环境变量。
2. ChatGPT 新版稳定包装入口：
   `Contents/Resources/codex-cli/bin/codex`。
3. ChatGPT 新版嵌套 App 内部二进制：
   `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`。
4. `codex-cli` 目录下未来可能出现的其他嵌套 CLI App。
5. 旧版：
   `Contents/Resources/codex`。
6. `/Applications/Codex.app` 和用户目录下的 ChatGPT/Codex App。
7. Homebrew 和 MacPorts 常见路径。
8. `PATH` 中的 `codex`。
9. 常见用户级 Node 安装目录，包括 npm、Volta、asdf、pnpm、nvm 和 fnm。

当前版本优先使用新版稳定包装入口，因为它负责转发到内部 CLI，避免菜单栏工具硬编码内部二进制结构。

## 5. 视觉与应用形态

- 原生 SwiftUI macOS 菜单栏应用。
- 使用原生 `NSStatusItem`，不显示普通 Dock 窗口。
- 使用自定义深蓝仪表盘风格图标。
- 状态栏使用专属 gauge mark。
- 应用图标由 PNG 素材生成 `.icns`。
- `Info.plist` 设置为 `LSUIElement` 状态栏应用。

## 6. 构建和验证

### 6.1 常用命令

在当前工程目录执行：

```bash
cd /Users/dt/Desktop/Sync/Product/CodexQuotaMenu
swift test
./scripts/build_app.sh
open CodexQuotaMenu.app
```

也可以直接用 Xcode 打开：

```bash
open /Users/dt/Desktop/Sync/Product/CodexQuotaMenu/CodexQuotaMenu.xcodeproj
```

### 6.2 已完成验证

- Swift Package 测试：3 个测试全部通过。
- 覆盖额度 JSON 解码、窗口映射、百分比边界保护、稀疏额度更新合并。
- Xcode 工程可以识别以下 targets：
  - `CodexQuotaCore`
  - `CodexQuotaMenu`
  - `CodexQuotaCoreTests`
- Xcode 工程可以识别 `CodexQuotaMenu` scheme。
- Release 构建成功。
- App 为 `x86_64` 和 `arm64` 通用二进制。
- `codesign --verify --deep --strict` 验证通过。
- 实际启动后的应用成功拉起本机 Codex app-server。
- 实际运行进程使用了新版 `codex-cli/bin/codex` 包装入口。
- 实时额度快照能够写入本机缓存。

兼容修复后的运行验证中，曾读取到以下快照值；这些数值只代表验证时刻，不代表当前额度：

```text
更新时间：2026-09-28T02:56:37Z
5 小时已使用：34%
周额度已使用：26%
套餐：plus
```

## 7. 当前文件位置

### 7.1 工程目录

当前正式工程目录为：

```text
/Users/dt/Desktop/Sync/Product/CodexQuotaMenu
```

标准 Xcode 工程：

```text
/Users/dt/Desktop/Sync/Product/CodexQuotaMenu/CodexQuotaMenu.xcodeproj
```

工程内附带的构建 App：

```text
/Users/dt/Desktop/Sync/Product/CodexQuotaMenu/CodexQuotaMenu.app
```

### 7.2 已安装并运行的 App

当前已安装并运行：

```text
/Applications/CodexQuotaMenu.app
```

该安装副本与工程内构建出的 App 内容一致。菜单栏工具运行期间会启动一个子进程：

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex app-server --stdio
```

### 7.3 旧位置和归档

整合工程已经从以下旧位置移出：

```text
/Users/dt/Documents/Codex/2026-09-08/bang/outputs/CodexQuotaMenu
```

旧压缩包、旧 App、构建缓存和临时素材没有直接删除，而是保留在原工作区的 `work/` 归档目录中，方便回溯。

## 8. 使用注意事项

1. 如果需要登录启动，建议使用 `/Applications/CodexQuotaMenu.app`，再打开菜单中的“登录时自动启动”。
2. 如果 ChatGPT/Codex 安装位置非常特殊，可以设置 `CODEX_CLI_PATH` 指向可执行文件。
3. “跟随 Codex（智能）”是 app-server 通知优先、30 秒兜底，并不是读取 ChatGPT 主窗口私有内存状态。
4. Codex CLI 的路径和 app-server 协议属于外部版本依赖，未来 CLI 更新后如果协议字段变化，需要重新检查 `CodexAppServerClient.swift` 和 `QuotaModels.swift`。
5. 构建脚本面向 macOS 13 或更高版本。

## 9. 会话最终状态

本次会话的最终结果是：

- 完成 Codex 5 小时和周额度菜单栏工具。
- 完成图标和视觉素材。
- 完成智能刷新和可选刷新间隔。
- 完成缓存、手动刷新和登录启动。
- 修复新版 ChatGPT CLI 路径导致的实时读取失败。
- 增强 ChatGPT/Codex CLI 多路径兼容性。
- 整理为标准 Xcode 工程目录。
- 移动到 `/Users/dt/Desktop/Sync/Product/CodexQuotaMenu/`。
- 当前安装版已运行并能实时读取本机 Codex 额度。
