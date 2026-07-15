# Codex“可”悬浮按钮设计规格

- 日期：2026-07-15
- 项目名：CodexQuickOK（界面名称：Codex 可）
- 目标平台：当前 Mac（macOS 26.5.2）
- 目标 Codex 应用：Bundle ID `com.openai.codex`

## 1. 摘要

构建一个原生 macOS 悬浮小工具。当 Codex 有任务正在运行或等待用户批准时，它显示一个
可拖动的圆形“可”按钮；点击后自动切换到最近进入待批准状态的 Codex 会话，并直接发送
一次“可”。按钮外围的单层光环只表示 Codex 周额度，悬停显示剩余百分比和重置时间。

小工具以安全失败为默认行为：目标会话、Codex 输入框、周额度或辅助功能状态不明确时，
拒绝发送或把光环显示为灰色，不向其他应用输入文字，也不使用短周期额度替代周额度。

## 2. 目标与非目标

### 2.1 目标

- 把常见的“回复可并发送”缩短为一次点击。
- 仅在至少一个 Codex 会话运行中或等待批准时显示按钮，完全空闲时隐藏。
- 多会话时优先处理最近进入待批准状态的会话。
- 显示真实的 Codex 周剩余额度；数据不可用时明确显示灰色。
- 提供原生、轻量、可拖动、位置可恢复的悬浮体验。
- 限制权限与数据保存范围，并防止误发、重复发送和跨应用输入。

### 2.2 非目标

- 不自动批准所有 Codex 请求，也不绕过 Codex 或操作系统的审批机制。
- 不处理 Codex 原生安全审批卡片；本功能只向对话输入框回复“可”。
- 不回复“可”以外的文字，不提供自定义宏或全局快捷键。
- 不显示短周期、日额度或累计 token；只显示明确的七天额度窗口。
- 不读取或保存完整对话、API Key、ChatGPT 凭据或其他应用内容。
- 不申请完全磁盘访问、屏幕录制或管理员权限。

## 3. 用户体验

### 3.1 外观

- 使用已确认的 A“极简光环”方案：圆形深色按钮，中央显示“可”，外围为单层进度光环。
- 按钮默认直径约 64 pt，始终置于普通窗口上方，但不抢占键盘焦点。
- 周剩余额度大于 50% 时为青绿色，20%–50% 时为橙色，低于 20% 时为红色。
- 周额度缺失或不是明确七天窗口时，光环为灰色。
- 悬停提示显示“周额度剩余 X%”及本地时区的重置时间；无数据时显示“周额度暂不可用”。

### 3.2 显示状态

| 状态 | 可见性与反馈 |
| --- | --- |
| 完全空闲 | 隐藏 |
| 至少一个任务运行中 | 显示，光环轻微呼吸 |
| 至少一个任务等待批准 | 显示，增加柔和光晕 |
| 正在发送 | 光环短暂旋转并锁定重复点击 |
| 发送成功 | 轻闪绿色；若无其他活跃会话则隐藏 |
| 发送失败 | 闪红两次并显示原因；保留等待状态 |

### 3.3 输入行为

- 单击触发发送流程。
- 指针移动超过 5 pt 后按拖动处理，绝不发送；松手后保存显示器和相对位置。
- 右键菜单提供周额度详情、刷新额度、暂时隐藏和退出小工具。
- 右键菜单不提供“自动批准全部”。
- 若当前只有运行中会话、没有待批准会话，单击只闪红提示“暂无待批准会话”。

## 4. 系统架构

系统由 Codex 状态插件、原生 macOS 小工具和 Codex 适配层三个部分组成。

### 4.1 Codex 状态插件

插件使用官方 Codex Hooks，并订阅以下事件：

- `SessionStart`：注册会话，但不因此显示按钮。
- `UserPromptSubmit`：把对应 `session_id` 标记为 `running`。
- `Stop`：读取 `last_assistant_message`，在本机内存中判断是否为批准请求；随后只保存分类结果。

Hook 处理器写入：

```text
~/Library/Application Support/CodexQuickOK/sessions/<session_id>.json
```

状态文件只包含 `sessionId`、`state`、`updatedAt`、`waitingSince` 和可选的 `cwd`。文件以临时
文件加原子重命名更新，不保存 `last_assistant_message` 或 transcript 内容。插件处理器即使
找不到小工具，也必须在短时间内成功退出，不能阻塞 Codex。

插件以独立 Codex 插件安装，避免覆盖已有的 `~/.codex/hooks.json`。首次启用时，由用户在
Codex 的 Hooks 审查界面检查并信任该插件 Hook。

### 4.2 本地批准分类器

`Stop` Hook 使用确定性的本地规则，不调用模型或网络。它将以下类型的最后回复归为
`waitingForApproval`：

- 明确含有“可以吗”“是否继续”“请确认”“要我继续”“批准”等确认语句；
- 英文等价表达，例如 `proceed`、`approve`、`shall I continue`；

