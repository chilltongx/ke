# Manual Verification — Build 4

## Automatic evidence

| Check | Expected |
| --- | --- |
| `swift test` | 0 failures |
| `zsh Tests/PackagingTests.sh` | Packaging static checks passed. |
| `zsh Tests/AppIconTests.sh` | App icon renderer checks passed. |
| `zsh Tests/SigningTests.sh` | Stable signing checks passed. |
| `codesign --verify --deep --strict 'dist/Codex 可.app'` | exit 0 |
| Bundle version | `4` |

## Manual acceptance

| ID | Check | Initial status |
| --- | --- | --- |
| 1 | 点击 Dock 冷启动后按钮立即出现 | PENDING (manual) |
| 2 | 没有运行中 Codex 任务时按钮仍保持可见 | PENDING (manual) |
| 3 | 隐藏按钮后再次点击 Dock 可恢复 | PENDING (manual) |
| 4 | Codex 已在前台时发送到 focused window | PENDING (manual) |
| 5 | 其他应用在前台时激活最近使用的 Codex 窗口并发送 | PENDING (manual) |
| 6 | 多个 Codex 窗口时不跳转任务 | PENDING (manual) |
| 7 | 非空草稿保持原样且不发送 | PASS (automatic) |
| 8 | 原生审批卡片存在时不发送聊天文字 | PASS (automatic) |
| 9 | 重复点击最多执行一次发送 | PASS (automatic) |
| 10 | Codex 未运行时显示失败且不启动 Codex | PASS (automatic) |
| 11 | 周额度不可用时光环为灰色且按钮可点击 | PASS (automatic) |
| 12 | 拖动超过 5 pt 不发送 | PASS (automatic) |
| 13 | 退出后重新登录系统不会自动启动 | PENDING (manual) |
| 14 | 旧版登录项在 build 4 首次启动后被注销 | PASS (automatic) |
| 15 | 同一签名身份升级后 Accessibility 授权保持有效 | PENDING (manual) |
| 16 | 卸载只删除本应用、旧 plugin 和自有支持目录 | PASS (automatic) |

真实发送只在用户选定的 Codex 当前任务输入框为空时执行一次。自动化验证不得代替用户点击
悬浮按钮，以免在正在运行的任务中注入额外消息。
