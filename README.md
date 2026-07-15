# Codex 可

一个只向 Codex 对话回复“可”的 macOS 悬浮按钮，光环只显示周额度。

## 安装

```bash
zsh scripts/build-release.sh
zsh scripts/install-local.sh
```

安装后只授予“辅助功能”权限，然后在 Codex `/hooks` 中审查并信任
`codex-quick-ok`。新开或恢复一个 Codex 任务后，Hook 才会产生状态。

## 使用

- 任务运行或等待批准时显示；完全空闲时隐藏。
- 单击会切换到最近待批准任务并发送一次“可”。
- 拖动超过 5 pt 只移动按钮；右键可看周额度、刷新、隐藏或退出。
- 灰色光环表示官方接口暂未提供明确周额度，不代表额度为零。

## 安全边界

原生审批卡片不受支持；输入框已有草稿时不会覆盖或发送；目标无法唯一确认时安全失败。

## 卸载

```bash
zsh scripts/uninstall-local.sh
```
