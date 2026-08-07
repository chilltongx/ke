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
| 4 | Codex 空 composer 输入并发送一次“可” | PENDING (manual) |
| 5 | Codex 闲置后占位符仍视为空 | PENDING (manual) |
| 6 | VS Code 侧边栏聊天空 composer 输入并发送一次“可” | PENDING (manual) |
| 7 | VS Code 编辑器、终端和搜索框闪红且无输入 | PENDING (manual) |
| 8 | 微信测试会话空消息框输入并发送一次“可” | PENDING (manual) |
| 9 | 微信搜索框闪红且无输入 | PENDING (manual) |
| 10 | 三个应用已有草稿时内容不变且不发送 | PASS (automatic) |
| 11 | 点击期间切换焦点时不投递 Enter | PASS (automatic) |
| 12 | 未知应用只有明确聊天语义时允许 | PASS (automatic) |
| 13 | Enter 配置为换行时不改用其他快捷键 | PENDING (manual) |
| 14 | 重复点击最多执行一次发送 | PASS (automatic) |
| 15 | 周额度不可用时光环为灰色且按钮可点击 | PASS (automatic) |
| 16 | 拖动超过 5 pt 不发送 | PASS (automatic) |
| 17 | 退出后重新登录系统不会自动启动 | PENDING (manual) |
| 18 | 旧版登录项在 build 4 首次启动后被注销 | PASS (automatic) |
| 19 | 同一签名身份升级后 Accessibility 授权保持有效 | PENDING (manual) |
| 20 | 卸载只删除本应用、旧 plugin 和自有支持目录 | PASS (automatic) |
| 21 | 从其他应用切回 Codex，不点击 composer，单击“可”后发送一次 | PENDING (manual) |
| 22 | Codex 首个可编辑元素为明确搜索框时闪红且不输入 | PENDING (manual) |
| 23 | VS Code 和微信没有输入焦点时不启用 Codex 自动扫描 | PENDING (manual) |
| 24 | Codex 任务完成且最终回复明确等待确认时，约 3 秒内出现琥珀色呼吸光晕 | PENDING (manual) |
| 25 | 普通完成回复不会触发琥珀色光晕 | PASS (automatic) |
| 26 | 等待确认后发送新回复，琥珀色光晕自动消失 | PENDING (manual) |
| 27 | 启用“减少动态效果”时，等待确认光晕常亮且不闪动 | PASS (automatic) |
| 28 | 临时隐藏按钮后，等待确认轮询不会擅自重新显示按钮 | PASS (automatic) |

微信只能使用测试联系人或“文件传输助手”，VS Code 和 Codex 只能使用专门测试会话。
不得向真实联系人、工作群或生产任务执行发送验收。自动化 probe 只能写入“探针”再清空，
不得调用 Enter；真实发送只允许由用户亲自点击悬浮按钮验证。
