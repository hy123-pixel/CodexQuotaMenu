# Changelog

## Unreleased

- 将菜单栏状态项调整为原生 `NSStatusItem`，参考 MemoryBar 的整体布局，让图标和额度文本保持水平居中。
- 保留 SwiftUI 额度面板和原有刷新逻辑。

## 0.1.0 - 2026-09-28

- 创建 macOS Codex 用量菜单栏工具。
- 支持 5 小时额度和周额度。
- 支持 app-server 通知优先和多档刷新间隔。
- 增加本地缓存、手动刷新和登录启动。
- 增加统一图标、状态栏标识和 `.icns` 素材。
- 兼容新版、旧版、Homebrew、PATH 和常见用户级安装的 Codex CLI 路径。
- 整理为标准 Xcode 工程并补充 Swift Package 测试。
