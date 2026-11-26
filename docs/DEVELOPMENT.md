# Development / 开发

`Sources` 和 `Resources` 来自已验证的 macOS 本地版本 20261126.22，App 版本 1.4.4。发布的通用包经过签名完整性和 ZIP 校验；本地 105 项检查覆盖真实额度解析、增量会话、任务保留、音量与轴体设置，以及键盘气泡与工作条的兼容。

## 构建

使用 `bash build.sh`。需要 macOS SDK 和 Swift（Xcode Command Line Tools），不需要 Python 图像库或额外依赖。程序保留 `com.chanke.kurocat` bundle identifier 和原设置路径，因此与另一份 KuroCat 不宜同时运行。默认未配置开发者签名时为 ad-hoc；首次或更新后可能需要重新授权输入监控。

## 检查

运行 `bash tests/run.sh`。脚本只在临时副本中把 `UserDefaults.standard` 重定向到随机测试 suite，避免覆盖真实小猫设置。AppKit 的控件检查需要 macOS 图形会话；不会打开真实聊天或执行工具审批。会生成约数十 MB 的临时 JSONL 测试记录和一张离屏设置卡截图；临时目录在脚本退出后清理。

未将本机账户、登录凭据、会话日志、用户偏好或构建缓存放进源码。宣传视频放在 Release 附件中，额度与任务为模拟数据。
