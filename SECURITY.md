# 安全说明

## 支持版本

通常只维护最新 Release。旧版本可能不再兼容当前 ChatGPT/Codex CLI 的路径或 app-server 协议。

## 报告安全问题

如果发现可能导致认证信息泄露、任意命令执行或本地数据暴露的问题，请不要在公开 Issue 中粘贴 token、日志凭证或完整的本机路径信息。

请优先通过 GitHub 的私密安全报告功能提交：

<https://github.com/hy123-pixel/CodexQuotaMenu/security/advisories/new>

报告中请包含复现步骤、受影响版本和必要的最小日志片段。工具本身不要求用户输入 API Key，也不会读取或保存 Codex 认证 token。
