# Codex 可

一个只向 Codex 对话回复“可”的 macOS 悬浮按钮，光环只显示周额度。

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

从旧的 ad-hoc 签名版本迁移到 build 3 后，需要为“Codex 可”重新授予一次
“辅助功能”权限。之后只要保留同一签名身份，后续本地升级将使用稳定的应用身份。

安装后只授予“辅助功能”权限，然后在 Codex `/hooks` 中审查并信任
`codex-quick-ok`。新开或恢复一个 Codex 任务后，Hook 才会产生状态。

## 使用

- 任务运行或等待批准时显示；完全空闲时隐藏。
- 单击会切换到最近待批准任务并发送一次“可”。
- 拖动超过 5 pt 只移动按钮；右键可看周额度、刷新、隐藏或退出。
- 灰色光环表示官方接口暂未提供明确周额度，不代表额度为零。

## 安全边界

原生审批卡片不受支持；输入框已有草稿时不会覆盖或发送；目标无法唯一确认时安全失败。
签名初始化会生成临时私钥材料并在退出时删除，不输出私钥；它不会修改 Dock、
TCC、Hook、登录项或 Codex 会话数据。

## 卸载

```bash
zsh scripts/uninstall-local.sh
```
