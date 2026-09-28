# 贡献说明

感谢关注 CodexQuotaMenu。

## 开发环境

- macOS 13 或更高版本
- Swift 5.9 或更高版本
- Xcode

## 本地验证

提交前运行：

```bash
swift test
```

如果修改了 App 或资源，也可以运行：

```bash
./scripts/build_app.sh
```

## 提交建议

- 保持额度协议解析、菜单栏 UI 和构建配置的改动分离。
- 不要提交 `.build`、`DerivedData`、`.app` 或用户态 Xcode 文件。
- 不要提交 API Key、认证 token、个人配置或本机缓存。
- 提交信息应清楚说明行为变化和验证方式。
