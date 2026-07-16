# Codex 可 App 图标设计

## 目标

将 macOS Dock 中因缺少应用图标而显示的问号替换为清晰的“可”字图标，视觉上与悬浮按钮一致，并在常见 Dock 尺寸下保持可辨认。

## 已选视觉方案

- 使用 macOS 圆角方形图标轮廓。
- 背景为深煤灰色，中央为米白色“可”字。
- “可”字使用系统苹方粗体并按视觉中心校正，不使用生成式图像模型，避免汉字变形。
- 外围使用一圈克制的灰色细环，呼应悬浮按钮的周额度光环。
- 不添加阴影文字、渐变、额外符号或品牌装饰。

## 资源与打包

- 以 1024 × 1024 的确定性矢量式绘制为源，生成 macOS 所需的完整 iconset 尺寸。
- 使用 `iconutil` 生成 `AppIcon.icns`，并把资源复制到 App bundle 的 `Contents/Resources`。
- 在 `Info.plist` 中声明 `CFBundleIconFile = AppIcon`。
- 构建脚本必须在每次 release 打包时重新生成或复制同一份图标资源，保证结果可复现。

## 安装与刷新流程

重新构建并签名 App 后，替换 `~/Applications/Codex 可.app`。保留现有插件、会话状态和权限；只刷新 Dock 图标缓存并重启 Dock，不重复添加 Dock 项。

## 失败处理

- 任一 iconset 尺寸缺失时构建失败，不生成不完整 App。
- `iconutil`、`plutil` 或 `codesign` 验证失败时停止安装。
- Dock 刷新后仍显示问号时，先验证已安装 bundle 内的 `AppIcon.icns` 与 `CFBundleIconFile`，不删除用户其他 Dock 配置。

## 验收

- 源图标中央只出现准确的“可”字，煤灰底、米白字、灰色细环与设计一致。
- `AppIcon.icns` 包含完整尺寸并随 App 打包。
- `plutil`、release build、`codesign --verify --deep --strict` 和全量测试通过。
- 已安装 App 与 Dock 持久项指向同一路径，Dock 不再显示问号，点击仍能启动 App。
- 图标修复不修改插件、Hook、辅助功能权限、登录项或用户会话数据。