普通结果、说明性问题和没有批准意图的结束回复归为 `idle`。分类规则必须独立单元测试，
并允许后续增加词形而不修改状态存储或界面代码。误判时用户不点击即可；发送前仍有目标、
输入框和空草稿三道校验。

### 4.3 会话状态协调器

`SessionCoordinator` 监视状态目录，并维护 `session_id -> SessionState` 映射：

- 有任意 `running` 或 `waitingForApproval` 会话时显示按钮；否则隐藏。
- 目标选择只考虑 `waitingForApproval`，按 `waitingSince` 降序取最新一条。
- Codex 进程退出时立即隐藏并清空内存状态。
- 超过 12 小时没有更新的状态记录视为陈旧并清理，防止崩溃留下幽灵按钮。
- 发送成功后的 `UserPromptSubmit` 事件把该会话转回 `running`。

### 4.4 周额度客户端

`QuotaClient` 从已安装的 Codex 应用包解析其内置 `codex` 可执行文件，启动
`codex app-server --listen stdio://`，完成初始化后调用：

```json
{ "method": "account/rateLimits/read" }
```

额度选择规则是确定的：

1. 优先读取 `rateLimitsByLimitId["codex"]`，缺失时使用兼容字段 `rateLimits`。
2. 只在 `primary` 或 `secondary` 中选择 `windowDurationMins == 10080` 的七天窗口。
3. 剩余百分比为 `clamp(100 - usedPercent, 0, 100)`。
4. 没有精确七天窗口、未登录、App Server 失败或数据过期时，状态为 unavailable，光环变灰。

客户端监听 `account/rateLimits/updated`，并每五分钟及用户手动刷新时重新读取。它不直接读取
认证文件，不保存凭据，也不把短周期窗口当作周额度。

### 4.5 悬浮面板

`FloatingPanelController` 使用 `NSPanel` 创建无标题、透明、非激活式置顶面板。面板负责：

- 显示“可”按钮、额度光环、悬停提示和短反馈动画；
- 区分点击与拖动；
- 用 `UserDefaults` 持久化显示器标识及归一化位置；
- 显示右键菜单；
- 在发送过程中禁用重复点击。

### 4.6 Codex 会话导航适配层

`CodexSessionNavigator` 接收目标 `session_id`，并按以下顺序切换会话：

1. 使用当前 Codex 版本注册的 `codex://` 会话路由打开该会话，并验证前台应用的 Bundle ID。
2. 若该版本没有可验证的直接路由，读取 App Server 中对应会话的标题、工作目录和更新时间，
   再通过 Codex 自身的任务搜索界面精确选择。
3. 若无法唯一匹配目标会话，则停止，不退化为“当前随便一个 Codex 对话”。

导航细节封装在版本适配器中。Codex 更新导致路由或辅助功能结构变化时，只更换适配器；
状态、额度和悬浮界面不受影响。

### 4.7 安全发送器

`ApprovalSender` 只有在以下条件全部满足时才发送：

1. 目标会话仍是最近待批准会话。
2. 前台应用 Bundle ID 严格等于 `com.openai.codex`。
3. 已验证目标会话唯一匹配。
4. 找到可编辑的 Codex 对话输入框。
5. 输入框中没有用户未发送的草稿。

通过 macOS Accessibility API 直接设置输入框值为“可”，不借用系统剪贴板；然后执行一次发送
动作或 Return。两秒内收到同一 `session_id` 的 `UserPromptSubmit` 事件即视为成功。若结果
不确定，不自动重试，避免重复发送；按钮闪红并交由用户检查。

## 5. 数据流

### 5.1 运行与隐藏

```text
UserPromptSubmit Hook
  -> 原子更新会话状态为 running
  -> SessionCoordinator 收到文件变化
  -> 显示悬浮按钮
```

```text
Stop Hook
  -> 内存分类 last_assistant_message
  -> 保存 waitingForApproval 或 idle，不保存消息正文
  -> 有等待会话则保持显示，否则按所有会话状态决定显示或隐藏
```

### 5.2 点击发送

```text
单击
  -> 发送锁
  -> 选出最新 waitingForApproval session
  -> 激活 Codex 并切换精确会话
  -> 验证 Bundle ID、会话、输入框、空草稿
  -> 写入“可”并发送一次
  -> 等待 UserPromptSubmit 确认
  -> 成功反馈或安全失败反馈
```

### 5.3 额度刷新

```text
App Server account/rateLimits/read 或 updated
  -> 选择 codex 七天窗口
  -> 计算 100 - usedPercent
  -> 更新单层光环和悬停文本
```

## 6. 权限与隐私

### 6.1 所需权限

- 辅助功能：激活 Codex、操作任务导航和输入框。
- 登录项：小工具随 Mac 登录后台启动。
- 普通用户目录写权限：保存最小会话状态和界面偏好。
- 网络访问由官方 Codex App Server 负责，仅用于读取当前账号额度。

