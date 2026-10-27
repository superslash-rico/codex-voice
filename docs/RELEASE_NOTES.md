# Codex 语音提醒 v0.9.2-approval.1

修复 Computer Use 的“允许 ChatGPT 使用某个应用”没有审批提醒的问题。本次发布与本机已验证的修复版使用同一应用构建。

## 本次更新

- 新增 **提醒设置 → Computer Use 授权提醒**。**默认关闭，升级后请按需手动开启**，并允许本软件的辅助功能/设备控制权限。
- 只读识别 Codex 已打开窗口中的真实应用授权卡片，沿用原有声音、电脑/工牌输出、次数、暂停和免打扰。
- “已接手”只停止提醒；允许或拒绝仍由你在 Codex 中完成。
- 同一卡片不重复添加，卡片离开后清理提醒；界面来源的旧卡片不在重启后恢复。
- 后台线程限制读取范围和等待时间，跳过编辑框，不保存聊天正文或截图，不代点审批。
- 保留昵称、扬声器、规则、登录自启及已有 Codex 连接；AI Passport 固件继续使用0.3.0-pets，已有工牌无需重新刷写。

## 下载与升级

推荐 `CodexVoice-0.9.2-approval.1-universal.dmg`，也提供 ZIP、校验文件和完整工牌指南。配套固件及固件 ZIP 与上一版逐字节一致。

退出旧版，替换 `/Applications/Codex 语音提醒.app`，重新打开。临时签名更新可能使原辅助功能授权失效；请在系统“设备控制和数据访问/辅助功能”移除旧项，重新添加当前同名应用并开启。

[完整使用说明](https://github.com/superslash-rico/codex-voice/blob/v0.9.2-approval.1/README.md) · [授权识别说明](https://github.com/superslash-rico/codex-voice/blob/v0.9.2-approval.1/docs/APPROVAL_COMPATIBILITY.md) · [验证记录](https://github.com/superslash-rico/codex-voice/blob/v0.9.2-approval.1/docs/VALIDATION.md)

本工具免费使用。ChatGPT / Codex 订阅及充值说明可访问 [slashx.shop](https://slashx.shop/)，为第三方可选服务，非 OpenAI 官方网站。

## 验证与边界

199项 Python 测试、原生卡片匹配/生命周期及已有协议/音频/宠物/剪贴板检查通过；应用签名、移动路径和隔离运行通过。本机真实计算器访问授权已记录审批语音播放，用户确认听到并接手。

目前只覆盖 Codex 已打开窗口中的应用授权卡片，未展开的后台聊天、其他客户端和未来界面版本暂不保证覆盖。普通命令审批仍走原有事件流程。

macOS 13+，含 arm64 / x86_64；工牌听写仍需 macOS 26+ 和本机中文模型。Intel 和旧系统尚未实机验收。**仍为未完成 Apple Developer ID 签名与公证的测试版**，首次打开先核对来源与 SHA-256，再按系统安全提示操作。
