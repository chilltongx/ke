# Manual Verification — Build 8

本清单是当前 macOS 本地包的发布门槛。`PASS (automatic)` 只表示对应的隔离测试已覆盖；
标为 `PENDING` 的项目在完成前不得宣称 Build 8 已通过完整实机验收。

## Automatic evidence

| Check | Expected | macOS CI |
| --- | --- | --- |
| `swift test` | 0 failures；实机 probe 默认跳过 | Yes |
| `zsh Tests/PackagingTests.sh` | Packaging static checks passed. | Yes |
| `zsh Tests/AppIconTests.sh` | App icon renderer checks passed. | Yes |
| `zsh Tests/SigningTests.sh` | Stable signing checks passed. | Yes，使用命令替身 |
| `codesign --verify --deep --strict 'dist/Codex 可.app'` | exit 0 | No，仅本地发布包 |
| Bundle version | 0.1.0 (8) | Yes，与 `Info.plist` 一致性检查 |

macOS CI 不运行真实发布构建，不读取登录钥匙串，不创建签名身份，也不安装、启动或卸载应用。
打包与安装行为测试只在临时目录和隔离的 `HOME` 中使用命令替身。

## Verification record

| Field | Value |
| --- | --- |
| Date / verifier | PENDING |
| macOS / hardware | PENDING |
| Codex version | PENDING |
| App SHA-256 | PENDING |
| Signing identity fingerprint | PENDING |

## Manual acceptance

| ID | Check | Status |
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
| 18 | 从历史旧版升级到 build 4 或更高版本后，遗留登录项被注销 | PASS (automatic) |
| 19 | 同一签名身份升级后 Accessibility 授权保持有效 | PENDING (manual) |
| 20 | 卸载只删除本应用、旧 plugin 和自有支持目录 | PASS (automatic) |
| 21 | 从其他应用切回 Codex，不点击 composer，单击“可”后发送一次 | PENDING (manual) |
| 22 | Codex 首个可编辑元素为明确搜索框时闪红且不输入 | PENDING (manual) |
| 23 | VS Code 和微信没有输入焦点时不启用 Codex 自动扫描 | PENDING (manual) |
| 24 | Codex 任务完成且最终回复明确等待确认时，约 3 秒内出现青色萤火微光 | PENDING (manual) |
| 25 | 普通完成回复不会触发青色萤火微光 | PASS (automatic) |
| 26 | 等待确认后发送新回复，青色萤火微光自动消失 | PENDING (manual) |
| 27 | 启用“减少动态效果”时，青色光条柔和常亮且不闪动 | PASS (automatic) |
| 28 | 临时隐藏按钮后，等待确认轮询不会擅自重新显示按钮 | PASS (automatic) |
| 29 | Codex 冷启动且 AX 窗口子树初始折叠时，启用增强辅助功能后在 2 秒内找到 composer，并且只发送一次 | PENDING (manual) |
| 30 | 准备捕获期间在同一 Codex PID 内切换窗口时，两边都不写入且不投递 Enter | PENDING (manual) |
| 31 | 第二次空草稿检查后、首个写入事件前出现晚到草稿时，草稿保持不变且不投递 Enter | PASS (automatic controlled race) |
| 32 | App Server 接收请求后永久静默时，请求按期限失败、所有 pending 被恢复，停止和后续重连均不挂起 | PASS (automatic) |
| 33 | 权限缺失、目标不受支持等失败只在按钮上显示约 4 秒红色反馈，并发出 VoiceOver 公告；不出现额外窗口或气泡 | PENDING (manual) |
| 34 | 新任务完成时，现有额度圆环最外缘微微发光三次，不叠加明显新圆环；同一任务回合后续轮询不重复提醒 | PENDING (manual) |
| 35 | 新任务被终止时沿用同一额度圆环外缘微光；多个任务同时结束时逐个提醒 | PENDING (manual) |
| 36 | 启用“减少动态效果”时，任务完成或终止改为短暂静态亮环并发出 VoiceOver 公告 | PASS (automatic) |
| 37 | 临时隐藏期间完成或终止的任务不擅自显示按钮，点击 Dock 恢复后依次提醒 | PASS (automatic) |

微信只能使用测试联系人或“文件传输助手”，VS Code 和 Codex 只能使用专门测试会话。
不得向真实联系人、工作群或生产任务执行发送验收。自动化 probe 只能写入“探针”再清空，
不得调用 Enter；真实发送只允许由用户亲自点击悬浮按钮验证。

第 18 项保留的是历史迁移回归门槛，不代表 Build 5 仍会重新启用旧版登录项设计。
