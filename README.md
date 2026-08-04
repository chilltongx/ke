# 可

一个跟随当前光标、向空聊天输入框发送“可”的 macOS 悬浮按钮。光环只显示周额度。

## 安装

```bash
zsh scripts/setup-local-signing.sh
zsh scripts/build-release.sh
zsh scripts/install-local.sh
```

`setup-local-signing.sh` 只需运行一次：它在当前用户的登录钥匙串中创建
`Codex Quick OK Local Signing` 专用自签名身份，并使用 `security` 默认的用户
信任域，只添加
`codeSign` 策略信任，不修改管理员或系统信任。macOS 可能要求交互确认。
构建不会自动回退到 ad-hoc 签名；找不到该身份时会在编译前停止。

从旧的 ad-hoc 签名版本迁移到稳定签名 build 后，需要为“Codex 可”重新授予一次
“辅助功能”权限。之后只要保留同一签名身份，后续本地升级将使用稳定的应用身份。

安装后只授予“辅助功能”权限。

## 使用

- 点击 Dock 中的“Codex 可”，悬浮按钮立即出现并保持可见。
- 在 Codex、Visual Studio Code 侧边栏聊天、微信或其他受支持聊天应用中聚焦空输入框。
- 单击按钮后，应用确认当前焦点属于聊天框，写入“可”，再向同一应用发送 Enter。
- 已有草稿、代码编辑器、终端、搜索框、密码框和普通表单会闪红并拒绝操作。
- 发送统一使用 Enter；如果目标应用把 Enter 配置为换行，本工具也只会换行。
- 右键可查看周额度、刷新、隐藏或退出；隐藏后再次点击 Dock 图标恢复。
- 应用不会开机自启，也不依赖 Codex Hook。
- 灰色光环表示周额度暂不可用，不代表额度为零。

## 安全边界

原生审批卡片不受支持；输入框已有草稿时不会覆盖或发送；当前焦点无法安全确认为聊天框时失败。
发送前会再次确认前台应用、窗口、输入框和内容未变化；不会自动切换到其他应用。
签名初始化会生成临时私钥材料并在退出时删除，不输出私钥；它不会修改 Dock、
TCC、登录项或 Codex 会话数据。

## 卸载

```bash
zsh scripts/uninstall-local.sh
```

## 许可证

[MIT License](LICENSE)