### 6.2 明确不需要

- 完全磁盘访问；
- 屏幕录制；
- 管理员或 root 权限；
- OpenAI API Key；
- 读取或修改其他应用的文本。

Accessibility 权限本身能力较强，因此所有输入前必须再次校验 Bundle ID、目标会话、输入框
可编辑性和空草稿。最高系统权限不是本项目的目标。

## 7. 安装、启动与卸载

- `.app` 首次启动显示简短引导，解释辅助功能权限、Hook 信任和登录项。
- 登录项默认启用；小工具后台常驻，但没有活动 Codex 会话时不显示面板。
- 插件单独安装和启用，保留用户已有 Hooks；若 Hooks 被全局禁用，界面说明原因并保持隐藏。
- 卸载时移除登录项、插件和 `CodexQuickOK` 状态目录，不修改其他 Codex 配置。

## 8. 异常处理

| 异常 | 行为 |
| --- | --- |
| Codex 未运行 | 隐藏按钮，不启动 Codex，不发送 |
| 没有待批准会话 | 闪红并提示，不发送 |
| 检测到 Codex 原生审批卡片 | 提示“不支持此类审批”，不向对话输入框发送 |
| 多个等待会话 | 选择 `waitingSince` 最新者 |
| 会话无法唯一导航 | 闪红并提示“不确定目标会话”，不发送 |
| 找不到或无法编辑输入框 | 闪红并提示，不发送 |
| 输入框已有草稿 | 闪红并提示“检测到未发送草稿”，不覆盖 |
| 辅助功能权限缺失 | 打开权限引导，不发送 |
| 发送结果不确定 | 不自动重试，保留等待状态 |
| 周额度缺失或非七天窗口 | 灰色光环，按钮发送功能不受影响 |
| App Server 断开 | 指数退避重连；额度保持灰色直到收到新数据 |
| Hook 状态陈旧 | 12 小时后清理；Codex 退出时立即清理 |

## 9. 测试策略

### 9.1 单元测试

- `ApprovalClassifier`：中英文批准表达、普通问句、普通结果和边界文本。
- `SessionCoordinator`：运行、等待、空闲、陈旧状态和多会话最新优先。
- `QuotaSelector`：精确七天窗口、短周期混入、多 bucket、缺失和越界百分比。
- `ClickDragRecognizer`：5 pt 阈值、重复点击锁和拖动位置恢复。
- `SafetyGate`：错误 Bundle ID、错误会话、非空草稿和不可编辑输入框。

### 9.2 集成测试

- 使用模拟 Hook 事件驱动悬浮面板显示和隐藏。
- 使用模拟 App Server 响应验证光环颜色、灰色回退和重置时间。
- 使用测试 Accessibility 树验证只操作 `com.openai.codex`。
- 模拟发送确认超时，验证不会自动重试。
- 模拟 Codex 更新后导航适配器失败，验证安全拒绝。

### 9.3 手动端到端测试

- Codex 开始任务后按钮出现，普通完成后隐藏。
- Codex 请求批准后按钮保持显示，单击切换并只发送一次“可”。
- 两个以上会话同时运行或等待时，选择最新待批准会话。
- 在其他应用前台时，单击后自动切换到 Codex。
- Codex 未运行、权限撤销、输入框已有草稿和额度断网时行为符合异常表。
- 拖动不发送，重启和多显示器切换后位置可恢复。

## 10. 验收标准

- 从单击到目标会话收到“可”通常不超过 1 秒；首次冷启动导航允许稍长但必须有反馈。
- 每次点击最多发送一条“可”，不自动重试不确定结果。
- 不向 Bundle ID 非 `com.openai.codex` 的应用输入任何文本。
- 活跃或待批准会话存在时显示，完全空闲或 Codex 退出时隐藏。
- 单环只显示精确周额度；数据不可用时为灰色。
- 用户拖动、右键或已有草稿时不会误触发送。
- 安装和卸载不覆盖或破坏用户已有 Codex Hooks 与配置。

## 11. 兼容性与已知风险

- Codex 注册了 `codex://` URL scheme，但会话路由及 Accessibility 层级可能随桌面版本变化。
  通过版本化 `CodexSessionNavigator` 隔离变化，并在无法验证时安全失败。
- Codex Hooks 会要求用户首次审查和信任；未信任或被组织策略禁用时，状态功能不可用。
- 自然语言批准分类可能有误判。误判只影响按钮是否显示，不绕过发送前安全门。
- App Server 可能暂时不返回七天窗口。规格明确要求显示灰色，不推算或替代数据。

## 12. 官方依据

- Codex Hooks 提供 `session_id`、`UserPromptSubmit`、`Stop` 和
  `last_assistant_message`：<https://learn.chatgpt.com/docs/hooks>
- Codex App Server 提供 `account/rateLimits/read`、`usedPercent`、`windowDurationMins` 与
  `resetsAt`：<https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt>
